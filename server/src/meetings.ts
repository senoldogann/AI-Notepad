import type { Config } from "./config";
import { randomId } from "./crypto";
import { deviceTrialMeetingsUsed, hasSubscriptionAccess, subscriptionState, userTrialMeetingsUsed } from "./entitlements";
import { ApiError } from "./errors";
import { log } from "./log";
import { type MonthlyUsage, dayKey, monthlyUsage, spendCeilingReached } from "./usage";

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
}

/** Kullanıcının açık oturumlarını kapatır (aynı anda tek toplantı; yeni başlangıç eskisini bitirir). */
async function closeOpenMeetings(db: D1Database, userId: string, now: Date): Promise<void> {
  await db
    .prepare(
      `UPDATE meeting_sessions
       SET ended_at = MIN(?, max_ends_at), minutes = CAST((MIN(?, max_ends_at) - started_at + 59999) / 60000 AS INTEGER)
       WHERE user_id = ? AND ended_at IS NULL`,
    )
    .bind(now.getTime(), now.getTime(), userId)
    .run();
}

/**
 * Toplantı oturumu açar. Günlük harcama tavanı aşıldıysa 503. Abonelik erişimi varsa (`past_due` ek süresi dahil)
 * aylık sınırın altında olmak gerekir (oturum süresi kalan aylık süreyle de sınırlanır); yoksa bir deneme toplantısı
 * düşer (`startTrialMeeting`).
 */
export async function startMeeting(
  db: D1Database,
  config: Config,
  userId: string,
  deviceId: string | null,
  clientIpHash: string,
  now: Date,
): Promise<StartedMeeting> {
  if (await spendCeilingReached(db, config, now)) {
    throw new ApiError("spend_ceiling_reached", "Servis bugün yoğun; yeni toplantı şu an başlatılamıyor. Lütfen daha sonra yeniden dene.");
  }
  await closeOpenMeetings(db, userId, now);
  if (!hasSubscriptionAccess(await subscriptionState(db, userId), now, config.pastDueGraceMs)) {
    return startTrialMeeting(db, config, userId, deviceId, clientIpHash, now);
  }
  const meetingId: string = randomId();
  const usage: MonthlyUsage = await monthlyUsage(db, userId, now);
  const remainingSeconds: number = config.monthlyCapSeconds - usage.usedSeconds;
  if (remainingSeconds <= 0) {
    throw new ApiError("monthly_cap_reached", "Bu ayki kullanım sınırına ulaştın; sınır ay başında sıfırlanır.");
  }
  const maxMinutes: number = Math.max(1, Math.min(config.subscriberMaxMeetingMinutes, Math.floor(remainingSeconds / 60)));
  const maxEndsAt: number = now.getTime() + maxMinutes * 60_000;
  await db
    .prepare(
      `INSERT INTO meeting_sessions (id, user_id, device_id, kind, started_at, max_ends_at, token_budget)
       VALUES (?, ?, ?, 'subscription', ?, ?, ?)`,
    )
    .bind(meetingId, userId, deviceId, now.getTime(), maxEndsAt, config.subscriberMeetingTokenBudget)
    .run();
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
 * Deneme toplantısı. Her hesabın doğrulanmış bir kimliği vardır (Apple `sub` ya da tıklanmış e-posta bağlantısı;
 * hesap başka yoldan oluşmaz). Hak üç koşula bağlıdır:
 * - hesap başına `trialMeetings` toplantı;
 * - doğrulanmış cihaz bildirildiyse cihaz başına `trialMeetings` toplantı (yeni hesap aynı cihazda yeni deneme almaz);
 * - hesabın ilk denemesiyse, aynı IP'den (HMAC özeti) bugün denemeye başlamış hesap sayısı `trialAccountsPerIpPerDay`
 *   altında olmalı.
 * Koşullar ve ekleme tek toplu işlemdir (D1 işlemi): eşzamanlı istekler sınırları aşamaz.
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
  const [inserted] = await db.batch([
    db
      .prepare(
        `INSERT INTO meeting_sessions (id, user_id, device_id, kind, started_at, max_ends_at, token_budget)
         SELECT ?, ?, ?, 'trial', ?, ?, ?
         WHERE (SELECT COUNT(*) FROM meeting_sessions WHERE user_id = ? AND kind = 'trial') < ?
           AND (? IS NULL OR (SELECT COUNT(*) FROM meeting_sessions WHERE device_id = ? AND kind = 'trial') < ?)
           AND (EXISTS (SELECT 1 FROM trial_starts WHERE user_id = ?)
             OR (SELECT COUNT(*) FROM trial_starts WHERE ip_hash = ? AND day = ?) < ?)`,
      )
      .bind(
        meetingId,
        userId,
        deviceId,
        now.getTime(),
        maxEndsAt,
        config.trialMeetingTokenBudget,
        userId,
        config.trialMeetings,
        deviceId,
        deviceId,
        config.trialMeetings,
        userId,
        clientIpHash,
        day,
        config.trialAccountsPerIpPerDay,
      ),
    db
      .prepare(
        `INSERT OR IGNORE INTO trial_starts (user_id, ip_hash, day, created_at)
         SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM meeting_sessions WHERE id = ?)`,
      )
      .bind(userId, clientIpHash, day, now.getTime(), meetingId),
  ]);
  const accountUsed: number = await userTrialMeetingsUsed(db, userId);
  const deviceUsed: number | null = deviceId === null ? null : await deviceTrialMeetingsUsed(db, deviceId);
  if (inserted?.meta.changes !== 1) {
    const exhausted: boolean = accountUsed >= config.trialMeetings || (deviceUsed ?? 0) >= config.trialMeetings;
    log("info", "trial_refused", { userId, attested: deviceId !== null, reason: exhausted ? "exhausted" : "ip_daily_limit" });
    if (exhausted) {
      throw new ApiError("trial_exhausted", "Ücretsiz deneme toplantıların bitti (hesap ya da bu cihaz için). Devam etmek için abone ol.");
    }
    throw new ApiError("trial_ip_limit", "Bu ağdan bugün çok fazla yeni deneme başlatıldı; yarın yeniden dene ya da abone ol.");
  }
  log("info", "meeting_started", { userId, meetingId, kind: "trial", attested: deviceId !== null });
  return {
    meetingId,
    kind: "trial",
    tokenBudget: config.trialMeetingTokenBudget,
    maxDurationMinutes: config.trialMaxMeetingMinutes,
    expiresAt: new Date(maxEndsAt).toISOString(),
    trialMeetingsLeft: Math.max(0, config.trialMeetings - Math.max(accountUsed, deviceUsed ?? 0)),
  };
}

/** Toplantıyı bitirir; zaten bittiyse kayıtlı sonucu döndürür. Başkasının toplantısı `not_found`. */
export async function endMeeting(db: D1Database, userId: string, meetingId: string, now: Date): Promise<MeetingRow> {
  await db
    .prepare(
      `UPDATE meeting_sessions
       SET ended_at = MIN(?, max_ends_at), minutes = CAST((MIN(?, max_ends_at) - started_at + 59999) / 60000 AS INTEGER)
       WHERE id = ? AND user_id = ? AND ended_at IS NULL`,
    )
    .bind(now.getTime(), now.getTime(), meetingId, userId)
    .run();
  const row: MeetingRow | null = await findMeeting(db, userId, meetingId);
  if (row === null) {
    throw new ApiError("not_found", "Toplantı oturumu bulunamadı.");
  }
  log("info", "meeting_ended", { userId, meetingId, minutes: row.minutes, tokensUsed: row.tokens_used, audioSeconds: row.audio_seconds });
  return row;
}

async function findMeeting(db: D1Database, userId: string, meetingId: string): Promise<MeetingRow | null> {
  return db.prepare("SELECT * FROM meeting_sessions WHERE id = ? AND user_id = ?").bind(meetingId, userId).first<MeetingRow>();
}

/** Toplantının vekil çağrılarına açık olduğu son an: bitiş (ya da en çok süre) + not üretimi için ek süre. Saf fonksiyondur. */
export function meetingUsableUntil(row: MeetingRow, graceMs: number): number {
  return Math.min(row.ended_at ?? row.max_ends_at, row.max_ends_at) + graceMs;
}

/** Vekil çağrısı için toplantı: çağırana ait, açık ya da ek süre içinde olmalı; değilse `meeting_not_active`. */
export async function requireUsableMeeting(db: D1Database, config: Config, userId: string, meetingId: string, now: Date): Promise<MeetingRow> {
  const row: MeetingRow | null = await findMeeting(db, userId, meetingId);
  if (row === null || now.getTime() >= meetingUsableUntil(row, config.meetingGraceMs)) {
    throw new ApiError("meeting_not_active", "Toplantı oturumu açık değil; yeni bir toplantı başlat.");
  }
  return row;
}

/** Toplantı bütçesinden token ayırır (tek koşullu ifade); bütçe yetmezse false. */
export async function reserveMeetingTokens(db: D1Database, meetingId: string, tokens: number): Promise<boolean> {
  const result: D1Result = await db
    .prepare("UPDATE meeting_sessions SET tokens_used = tokens_used + ? WHERE id = ? AND tokens_used + ? <= token_budget")
    .bind(tokens, meetingId, tokens)
    .run();
  return result.meta.changes === 1;
}

/** Ayrılan tokenı gerçek kullanımla değiştiren ifade. */
export function settleMeetingTokensStatement(db: D1Database, meetingId: string, reserved: number, actual: number): D1PreparedStatement {
  return db.prepare("UPDATE meeting_sessions SET tokens_used = MAX(0, tokens_used - ? + ?) WHERE id = ?").bind(reserved, actual, meetingId);
}

/** Toplantının ses süresine ekleme ifadesi. */
export function addMeetingAudioStatement(db: D1Database, meetingId: string, seconds: number): D1PreparedStatement {
  return db.prepare("UPDATE meeting_sessions SET audio_seconds = audio_seconds + ? WHERE id = ?").bind(seconds, meetingId);
}
