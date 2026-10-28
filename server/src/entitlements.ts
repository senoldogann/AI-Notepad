import type { Config } from "./config";
import { type MonthlyUsage, monthlyUsage } from "./usage";

/** Webhook'un yazdığı abonelik durumu. */
export interface SubscriptionState {
  readonly status: string;
  readonly currentPeriodEnd: number;
}

/** Kullanıcının planı: deneme ya da abonelik. */
export type Plan = "trial" | "subscription";

/** `GET /v1/me` yanıtı. */
export interface Entitlements {
  readonly userId: string;
  readonly plan: Plan;
  readonly trialMeetingsTotal: number;
  readonly trialMeetingsLeft: number;
  readonly monthlyHoursUsed: number;
  readonly monthlyHoursCap: number;
  readonly subscription: { readonly status: string; readonly currentPeriodEnd: string } | null;
}

/** Abonelik hak veriyor mu: `active` ya da `trialing` ve dönem bitmemiş. Saf fonksiyondur. */
export function isSubscriptionActive(subscription: SubscriptionState | null, now: Date): boolean {
  return subscription !== null && ["active", "trialing"].includes(subscription.status) && subscription.currentPeriodEnd > now.getTime();
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

/** Saatin onda biri hassasiyetle saat. Saf fonksiyondur. */
export function hoursRoundedUp(seconds: number): number {
  return Math.ceil((seconds / 3600) * 10) / 10;
}

/** Hak durumu: plan, kalan deneme, aylık kullanım ve sınır. */
export async function entitlements(db: D1Database, config: Config, userId: string, now: Date): Promise<Entitlements> {
  const [subscription, trialUsed, usage]: [SubscriptionState | null, number, MonthlyUsage] = await Promise.all([
    subscriptionState(db, userId),
    userTrialMeetingsUsed(db, userId),
    monthlyUsage(db, userId, now),
  ]);
  return {
    userId,
    plan: isSubscriptionActive(subscription, now) ? "subscription" : "trial",
    trialMeetingsTotal: config.trialMeetings,
    trialMeetingsLeft: Math.max(0, config.trialMeetings - trialUsed),
    monthlyHoursUsed: hoursRoundedUp(usage.usedSeconds),
    monthlyHoursCap: config.monthlyCapSeconds / 3600,
    subscription:
      subscription === null
        ? null
        : { status: subscription.status, currentPeriodEnd: new Date(subscription.currentPeriodEnd).toISOString() },
  };
}
