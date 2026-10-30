import { AggregateRowMissingError, type SubscriptionCounts, type TrialCounts, monthlyRecurringRevenueUsd, subscriptionCounts, trialCounts } from "./admin";
import type { Config } from "./config";
import { log } from "./log";
import { utcDayStartMs } from "./reports";
import { type CurrencyMrr, invoicedMrrByCurrency } from "./revenue";
import { dayKey } from "./usage";

const dayMs: number = 86_400_000;

/**
 * Günlük anlık görüntü (`daily_metrics`, `daily_revenue_metrics`; göç 0041, 0042): günlük Cron her gece biten UTC
 * gününün (dün) toplamlarını ve gün sonundaki durumu yazar. Toplamlar o günün satırlarından; durum (abonelik, deneme,
 * MRR) Cron anındaki satırlardan gün sonu anına göre hesaplanır (gece yarısından sonra değişen satırın eski hâli
 * bilinmez; fark birkaç saatliktir). Kaynak tabloların saklama süresi dolsa da eğilim kalır. Yalnızca toplamlar.
 */
export interface DailyMetrics {
  readonly day: string;
  readonly capturedAt: number;
  readonly usersTotal: number;
  readonly usersNew: number;
  readonly activeUsersDay: number;
  readonly activeUsers7d: number;
  readonly activeUsers30d: number;
  readonly meetingsTrial: number;
  readonly meetingsSubscription: number;
  readonly trialsStarted: number;
  readonly trials: TrialCounts;
  readonly subscriptions: SubscriptionCounts;
  readonly mrrListCents: number;
  readonly spendAnthropicMicroUsd: number;
  readonly spendElevenLabsMicroUsd: number;
  readonly spendDeepgramMicroUsd: number;
  readonly spendTrialMicroUsd: number;
  readonly elevenLabsAudioSeconds: number;
  readonly deepgramStreamSeconds: number;
  /** Faturalanan MRR para birimine göre (`invoicedMrrByCurrency`). */
  readonly revenue: readonly CurrencyMrr[];
}

interface ActivityRow {
  readonly users_total: number;
  readonly users_new: number;
  readonly active_day: number;
  readonly active_7d: number;
  readonly active_30d: number;
  readonly meetings_trial: number;
  readonly meetings_subscription: number;
  readonly trials_started: number;
}

interface SpendRow {
  readonly micro_usd: number;
  readonly llm_micro_usd: number;
  readonly trial_micro_usd: number;
  readonly audio_seconds: number;
}

/** Biten günün toplamlarını okur (`now`: Cron anı; gün: ondan önceki UTC günü). */
export async function collectDailyMetrics(db: D1Database, config: Config, now: Date): Promise<DailyMetrics> {
  const dayEndMs: number = utcDayStartMs(now);
  const dayStartMs: number = dayEndMs - dayMs;
  const day: string = dayKey(new Date(dayStartMs));
  const [activity, spend, deepgram, trials, subscriptions, revenue] = await Promise.all([
    db
      .prepare(
        `SELECT
           (SELECT COUNT(*) FROM users WHERE created_at < ?2) AS users_total,
           (SELECT COUNT(*) FROM users WHERE created_at >= ?1 AND created_at < ?2) AS users_new,
           (SELECT COUNT(DISTINCT user_id) FROM meeting_sessions WHERE started_at >= ?1 AND started_at < ?2) AS active_day,
           (SELECT COUNT(DISTINCT user_id) FROM meeting_sessions WHERE started_at >= ?2 - 7 * ?3 AND started_at < ?2) AS active_7d,
           (SELECT COUNT(DISTINCT user_id) FROM meeting_sessions WHERE started_at >= ?2 - 30 * ?3 AND started_at < ?2) AS active_30d,
           (SELECT COUNT(*) FROM meeting_sessions WHERE kind = 'trial' AND started_at >= ?1 AND started_at < ?2) AS meetings_trial,
           (SELECT COUNT(*) FROM meeting_sessions WHERE kind = 'subscription' AND started_at >= ?1 AND started_at < ?2) AS meetings_subscription,
           (SELECT COUNT(*) FROM users WHERE trial_started_at >= ?1 AND trial_started_at < ?2) AS trials_started`,
      )
      .bind(dayStartMs, dayEndMs, dayMs)
      .first<ActivityRow>(),
    db.prepare("SELECT micro_usd, llm_micro_usd, trial_micro_usd, audio_seconds FROM daily_spend WHERE day = ?").bind(day).first<SpendRow>(),
    db
      .prepare("SELECT COALESCE(SUM(charged_seconds), 0) AS seconds FROM deepgram_live_meetings WHERE first_grant_at >= ? AND first_grant_at < ?")
      .bind(dayStartMs, dayEndMs)
      .first<{ seconds: number }>(),
    trialCounts(db, config, dayEndMs),
    subscriptionCounts(db, config, dayEndMs),
    invoicedMrrByCurrency(db, dayEndMs),
  ]);
  if (activity === null) {
    throw new AggregateRowMissingError("dailyMetrics.activity");
  }
  if (deepgram === null) {
    throw new AggregateRowMissingError("dailyMetrics.deepgram");
  }
  // Harcaması olmayan günün `daily_spend` satırı yoktur: harcama 0'dır.
  const spent: SpendRow = spend ?? { micro_usd: 0, llm_micro_usd: 0, trial_micro_usd: 0, audio_seconds: 0 };
  return {
    day,
    capturedAt: now.getTime(),
    usersTotal: activity.users_total,
    usersNew: activity.users_new,
    activeUsersDay: activity.active_day,
    activeUsers7d: activity.active_7d,
    activeUsers30d: activity.active_30d,
    meetingsTrial: activity.meetings_trial,
    meetingsSubscription: activity.meetings_subscription,
    trialsStarted: activity.trials_started,
    trials,
    subscriptions,
    mrrListCents: Math.round(monthlyRecurringRevenueUsd(subscriptions.monthly, subscriptions.yearly, config.priceUsdMonthly, config.priceUsdYearly) * 100),
    spendAnthropicMicroUsd: spent.llm_micro_usd,
    spendElevenLabsMicroUsd: spent.micro_usd - spent.llm_micro_usd,
    spendDeepgramMicroUsd: Math.round((deepgram.seconds / 60) * config.deepgram.microUsdPerMinute),
    spendTrialMicroUsd: spent.trial_micro_usd,
    elevenLabsAudioSeconds: spent.audio_seconds,
    deepgramStreamSeconds: deepgram.seconds,
    revenue,
  };
}

/** Anlık görüntünün yazım ifadeleri: günün satırı (varsa güncellenir) ve gelir satırları (günün eskileri silinir). */
function dailyMetricsStatements(db: D1Database, metrics: DailyMetrics): D1PreparedStatement[] {
  const subscriptions: SubscriptionCounts = metrics.subscriptions;
  const values: ReadonlyArray<readonly [string, number | string]> = [
    ["day", metrics.day],
    ["captured_at", metrics.capturedAt],
    ["users_total", metrics.usersTotal],
    ["users_new", metrics.usersNew],
    ["active_users_day", metrics.activeUsersDay],
    ["active_users_7d", metrics.activeUsers7d],
    ["active_users_30d", metrics.activeUsers30d],
    ["meetings_trial", metrics.meetingsTrial],
    ["meetings_subscription", metrics.meetingsSubscription],
    ["trials_started", metrics.trialsStarted],
    ["trials_active", metrics.trials.active],
    ["trials_exhausted", metrics.trials.exhausted],
    ["subscriptions_active", subscriptions.active],
    ["subscriptions_grace", subscriptions.grace],
    ["subscriptions_ending", subscriptions.ending],
    ["subscriptions_canceled", subscriptions.canceled],
    ["subscriptions_monthly", subscriptions.monthly],
    ["subscriptions_yearly", subscriptions.yearly],
    ["subscriptions_complimentary", subscriptions.complimentary],
    ["subscriptions_free_invite_month", subscriptions.freeInviteMonth],
    ["mrr_list_cents", metrics.mrrListCents],
    ["spend_anthropic_micro_usd", metrics.spendAnthropicMicroUsd],
    ["spend_elevenlabs_micro_usd", metrics.spendElevenLabsMicroUsd],
    ["spend_deepgram_micro_usd", metrics.spendDeepgramMicroUsd],
    ["spend_trial_micro_usd", metrics.spendTrialMicroUsd],
    ["elevenlabs_audio_seconds", metrics.elevenLabsAudioSeconds],
    ["deepgram_stream_seconds", metrics.deepgramStreamSeconds],
  ];
  const columns: string[] = values.map(([column]: readonly [string, number | string]): string => column);
  const updates: string = columns
    .filter((column: string): boolean => column !== "day")
    .map((column: string): string => `${column} = excluded.${column}`)
    .join(", ");
  return [
    db
      .prepare(
        `INSERT INTO daily_metrics (${columns.join(", ")}) VALUES (${columns.map((): string => "?").join(", ")})
         ON CONFLICT(day) DO UPDATE SET ${updates}`,
      )
      .bind(...values.map(([, value]: readonly [string, number | string]): number | string => value)),
    db.prepare("DELETE FROM daily_revenue_metrics WHERE day = ?").bind(metrics.day),
    ...metrics.revenue.map(
      (currency: CurrencyMrr): D1PreparedStatement =>
        db
          .prepare("INSERT INTO daily_revenue_metrics (day, currency, mrr_cents, paying_subscriptions) VALUES (?, ?, ?, ?)")
          .bind(metrics.day, currency.currency, currency.mrrCents, currency.payingSubscriptions),
    ),
  ];
}

/**
 * Biten günün anlık görüntüsünü yazar (tek toplu işlem; aynı gün yeniden çalışırsa satır güncellenir) ve döndürür.
 * Günlük Cron çağırır (`index.ts` → `scheduled`).
 */
export async function recordDailyMetrics(db: D1Database, config: Config, now: Date): Promise<DailyMetrics> {
  const metrics: DailyMetrics = await collectDailyMetrics(db, config, now);
  await db.batch(dailyMetricsStatements(db, metrics));
  log("info", "daily_metrics_recorded", { day: metrics.day, usersTotal: metrics.usersTotal, subscriptionsActive: metrics.subscriptions.active });
  return metrics;
}
