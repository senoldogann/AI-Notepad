import { log } from "./log";
import { expiredReservationStatements } from "./reservations";
import { dayKey } from "./usage";

/** SQL bağ değeri. */
type SqlValue = string | number | null;

/** Temizlik sınırları: her turda en çok `batchSize` satır, tablo başına en çok `maxBatchesPerTable` tur. */
export interface CleanupLimits {
  readonly batchSize: number;
  readonly maxBatchesPerTable: number;
}

/** Tablo adı → silinen satır sayısı. */
export type CleanupReport = Readonly<Record<string, number>>;

/** Silinecek satırların tablosu ve koşulu. */
interface CleanupTarget {
  readonly table: string;
  readonly where: string;
  readonly binds: readonly SqlValue[];
}

const dayMs: number = 86_400_000;
/** İşlenmiş Stripe olayları 90 gün tutulur (Stripe en çok 3 gün yeniden dener). */
const stripeEventRetentionMs: number = 90 * dayMs;
/** Günlük harcama 90 gün tutulur (maliyet incelemesi için; tavan yalnızca bugüne bakar). */
const dailySpendRetentionMs: number = 90 * dayMs;
/** Kullanıcı başına günlük kullanım 2 gün tutulur (gece yarısını aşan çağrının kesinleştirmesi dünün satırını yazar). */
const dailyUsageRetentionMs: number = 2 * dayMs;
/** Raporlar (geri bildirim, çökme, iletişim; durumundan bağımsız) 180 gün tutulur. */
const reportRetentionMs: number = 180 * dayMs;
/** Kimlik deneme defteri son güncellemeden 730 gün (24 ay) tutulur (bkz. `trialLedger.ts`). */
const trialLedgerRetentionMs: number = 730 * dayMs;

/**
 * Zamanlanmış temizliğin sınırları: tablo başına günde en çok 4 × 1000 satır. 11 tablo × 4 tur = en çok 44 sorgu;
 * Workers ücretsiz planının çağrı başına 50 D1 sorgusu sınırının altındadır. Kalan satırlar ertesi gün silinir.
 */
export const scheduledCleanupLimits: CleanupLimits = { batchSize: 1000, maxBatchesPerTable: 4 };

/**
 * Süresi dolmuş ya da işi bitmiş satırlar. Saf fonksiyondur. Denetimlerin baktığı satırlar korunur:
 * - kullanılmış ama süresi dolmamış yenileme jetonu (yeniden kullanım algılaması için) yalnızca ailesi düşürülmüşse
 *   silinir; jetonu kalmayan aile silinir (erişim jetonu aile bulunamayınca zaten geçersizdir);
 * - deneme başlangıçları yalnızca bugün sayılır (IP başına günlük sınır), daha eskileri silinir.
 */
function cleanupTargets(now: Date): CleanupTarget[] {
  const nowMs: number = now.getTime();
  const today: string = dayKey(now);
  return [
    { table: "used_nonces", where: "expires_at <= ?", binds: [nowMs] },
    { table: "device_challenges", where: "expires_at <= ? OR used_at IS NOT NULL", binds: [nowMs] },
    {
      table: "refresh_tokens",
      where: "expires_at <= ? OR family_id IN (SELECT id FROM refresh_families WHERE revoked_at IS NOT NULL)",
      binds: [nowMs],
    },
    {
      // Ailede daha sonra kullanılmış bir jeton varsa eski kullanılmış jeton yeniden kullanım algılamasına gerekmez.
      table: "refresh_tokens",
      where: `used_at IS NOT NULL AND EXISTS (SELECT 1 FROM refresh_tokens AS newer
        WHERE newer.family_id = refresh_tokens.family_id AND newer.used_at > refresh_tokens.used_at)`,
      binds: [],
    },
    {
      table: "refresh_families",
      where: "NOT EXISTS (SELECT 1 FROM refresh_tokens WHERE refresh_tokens.family_id = refresh_families.id)",
      binds: [],
    },
    { table: "stripe_events", where: "processed_at < ?", binds: [nowMs - stripeEventRetentionMs] },
    { table: "trial_starts", where: "day < ?", binds: [today] },
    { table: "deleted_trial_starts", where: "day < ?", binds: [today] },
    { table: "daily_spend", where: "day < ?", binds: [dayKey(new Date(nowMs - dailySpendRetentionMs))] },
    { table: "daily_usage", where: "day < ?", binds: [dayKey(new Date(nowMs - dailyUsageRetentionMs))] },
    { table: "reports", where: "created_at < ?", binds: [nowMs - reportRetentionMs] },
    { table: "trial_identity_ledger", where: "updated_at < ?", binds: [nowMs - trialLedgerRetentionMs] },
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
  log("warn", "cleanup_incomplete", { table: target.table, deleted });
  return deleted;
}

/**
 * Süresi dolmuş ya da işi bitmiş satırları siler (`cleanupTargets`); her tablo sınırlı turlarla. Günlük Cron
 * Trigger'ı (`wrangler.jsonc` → `triggers.crons`) çağırır. Silinen sayıları loglar ve döndürür.
 */
export async function cleanupExpiredRows(db: D1Database, now: Date, limits: CleanupLimits): Promise<CleanupReport> {
  const report: Record<string, number> = {};
  // Süresi dolmuş ayırmalar: tahmini maliyet harcamaya yazılır, satırlar silinir (aynı toplu işlem).
  const expired: D1Result[] = await db.batch(expiredReservationStatements(db, now));
  const expiredCount: number = expired[1]?.meta.changes ?? 0;
  if (expiredCount > 0) {
    log("warn", "usage_reservations_expired", { count: expiredCount });
  }
  report["usage_reservations"] = expiredCount;
  for (const target of cleanupTargets(now)) {
    report[target.table] = (report[target.table] ?? 0) + (await deleteInBatches(db, target, limits));
  }
  log("info", "cleanup_done", report);
  return report;
}
