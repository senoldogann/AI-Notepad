import { dayKey } from "./usage";

/** Reddedilen deneme başlatmanın nedeni (`trial_refusals.reason`). */
export type TrialRefusalReason = "device_used" | "exhausted" | "expired" | "ip_daily_limit";

/** Reddedilen deneme başlatmayı bugünün (UTC) neden sayacına ekler; kullanıcı ya da IP yazılmaz. */
export async function recordTrialRefusal(db: D1Database, reason: TrialRefusalReason, now: Date): Promise<void> {
  await db
    .prepare("INSERT INTO trial_refusals (day, reason, count) VALUES (?, ?, 1) ON CONFLICT(day, reason) DO UPDATE SET count = count + 1")
    .bind(dayKey(now), reason)
    .run();
}
