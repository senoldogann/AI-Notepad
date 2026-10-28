import type { Config } from "./config";
import { randomId } from "./crypto";
import { isSubscriptionActive, subscriptionState, userTrialMeetingsUsed } from "./entitlements";
import { ApiError } from "./errors";
import { log } from "./log";
import { type MonthlyUsage, monthlyUsage, spendCeilingReached } from "./usage";

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
 * Toplantı oturumu açar. Günlük harcama tavanı aşıldıysa 503. Aktif abonelikte aylık sınırın altında olmak gerekir
 * (oturum süresi kalan aylık süreyle de sınırlanır); abonelik yoksa bir deneme toplantısı düşer. Deneme hakkı kullanıcı
 * başına ve (doğrulanmış cihaz varsa) cihaz başınadır: yeni hesap aynı cihazda yeni deneme almaz. Sayım ve ekleme tek
 * SQL ifadesidir; eşzamanlı istekler fazladan deneme alamaz.
 */
export async function startMeeting(db: D1Database, config: Config, userId: string, deviceId: string | null, now: Date): Promise<StartedMeeting> {
  if (await spendCeilingReached(db, config, now)) {
    throw new ApiError("spend_ceiling_reached", "Servis bugün yoğun; yeni toplantı şu an başlatılamıyor. Lütfen daha sonra yeniden dene.");
  }
  await closeOpenMeetings(db, userId, now);
  const meetingId: string = randomId();
  if (isSubscriptionActive(await subscriptionState(db, userId), now)) {
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
  const maxEndsAt: number = now.getTime() + config.trialMaxMeetingMinutes * 60_000;
  const inserted: D1Result = await db
    .prepare(
      `INSERT INTO meeting_sessions (id, user_id, device_id, kind, started_at, max_ends_at, token_budget)
       SELECT ?, ?, ?, 'trial', ?, ?, ?
       WHERE (SELECT COUNT(*) FROM meeting_sessions WHERE user_id = ? AND kind = 'trial') < ?
         AND (? IS NULL OR (SELECT COUNT(*) FROM meeting_sessions WHERE device_id = ? AND kind = 'trial') < ?)`,
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
    )
    .run();
  if (inserted.meta.changes !== 1) {
    log("info", "trial_refused", { userId, attested: deviceId !== null });
    throw new ApiError("trial_exhausted", "Ücretsiz deneme toplantıların bitti (hesap ya da bu cihaz için). Devam etmek için abone ol.");
  }
  const trialUsed: number = await userTrialMeetingsUsed(db, userId);
  log("info", "meeting_started", { userId, meetingId, kind: "trial", attested: deviceId !== null });
  return {
    meetingId,
    kind: "trial",
    tokenBudget: config.trialMeetingTokenBudget,
    maxDurationMinutes: config.trialMaxMeetingMinutes,
    expiresAt: new Date(maxEndsAt).toISOString(),
    trialMeetingsLeft: Math.max(0, config.trialMeetings - trialUsed),
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
