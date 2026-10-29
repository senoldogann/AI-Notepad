import type { Config } from "./config";
import { randomId } from "./crypto";
import { ApiError } from "./errors";
import { dayKey, monthKey, monthStartMs, monthlyUsedSecondsSql } from "./usage";

/**
 * Önceden ayırma (`usage_reservations`): üst servise giden her çağrı (LLM ya da ses) için tek satır. Satır, çağrının
 * en kötü durumda harcayabileceği miktarı (token ya da saniye) ve tahmini maliyeti taşır; sınır hesapları kesinleşmiş
 * kullanım + süresi dolmamış ayırmaların toplamıdır. Kesinleştirme satırı siler ve gerçek kullanımı yazar.
 *
 * Satırın bir son kullanma anı vardır: istemci koptuğunda ya da Worker kesinleştirmeden önce durduğunda satır sonsuza
 * dek sınır yemez; süresi dolunca sınır hesapları onu yok sayar, günlük temizlik tahmini maliyetini günlük harcamaya
 * ekleyip siler (`expiredReservationStatements`).
 */

/** SQL bağ değeri. */
type SqlValue = string | number | null;

/** LLM ayırmasının ömrü: en uzun çağrı (3 deneme × 120 sn ya da uzun akış) bundan kısadır. */
export const llmReservationTtlMs: number = 15 * 60_000;
/** Ses ayırmasının ömrü: ElevenLabs zaman aşımından (15 dk) ve 95 MB yüklemeden uzundur. */
export const audioReservationTtlMs: number = 20 * 60_000;

/** Ayırma türü. */
export type ReservationKind = "llm" | "audio";

/** Tek çağrının ayırması (`usage_reservations` satırı). */
export interface UsageReservation {
  readonly id: string;
  readonly userId: string;
  /** Toplantıya bağlı çağrıda toplantı; hesap çağrısında null. */
  readonly meetingId: string | null;
  readonly kind: ReservationKind;
  /** Ayırmanın ve kesinleştirmenin yazdığı ay ve gün (UTC; ayırma anının). */
  readonly month: string;
  readonly day: string;
  /** Kullanıcının aylık ve günlük token sınırına (ve toplantı bütçesine) sayılan token. */
  readonly tokens: number;
  /** Denemedeki hesap çağrısında `tokens`; değilse 0 (`TRIAL_ACCOUNT_DAILY_TOKENS`). */
  readonly trialAccountTokens: number;
  /** Abonenin hesap çağrısında `tokens`; değilse 0 (`MONTHLY_ACCOUNT_TOKEN_CAP`). */
  readonly accountTokens: number;
  readonly audioSeconds: number;
  /** En kötü durumun tahmini maliyeti (mikro dolar); süresi dolarsa harcamaya bu yazılır. */
  readonly estimatedMicroUsd: number;
  /** Harcama deneme tavanına da sayılır mı (deneme toplantısı ya da denemedeki hesap çağrısı). */
  readonly trialSpend: boolean;
  readonly createdAt: number;
  readonly expiresAt: number;
}

/** Yeni LLM ayırmasının alanları. */
export interface LLMReservationInput {
  readonly userId: string;
  readonly meetingId: string | null;
  readonly tokens: number;
  readonly trialAccountCall: boolean;
  readonly subscriberAccountCall: boolean;
  readonly estimatedMicroUsd: number;
  readonly trialSpend: boolean;
}

/** LLM ayırması. Saf fonksiyondur (kimlik rastgeledir). */
export function llmReservation(input: LLMReservationInput, now: Date): UsageReservation {
  return {
    id: randomId(),
    userId: input.userId,
    meetingId: input.meetingId,
    kind: "llm",
    month: monthKey(now),
    day: dayKey(now),
    tokens: input.tokens,
    trialAccountTokens: input.trialAccountCall ? input.tokens : 0,
    accountTokens: input.subscriberAccountCall ? input.tokens : 0,
    audioSeconds: 0,
    estimatedMicroUsd: input.estimatedMicroUsd,
    trialSpend: input.trialSpend,
    createdAt: now.getTime(),
    expiresAt: now.getTime() + llmReservationTtlMs,
  };
}

/** Ses ayırması. Saf fonksiyondur (kimlik rastgeledir). */
export function audioReservation(userId: string, meetingId: string, seconds: number, estimatedMicroUsd: number, trialSpend: boolean, now: Date): UsageReservation {
  return {
    id: randomId(),
    userId,
    meetingId,
    kind: "audio",
    month: monthKey(now),
    day: dayKey(now),
    tokens: 0,
    trialAccountTokens: 0,
    accountTokens: 0,
    audioSeconds: seconds,
    estimatedMicroUsd,
    trialSpend,
    createdAt: now.getTime(),
    expiresAt: now.getTime() + audioReservationTtlMs,
  };
}

/**
 * Bir sınır: kalan miktarın SQL ifadesi (kesinleşmiş kullanım ve süresi dolmamış ayırmalar düşülmüş) ve aşılınca
 * fırlatılacak hata. İfade bağımsız bir `SELECT` içinde de, ayırma ifadesinin koşulunda da kullanılır.
 */
export interface ReservationLimit {
  readonly remainingSql: string;
  readonly binds: readonly SqlValue[];
  readonly error: ApiError;
}

/** Sınır ve ona karşı ayrılacak miktar. */
export interface ReservationCheck {
  readonly limit: ReservationLimit;
  readonly amount: number;
}

/** Süresi dolmamış ayırmaların bir sütununun toplamı (SQL). */
function activeSum(column: string, scope: string): string {
  return `(SELECT COALESCE(SUM(${column}), 0) FROM usage_reservations WHERE ${scope} AND expires_at > ?)`;
}

/** Toplantının token bütçesinden kalan. */
export function meetingTokenLimit(meetingId: string, now: Date): ReservationLimit {
  return {
    remainingSql: `(SELECT token_budget - tokens_used FROM meeting_sessions WHERE id = ?) - ${activeSum("tokens", "meeting_id = ? AND kind = 'llm'")}`,
    binds: [meetingId, meetingId, now.getTime()],
    error: new ApiError("meeting_budget_exhausted", "Bu toplantının yapay zekâ bütçesi doldu."),
  };
}

/** Kullanıcının aylık token sınırından kalan (tüm çağrılar). */
export function monthlyTokenLimit(config: Config, userId: string, now: Date): ReservationLimit {
  const month: string = monthKey(now);
  return {
    remainingSql: `? - COALESCE((SELECT input_tokens + output_tokens FROM monthly_usage WHERE user_id = ? AND month = ?), 0) - ${activeSum("tokens", "user_id = ? AND month = ?")}`,
    binds: [config.monthlyTokenCap, userId, month, userId, month, now.getTime()],
    error: new ApiError("monthly_cap_reached", "Bu ayki yapay zekâ kullanım sınırına ulaştın; sınır ay başında sıfırlanır."),
  };
}

/** Kullanıcının günlük token sınırından kalan (tüm çağrılar). */
export function dailyTokenLimit(config: Config, userId: string, now: Date): ReservationLimit {
  const day: string = dayKey(now);
  return {
    remainingSql: `? - COALESCE((SELECT tokens_used FROM daily_usage WHERE user_id = ? AND day = ?), 0) - ${activeSum("tokens", "user_id = ? AND day = ?")}`,
    binds: [config.dailyTokenCap, userId, day, userId, day, now.getTime()],
    error: new ApiError("daily_cap_reached", "Bugünkü yapay zekâ kullanım sınırına ulaştın; yarın yeniden dene."),
  };
}

/** Denemedeki kullanıcının toplantı dışı çağrılarının günlük sınırından kalan. */
export function trialAccountTokenLimit(config: Config, userId: string, now: Date): ReservationLimit {
  const day: string = dayKey(now);
  return {
    remainingSql: `? - COALESCE((SELECT trial_account_tokens_used FROM daily_usage WHERE user_id = ? AND day = ?), 0) - ${activeSum("trial_account_tokens", "user_id = ? AND day = ?")}`,
    binds: [config.trialAccountDailyTokens, userId, day, userId, day, now.getTime()],
    error: new ApiError("daily_cap_reached", "Denemede toplantı dışı yapay zekâ kullanımının bugünkü sınırına ulaştın; yarın yeniden dene ya da abone ol."),
  };
}

/** Abonenin toplantı dışı çağrılarının aylık sınırından kalan (`MONTHLY_ACCOUNT_TOKEN_CAP`). */
export function subscriberAccountTokenLimit(config: Config, userId: string, now: Date): ReservationLimit {
  const month: string = monthKey(now);
  return {
    remainingSql: `? - COALESCE((SELECT account_tokens FROM monthly_usage WHERE user_id = ? AND month = ?), 0) - ${activeSum("account_tokens", "user_id = ? AND month = ?")}`,
    binds: [config.monthlyAccountTokenCap, userId, month, userId, month, now.getTime()],
    error: new ApiError(
      "monthly_cap_reached",
      "Bu ayki toplantı dışı yapay zekâ kullanım sınırına ulaştın (Sor, not düzenleme); toplantılar sürer, sınır ay başında sıfırlanır.",
    ),
  };
}

/**
 * Uzun kaydın parçaları (`TRANSCRIBE_MAX_BYTES`, ~49 dk) birer dakika örtüşür (istemci `hostedChunkOverlapSec`):
 * ortak bölgeler ikinci kez yazıya döküldüğü için toplantının ses hakkına her parça sınırı için bir dakika pay eklenir.
 * Sınır sayısı toplantının en uzun süresinin parça adımına (`chunkStepSeconds`, gerçek adımdan biraz kısa: yukarı
 * yuvarlar) bölümüdür; 49 dakikadan kısa toplantıda pay yoktur.
 */
export const chunkOverlapSeconds: number = 60;
export const chunkStepSeconds: number = 2900;

/**
 * Toplantının ses süresinden kalan (en uzun süresi + parça örtüşme payı − yazılmış ses; ses hakkı kapandıysa 0). Toplantıda
 * aynı anda tek ses isteği olabildiği için (`meetingAudioIdleLimit`) süren ayırma düşülmez.
 */
export function meetingAudioLimit(meetingId: string): ReservationLimit {
  return {
    remainingSql: `(SELECT CASE WHEN transcription_closed = 0 THEN (max_ends_at - started_at) / 1000.0 + CAST((max_ends_at - started_at) / 1000.0 / ${chunkStepSeconds} AS INTEGER) * ${chunkOverlapSeconds} - audio_seconds ELSE 0 END FROM meeting_sessions WHERE id = ?)`,
    binds: [meetingId],
    error: new ApiError("audio_too_long", "Ses bu toplantının kalan ses süresini aşıyor."),
  };
}

/** Toplantıda süren (süresi dolmamış) ses isteği yoksa 1, varsa 0: toplantı başına aynı anda tek ses isteği. */
export function meetingAudioIdleLimit(meetingId: string, now: Date): ReservationLimit {
  return {
    remainingSql: "CASE WHEN EXISTS (SELECT 1 FROM usage_reservations WHERE meeting_id = ? AND kind = 'audio' AND expires_at > ?) THEN 0 ELSE 1 END",
    binds: [meetingId, now.getTime()],
    error: new ApiError("transcription_in_progress", "Bu toplantının bir ses dosyası hâlâ işleniyor; bitince yeniden dene."),
  };
}

/**
 * Kullanıcının aylık süre sınırından bu toplantıya yazılabilecek ses (deneme toplantılarında da; silinmiş hesaptan
 * devralınan süre dahil): sınır − sayılan süre (`monthlyUsedSecondsSql`) + toplantının sesinin henüz süresine
 * ulaşmamış kısmı (toplantının süresi zaten sayıldı; sesi süresini aşana dek ek sayılmaz).
 */
export function monthlyAudioLimit(config: Config, userId: string, meetingId: string, now: Date): ReservationLimit {
  const used: string = monthlyUsedSecondsSql({ user: "p.user_id", month: "p.month", now: "p.now", monthStart: "p.month_start" });
  const headroom: string = `COALESCE((SELECT MAX(0, MAX(0, MIN(COALESCE(s.ended_at, p.now), s.max_ends_at, p.now) - s.started_at) / 1000.0 - s.audio_seconds
      - COALESCE((SELECT SUM(r.audio_seconds) FROM usage_reservations r WHERE r.meeting_id = s.id AND r.kind = 'audio' AND r.expires_at > p.now), 0))
    FROM meeting_sessions s WHERE s.id = p.meeting_id AND s.started_at >= p.month_start), 0)`;
  return {
    remainingSql: `(SELECT p.cap - ${used} + ${headroom}
      FROM (SELECT ? AS cap, ? AS user_id, ? AS month, ? AS now, ? AS month_start, ? AS meeting_id) p)`,
    binds: [config.monthlyCapSeconds, userId, monthKey(now), now.getTime(), monthStartMs(now), meetingId],
    error: new ApiError("monthly_cap_reached", "Bu ayki kullanım sınırı bu kaydı işlemeye yetmiyor; sınır ay başında sıfırlanır."),
  };
}

/** Sınırların kalanlarını tek sorguda okur (sırayla). */
export async function remainingOf(db: D1Database, limits: readonly ReservationLimit[]): Promise<number[]> {
  const columns: string = limits.map((limit: ReservationLimit, index: number): string => `(${limit.remainingSql}) AS r${index}`).join(", ");
  const row: Record<string, number | null> | null = await db
    .prepare(`SELECT ${columns}`)
    .bind(...limits.flatMap((limit: ReservationLimit): readonly SqlValue[] => limit.binds))
    .first<Record<string, number | null>>();
  return limits.map((_: ReservationLimit, index: number): number => row?.[`r${index}`] ?? 0);
}

/** En dar sınır: kalanı ve hatası. Saf fonksiyondur. */
export function tightestLimit(limits: readonly ReservationLimit[], remaining: readonly number[]): { readonly remaining: number; readonly error: ApiError } {
  const first: ReservationLimit | undefined = limits[0];
  if (first === undefined) {
    throw new Error("En az bir sınır gerekir.");
  }
  return limits.reduce(
    (tightest: { remaining: number; error: ApiError }, limit: ReservationLimit, index: number): { remaining: number; error: ApiError } => {
      const value: number = remaining[index] ?? 0;
      return value < tightest.remaining ? { remaining: value, error: limit.error } : tightest;
    },
    { remaining: remaining[0] ?? 0, error: first.error },
  );
}

/**
 * Ayırma satırını yalnızca tüm sınırlar yetiyorsa ekler (tek koşullu ifade: eşzamanlı istekler sınırı aşamaz).
 * Eklenmezse kalanlar yeniden okunur ve yetmeyen ilk sınırın hatası fırlatılır (arada yer açıldıysa ilk sınırınki).
 */
export async function reserveUsage(db: D1Database, reservation: UsageReservation, checks: readonly ReservationCheck[]): Promise<void> {
  const conditions: string = checks.map((check: ReservationCheck): string => `(${check.limit.remainingSql}) >= ?`).join(" AND ");
  const conditionBinds: SqlValue[] = checks.flatMap((check: ReservationCheck): SqlValue[] => [...check.limit.binds, check.amount]);
  const inserted: D1Result = await db
    .prepare(
      `INSERT INTO usage_reservations (id, user_id, meeting_id, kind, month, day, tokens, trial_account_tokens, account_tokens,
         audio_seconds, estimated_micro_usd, trial_spend, created_at, expires_at)
       SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE ${conditions}`,
    )
    .bind(
      reservation.id,
      reservation.userId,
      reservation.meetingId,
      reservation.kind,
      reservation.month,
      reservation.day,
      reservation.tokens,
      reservation.trialAccountTokens,
      reservation.accountTokens,
      reservation.audioSeconds,
      reservation.estimatedMicroUsd,
      reservation.trialSpend ? 1 : 0,
      reservation.createdAt,
      reservation.expiresAt,
      ...conditionBinds,
    )
    .run();
  if (inserted.meta.changes === 1) {
    return;
  }
  const limits: ReservationLimit[] = checks.map((check: ReservationCheck): ReservationLimit => check.limit);
  const remaining: number[] = await remainingOf(db, limits);
  const failed: ReservationCheck | undefined = checks.find((check: ReservationCheck, index: number): boolean => (remaining[index] ?? 0) < check.amount);
  throw (failed ?? checks[0])?.limit.error ?? new Error("Ayırma sınırı olmadan çağrıldı.");
}

/**
 * Harcama ifadesi: deneme harcamasıysa deneme toplamına da yazılır. Yalnızca ayırma satırı hâlâ duruyorsa yazılır:
 * satırı kaldıran (süre dolumu temizliği ya da hesap silme) tahmini maliyeti zaten yazmıştır; gerçek maliyet ikinci kez
 * eklenmez. Bu yüzden kesinleştirmede ayırmayı silen ifade en sonda çalışır.
 */
function spendStatement(db: D1Database, reservation: UsageReservation, microUsd: number, now: Date): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO daily_spend (day, micro_usd, trial_micro_usd)
       SELECT ?1, ?2, CASE WHEN ?3 = 1 THEN ?2 ELSE 0 END WHERE EXISTS (SELECT 1 FROM usage_reservations WHERE id = ?4)
       ON CONFLICT(day) DO UPDATE SET micro_usd = micro_usd + excluded.micro_usd, trial_micro_usd = trial_micro_usd + excluded.trial_micro_usd`,
    )
    .bind(dayKey(now), microUsd, reservation.trialSpend ? 1 : 0, reservation.id);
}

/** Kesinleştirmenin son ifadesi: ayırma satırını siler (önceki ifadeler satırın varlığına bakar). */
function deleteReservationStatement(db: D1Database, reservation: UsageReservation): D1PreparedStatement {
  return db.prepare("DELETE FROM usage_reservations WHERE id = ?").bind(reservation.id);
}

/** Gerçekleşen token kullanımı. */
export interface TokenUsage {
  readonly inputTokens: number;
  readonly outputTokens: number;
}

/**
 * LLM ayırmasını kesinleştiren ifadeler: gerçek kullanım toplantıya (varsa), kullanıcının ayına ve gününe (denemedeki
 * ya da abonenin hesap çağrısında ayrıca kendi sayacına) ve `spendMicroUsd` günlük harcamaya yazılır, en sonda ayırma
 * satırı silinir. Ay ve gün ayırmanınkidir (gece yarısını aşan çağrı ayırdığı satırı kesinleştirir). Hesap çağrı
 * sürerken silindiyse kullanıcı sayaçları yazılmaz (yabancı anahtar hatası toplu işlemi düşürmez); harcama, ayırmayı
 * silen hesap silme işleminde tahminle yazılmıştır (`reservationSpendOnRemovalStatement`).
 */
export function settleLLMStatements(db: D1Database, reservation: UsageReservation, usage: TokenUsage, spendMicroUsd: number, now: Date): D1PreparedStatement[] {
  const actual: number = usage.inputTokens + usage.outputTokens;
  const meeting: D1PreparedStatement[] =
    reservation.meetingId === null
      ? []
      : [db.prepare("UPDATE meeting_sessions SET tokens_used = tokens_used + ? WHERE id = ?").bind(actual, reservation.meetingId)];
  return [
    ...meeting,
    db
      .prepare(
        `INSERT INTO monthly_usage (user_id, month, input_tokens, output_tokens, account_tokens)
         SELECT ?1, ?2, ?3, ?4, ?5 WHERE EXISTS (SELECT 1 FROM users WHERE id = ?1)
         ON CONFLICT(user_id, month) DO UPDATE SET input_tokens = input_tokens + excluded.input_tokens,
           output_tokens = output_tokens + excluded.output_tokens, account_tokens = account_tokens + excluded.account_tokens`,
      )
      .bind(reservation.userId, reservation.month, usage.inputTokens, usage.outputTokens, reservation.accountTokens > 0 ? actual : 0),
    db
      .prepare(
        `INSERT INTO daily_usage (user_id, day, tokens_used, trial_account_tokens_used)
         SELECT ?1, ?2, ?3, ?4 WHERE EXISTS (SELECT 1 FROM users WHERE id = ?1)
         ON CONFLICT(user_id, day) DO UPDATE SET tokens_used = tokens_used + excluded.tokens_used,
           trial_account_tokens_used = trial_account_tokens_used + excluded.trial_account_tokens_used`,
      )
      .bind(reservation.userId, reservation.day, actual, reservation.trialAccountTokens > 0 ? actual : 0),
    spendStatement(db, reservation, spendMicroUsd, now),
    deleteReservationStatement(db, reservation),
  ];
}

/**
 * Ses ayırmasını kesinleştiren ifadeler: ayırma satırı silinir (toplantının ses isteği serbest kalır); gerçek süre
 * toplantıya ve kullanıcının ayına, `spendMicroUsd` günlük harcamaya, `providerSeconds` (ElevenLabs'in kredisinden
 * düştüğü kabul edilen saniye) günlük ElevenLabs sayacına (`daily_spend.audio_seconds`) yazılır. Gerçek süre ayrılanı
 * aştıysa toplantının ses hakkı kapanır (`closeTranscription`). Ayırma satırı en sonda silinir; harcama yalnızca satır
 * hâlâ duruyorsa yazılır, kullanıcı sayacı yalnızca hesap duruyorsa (bkz. `settleLLMStatements`).
 */
export function settleAudioStatements(
  db: D1Database,
  reservation: UsageReservation,
  actualSeconds: number,
  closeTranscription: boolean,
  spendMicroUsd: number,
  providerSeconds: number,
  now: Date,
): D1PreparedStatement[] {
  return [
    db
      .prepare("UPDATE meeting_sessions SET audio_seconds = audio_seconds + ?, transcription_closed = MAX(transcription_closed, ?) WHERE id = ?")
      .bind(actualSeconds, closeTranscription ? 1 : 0, reservation.meetingId),
    db
      .prepare(
        `INSERT INTO monthly_usage (user_id, month, audio_seconds)
         SELECT ?1, ?2, ?3 WHERE EXISTS (SELECT 1 FROM users WHERE id = ?1)
         ON CONFLICT(user_id, month) DO UPDATE SET audio_seconds = audio_seconds + excluded.audio_seconds`,
      )
      .bind(reservation.userId, reservation.month, actualSeconds),
    spendStatement(db, reservation, spendMicroUsd, now),
    db
      .prepare(
        `INSERT INTO daily_spend (day, audio_seconds)
         SELECT ?1, ?2 WHERE EXISTS (SELECT 1 FROM usage_reservations WHERE id = ?3)
         ON CONFLICT(day) DO UPDATE SET audio_seconds = audio_seconds + excluded.audio_seconds`,
      )
      .bind(dayKey(now), providerSeconds, reservation.id),
    deleteReservationStatement(db, reservation),
  ];
}

/**
 * Süresi dolmuş (kesinleşmemiş) ayırmaları kapatan ifadeler; aynı toplu işlemde, aynı anla çalışmalıdır. Çağrının gerçek
 * kullanımı bilinmez: en kötü durum tahmini maliyeti (seste ayrıca saniyesi ElevenLabs sayacına) ayırmanın gününün
 * harcamasına eklenir (deneme payı ayrıca), satırlar
 * silinir. Kullanıcının token ve süre sayaçlarına yazılmaz (istemci yanıt almadı).
 */
export function expiredReservationStatements(db: D1Database, now: Date): D1PreparedStatement[] {
  return removedReservationStatements(db, "expires_at <= ?", [now.getTime()]);
}

/**
 * Hesap silinirken süren ayırmalarını kaldıran ifadeler (hesabın satırları silinmeden, aynı toplu işlemde): çağrılar
 * üst serviste sürüyor olabilir; tahmini maliyetleri günlük harcamaya yazılır (sonraki kesinleştirme satırı bulamaz ve
 * ikinci kez yazmaz), satırlar silinir.
 */
export function userReservationRemovalStatements(db: D1Database, userId: string): D1PreparedStatement[] {
  return removedReservationStatements(db, "user_id = ?", [userId]);
}

/** Koşula uyan ayırmaların tahmini maliyetini ayırmanın gününe yazıp satırları silen ifadeler. */
function removedReservationStatements(db: D1Database, condition: string, binds: readonly SqlValue[]): D1PreparedStatement[] {
  return [
    db
      .prepare(
        `INSERT INTO daily_spend (day, micro_usd, trial_micro_usd, audio_seconds)
         SELECT day, SUM(estimated_micro_usd), SUM(CASE WHEN trial_spend = 1 THEN estimated_micro_usd ELSE 0 END),
           SUM(CASE WHEN kind = 'audio' THEN audio_seconds ELSE 0 END)
         FROM usage_reservations WHERE ${condition} GROUP BY day
         ON CONFLICT(day) DO UPDATE SET micro_usd = micro_usd + excluded.micro_usd, trial_micro_usd = trial_micro_usd + excluded.trial_micro_usd,
           audio_seconds = audio_seconds + excluded.audio_seconds`,
      )
      .bind(...binds),
    db.prepare(`DELETE FROM usage_reservations WHERE ${condition}`).bind(...binds),
  ];
}
