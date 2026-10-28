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

/** Aylık kullanım özeti. */
export interface MonthlyUsage {
  /** Bu ay başlayan toplantıların süresi (açık olanlar şimdiye ya da en çok süreye kadar). */
  readonly meetingSeconds: number;
  readonly audioSeconds: number;
  /** Sınıra sayılan süre: toplantı ve ses süresinden büyüğü (aynı toplantının sesi iki kez sayılmaz). */
  readonly usedSeconds: number;
}

/** Kullanıcının bu ayki kullanımı. */
export async function monthlyUsage(db: D1Database, userId: string, now: Date): Promise<MonthlyUsage> {
  const nowMs: number = now.getTime();
  const [meetingRow, usageRow]: [{ seconds: number | null } | null, { audio_seconds: number } | null] = await Promise.all([
    db
      .prepare(
        `SELECT SUM(MAX(0, MIN(COALESCE(ended_at, ?), max_ends_at, ?) - started_at)) / 1000.0 AS seconds
         FROM meeting_sessions WHERE user_id = ? AND started_at >= ?`,
      )
      .bind(nowMs, nowMs, userId, monthStartMs(now))
      .first<{ seconds: number | null }>(),
    db
      .prepare("SELECT audio_seconds + audio_reserved AS audio_seconds FROM monthly_usage WHERE user_id = ? AND month = ?")
      .bind(userId, monthKey(now))
      .first<{ audio_seconds: number }>(),
  ]);
  const meetingSeconds: number = Math.ceil(meetingRow?.seconds ?? 0);
  const audioSeconds: number = Math.ceil(usageRow?.audio_seconds ?? 0);
  return { meetingSeconds, audioSeconds, usedSeconds: Math.max(meetingSeconds, audioSeconds) };
}

/** Bugünkü tahmini toplam harcama (mikro dolar). */
export async function todaySpendMicroUsd(db: D1Database, now: Date): Promise<number> {
  const row: { micro_usd: number } | null = await db
    .prepare("SELECT micro_usd FROM daily_spend WHERE day = ?")
    .bind(dayKey(now))
    .first<{ micro_usd: number }>();
  return row?.micro_usd ?? 0;
}

/** Günlük harcamaya ekleme ifadesi. */
export function addSpendStatement(db: D1Database, now: Date, microUsd: number): D1PreparedStatement {
  return db
    .prepare("INSERT INTO daily_spend (day, micro_usd) VALUES (?, ?) ON CONFLICT(day) DO UPDATE SET micro_usd = micro_usd + excluded.micro_usd")
    .bind(dayKey(now), microUsd);
}

/**
 * Günlük harcama tavanı: aşıldıysa alarm logu yazar ve 503 `spend_ceiling_reached` fırlatır. Toplantı başlatmada ve
 * her vekil çağrısında (LLM, konuşma tanıma) denetlenir.
 */
export async function requireSpendHeadroom(db: D1Database, config: Config, now: Date): Promise<void> {
  const spent: number = await todaySpendMicroUsd(db, now);
  if (spent < config.dailySpendCeilingMicroUsd) {
    return;
  }
  log("alert", "daily_spend_ceiling_reached", { day: dayKey(now), spentMicroUsd: spent, ceilingMicroUsd: config.dailySpendCeilingMicroUsd });
  throw new ApiError("spend_ceiling_reached", "Servis bugün yoğun; şu an yeni istek alınamıyor. Lütfen daha sonra yeniden dene.");
}
