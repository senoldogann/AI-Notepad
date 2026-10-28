import type { Config } from "./config";
import { type MonthlyUsage, monthlyUsage } from "./usage";

/** Webhook'un yazdığı abonelik durumu. */
export interface SubscriptionState {
  readonly status: string;
  readonly currentPeriodEnd: number;
}

/** Kullanıcının planı: deneme ya da abonelik. */
export type Plan = "trial" | "subscription";

/**
 * Aboneliğin erişim durumu: `active` (ödenmiş dönem), `grace` (`past_due`, dönem sonundan sonra ek süre içinde),
 * `none` (erişim yok: `unpaid`, `canceled`, `incomplete_expired`, süresi geçmiş ya da bilinmeyen durum).
 */
export type SubscriptionAccess = "active" | "grace" | "none";

/** `GET /v1/me` yanıtı. */
export interface Entitlements {
  readonly userId: string;
  readonly plan: Plan;
  readonly trialMeetingsTotal: number;
  /** Etkin kalan deneme: hesap ve (bildirilen doğrulanmış cihaz varsa) cihaz kalanının küçüğü. */
  readonly trialMeetingsLeft: number;
  readonly accountTrialMeetingsLeft: number;
  /** Bildirilen cihazın kalan denemesi; cihaz bildirilmediyse ya da kayıtlı değilse null. */
  readonly deviceTrialMeetingsLeft: number | null;
  readonly monthlyHoursUsed: number;
  readonly monthlyHoursCap: number;
  readonly subscription: {
    readonly status: string;
    readonly currentPeriodEnd: string;
    readonly access: SubscriptionAccess;
    /** `past_due` ek süresinin bittiği an; ek süre yoksa null. */
    readonly graceEndsAt: string | null;
  } | null;
}

/**
 * Aboneliğin erişim durumu. `active`/`trialing` dönem sonuna dek; `past_due` dönem sonundan sonra `pastDueGraceMs`
 * boyunca (Stripe ödemeyi yeniden denerken) erişimi korur. Saf fonksiyondur.
 */
export function subscriptionAccess(subscription: SubscriptionState | null, now: Date, pastDueGraceMs: number): SubscriptionAccess {
  if (subscription === null) {
    return "none";
  }
  if (["active", "trialing"].includes(subscription.status) && subscription.currentPeriodEnd > now.getTime()) {
    return "active";
  }
  if (subscription.status === "past_due" && subscription.currentPeriodEnd + pastDueGraceMs > now.getTime()) {
    return "grace";
  }
  return "none";
}

/**
 * Abonelik bitmiş mi: `canceled`, `incomplete_expired` ya da dönemi geçmiş `unpaid`. Bitmemiş abonelik (`active`,
 * `trialing`, `past_due`, `unpaid`, `incomplete`, `paused`) ek süresi geçmiş olsa da Stripe'ta yaşar: yeni Checkout
 * açılmaz (Portal'dan yönetilir) ve başka bir aboneliğin olayı onu ezmez (bkz. `handleStripeWebhook`; SQL koşulu bu
 * fonksiyonla aynıdır). Saf fonksiyondur.
 */
export function isTerminalSubscription(subscription: SubscriptionState, now: Date): boolean {
  if (subscription.status === "canceled" || subscription.status === "incomplete_expired") {
    return true;
  }
  return subscription.status === "unpaid" && subscription.currentPeriodEnd <= now.getTime();
}

/** Abonelik hak veriyor mu (`active` ya da `grace`). Saf fonksiyondur. */
export function hasSubscriptionAccess(subscription: SubscriptionState | null, now: Date, pastDueGraceMs: number): boolean {
  return subscriptionAccess(subscription, now, pastDueGraceMs) !== "none";
}

/** Kullanıcının abonelik durumu (yoksa null). */
export async function subscriptionState(db: D1Database, userId: string): Promise<SubscriptionState | null> {
  const row: { status: string; current_period_end: number } | null = await db
    .prepare("SELECT status, current_period_end FROM subscriptions WHERE user_id = ?")
    .bind(userId)
    .first<{ status: string; current_period_end: number }>();
  return row === null ? null : { status: row.status, currentPeriodEnd: row.current_period_end };
}

/** Kullanıcının harcadığı deneme toplantısı sayısı. */
export async function userTrialMeetingsUsed(db: D1Database, userId: string): Promise<number> {
  const row: { count: number } | null = await db
    .prepare("SELECT COUNT(*) AS count FROM meeting_sessions WHERE user_id = ? AND kind = 'trial'")
    .bind(userId)
    .first<{ count: number }>();
  return row?.count ?? 0;
}

/** Kayıtlı cihazda (tüm hesaplarca) harcanan deneme sayısı; cihaz kayıtlı değilse null. */
export async function deviceTrialMeetingsUsed(db: D1Database, deviceId: string): Promise<number | null> {
  const row: { registered: number; count: number } | null = await db
    .prepare(
      `SELECT EXISTS (SELECT 1 FROM devices WHERE id = ?) AS registered,
         (SELECT COUNT(*) FROM meeting_sessions WHERE device_id = ? AND kind = 'trial') AS count`,
    )
    .bind(deviceId, deviceId)
    .first<{ registered: number; count: number }>();
  return row === null || row.registered === 0 ? null : row.count;
}

/** Saatin onda biri hassasiyetle saat. Saf fonksiyondur. */
export function hoursRoundedUp(seconds: number): number {
  return Math.ceil((seconds / 3600) * 10) / 10;
}

/**
 * Hak durumu: plan, etkin kalan deneme (cihaz bildirildiyse hesap ve cihazın küçüğü), aylık kullanım, sınır ve
 * abonelik erişimi (ek süre dahil). `deviceId` istemcinin bildirdiği App Attest anahtar kimliğidir; yalnızca
 * gösterim içindir, hak toplantı başlatırken imzalı onayla yeniden denetlenir.
 */
export async function entitlements(db: D1Database, config: Config, userId: string, deviceId: string | null, now: Date): Promise<Entitlements> {
  const [subscription, trialUsed, deviceUsed, usage]: [SubscriptionState | null, number, number | null, MonthlyUsage] = await Promise.all([
    subscriptionState(db, userId),
    userTrialMeetingsUsed(db, userId),
    deviceId === null ? Promise.resolve(null) : deviceTrialMeetingsUsed(db, deviceId),
    monthlyUsage(db, userId, now),
  ]);
  const access: SubscriptionAccess = subscriptionAccess(subscription, now, config.pastDueGraceMs);
  const accountLeft: number = Math.max(0, config.trialMeetings - trialUsed);
  const deviceLeft: number | null = deviceUsed === null ? null : Math.max(0, config.trialMeetings - deviceUsed);
  return {
    userId,
    plan: access === "none" ? "trial" : "subscription",
    trialMeetingsTotal: config.trialMeetings,
    trialMeetingsLeft: deviceLeft === null ? accountLeft : Math.min(accountLeft, deviceLeft),
    accountTrialMeetingsLeft: accountLeft,
    deviceTrialMeetingsLeft: deviceLeft,
    monthlyHoursUsed: hoursRoundedUp(usage.usedSeconds),
    monthlyHoursCap: config.monthlyCapSeconds / 3600,
    subscription:
      subscription === null
        ? null
        : {
            status: subscription.status,
            currentPeriodEnd: new Date(subscription.currentPeriodEnd).toISOString(),
            access,
            graceEndsAt: access === "grace" ? new Date(subscription.currentPeriodEnd + config.pastDueGraceMs).toISOString() : null,
          },
  };
}
