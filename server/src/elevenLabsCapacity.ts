import type { Config } from "./config";
import { ApiError } from "./errors";
import { log } from "./log";
import { dayKey } from "./usage";

/**
 * ElevenLabs kapasitesi: Creator planı sabit aylık kredidir (`ELEVENLABS_MONTHLY_AUDIO_HOURS` saat ses), her ay
 * `ELEVENLABS_BILLING_DAY` günü yenilenir; kredi bitince her konuşma tanıma isteği başarısız olur ve sağlayıcı uyarı
 * vermez. Kullanım hesaptan bağımsız toplamdan okunur (`daily_spend.audio_seconds`, ElevenLabs'e giden ses saniyesi;
 * hesap silinince toplantılar silinse de kalır).
 */

/** Uyarı eşikleri (kullanım oranı). */
export const elevenLabsAlertThresholds: readonly number[] = [0.8, 0.95];
/** Bu orandan sonra yeni ses işleme isteği kabul edilmez: kredi tükenip abonelerin isteği sağlayıcıda düşmesin. */
export const elevenLabsHardStopRatio: number = 0.97;
/** Bu orandan sonra yeni deneme toplantısı açılmaz: kalan kapasite abonelere kalır. */
export const elevenLabsTrialStopRatio: number = 0.85;

/** Bu dönemin ElevenLabs kullanımı. */
export interface ElevenLabsUsage {
  /** Dönemin ilk günü (UTC, `YYYY-MM-DD`). */
  readonly cycleStart: string;
  readonly usedHours: number;
  readonly capHours: number;
  /** Kullanım yüzdesi (bir ondalık). */
  readonly percent: number;
}

/**
 * Faturalama döneminin ilk günü (UTC): bugün ayın `billingDay`'inden önceyse geçen ayın, değilse bu ayın o günü.
 * `billingDay` 1–28'dir (yapılandırmada doğrulanır). Saf fonksiyondur.
 */
export function billingCycleStart(now: Date, billingDay: number): string {
  const year: number = now.getUTCFullYear();
  const month: number = now.getUTCMonth();
  const start: number = now.getUTCDate() >= billingDay ? Date.UTC(year, month, billingDay) : Date.UTC(year, month - 1, billingDay);
  return dayKey(new Date(start));
}

/** Saniyeden dönem kullanımı. Saf fonksiyondur. */
export function elevenLabsUsageOf(usedSeconds: number, capHours: number, cycleStart: string): ElevenLabsUsage {
  const usedHours: number = usedSeconds / 3600;
  return {
    cycleStart,
    usedHours: Math.round(usedHours * 10) / 10,
    capHours,
    percent: Math.round((usedHours / capHours) * 1000) / 10,
  };
}

/** Kullanım `before`'dan `after`'a çıkarken aşılan en yüksek eşik; aşılan yoksa null. Saf fonksiyondur. */
export function crossedThreshold(beforeSeconds: number, afterSeconds: number, capSeconds: number): number | null {
  const crossed: number[] = elevenLabsAlertThresholds.filter(
    (threshold: number): boolean => beforeSeconds < threshold * capSeconds && afterSeconds >= threshold * capSeconds,
  );
  return crossed.at(-1) ?? null;
}

/** Bu dönem ElevenLabs'e giden ses saniyesi. */
async function cycleAudioSeconds(db: D1Database, config: Config, now: Date): Promise<{ cycleStart: string; seconds: number }> {
  const cycleStart: string = billingCycleStart(now, config.elevenLabs.billingDay);
  const row: { seconds: number } | null = await db
    .prepare("SELECT COALESCE(SUM(audio_seconds), 0) AS seconds FROM daily_spend WHERE day >= ?")
    .bind(cycleStart)
    .first<{ seconds: number }>();
  return { cycleStart, seconds: row?.seconds ?? 0 };
}

/** Bu dönemin ElevenLabs kullanımı (yönetici istatistiği). */
export async function elevenLabsUsage(db: D1Database, config: Config, now: Date): Promise<ElevenLabsUsage> {
  const { cycleStart, seconds } = await cycleAudioSeconds(db, config, now);
  return elevenLabsUsageOf(seconds, config.elevenLabs.monthlyAudioHours, cycleStart);
}

/**
 * Yeni yazılan `addedSeconds` kullanımı bir eşiği (%80, %95) aştırdıysa hemen `alert` yazar (dönem başına eşik başına
 * bir kez: aşım yalnızca bir kesinleştirmede olur).
 */
export async function alertOnElevenLabsCrossing(db: D1Database, config: Config, addedSeconds: number, now: Date): Promise<void> {
  const { cycleStart, seconds } = await cycleAudioSeconds(db, config, now);
  const capSeconds: number = config.elevenLabs.monthlyAudioHours * 3600;
  const threshold: number | null = crossedThreshold(seconds - addedSeconds, seconds, capSeconds);
  if (threshold !== null) {
    const usage: ElevenLabsUsage = elevenLabsUsageOf(seconds, config.elevenLabs.monthlyAudioHours, cycleStart);
    log("alert", "elevenlabs_capacity_threshold", { threshold, ...usage });
  }
}

/**
 * Ses işleme isteğinden önce: bu dönemin kullanımı + `addedSeconds` kapasitenin `elevenLabsHardStopRatio`'sunu aşacaksa
 * istek ElevenLabs'e gitmeden `spend_ceiling_reached` (anlaşılır 503; aksi halde kredi bitince istek sağlayıcıda 502 ile
 * düşerdi) ve `alert` yazılır.
 */
export async function requireElevenLabsHeadroom(db: D1Database, config: Config, addedSeconds: number, now: Date): Promise<void> {
  const { cycleStart, seconds } = await cycleAudioSeconds(db, config, now);
  const capSeconds: number = config.elevenLabs.monthlyAudioHours * 3600;
  if (seconds + addedSeconds <= elevenLabsHardStopRatio * capSeconds) {
    return;
  }
  log("alert", "elevenlabs_capacity_exhausted", { addedSeconds, ...elevenLabsUsageOf(seconds, config.elevenLabs.monthlyAudioHours, cycleStart) });
  throw new ApiError("spend_ceiling_reached", "Konuşma tanıma kapasitesi bu dönem doldu; biraz sonra yeniden dene.");
}

/** Yeni deneme toplantısından önce: kullanım `elevenLabsTrialStopRatio`'yu geçtiyse `trial_capacity_reached`. */
export async function requireElevenLabsTrialHeadroom(db: D1Database, config: Config, now: Date): Promise<void> {
  const { cycleStart, seconds } = await cycleAudioSeconds(db, config, now);
  if (seconds < elevenLabsTrialStopRatio * config.elevenLabs.monthlyAudioHours * 3600) {
    return;
  }
  log("warn", "elevenlabs_trial_stop", { ...elevenLabsUsageOf(seconds, config.elevenLabs.monthlyAudioHours, cycleStart) });
  throw new ApiError("trial_capacity_reached", "Ücretsiz denemeler şu an kapasitede; yarın yeniden dene ya da abone ol.");
}

/** Günlük denetim (Cron): kullanım bir eşiğin üstündeyse günde bir `alert` yazar. Kullanımı döndürür. */
export async function dailyElevenLabsCapacityCheck(db: D1Database, config: Config, now: Date): Promise<ElevenLabsUsage> {
  const usage: ElevenLabsUsage = await elevenLabsUsage(db, config, now);
  const reached: number | undefined = elevenLabsAlertThresholds.filter((threshold: number): boolean => usage.percent >= threshold * 100).at(-1);
  if (reached !== undefined) {
    log("alert", "elevenlabs_capacity_high", { threshold: reached, ...usage });
  }
  return usage;
}
