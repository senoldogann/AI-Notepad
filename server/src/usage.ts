import type { Config } from "./config";
import { ApiError } from "./errors";
import { log } from "./log";

/**
 * Claude Haiku 5.5 fiyatları (USD / milyon token). İstem 100K token'a kadar 0,10 / 0,50; üstünde 0,50 / 2,50.
 * Kaynak: Anthropic model belgeleri (claude-api, shared/models.md).
 */
const haikuShortInputUsdPerMTok: number = 0.1;
const haikuShortOutputUsdPerMTok: number = 0.5;
const haikuLongInputUsdPerMTok: number = 0.5;
const haikuLongOutputUsdPerMTok: number = 2.5;
const haikuLongPromptThreshold: number = 100_000;

/** Ay anahtarı "YYYY-MM" (UTC). Saf fonksiyondur. */
export function monthKey(now: Date): string {
  return now.toISOString().slice(0, 7);
}

/** Gün anahtarı "YYYY-MM-DD" (UTC). Saf fonksiyondur. */
export function dayKey(now: Date): string {
  return now.toISOString().slice(0, 10);
}

/** Ayın ilk anı (UTC), milisaniye. Saf fonksiyondur. */
export function monthStartMs(now: Date): number {
  return Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1);
}

/** Sonraki ayın ilk anı (UTC), milisaniye. Saf fonksiyondur. */
export function nextMonthStartMs(now: Date): number {
  return Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1);
}

/** Sonraki günün ilk anı (UTC), milisaniye. Saf fonksiyondur. */
export function nextDayStartMs(now: Date): number {
  return Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
}

/** Claude çağrısının tahmini maliyeti (mikro dolar, yukarı yuvarlanır). Saf fonksiyondur. */
export function llmCostMicroUsd(inputTokens: number, outputTokens: number): number {
  const long: boolean = inputTokens > haikuLongPromptThreshold;
  const inputRate: number = long ? haikuLongInputUsdPerMTok : haikuShortInputUsdPerMTok;
  const outputRate: number = long ? haikuLongOutputUsdPerMTok : haikuShortOutputUsdPerMTok;
  return Math.ceil(inputTokens * inputRate + outputTokens * outputRate);
}

/** Konuşma tanımanın tahmini maliyeti (mikro dolar). `usdPerHour` ek ücretler dahil saatlik fiyattır. Saf fonksiyondur. */
export function transcriptionCostMicroUsd(seconds: number, usdPerHour: number): number {
  return Math.ceil((seconds / 3600) * usdPerHour * 1_000_000);
}

/**
 * Uzun kaydın parçaları (`TRANSCRIBE_MAX_BYTES`, ~49 dk) birer dakika örtüşür (istemci `hostedChunkOverlapSec`):
 * ortak bölgeler ikinci kez yazıya döküldüğü için toplantının ses hakkına her parça sınırı için bir dakika pay eklenir.
 * Sınır sayısı toplantının en uzun süresinin parça adımına (`chunkStepSeconds`, gerçek adımdan biraz kısa: yukarı
 * yuvarlar) bölümüdür; 49 dakikadan kısa toplantıda pay yoktur.
 */
export const chunkOverlapSeconds: number = 60;
export const chunkStepSeconds: number = 2900;

/** Sesin parça sınırlarında ikinci kez yazılan payı (saniye; SQL ifadesi). */
export function chunkOverlapAllowanceSql(seconds: string): string {
  return `CAST((${seconds}) / ${chunkStepSeconds} AS INTEGER) * ${chunkOverlapSeconds}`;
}

/** Sesin parça sınırlarında ikinci kez yazılan payı (saniye). Saf fonksiyondur. */
export function chunkOverlapAllowance(seconds: number): number {
  return Math.trunc(seconds / chunkStepSeconds) * chunkOverlapSeconds;
}

/**
 * Sesin örtüşmesiz süresi (SQL ifadesi): parça sınırlarında ikinci kez yazılan saniyeler düşülür; aylık süreye bu
 * sayılır (örtüşme kullanıcının süresinden yemez).
 */
export function overlapFreeSecondsSql(seconds: string): string {
  return `(${seconds} - ${chunkOverlapAllowanceSql(seconds)})`;
}

/** Aylık süre SQL'inin girdileri: her biri SQL ifadesidir (parametre ya da sütun). */
export interface MonthlyUsageRefs {
  readonly user: string;
  readonly month: string;
  readonly now: string;
  readonly monthStart: string;
}

/**
 * Kullanıcının bu ay sınıra sayılan süresi (saniye; SQL ifadesi): devralınan süre + bu ay başlayan her toplantının
 * süresi ile örtüşmesiz sesinin (kesinleşmiş + süren ayırma; `overlapFreeSecondsSql`) büyüğü + önceki aylarda başlamış toplantıların bu ay yazılan sesi ve
 * süren ayırmaları. Toplantı başına büyüğü alınır: uzun canlı toplantılar ile uzun içe aktarmalar birbirini örtmez
 * (toplamların büyüğü değil).
 */
export function monthlyUsedSecondsSql(refs: MonthlyUsageRefs): string {
  const { user, month, now, monthStart } = refs;
  const thisMonth: string = `user_id = ${user} AND started_at >= ${monthStart}`;
  return `(
    COALESCE((SELECT carried_seconds FROM monthly_usage WHERE user_id = ${user} AND month = ${month}), 0)
    + COALESCE((SELECT SUM(MAX(
        MAX(0, MIN(COALESCE(s.ended_at, ${now}), s.max_ends_at, ${now}) - s.started_at) / 1000.0,
        ${overlapFreeSecondsSql(`s.audio_seconds + COALESCE((SELECT SUM(r.audio_seconds) FROM usage_reservations r WHERE r.meeting_id = s.id AND r.kind = 'audio' AND r.expires_at > ${now}), 0)`)}
      )) FROM meeting_sessions s WHERE s.${thisMonth}), 0)
    + MAX(0, COALESCE((SELECT audio_seconds FROM monthly_usage WHERE user_id = ${user} AND month = ${month}), 0)
      - COALESCE((SELECT SUM(audio_seconds) FROM meeting_sessions WHERE ${thisMonth}), 0))
    + COALESCE((SELECT SUM(r.audio_seconds) FROM usage_reservations r WHERE r.user_id = ${user} AND r.month = ${month} AND r.kind = 'audio'
        AND r.expires_at > ${now} AND r.meeting_id NOT IN (SELECT id FROM meeting_sessions WHERE ${thisMonth})), 0)
  )`;
}

/** Aylık kullanım özeti. */
export interface MonthlyUsage {
  /** Bu ay başlayan toplantıların süresi (açık olanlar şimdiye ya da en çok süreye kadar). */
  readonly meetingSeconds: number;
  /** Kesinleşmiş ses süresi + süresi dolmamış ses ayırmaları. */
  readonly audioSeconds: number;
  /** Aynı kimliğin bu ay silinmiş hesabından devralınan süre (bkz. `trialLedger.ts`). */
  readonly carriedSeconds: number;
  /** Sınıra sayılan süre (bkz. `monthlyUsedSecondsSql`): toplantı başına süre ile sesin büyüğü, devralınan dahil. */
  readonly usedSeconds: number;
}

/** Kullanıcının bu ayki kullanımı. */
export async function monthlyUsage(db: D1Database, userId: string, now: Date): Promise<MonthlyUsage> {
  const nowMs: number = now.getTime();
  const [meetingRow, usageRow, usedRow]: [
    { seconds: number | null } | null,
    { audio_seconds: number; carried_seconds: number } | null,
    { used: number | null } | null,
  ] = await Promise.all([
    db
      .prepare(
        `SELECT SUM(MAX(0, MIN(COALESCE(ended_at, ?), max_ends_at, ?) - started_at)) / 1000.0 AS seconds
         FROM meeting_sessions WHERE user_id = ? AND started_at >= ?`,
      )
      .bind(nowMs, nowMs, userId, monthStartMs(now))
      .first<{ seconds: number | null }>(),
    db
      .prepare(
        `SELECT COALESCE((SELECT audio_seconds FROM monthly_usage WHERE user_id = ?1 AND month = ?2), 0)
           + (SELECT COALESCE(SUM(audio_seconds), 0) FROM usage_reservations WHERE user_id = ?1 AND month = ?2 AND kind = 'audio' AND expires_at > ?3)
           AS audio_seconds,
           COALESCE((SELECT carried_seconds FROM monthly_usage WHERE user_id = ?1 AND month = ?2), 0) AS carried_seconds`,
      )
      .bind(userId, monthKey(now), nowMs)
      .first<{ audio_seconds: number; carried_seconds: number }>(),
    db
      .prepare(`SELECT ${monthlyUsedSecondsSql({ user: "?1", month: "?2", now: "?3", monthStart: "?4" })} AS used`)
      .bind(userId, monthKey(now), nowMs, monthStartMs(now))
      .first<{ used: number | null }>(),
  ]);
  const meetingSeconds: number = Math.ceil(meetingRow?.seconds ?? 0);
  const audioSeconds: number = Math.ceil(usageRow?.audio_seconds ?? 0);
  const carriedSeconds: number = Math.ceil(usageRow?.carried_seconds ?? 0);
  return { meetingSeconds, audioSeconds, carriedSeconds, usedSeconds: Math.ceil(usedRow?.used ?? 0) };
}

/** Bugünkü tahmini toplam harcama (mikro dolar). */
export async function todaySpendMicroUsd(db: D1Database, now: Date): Promise<number> {
  const row: { micro_usd: number } | null = await db
    .prepare("SELECT micro_usd FROM daily_spend WHERE day = ?")
    .bind(dayKey(now))
    .first<{ micro_usd: number }>();
  return row?.micro_usd ?? 0;
}

/** Bugünkü tahmini deneme harcaması (mikro dolar; toplamın parçası). */
export async function todayTrialSpendMicroUsd(db: D1Database, now: Date): Promise<number> {
  const row: { trial_micro_usd: number } | null = await db
    .prepare("SELECT trial_micro_usd FROM daily_spend WHERE day = ?")
    .bind(dayKey(now))
    .first<{ trial_micro_usd: number }>();
  return row?.trial_micro_usd ?? 0;
}

/** Tavan alarmının günlük işaret sütunu (`daily_spend`; sabit ad, kullanıcı girdisi değil). */
type CeilingAlertColumn = "ceiling_alerted_at" | "trial_ceiling_alerted_at";

/**
 * Günün ilk tavan reddi mi: işaret sütunu boşsa doldurur ve true döner; doluysa (alarm bugün yazıldı) false. Gün satırı
 * yoksa (ör. tavan 0) işaretle birlikte eklenir.
 */
async function firstCeilingRefusalToday(db: D1Database, column: CeilingAlertColumn, now: Date): Promise<boolean> {
  const result: D1Result = await db
    .prepare(
      `INSERT INTO daily_spend (day, ${column}) VALUES (?, ?)
       ON CONFLICT(day) DO UPDATE SET ${column} = excluded.${column} WHERE daily_spend.${column} IS NULL`,
    )
    .bind(dayKey(now), now.getTime())
    .run();
  return result.meta.changes === 1;
}

/**
 * Günlük harcama tavanı: aşıldıysa 503 `spend_ceiling_reached` fırlatır; alarm logu günde bir kez (günün ilk reddinde)
 * yazılır, sonraki retler yönetim panelinin sayacında görünür (`opsEvents.ts`). Toplantı başlatmada ve her vekil
 * çağrısında (LLM, konuşma tanıma) denetlenir.
 */
export async function requireSpendHeadroom(db: D1Database, config: Config, now: Date): Promise<void> {
  const spent: number = await todaySpendMicroUsd(db, now);
  if (spent < config.dailySpendCeilingMicroUsd) {
    return;
  }
  if (await firstCeilingRefusalToday(db, "ceiling_alerted_at", now)) {
    log("alert", "daily_spend_ceiling_reached", { day: dayKey(now), spentMicroUsd: spent, ceilingMicroUsd: config.dailySpendCeilingMicroUsd });
  }
  throw new ApiError("spend_ceiling_reached", "Servis bugün yoğun; şu an yeni istek alınamıyor. Lütfen daha sonra yeniden dene.");
}

/**
 * Günlük deneme harcaması tavanı: bugünkü deneme harcaması `dailyTrialSpendCeilingMicroUsd`'e ulaştıysa 503
 * `trial_capacity_reached` fırlatır; alarm logu günde bir kez yazılır (`requireSpendHeadroom` gibi). Deneme harcaması
 * açan her yolda denetlenir: yeni deneme toplantısı, denemedeki hesap çağrısı (toplantı dışı yapay zekâ), açık ya da
 * yeniden açılmış deneme toplantısının yapay zekâ ve yazıya dökme çağrıları ve deneme toplantısını yeniden işleme.
 * Kötüye kullanılan deneme genel tavanı (`requireSpendHeadroom`) tüketip aboneleri durduramasın diye ayrıdır; aboneler
 * yalnızca genel tavana tabidir.
 */
export async function requireTrialSpendHeadroom(db: D1Database, config: Config, now: Date): Promise<void> {
  const spent: number = await todayTrialSpendMicroUsd(db, now);
  if (spent < config.dailyTrialSpendCeilingMicroUsd) {
    return;
  }
  if (await firstCeilingRefusalToday(db, "trial_ceiling_alerted_at", now)) {
    log("alert", "daily_trial_spend_ceiling_reached", { day: dayKey(now), spentMicroUsd: spent, ceilingMicroUsd: config.dailyTrialSpendCeilingMicroUsd });
  }
  throw new ApiError("trial_capacity_reached", "Ücretsiz denemeler bugün kapasitede; yarın yeniden dene ya da abone ol.");
}
