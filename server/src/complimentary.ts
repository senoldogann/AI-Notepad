import { z } from "zod";
import { randomId } from "./crypto";
import { ApiError } from "./errors";
import { log } from "./log";

/**
 * Ücretsiz tam erişim: yöneticinin verdiği, Stripe'tan faturalanmayan abonelik satırı (`subscriptions.complimentary =
 * 1`; göç 0039). Satır ödeyen aylık abonenin satırıyla aynı görünür (`status = 'active'`, `plan = 'monthly'`): haklar,
 * `/v1/me` ve davet kodu ödeyen aboneyle aynıdır. Stripe kimlikleri yapaydır (`comp_cus_<uuid>`, `comp_sub_<uuid>`),
 * Stripe'a hiç gönderilmez ve `stripe_customers` satırı yazılmaz. Portal açılmaz (`complimentary_subscription`), hesap
 * silmede Stripe çağrılmaz, davet ödülü Stripe'a gitmez, webhook süren ücretsiz erişimi ezmez ve yönetim
 * istatistikleri gelir saymaz.
 */

/** Süresiz ücretsiz erişimin dönem sonu: verilişten 100 yıl sonra. */
export const complimentaryForeverMs: number = 100 * 365 * 86_400_000;

/**
 * `POST /v1/admin/users/{id}/complimentary` gövdesi: `grant` verir ya da kaldırır; `until` (ISO 8601 tarih ya da
 * saat dilimli zaman) yalnızca verirken, bitiş tarihidir (yoksa süresiz).
 */
export const complimentaryRequestSchema = z
  .strictObject({
    grant: z.boolean(),
    until: z.union([z.iso.date(), z.iso.datetime({ offset: true })]).optional(),
  })
  .refine((body: { grant: boolean; until?: string | undefined }): boolean => body.grant || body.until === undefined, { path: ["until"] });

/** Ücretsiz erişimi olan hesabın Stripe'ta yönetilecek aboneliği yok (Portal, Checkout). */
export function complimentaryAccessError(): ApiError {
  return new ApiError("complimentary_subscription", "This account has free access; there is nothing to manage.");
}

/**
 * İstekteki bitiş tarihini ms'ye çevirir; tarih yoksa null (süresiz). Geçmiş ya da şimdiki an `invalid_body`. Saf
 * fonksiyondur.
 */
export function complimentaryUntilMs(until: string | null, now: Date): number | null {
  if (until === null) {
    return null;
  }
  const untilMs: number = Date.parse(until);
  if (!(untilMs > now.getTime())) {
    throw new ApiError("invalid_body", "\"until\" must be a date in the future.");
  }
  return untilMs;
}

/**
 * Hesaba ücretsiz erişim verir ya da süresini değiştirir. Süresizde dönem sonu şimdi + `complimentaryForeverMs` ve
 * `cancel_at` boştur; bitiş tarihliyse dönem sonu ve `cancel_at` o tarihtir (`/v1/me` biteceği anı gösterir, erişim
 * tam o anda biter). Mevcut ücretsiz erişimin yapay kimlikleri korunur. Bitmiş (`isTerminalSubscription`) Stripe
 * aboneliğinin satırı ücretsiz erişimle değiştirilir; bitmemiş Stripe aboneliği varsa `subscription_exists` (koşul aynı
 * SQL ifadesindedir: arada gelen webhook'un yazdığı aboneliğin üzerine yazılmaz). Hesap yoksa `not_found`.
 */
export async function grantComplimentaryAccess(db: D1Database, userId: string, untilMs: number | null, adminUserId: string, now: Date): Promise<void> {
  const nowMs: number = now.getTime();
  const user: { id: string } | null = await db.prepare("SELECT id FROM users WHERE id = ?").bind(userId).first<{ id: string }>();
  if (user === null) {
    throw new ApiError("not_found", "Account not found.");
  }
  const tag: string = randomId();
  const result: D1Result = await db
    .prepare(
      `INSERT INTO subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, current_period_end, cancel_at,
         past_due_since, last_event_created, updated_at, plan, complimentary)
       VALUES (?1, ?2, ?3, 'active', ?4, ?5, NULL, 0, ?6, 'monthly', 1)
       ON CONFLICT(user_id) DO UPDATE SET
         stripe_customer_id = CASE WHEN subscriptions.complimentary = 1 THEN subscriptions.stripe_customer_id ELSE excluded.stripe_customer_id END,
         stripe_subscription_id = CASE WHEN subscriptions.complimentary = 1 THEN subscriptions.stripe_subscription_id ELSE excluded.stripe_subscription_id END,
         status = 'active', current_period_end = excluded.current_period_end, cancel_at = excluded.cancel_at, past_due_since = NULL,
         updated_at = excluded.updated_at, plan = 'monthly', complimentary = 1
       WHERE subscriptions.complimentary = 1
         OR subscriptions.status IN ('canceled', 'incomplete_expired')
         OR (subscriptions.status = 'unpaid' AND subscriptions.current_period_end <= ?6)`,
    )
    .bind(userId, `comp_cus_${tag}`, `comp_sub_${tag}`, untilMs ?? nowMs + complimentaryForeverMs, untilMs, nowMs)
    .run();
  if (result.meta.changes !== 1) {
    log("warn", "complimentary_refused_paid_subscription", { userId, adminUserId });
    throw new ApiError("subscription_exists", "This account has a paid Stripe subscription; free access can't be granted over it.");
  }
  log("info", "complimentary_granted", { userId, adminUserId, untilMs });
}

/**
 * Hesabın ücretsiz erişimini kaldırır (satır silinir: hesap denemeye ya da plansız duruma döner; yeniden abone
 * olabilir). Ücretsiz erişimi yoksa `not_found`; Stripe aboneliğinin satırına dokunulmaz.
 */
export async function revokeComplimentaryAccess(db: D1Database, userId: string, adminUserId: string): Promise<void> {
  const result: D1Result = await db.prepare("DELETE FROM subscriptions WHERE user_id = ? AND complimentary = 1").bind(userId).run();
  if (result.meta.changes !== 1) {
    throw new ApiError("not_found", "This account has no free access to remove.");
  }
  log("info", "complimentary_revoked", { userId, adminUserId });
}
