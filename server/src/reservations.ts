import type { Config } from "./config";
import { ApiError } from "./errors";
import { dayKey, monthKey } from "./usage";

/**
 * Bir sınıra karşı ayırma: `reserve` ifadelerinin sonuncusu koşullu güncellemedir (sınır aşılacaksa 0 satır değişir);
 * `release` ayırmayı geri verir; `error` sınır aşıldığında fırlatılır.
 */
export interface ReservationStep {
  readonly reserve: readonly D1PreparedStatement[];
  readonly release: D1PreparedStatement;
  readonly error: ApiError;
}

/**
 * Adımları sırayla ayırır. Biri sınırı aşarsa önceki adımlar geri verilir ve adımın hatası fırlatılır. Her koşullu
 * güncelleme tek SQL ifadesidir: eşzamanlı istekler sınırı aşamaz; geri verme anına dek yalnızca fazla sayım olur
 * (hiçbir zaman eksik sayım olmaz).
 */
export async function reserveAll(db: D1Database, steps: readonly ReservationStep[]): Promise<void> {
  const done: ReservationStep[] = [];
  for (const step of steps) {
    const results: D1Result[] = await db.batch([...step.reserve]);
    if (results.at(-1)?.meta.changes !== 1) {
      if (done.length > 0) {
        await db.batch(done.map((reserved: ReservationStep): D1PreparedStatement => reserved.release));
      }
      throw step.error;
    }
    done.push(step);
  }
}

/** Kullanıcının aylık ve günlük token kalanı (kesinleşmiş + ayrılmış düşülür). */
export interface TokenHeadroom {
  readonly monthly: number;
  readonly daily: number;
}

/** Aylık ve günlük token kalanı. */
export async function tokenHeadroom(db: D1Database, config: Config, userId: string, now: Date): Promise<TokenHeadroom> {
  const [monthly, daily]: [{ used: number } | null, { used: number } | null] = await Promise.all([
    db
      .prepare("SELECT input_tokens + output_tokens + tokens_reserved AS used FROM monthly_usage WHERE user_id = ? AND month = ?")
      .bind(userId, monthKey(now))
      .first<{ used: number }>(),
    db
      .prepare("SELECT tokens_used + tokens_reserved AS used FROM daily_usage WHERE user_id = ? AND day = ?")
      .bind(userId, dayKey(now))
      .first<{ used: number }>(),
  ]);
  return { monthly: config.monthlyTokenCap - (monthly?.used ?? 0), daily: config.dailyTokenCap - (daily?.used ?? 0) };
}

/** Toplantı bütçesine token ayırma adımı (toplantıya bağlı çağrılar). */
export function meetingTokenStep(db: D1Database, meetingId: string, tokens: number): ReservationStep {
  return {
    reserve: [
      db
        .prepare("UPDATE meeting_sessions SET tokens_used = tokens_used + ? WHERE id = ? AND tokens_used + ? <= token_budget")
        .bind(tokens, meetingId, tokens),
    ],
    release: db.prepare("UPDATE meeting_sessions SET tokens_used = MAX(0, tokens_used - ?) WHERE id = ?").bind(tokens, meetingId),
    error: new ApiError("meeting_budget_exhausted", "Bu toplantının yapay zekâ bütçesi doldu."),
  };
}

/** Kullanıcının aylık ve günlük token sınırına ayırma adımları (her çağrıda). */
export function userTokenSteps(db: D1Database, config: Config, userId: string, tokens: number, now: Date): ReservationStep[] {
  const month: string = monthKey(now);
  const day: string = dayKey(now);
  return [
    {
      reserve: [
        db.prepare("INSERT OR IGNORE INTO monthly_usage (user_id, month) VALUES (?, ?)").bind(userId, month),
        db
          .prepare(
            `UPDATE monthly_usage SET tokens_reserved = tokens_reserved + ?
             WHERE user_id = ? AND month = ? AND input_tokens + output_tokens + tokens_reserved + ? <= ?`,
          )
          .bind(tokens, userId, month, tokens, config.monthlyTokenCap),
      ],
      release: db
        .prepare("UPDATE monthly_usage SET tokens_reserved = MAX(0, tokens_reserved - ?) WHERE user_id = ? AND month = ?")
        .bind(tokens, userId, month),
      error: new ApiError("monthly_cap_reached", "Bu ayki yapay zekâ kullanım sınırına ulaştın; sınır ay başında sıfırlanır."),
    },
    {
      reserve: [
        db.prepare("INSERT OR IGNORE INTO daily_usage (user_id, day) VALUES (?, ?)").bind(userId, day),
        db
          .prepare(
            `UPDATE daily_usage SET tokens_reserved = tokens_reserved + ?
             WHERE user_id = ? AND day = ? AND tokens_used + tokens_reserved + ? <= ?`,
          )
          .bind(tokens, userId, day, tokens, config.dailyTokenCap),
      ],
      release: db
        .prepare("UPDATE daily_usage SET tokens_reserved = MAX(0, tokens_reserved - ?) WHERE user_id = ? AND day = ?")
        .bind(tokens, userId, day),
      error: new ApiError("daily_cap_reached", "Bugünkü yapay zekâ kullanım sınırına ulaştın; yarın yeniden dene."),
    },
  ];
}

/** Toplantıda ayrılan tokenı gerçek kullanımla değiştiren ifade. */
export function settleMeetingTokenStatement(db: D1Database, meetingId: string, reserved: number, actual: number): D1PreparedStatement {
  return db.prepare("UPDATE meeting_sessions SET tokens_used = MAX(0, tokens_used - ? + ?) WHERE id = ?").bind(reserved, actual, meetingId);
}

/**
 * Kullanıcının aylık ve günlük sınırında ayrılan tokenı gerçek kullanımla değiştiren ifadeler. Ayırma ile aynı `now`
 * verilmelidir (aynı ay/gün satırı).
 */
export function settleUserTokenStatements(
  db: D1Database,
  userId: string,
  reserved: number,
  inputTokens: number,
  outputTokens: number,
  now: Date,
): D1PreparedStatement[] {
  return [
    db
      .prepare(
        `UPDATE monthly_usage SET tokens_reserved = MAX(0, tokens_reserved - ?), input_tokens = input_tokens + ?,
           output_tokens = output_tokens + ? WHERE user_id = ? AND month = ?`,
      )
      .bind(reserved, inputTokens, outputTokens, userId, monthKey(now)),
    db
      .prepare("UPDATE daily_usage SET tokens_reserved = MAX(0, tokens_reserved - ?), tokens_used = tokens_used + ? WHERE user_id = ? AND day = ?")
      .bind(reserved, inputTokens + outputTokens, userId, dayKey(now)),
  ];
}

/**
 * Ses ayırma adımları: toplantının ses süresi sınırı (en uzun süresi; ses hakkı kapanmamış olmalı) ve kullanıcının
 * aylık süre sınırı. Aylık adım deneme toplantılarında da uygulanır (deneme toplamı 3 × 90 dk sınırın altındadır);
 * böylece kesinleştirme her toplantıda aynıdır.
 */
export function audioReservationSteps(db: D1Database, config: Config, meetingId: string, userId: string, seconds: number, now: Date): ReservationStep[] {
  const month: string = monthKey(now);
  const meetingStep: ReservationStep = {
    reserve: [
      db
        .prepare(
          `UPDATE meeting_sessions SET audio_reserved = audio_reserved + ?
           WHERE id = ? AND transcription_closed = 0 AND audio_seconds + audio_reserved + ? <= (max_ends_at - started_at) / 1000.0`,
        )
        .bind(seconds, meetingId, seconds),
    ],
    release: db.prepare("UPDATE meeting_sessions SET audio_reserved = MAX(0, audio_reserved - ?) WHERE id = ?").bind(seconds, meetingId),
    error: new ApiError("audio_too_long", "Ses bu toplantının kalan ses süresini aşıyor."),
  };
  return [
    meetingStep,
    {
      reserve: [
        db.prepare("INSERT OR IGNORE INTO monthly_usage (user_id, month) VALUES (?, ?)").bind(userId, month),
        db
          .prepare(
            `UPDATE monthly_usage SET audio_reserved = audio_reserved + ?
             WHERE user_id = ? AND month = ? AND audio_seconds + audio_reserved + ? <= ?`,
          )
          .bind(seconds, userId, month, seconds, config.monthlyCapSeconds),
      ],
      release: db
        .prepare("UPDATE monthly_usage SET audio_reserved = MAX(0, audio_reserved - ?) WHERE user_id = ? AND month = ?")
        .bind(seconds, userId, month),
      error: new ApiError("monthly_cap_reached", "Bu ayki kullanım sınırı bu kaydı işlemeye yetmiyor; sınır ay başında sıfırlanır."),
    },
  ];
}

/**
 * Ayrılan ses süresini gerçek süreyle kesinleştiren ifadeler (toplantı ve aylık). Gerçek süre ayrılanı aşarsa
 * toplantının ses hakkı kapanır (`closeTranscription`). Ayırma ile aynı `now` verilmelidir.
 */
export function settleAudioStatements(
  db: D1Database,
  meetingId: string,
  userId: string,
  reservedSeconds: number,
  actualSeconds: number,
  closeTranscription: number,
  now: Date,
): D1PreparedStatement[] {
  return [
    db
      .prepare(
        `UPDATE meeting_sessions SET audio_reserved = MAX(0, audio_reserved - ?), audio_seconds = audio_seconds + ?,
           transcription_closed = MAX(transcription_closed, ?) WHERE id = ?`,
      )
      .bind(reservedSeconds, actualSeconds, closeTranscription, meetingId),
    db
      .prepare(
        `UPDATE monthly_usage SET audio_reserved = MAX(0, audio_reserved - ?), audio_seconds = audio_seconds + ?
         WHERE user_id = ? AND month = ?`,
      )
      .bind(reservedSeconds, actualSeconds, userId, monthKey(now)),
  ];
}
