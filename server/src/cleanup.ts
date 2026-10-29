import { errorName, log } from "./log";
import { expiredReservationStatements } from "./reservations";
import { dayKey, monthKey } from "./usage";

/** SQL bağ değeri. */
type SqlValue = string | number | null;

/** Temizlik sınırları: her turda en çok `batchSize` satır, tablo başına en çok `maxBatchesPerTable` tur. */
export interface CleanupLimits {
  readonly batchSize: number;
  readonly maxBatchesPerTable: number;
}

/** Adım adı → silinen (ya da kapatılan) satır sayısı. */
export type CleanupReport = Readonly<Record<string, number>>;

/** Bir ya da daha çok temizlik adımı başarısız oldu; diğer adımlar yine çalıştı. Yalnızca adım adlarını taşır. */
export class CleanupFailedError extends Error {
  override readonly name: string = "CleanupFailedError";
  readonly steps: readonly string[];
  /** Başarılı adımların raporu. */
  readonly report: CleanupReport;

  constructor(steps: readonly string[], report: CleanupReport) {
    super(`Temizlik adımları başarısız: ${steps.join(", ")}`);
    this.steps = steps;
    this.report = report;
  }
}

/** Sınırlı turlarla silinecek satırların tablosu ve koşulu. */
interface CleanupTarget {
  /** Rapordaki ad (aynı tabloda birden çok koşul olabilir). */
  readonly name: string;
  readonly table: string;
  readonly where: string;
  readonly binds: readonly SqlValue[];
}

/** Tek toplu işlemde (D1 işlemi) çalışan temizlik adımı; sayı `countIndex`'teki ifadenin değiştirdiği satırdır. */
interface CleanupBatch {
  readonly name: string;
  readonly statements: readonly D1PreparedStatement[];
  readonly countIndex: number;
}

const dayMs: number = 86_400_000;
/** İşlenmiş Stripe olayları 90 gün tutulur (Stripe en çok 3 gün yeniden dener). */
const stripeEventRetentionMs: number = 90 * dayMs;
/** Kopya abonelik kaydının saklama süresi: geç ödenen faturası bu süre içinde iade edilir. */
const duplicateSubscriptionRetentionMs: number = 400 * dayMs;
/** Günlük harcama 90 gün tutulur (maliyet incelemesi için; tavan yalnızca bugüne bakar). */
const dailySpendRetentionMs: number = 90 * dayMs;
/** Kullanıcı başına günlük kullanım 2 gün tutulur (gece yarısını aşan çağrının kesinleştirmesi dünün satırını yazar). */
const dailyUsageRetentionMs: number = 2 * dayMs;
/** Raporlar (geri bildirim, çökme, iletişim; durumundan bağımsız) 180 gün tutulur. */
const reportRetentionMs: number = 180 * dayMs;
/** Kimlik deneme defteri son güncellemeden 730 gün (24 ay) tutulur (bkz. `trialLedger.ts`). */
const trialLedgerRetentionMs: number = 730 * dayMs;
/** Toplantılar, aylık kullanım ve kullanılmayan cihazlar 13 ay (~395 gün) tutulur (yıllık karşılaştırma + bir ay). */
const usageRetentionMs: number = 395 * dayMs;

/**
 * Zamanlanmış temizliğin sınırları: tablo başına günde en çok 3 × 1000 satır. 13 tablo koşulu × 3 tur + 3 toplu işlem
 * = en çok 42 sorgu; Workers ücretsiz planının çağrı başına 50 D1 sorgusu sınırının altındadır. Kalan satırlar ertesi
 * gün silinir.
 */
export const scheduledCleanupLimits: CleanupLimits = { batchSize: 1000, maxBatchesPerTable: 3 };

/**
 * Sınırlı turlarla silinecek satırlar. Saf fonksiyondur. Denetimlerin baktığı satırlar korunur:
 * - kullanılmış ama süresi dolmamış yenileme jetonu (yeniden kullanım algılaması için) yalnızca ailesi düşürülmüşse ya
 *   da ailede daha sonra kullanılmış bir jeton varsa silinir; jetonu kalmayan aile silinir (erişim jetonu aile
 *   bulunamayınca zaten geçersizdir);
 * - deneme başlangıçları yalnızca bugün sayılır (IP başına günlük sınır), daha eskileri silinir;
 * - aylık kullanım 13 ay tutulur (sınırlar yalnızca bu aya bakar).
 */
function cleanupTargets(now: Date): CleanupTarget[] {
  const nowMs: number = now.getTime();
  const today: string = dayKey(now);
  return [
    { name: "used_nonces", table: "used_nonces", where: "expires_at <= ?", binds: [nowMs] },
    { name: "transcription_results", table: "transcription_results", where: "expires_at <= ?", binds: [nowMs] },
    { name: "device_challenges", table: "device_challenges", where: "expires_at <= ? OR used_at IS NOT NULL", binds: [nowMs] },
    {
      name: "refresh_tokens",
      table: "refresh_tokens",
      where: "expires_at <= ? OR family_id IN (SELECT id FROM refresh_families WHERE revoked_at IS NOT NULL)",
      binds: [nowMs],
    },
    {
      // Ailede daha sonra kullanılmış bir jeton varsa eski kullanılmış jeton yeniden kullanım algılamasına gerekmez.
      name: "refresh_tokens_superseded",
      table: "refresh_tokens",
      where: `used_at IS NOT NULL AND EXISTS (SELECT 1 FROM refresh_tokens AS newer
        WHERE newer.family_id = refresh_tokens.family_id AND newer.used_at > refresh_tokens.used_at)`,
      binds: [],
    },
    {
      name: "refresh_families",
      table: "refresh_families",
      where: "NOT EXISTS (SELECT 1 FROM refresh_tokens WHERE refresh_tokens.family_id = refresh_families.id)",
      binds: [],
    },
    { name: "stripe_events", table: "stripe_events", where: "processed_at < ?", binds: [nowMs - stripeEventRetentionMs] },
    { name: "duplicate_subscriptions", table: "duplicate_subscriptions", where: "created_at < ?", binds: [nowMs - duplicateSubscriptionRetentionMs] },
    { name: "trial_starts", table: "trial_starts", where: "day < ?", binds: [today] },
    { name: "deleted_trial_starts", table: "deleted_trial_starts", where: "day < ?", binds: [today] },
    { name: "daily_spend", table: "daily_spend", where: "day < ?", binds: [dayKey(new Date(nowMs - dailySpendRetentionMs))] },
    { name: "daily_usage", table: "daily_usage", where: "day < ?", binds: [dayKey(new Date(nowMs - dailyUsageRetentionMs))] },
    { name: "monthly_usage", table: "monthly_usage", where: "month < ?", binds: [monthKey(new Date(nowMs - usageRetentionMs))] },
    { name: "reports", table: "reports", where: "created_at < ?", binds: [nowMs - reportRetentionMs] },
    { name: "trial_identity_ledger", table: "trial_identity_ledger", where: "updated_at < ?", binds: [nowMs - trialLedgerRetentionMs] },
  ];
}

/**
 * Tek toplu işlemli adımlar (birlikte değişmesi gereken satırlar):
 * - süresi dolmuş ayırmalar: tahmini maliyet harcamaya yazılır, satırlar silinir (`expiredReservationStatements`);
 * - 13 aydan eski toplantılar: silinmeden önce kullanıcının deneme toplantıları `users.carried_trial_meetings`'e
 *   eklenir ve deneme başlangıcı korunur (deneme hakkı geri gelmez);
 * - 13 aydır kullanılmayan cihazlar: önce toplantıların cihaz bağı kaldırılır.
 * Saf fonksiyondur.
 */
function cleanupBatches(db: D1Database, now: Date): CleanupBatch[] {
  const cutoff: number = now.getTime() - usageRetentionMs;
  return [
    { name: "usage_reservations", statements: expiredReservationStatements(db, now), countIndex: 1 },
    {
      name: "meeting_sessions",
      statements: [
        db
          .prepare(
            `UPDATE users SET
               carried_trial_meetings = carried_trial_meetings
                 + (SELECT COUNT(*) FROM meeting_sessions m WHERE m.user_id = users.id AND m.kind = 'trial' AND m.started_at < ?1),
               trial_started_at = COALESCE(trial_started_at,
                 (SELECT MIN(started_at) FROM meeting_sessions m WHERE m.user_id = users.id AND m.kind = 'trial'))
             WHERE id IN (SELECT user_id FROM meeting_sessions WHERE kind = 'trial' AND started_at < ?1)`,
          )
          .bind(cutoff),
        db.prepare("DELETE FROM meeting_sessions WHERE started_at < ?").bind(cutoff),
      ],
      countIndex: 1,
    },
    {
      name: "devices",
      statements: [
        db.prepare("UPDATE meeting_sessions SET device_id = NULL WHERE device_id IN (SELECT id FROM devices WHERE last_used_at < ?)").bind(cutoff),
        db.prepare("DELETE FROM devices WHERE last_used_at < ?").bind(cutoff),
      ],
      countIndex: 1,
    },
  ];
}

/** Bir tablodan sınırlı turlarla siler; tur sınırına gelinip satır kaldıysa uyarı loglar. Silinen sayıyı döndürür. */
async function deleteInBatches(db: D1Database, target: CleanupTarget, limits: CleanupLimits): Promise<number> {
  const statement: D1PreparedStatement = db
    .prepare(`DELETE FROM ${target.table} WHERE rowid IN (SELECT rowid FROM ${target.table} WHERE ${target.where} LIMIT ?)`)
    .bind(...target.binds, limits.batchSize);
  let deleted: number = 0;
  for (let batch: number = 1; batch <= limits.maxBatchesPerTable; batch += 1) {
    const changes: number = (await statement.run()).meta.changes;
    deleted += changes;
    if (changes < limits.batchSize) {
      return deleted;
    }
  }
  log("warn", "cleanup_incomplete", { table: target.table, step: target.name, deleted });
  return deleted;
}

/** Toplu işlem adımını çalıştırır; sayılan ifadenin değiştirdiği satır sayısını döndürür. */
async function runBatch(db: D1Database, batch: CleanupBatch): Promise<number> {
  const results: D1Result[] = await db.batch([...batch.statements]);
  return results[batch.countIndex]?.meta.changes ?? 0;
}

/**
 * Süresi dolmuş ya da işi bitmiş satırları siler (`cleanupBatches`, `cleanupTargets`). Günlük Cron Trigger'ı
 * (`wrangler.jsonc` → `triggers.crons`) çağırır. Her adım ayrı denenir: biri başarısız olursa `cleanup_failed` alarmı
 * yazılır ve diğerleri yine çalışır; sonunda başarısız adımların adlarıyla `CleanupFailedError` fırlatılır (Cron
 * çalıştırması başarısız görünür). Hepsi başarılıysa silinen sayıları loglar ve döndürür.
 */
export async function cleanupExpiredRows(db: D1Database, now: Date, limits: CleanupLimits): Promise<CleanupReport> {
  const steps: ReadonlyArray<readonly [string, () => Promise<number>]> = [
    ...cleanupBatches(db, now).map((batch: CleanupBatch): readonly [string, () => Promise<number>] => [batch.name, (): Promise<number> => runBatch(db, batch)]),
    ...cleanupTargets(now).map((target: CleanupTarget): readonly [string, () => Promise<number>] => [
      target.name,
      (): Promise<number> => deleteInBatches(db, target, limits),
    ]),
  ];
  const report: Record<string, number> = {};
  const failed: string[] = [];
  for (const [name, run] of steps) {
    try {
      report[name] = await run();
    } catch (error: unknown) {
      // Bir tablonun hatası diğerlerinin temizliğini durdurmasın; hepsi bitince toplu hata fırlatılır.
      log("alert", "cleanup_failed", { step: name, error: errorName(error) });
      failed.push(name);
    }
  }
  if ((report["usage_reservations"] ?? 0) > 0) {
    log("warn", "usage_reservations_expired", { count: report["usage_reservations"] ?? 0 });
  }
  log("info", "cleanup_done", report);
  if (failed.length > 0) {
    throw new CleanupFailedError(failed, report);
  }
  return report;
}
