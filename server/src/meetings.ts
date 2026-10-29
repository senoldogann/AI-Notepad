import type { Config } from "./config";
import { randomId } from "./crypto";
import { type DeviceBits, queryDeviceBits, updateDeviceBits } from "./deviceCheck";
import {
  type TrialState,
  deviceTrialMeetingsUsed,
  hasSubscriptionAccess,
  isTrialExpired,
  subscriptionState,
  trialMeetingsLeft,
  userTrialState,
} from "./entitlements";
import { settleDeepgramMeetings } from "./deepgram";
import { ApiError } from "./errors";
import { log } from "./log";
import type { Platform } from "./platform";
import { type MonthlyUsage, dayKey, monthlyUsage, requireSpendHeadroom, requireTrialSpendHeadroom } from "./usage";

/** Yeni toplantı oturumu. */
export interface StartedMeeting {
  readonly meetingId: string;
  readonly kind: "trial" | "subscription";
  readonly tokenBudget: number;
  readonly maxDurationMinutes: number;
  readonly expiresAt: string;
  readonly trialMeetingsLeft: number | null;
}

/** Veritabanındaki toplantı oturumu. */
export interface MeetingRow {
  readonly id: string;
  readonly user_id: string;
  readonly kind: "trial" | "subscription";
  readonly started_at: number;
  readonly max_ends_at: number;
  readonly ended_at: number | null;
  readonly minutes: number | null;
  readonly token_budget: number;
  readonly tokens_used: number;
  readonly audio_seconds: number;
  /** 1: gerçek ses süresi ayrılanı aştı, toplantının ses hakkı kapandı. */
  readonly transcription_closed: number;
  /** `ended`: kullanıcı bitirdi (not için ek süre); `superseded`: yeni toplantı başlayınca kapandı (ek süre yok). */
  readonly end_reason: "ended" | "superseded" | null;
}

/** Toplantı başlatma isteğinin kötüye kullanım bilgileri. */
export interface MeetingStartRequest {
  /** Doğrulanmış App Attest cihazı (bildirildiyse). */
  readonly deviceId: string | null;
  /** İstemci IP'sinin HMAC özeti (yeni hesap başına günlük deneme sınırı). */
  readonly clientIpHash: string;
  /** İstemcinin Apple DeviceCheck jetonu (base64); deneme toplantısında gerekebilir (`requireTrialDevice`). */
  readonly deviceCheckToken: string | null;
}

/** SQL bağ değeri. */
type SqlValue = string | number | null;

/** Toplantı eklemenin ek koşulu: SQL ifadesi ve bağları (deneme hakları gibi). */
interface StartGate {
  readonly sql: string;
  readonly binds: readonly SqlValue[];
}

/** Eklenecek toplantı satırı. */
interface NewMeeting {
  readonly id: string;
  readonly userId: string;
  readonly deviceId: string | null;
  readonly kind: "trial" | "subscription";
  readonly maxEndsAt: number;
  readonly tokenBudget: number;
}

/** Abonelik toplantısının ek koşulu yoktur: aylık sınır eklemeden önce denetlenir. */
const noGate: StartGate = { sql: "1", binds: [] };

/**
 * Toplantıyı tek D1 toplu işleminde (tek işlem) ekler. Satır yalnızca kullanıcının bugünkü başlatma sayısı
 * `maxMeetingStartsPerDay` altındaysa ve `gate` sağlanıyorsa eklenir. Eklenirse aynı işlemde günlük başlatma sayısı
 * artar ve kullanıcının açık toplantısı ek süresiz kapanır (`superseded`; aynı anda tek toplantı, yeniden başlatarak
 * bütçe katlanamaz). Eklenmezse hiçbir sayaç ve açık toplantı değişmez. `followUps` eklemeden sonra çalışır ve kendi
 * "toplantı eklendi mi" koşulunu taşır. Eklendiyse true döner.
 */
async function insertMeeting(
  db: D1Database,
  config: Config,
  meeting: NewMeeting,
  gate: StartGate,
  followUps: readonly D1PreparedStatement[],
  now: Date,
): Promise<boolean> {
  const day: string = dayKey(now);
  const nowMs: number = now.getTime();
  const results: D1Result[] = await db.batch([
    db.prepare("INSERT OR IGNORE INTO daily_usage (user_id, day) VALUES (?, ?)").bind(meeting.userId, day),
    db
      .prepare(
        `INSERT INTO meeting_sessions (id, user_id, device_id, kind, started_at, max_ends_at, token_budget)
         SELECT ?, ?, ?, ?, ?, ?, ?
         WHERE (SELECT meetings_started FROM daily_usage WHERE user_id = ? AND day = ?) < ? AND (${gate.sql})`,
      )
      .bind(
        meeting.id,
        meeting.userId,
        meeting.deviceId,
        meeting.kind,
        nowMs,
        meeting.maxEndsAt,
        meeting.tokenBudget,
        meeting.userId,
        day,
        config.maxMeetingStartsPerDay,
        ...gate.binds,
      ),
    db
      .prepare(
        `UPDATE daily_usage SET meetings_started = meetings_started + 1
         WHERE user_id = ? AND day = ? AND EXISTS (SELECT 1 FROM meeting_sessions WHERE id = ?)`,
      )
      .bind(meeting.userId, day, meeting.id),
    db
      .prepare(
        `UPDATE meeting_sessions
         SET ended_at = MIN(?, max_ends_at), minutes = CAST((MIN(?, max_ends_at) - started_at + 59999) / 60000 AS INTEGER),
           end_reason = 'superseded'
         WHERE user_id = ? AND ended_at IS NULL AND id <> ? AND EXISTS (SELECT 1 FROM meeting_sessions WHERE id = ?)`,
      )
      .bind(nowMs, nowMs, meeting.userId, meeting.id, meeting.id),
    ...followUps,
  ]);
  return results[1]?.meta.changes === 1;
}

/** Kullanıcı bugün `maxMeetingStartsPerDay` toplantı başlattıysa `daily_cap_reached` fırlatır. */
async function requireDailyStartLeft(db: D1Database, config: Config, userId: string, now: Date): Promise<void> {
  const row: { meetings_started: number } | null = await db
    .prepare("SELECT meetings_started FROM daily_usage WHERE user_id = ? AND day = ?")
    .bind(userId, dayKey(now))
    .first<{ meetings_started: number }>();
  if ((row?.meetings_started ?? 0) >= config.maxMeetingStartsPerDay) {
    throw new ApiError("daily_cap_reached", `Bugün en çok ${config.maxMeetingStartsPerDay} toplantı başlatılabilir; yarın yeniden dene.`);
  }
}

/**
 * Toplantı oturumu açar. Günlük harcama tavanı aşıldıysa 503; deneme toplantısında günlük deneme harcaması tavanı
 * aşıldıysa da 503 (`trial_capacity_reached`). Abonelik erişimi varsa (`past_due` ek süresi dahil) aylık sınırın
 * altında olmak gerekir (oturum süresi kalan aylık süreyle de sınırlanır); yoksa bir deneme toplantısı düşer (önce
 * `requireTrialDevice`, sonra `startTrialMeeting`); abonelik toplantısı DeviceCheck istemez. Kullanıcı bugün
 * `maxMeetingStartsPerDay` toplantı başlattıysa 429. Denetimler eklemeden önce ya da eklemeyle aynı işlemde yapılır:
 * reddedilen başlatma açık toplantıyı kapatmaz ve günlük başlatma hakkı harcamaz.
 */
export async function startMeeting(
  db: D1Database,
  platform: Platform,
  config: Config,
  userId: string,
  request: MeetingStartRequest,
  now: Date,
): Promise<StartedMeeting> {
  await requireSpendHeadroom(db, config, now);
  if (!hasSubscriptionAccess(await subscriptionState(db, userId), now, config.pastDueGraceMs)) {
    await requireTrialSpendHeadroom(db, config, now);
    await requireTrialDevice(db, platform, config, userId, request.deviceCheckToken, now);
    return startTrialMeeting(db, config, userId, request.deviceId, request.clientIpHash, now);
  }
  const deviceId: string | null = request.deviceId;
  const usage: MonthlyUsage = await monthlyUsage(db, userId, now);
  const remainingSeconds: number = config.monthlyCapSeconds - usage.usedSeconds;
  if (remainingSeconds <= 0) {
    throw new ApiError("monthly_cap_reached", "Bu ayki kullanım sınırına ulaştın; sınır ay başında sıfırlanır.");
  }
  const meetingId: string = randomId();
  const maxMinutes: number = Math.max(1, Math.min(config.subscriberMaxMeetingMinutes, Math.floor(remainingSeconds / 60)));
  const maxEndsAt: number = now.getTime() + maxMinutes * 60_000;
  const meeting: NewMeeting = {
    id: meetingId,
    userId,
    deviceId,
    kind: "subscription",
    maxEndsAt,
    tokenBudget: config.subscriberMeetingTokenBudget,
  };
  if (!(await insertMeeting(db, config, meeting, noGate, [], now))) {
    await requireDailyStartLeft(db, config, userId, now);
    log("error", "meeting_insert_failed", { userId, kind: "subscription" });
    throw new ApiError("internal_error", "Toplantı başlatılamadı; yeniden dene.");
  }
  log("info", "meeting_started", { userId, meetingId, kind: "subscription", attested: deviceId !== null });
  return {
    meetingId,
    kind: "subscription",
    tokenBudget: config.subscriberMeetingTokenBudget,
    maxDurationMinutes: maxMinutes,
    expiresAt: new Date(maxEndsAt).toISOString(),
    trialMeetingsLeft: null,
  };
}

/**
 * Deneme için Mac denetimi (Apple DeviceCheck, `bit0` = "bu Mac bir hesaba deneme verdi"). Politika `off` ise, hesabın
 * denemesi zaten bir Mac'e bağlandıysa (`users.trial_device_verified_at`) ya da hesabın denemesi bittiyse (toplantılar
 * harcandı ya da süre doldu; kapı `trial_exhausted` verir, Mac boşuna işaretlenmez) bir şey yapmaz. Yoksa jeton
 * gerekir (`device_check_required`); `bit0` doluysa `trial_device_used`. Boşsa önce Mac işaretlenir (`bit0` = true, `bit1` okunduğu gibi), sonra hesap
 * doğrulanmış sayılır: hesabın sonraki deneme toplantıları jeton istemez. Mac kapıdan (IP sınırı) önce işaretlenir;
 * kapı reddederse Mac yine bu hesabındır ve hesap yeniden deneyebilir. Apple karşılaştır-yaz sunmaz: aynı Mac'te iki
 * hesabın aynı anda ilk denemesi ikisine de geçebilir (kabul edilen yarış).
 */
async function requireTrialDevice(
  db: D1Database,
  platform: Platform,
  config: Config,
  userId: string,
  deviceCheckToken: string | null,
  now: Date,
): Promise<void> {
  const deviceCheck: Config["deviceCheck"] = config.deviceCheck;
  if (deviceCheck.policy === "off") {
    return;
  }
  const row: { verified_at: number | null } | null = await db
    .prepare("SELECT trial_device_verified_at AS verified_at FROM users WHERE id = ?")
    .bind(userId)
    .first<{ verified_at: number | null }>();
  if (row === null || row.verified_at !== null || trialMeetingsLeft(await userTrialState(db, userId), config, now) === 0) {
    return;
  }
  if (deviceCheckToken === null) {
    throw new ApiError("device_check_required", "Ücretsiz deneme için bu Mac'in Apple DeviceCheck jetonu gerekiyor; uygulamayı güncelle.");
  }
  const bits: DeviceBits = await queryDeviceBits(platform, deviceCheck, deviceCheckToken, now);
  if (bits.bit0) {
    log("info", "trial_refused", { userId, attested: false, reason: "device_used" });
    throw new ApiError("trial_device_used", "Bu Mac'te ücretsiz deneme daha önce başka bir hesapla kullanıldı. Devam etmek için abone ol.");
  }
  await updateDeviceBits(platform, deviceCheck, deviceCheckToken, { bit0: true, bit1: bits.bit1 }, now);
  await db
    .prepare("UPDATE users SET trial_device_verified_at = ? WHERE id = ? AND trial_device_verified_at IS NULL")
    .bind(now.getTime(), userId)
    .run();
  log("info", "trial_device_claimed", { userId });
}

/**
 * Deneme toplantısı. Her hesabın doğrulanmış bir kimliği vardır (Apple ya da Google `sub`; hesap başka yoldan
 * oluşmaz). Hak dört koşula bağlıdır:
 * - hesap başına `trialMeetings` toplantı; aynı kimliğin silinmiş hesaplarının harcadığı denemeler de sayılır
 *   (`users.carried_trial_meetings`, bkz. `trialLedger.ts`);
 * - deneme süresi (`trialDurationMs`) dolmamış olmalı: süre hesabın ilk deneme toplantısıyla başlar
 *   (`users.trial_started_at`, ilk toplantıyla aynı işlemde yazılır; silinmiş hesaptan devralınabilir) ve dolunca
 *   kullanılmamış toplantılar da düşer;
 * - doğrulanmış cihaz bildirildiyse cihaz başına `trialMeetings` toplantı (yeni hesap aynı cihazda yeni deneme almaz);
 * - hesabın ilk denemesiyse, aynı IP'den (HMAC özeti) bugün denemeye başlamış hesap sayısı (silinmiş hesaplar dahil)
 *   `trialAccountsPerIpPerDay` altında olmalı. Denemeyi devralan (yeniden açılmış) hesap yeni deneme hesabı sayılmaz.
 * Koşullar, günlük başlatma sınırı ve ekleme tek toplu işlemdir (D1 işlemi): eşzamanlı istekler sınırları aşamaz.
 */
async function startTrialMeeting(
  db: D1Database,
  config: Config,
  userId: string,
  deviceId: string | null,
  clientIpHash: string,
  now: Date,
): Promise<StartedMeeting> {
  const meetingId: string = randomId();
  const day: string = dayKey(now);
  const maxEndsAt: number = now.getTime() + config.trialMaxMeetingMinutes * 60_000;
  const gate: StartGate = {
    sql: `(SELECT COUNT(*) FROM meeting_sessions WHERE user_id = ? AND kind = 'trial')
        + (SELECT carried_trial_meetings FROM users WHERE id = ?) < ?
      AND COALESCE((SELECT trial_started_at FROM users WHERE id = ?) + ?, ? + 1) > ?
      AND (? IS NULL OR (SELECT COUNT(*) FROM meeting_sessions WHERE device_id = ? AND kind = 'trial') < ?)
      AND (EXISTS (SELECT 1 FROM meeting_sessions WHERE user_id = ? AND kind = 'trial')
        OR (SELECT carried_trial_meetings FROM users WHERE id = ?) > 0
        OR (SELECT COUNT(*) FROM trial_starts WHERE ip_hash = ? AND day = ?)
          + COALESCE((SELECT accounts FROM deleted_trial_starts WHERE ip_hash = ? AND day = ?), 0) < ?)`,
    binds: [
      userId,
      userId,
      config.trialMeetings,
      userId,
      config.trialDurationMs,
      now.getTime(),
      now.getTime(),
      deviceId,
      deviceId,
      config.trialMeetings,
      userId,
      userId,
      clientIpHash,
      day,
      clientIpHash,
      day,
      config.trialAccountsPerIpPerDay,
    ],
  };
  // Yalnızca hesabın ilk deneme toplantısı IP sayacına girer (denemeyi devralan hesabınki girmez): eski günlerin
  // satırları temizlikte silinir (`cleanup.ts`), "denemeye başlamış mı" sorusu toplantılardan yanıtlanır.
  const recordTrialStart: D1PreparedStatement = db
    .prepare(
      `INSERT OR IGNORE INTO trial_starts (user_id, ip_hash, day, created_at)
       SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM meeting_sessions WHERE id = ?)
         AND (SELECT COUNT(*) FROM meeting_sessions WHERE user_id = ? AND kind = 'trial') = 1
         AND (SELECT carried_trial_meetings FROM users WHERE id = ?) = 0`,
    )
    .bind(userId, clientIpHash, day, now.getTime(), meetingId, userId, userId);
  // Denemenin süresi ilk deneme toplantısıyla başlar (devralınmış başlangıç korunur).
  const recordTrialStartedAt: D1PreparedStatement = db
    .prepare("UPDATE users SET trial_started_at = ? WHERE id = ? AND trial_started_at IS NULL AND EXISTS (SELECT 1 FROM meeting_sessions WHERE id = ?)")
    .bind(now.getTime(), userId, meetingId);
  const meeting: NewMeeting = { id: meetingId, userId, deviceId, kind: "trial", maxEndsAt, tokenBudget: config.trialMeetingTokenBudget };
  const inserted: boolean = await insertMeeting(db, config, meeting, gate, [recordTrialStart, recordTrialStartedAt], now);
  if (!inserted) {
    await requireDailyStartLeft(db, config, userId, now);
  }
  const trial: TrialState = await userTrialState(db, userId);
  const deviceUsed: number | null = deviceId === null ? null : await deviceTrialMeetingsUsed(db, deviceId);
  if (!inserted) {
    throw trialRefusal(config, userId, deviceId, trial, deviceUsed, now);
  }
  log("info", "meeting_started", { userId, meetingId, kind: "trial", attested: deviceId !== null });
  return {
    meetingId,
    kind: "trial",
    tokenBudget: config.trialMeetingTokenBudget,
    maxDurationMinutes: config.trialMaxMeetingMinutes,
    expiresAt: new Date(maxEndsAt).toISOString(),
    trialMeetingsLeft: Math.max(0, config.trialMeetings - Math.max(trial.used, deviceUsed ?? 0)),
  };
}

/**
 * Reddedilen deneme başlatmanın hatası (nedeni loglanır): toplantılar harcandıysa (hesap ya da cihaz) ya da süre
 * dolduysa `trial_exhausted` (0.1.4 Mac uygulaması da bu kodu tanır), değilse IP başına günlük sınır `trial_ip_limit`.
 */
function trialRefusal(config: Config, userId: string, deviceId: string | null, trial: TrialState, deviceUsed: number | null, now: Date): ApiError {
  const usedUp: boolean = trial.used >= config.trialMeetings || (deviceUsed ?? 0) >= config.trialMeetings;
  const expired: boolean = !usedUp && isTrialExpired(trial, config.trialDurationMs, now);
  const reason: string = usedUp ? "exhausted" : expired ? "expired" : "ip_daily_limit";
  log("info", "trial_refused", { userId, attested: deviceId !== null, reason });
  if (usedUp) {
    return new ApiError("trial_exhausted", "Ücretsiz deneme toplantıların bitti (hesap ya da bu cihaz için). Devam etmek için abone ol.");
  }
  if (expired) {
    return new ApiError("trial_exhausted", `Ücretsiz deneme süren doldu (${config.trialDays} gün). Devam etmek için abone ol.`);
  }
  return new ApiError("trial_ip_limit", "Bu ağdan bugün çok fazla yeni deneme başlatıldı; yarın yeniden dene ya da abone ol.");
}

/**
 * Toplantıyı bitirir; zaten bittiyse kayıtlı sonucu döndürür. Başkasının toplantısı `not_found`. Biten toplantıların
 * (bu ve yeni toplantı başlayınca kapananlar) Deepgram tahmini gerçek süreye indirilir.
 */
export async function endMeeting(db: D1Database, userId: string, meetingId: string, now: Date): Promise<MeetingRow> {
  await db
    .prepare(
      `UPDATE meeting_sessions
       SET ended_at = MIN(?, max_ends_at), minutes = CAST((MIN(?, max_ends_at) - started_at + 59999) / 60000 AS INTEGER),
         end_reason = 'ended'
       WHERE id = ? AND user_id = ? AND ended_at IS NULL`,
    )
    .bind(now.getTime(), now.getTime(), meetingId, userId)
    .run();
  const row: MeetingRow | null = await findMeeting(db, userId, meetingId);
  if (row === null) {
    throw new ApiError("not_found", "Toplantı oturumu bulunamadı.");
  }
  await settleDeepgramMeetings(db, now);
  log("info", "meeting_ended", { userId, meetingId, minutes: row.minutes, tokensUsed: row.tokens_used, audioSeconds: row.audio_seconds });
  return row;
}

async function findMeeting(db: D1Database, userId: string, meetingId: string): Promise<MeetingRow | null> {
  return db.prepare("SELECT * FROM meeting_sessions WHERE id = ? AND user_id = ?").bind(meetingId, userId).first<MeetingRow>();
}

/**
 * Toplantının vekil çağrılarına açık olduğu son an: bitiş (ya da en çok süre) + not üretimi için ek süre. Yeni toplantı
 * başlayınca kapanan (`superseded`) toplantı ek süre almaz. Saf fonksiyondur.
 */
export function meetingUsableUntil(row: MeetingRow, graceMs: number): number {
  const end: number = Math.min(row.ended_at ?? row.max_ends_at, row.max_ends_at);
  return row.end_reason === "superseded" ? end : end + graceMs;
}

/** Vekil çağrısı için toplantı: çağırana ait, açık ya da ek süre içinde olmalı; değilse `meeting_not_active`. */
export async function requireUsableMeeting(db: D1Database, config: Config, userId: string, meetingId: string, now: Date): Promise<MeetingRow> {
  const row: MeetingRow | null = await findMeeting(db, userId, meetingId);
  if (row === null || now.getTime() >= meetingUsableUntil(row, config.meetingGraceMs)) {
    throw new ApiError("meeting_not_active", "Toplantı oturumu açık değil; yeni bir toplantı başlat.");
  }
  return row;
}
