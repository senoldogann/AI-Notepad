import { z } from "zod";
import type { Config, DeepgramConfig } from "./config";
import { crossedThreshold } from "./elevenLabsCapacity";
import { ApiError, UpstreamError } from "./errors";
import { log } from "./log";
import type { MeetingRow } from "./meetings";
import type { Platform } from "./platform";
import { fetchUpstream } from "./upstream";

/**
 * Deepgram canlı metni (abonelik sürümü). Mac uygulaması sesi Deepgram'a doğrudan akıtır; sunucu yalnızca kısa ömürlü
 * jeton verir (`POST https://api.deepgram.com/v1/auth/grant`, anahtar yalnızca Worker'da). Jeton yalnızca bağlantı
 * kurulurken geçerli olmalıdır; kurulan akış jetonun süresi dolsa da sürer. Her bağlantı ve yeniden bağlanma yeni jeton
 * ister; toplantı başına en çok `deepgramGrantsPerMeeting` jeton.
 *
 * Bütçe: sahibin Deepgram ücretsiz kredisinin bir kısmı (`DEEPGRAM_BUDGET_USD`, ömür boyu). Sunucu akışı görmediği için
 * harcama tahminidir ve temkinlidir: toplantının ilk jetonunda toplantının kalan en çok süresi × akış sayısı
 * (`deepgramStreamsPerMeeting`) peşin sayılır; toplantı bitince (`settleDeepgramMeetings`) gerçek süreye (ilk jetondan
 * bitişe) indirilir. Tahmini harcama bütçeye ulaşınca yeni toplantıya jeton verilmez (`503 deepgram_unavailable`) ve
 * `/v1/me` canlı motoru `whisperkit` der; jeton almış toplantının yeniden bağlanmaları sürer (süresi zaten sayıldı).
 */

/** Jeton isteği adresi. */
export const deepgramGrantUrl: string = "https://api.deepgram.com/v1/auth/grant";

/** Jetonun ömrü (saniye): yalnızca bağlantı kurulurken gerekir, olabildiğince kısa. */
export const deepgramGrantTtlSeconds: number = 30;

/** Toplantı başına en çok jeton: iki akışın ilk bağlantıları ve yeniden bağlanmaları. */
export const deepgramGrantsPerMeeting: number = 30;

/** Toplantı başına en çok eşzamanlı akış ("Sen" ve "Diğerleri"); peşin tahmin bununla çarpılır. */
export const deepgramStreamsPerMeeting: number = 2;

/** İstemcinin kullanacağı model (Nova-3; dil istemcide toplantı dilinden seçilir). */
export const deepgramLiveModel: string = "nova-3";

/** Yeniden deneme dahil en çok deneme (5xx, 429, ağ hatası, zaman aşımı). */
const grantAttempts: number = 3;

/** Deneme başına zaman aşımı. */
const grantTimeoutMs: number = 10_000;

/** İstemciye bildirilen canlı metin motoru. */
export type LiveEngine = "deepgram" | "whisperkit";

/** `POST /v1/live/deepgram-token` yanıtı. Jeton loglanmaz ve sunucuda saklanmaz. */
export interface DeepgramGrant {
  /** Deepgram JWT'si; istemci `Authorization: Bearer <jeton>` ile bağlanır. */
  readonly accessToken: string;
  /** Jetonun kalan ömrü (saniye). */
  readonly expiresIn: number;
  readonly model: string;
  /** İstemci akış adresine `mip_opt_out=true` ekler: Deepgram ses ve metni model geliştirmede kullanmaz, saklamaz. */
  readonly mipOptOut: true;
  /** Bu toplantıda kalan jeton. */
  readonly grantsLeft: number;
}

/** Yönetici istatistiğindeki Deepgram bütçe durumu. */
export interface DeepgramUsage {
  readonly policy: "on" | "off";
  readonly budgetUsd: number;
  /** Tahmini harcama (peşin sayılan açık toplantılar dahil). */
  readonly estimatedUsd: number;
  /** Tahmini harcamanın bütçeye oranı (yüzde, bir ondalık). */
  readonly percent: number;
  /** Bütçeye sayılan akış dakikası (tüm akışlar toplamı). */
  readonly streamMinutes: number;
  /** Deepgram jetonu almış toplantı sayısı ve henüz gerçek süreye indirilmemiş (süren) olanlar. */
  readonly meetings: number;
  readonly openMeetings: number;
  readonly usdPerMinute: number;
}

const grantResponseSchema = z.object({ access_token: z.string().min(1), expires_in: z.number().positive().optional() });

/** Bütçenin akış saniyesi karşılığı. Saf fonksiyondur. */
export function deepgramBudgetSeconds(deepgram: DeepgramConfig): number {
  return Math.floor((deepgram.budgetMicroUsd * 60) / deepgram.microUsdPerMinute);
}

/** Toplantının kalan en çok süresinin tüm akışlar için saniyesi (ilk jetondaki peşin tahmin). Saf fonksiyondur. */
export function upfrontChargeSeconds(meeting: MeetingRow, now: Date): number {
  return Math.ceil(Math.max(0, meeting.max_ends_at - now.getTime()) / 1000) * deepgramStreamsPerMeeting;
}

/** Akış saniyesinden bütçe durumu. Saf fonksiyondur. */
export function deepgramUsageOf(deepgram: DeepgramConfig, seconds: number, meetings: number, openMeetings: number): DeepgramUsage {
  const microUsd: number = (seconds * deepgram.microUsdPerMinute) / 60;
  return {
    policy: deepgram.access.policy,
    budgetUsd: deepgram.budgetMicroUsd / 1_000_000,
    estimatedUsd: Math.round(microUsd / 10_000) / 100,
    percent: Math.round((microUsd / deepgram.budgetMicroUsd) * 1000) / 10,
    streamMinutes: Math.round(seconds / 60),
    meetings,
    openMeetings,
    usdPerMinute: deepgram.microUsdPerMinute / 1_000_000,
  };
}

/** Bütçeye sayılan toplam akış saniyesi. */
async function chargedSeconds(db: D1Database): Promise<number> {
  const row: { seconds: number } | null = await db
    .prepare("SELECT COALESCE(SUM(charged_seconds), 0) AS seconds FROM deepgram_live_meetings")
    .first<{ seconds: number }>();
  return row?.seconds ?? 0;
}

/** Yönetici istatistiği: bütçe, tahmini harcama ve toplantı sayıları. */
export async function deepgramUsage(db: D1Database, config: Config): Promise<DeepgramUsage> {
  const row: { seconds: number; meetings: number; open: number } | null = await db
    .prepare(
      `SELECT COALESCE(SUM(charged_seconds), 0) AS seconds, COUNT(*) AS meetings,
         COALESCE(SUM(CASE WHEN settled_at IS NULL THEN 1 ELSE 0 END), 0) AS open
       FROM deepgram_live_meetings`,
    )
    .first<{ seconds: number; meetings: number; open: number }>();
  return deepgramUsageOf(config.deepgram, row?.seconds ?? 0, row?.meetings ?? 0, row?.open ?? 0);
}

/**
 * Yeni toplantının canlı metin motoru: politika açık ve tahmini harcama bütçenin altındaysa `deepgram`, değilse
 * `whisperkit` (`/v1/me`). Yalnızca okur.
 */
export async function liveEngine(db: D1Database, config: Config): Promise<LiveEngine> {
  if (config.deepgram.access.policy === "off") {
    return "whisperkit";
  }
  return (await chargedSeconds(db)) < deepgramBudgetSeconds(config.deepgram) ? "deepgram" : "whisperkit";
}

/**
 * Biten toplantıların peşin tahminini gerçek süreye indirir: toplantı bittiyse (kullanıcı bitirdi ya da yeni toplantı
 * başlayınca kapandı), en çok süresi geçtiyse ya da silindiyse (hesap silme, saklama süresi; tahmin olduğu gibi kalır).
 * Gerçek süre = akış sayısı × (bitiş − ilk jeton); tahmin yalnızca küçülür. İndirilen satır sayısını döndürür.
 */
export async function settleDeepgramMeetings(db: D1Database, now: Date): Promise<number> {
  const result: D1Result = await db
    .prepare(
      `UPDATE deepgram_live_meetings
       SET charged_seconds = MIN(charged_seconds, COALESCE((
             SELECT ?1 * MAX(0, CAST((MIN(COALESCE(m.ended_at, m.max_ends_at), m.max_ends_at) - deepgram_live_meetings.first_grant_at + 999) / 1000 AS INTEGER))
             FROM meeting_sessions m WHERE m.id = deepgram_live_meetings.meeting_id), charged_seconds)),
         settled_at = ?2
       WHERE settled_at IS NULL
         AND NOT EXISTS (SELECT 1 FROM meeting_sessions m WHERE m.id = deepgram_live_meetings.meeting_id AND m.ended_at IS NULL AND m.max_ends_at > ?2)`,
    )
    .bind(deepgramStreamsPerMeeting, now.getTime())
    .run();
  return result.meta.changes;
}

/** Toplantının jeton sayısı; jeton almamışsa null. */
async function meetingGrants(db: D1Database, meetingId: string): Promise<number | null> {
  const row: { grants: number } | null = await db
    .prepare("SELECT grants FROM deepgram_live_meetings WHERE meeting_id = ?")
    .bind(meetingId)
    .first<{ grants: number }>();
  return row?.grants ?? null;
}

/** Jeton almış toplantının jeton sayısını sınırın altındaysa artırır; yeni sayıyı ya da (satır yok ya da sınırda) null döndürür. */
async function incrementGrant(db: D1Database, meetingId: string): Promise<number | null> {
  const row: { grants: number } | null = await db
    .prepare("UPDATE deepgram_live_meetings SET grants = grants + 1 WHERE meeting_id = ? AND grants < ? RETURNING grants")
    .bind(meetingId, deepgramGrantsPerMeeting)
    .first<{ grants: number }>();
  return row?.grants ?? null;
}

/**
 * Toplantının ilk jetonu: satır yalnızca tahmini harcama bütçenin altındaysa eklenir (tek koşullu ifade); peşin tahmin
 * `chargeSeconds`. Eklendiyse true.
 */
async function insertFirstGrant(db: D1Database, meetingId: string, chargeSeconds: number, budgetSeconds: number, now: Date): Promise<boolean> {
  const row: { grants: number } | null = await db
    .prepare(
      `INSERT INTO deepgram_live_meetings (meeting_id, grants, first_grant_at, charged_seconds, settled_at)
       SELECT ?, 1, ?, ?, NULL WHERE (SELECT COALESCE(SUM(charged_seconds), 0) FROM deepgram_live_meetings) < ?
       ON CONFLICT(meeting_id) DO NOTHING RETURNING grants`,
    )
    .bind(meetingId, now.getTime(), chargeSeconds, budgetSeconds)
    .first<{ grants: number }>();
  return row !== null;
}

/** Bütçe dolu hatası. */
function budgetExhausted(): ApiError {
  return new ApiError("deepgram_unavailable", "Bulut canlı metni şu an kullanılamıyor; canlı metin Mac'te üretilir.");
}

/** Toplantının jeton sınırı doldu hatası. */
function grantLimitReached(): ApiError {
  return new ApiError("deepgram_grant_limit", "Bu toplantıda bulut canlı metnine çok sık yeniden bağlanıldı; canlı metin Mac'te sürer.");
}

/**
 * Jeton hakkını ayırır: jeton almış toplantının sayacı artar (sınırda `deepgram_grant_limit`); ilk jetonda bütçe
 * koşuluyla satır eklenir (bütçe dolduysa `deepgram_unavailable`). Eşzamanlı ilk jetonlarda ekleme yarışı kaybeden
 * istek sayacı artırır. Bütçe eşiği (%80, %95) aşılınca `alert` yazar. Toplantının jeton sayısını döndürür.
 */
async function reserveGrant(db: D1Database, deepgram: DeepgramConfig, meeting: MeetingRow, now: Date): Promise<number> {
  const incremented: number | null = await incrementGrant(db, meeting.id);
  if (incremented !== null) {
    return incremented;
  }
  const budgetSeconds: number = deepgramBudgetSeconds(deepgram);
  const before: number = await chargedSeconds(db);
  const charge: number = upfrontChargeSeconds(meeting, now);
  if (await insertFirstGrant(db, meeting.id, charge, budgetSeconds, now)) {
    // Eşikler ElevenLabs kapasitesiyle aynıdır (%80, %95).
    const threshold: number | null = crossedThreshold(before, before + charge, budgetSeconds);
    if (threshold !== null) {
      const usage: DeepgramUsage = deepgramUsageOf(deepgram, before + charge, 0, 0);
      log("alert", "deepgram_budget_threshold", { threshold, estimatedUsd: usage.estimatedUsd, budgetUsd: usage.budgetUsd, percent: usage.percent });
    }
    return 1;
  }
  const raced: number | null = await incrementGrant(db, meeting.id);
  if (raced !== null) {
    return raced;
  }
  if ((await meetingGrants(db, meeting.id)) !== null) {
    throw grantLimitReached();
  }
  const usage: DeepgramUsage = deepgramUsageOf(deepgram, before, 0, 0);
  log("warn", "deepgram_budget_exhausted", { meetingId: meeting.id, estimatedUsd: usage.estimatedUsd, budgetUsd: usage.budgetUsd, percent: usage.percent });
  throw budgetExhausted();
}

/**
 * Deepgram'dan kısa ömürlü jeton ister (`Authorization: Token <anahtar>`, `{"ttl_seconds": 30}`). 5xx, 429, ağ hatası
 * ve zaman aşımı uyarıyla `grantAttempts` kez denenir, sonra `UpstreamError` (gövde okunmaz). Yanıt beklenen biçimde
 * değilse `UpstreamError` (yeniden denenmez). Jeton loglanmaz.
 */
async function requestDeepgramToken(platform: Platform, apiKey: string): Promise<{ accessToken: string; expiresIn: number }> {
  const response: Response = await fetchUpstream(
    platform,
    "deepgram",
    deepgramGrantUrl,
    (): RequestInit => ({
      method: "POST",
      headers: { authorization: `Token ${apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({ ttl_seconds: deepgramGrantTtlSeconds }),
    }),
    grantAttempts,
    grantTimeoutMs,
  );
  let json: unknown;
  try {
    json = await response.json();
  } catch (error: unknown) {
    if (error instanceof SyntaxError) {
      throw new UpstreamError("deepgram", response.status, false, "jeton yanıtı JSON değil");
    }
    throw error;
  }
  const parsed = grantResponseSchema.safeParse(json);
  if (!parsed.success) {
    throw new UpstreamError("deepgram", response.status, false, "jeton yanıtı beklenen biçimde değil");
  }
  // `expires_in` Deepgram'da isteğe bağlıdır; yoksa jetonun ömrü istenen süredir.
  return { accessToken: parsed.data.access_token, expiresIn: parsed.data.expires_in ?? deepgramGrantTtlSeconds };
}

/**
 * Açık toplantıya Deepgram jetonu verir. Politika kapalıysa ya da bütçe dolduysa `deepgram_unavailable`; toplantı
 * bitmişse (ek süre dahil: canlı metin yalnızca kayıt sırasında) `meeting_not_active`; jeton sınırı dolduysa
 * `deepgram_grant_limit`. Önce biten toplantıların tahmini indirilir ve hak okunur (boşuna Deepgram çağrılmasın),
 * sonra jeton alınır, sonra hak tek koşullu ifadeyle ayrılır (ayrılamazsa alınan jeton atılır; kullanılmayan jeton
 * ücretsizdir).
 */
export async function issueDeepgramGrant(db: D1Database, platform: Platform, config: Config, meeting: MeetingRow, now: Date): Promise<DeepgramGrant> {
  const access: Config["deepgram"]["access"] = config.deepgram.access;
  if (access.policy === "off") {
    throw budgetExhausted();
  }
  if (meeting.ended_at !== null || now.getTime() >= meeting.max_ends_at) {
    throw new ApiError("meeting_not_active", "Toplantı kaydı bitti; bulut canlı metni yalnızca kayıt sırasında kullanılır.");
  }
  await settleDeepgramMeetings(db, now);
  const grants: number | null = await meetingGrants(db, meeting.id);
  if (grants !== null && grants >= deepgramGrantsPerMeeting) {
    throw grantLimitReached();
  }
  if (grants === null && (await chargedSeconds(db)) >= deepgramBudgetSeconds(config.deepgram)) {
    throw budgetExhausted();
  }
  const token: { accessToken: string; expiresIn: number } = await requestDeepgramToken(platform, access.apiKey);
  const reserved: number = await reserveGrant(db, config.deepgram, meeting, now);
  log("info", "deepgram_grant_issued", { userId: meeting.user_id, meetingId: meeting.id, grants: reserved });
  return {
    accessToken: token.accessToken,
    expiresIn: token.expiresIn,
    model: deepgramLiveModel,
    mipOptOut: true,
    grantsLeft: deepgramGrantsPerMeeting - reserved,
  };
}
