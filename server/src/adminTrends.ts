import { lastDays } from "./admin";
import { type LLMUsageBucket, llmUsageBuckets } from "./llm/usageBuckets";
import { type CurrencyMrr, invoicedMrrByCurrency } from "./revenue";
import { dayKey } from "./usage";

const dayMs: number = 86_400_000;

/** Anlık görüntü serisinin ve gelir serisinin gün sayısı (bugün dahil). */
export const trendDays: number = 90;
/** Token kovaları, diller, silmeler, yeniden denemeler ve kampanyaların penceresi (gün, bugün dahil). */
export const trendWindowDays: number = 30;

/** Günün anlık görüntüsü (`daily_metrics`); para alanları USD. */
export interface TrendSnapshot {
  readonly usersTotal: number;
  readonly usersNew: number;
  readonly activeUsersDay: number;
  readonly activeUsers7d: number;
  readonly activeUsers30d: number;
  readonly meetingsTrial: number;
  readonly meetingsSubscription: number;
  readonly trialsStarted: number;
  readonly trialsActive: number;
  readonly trialsExhausted: number;
  readonly subscriptionsActive: number;
  readonly subscriptionsGrace: number;
  readonly subscriptionsEnding: number;
  readonly subscriptionsCanceled: number;
  readonly subscriptionsMonthly: number;
  readonly subscriptionsYearly: number;
  readonly subscriptionsComplimentary: number;
  readonly subscriptionsFreeInviteMonth: number;
  readonly mrrListUsd: number;
  readonly spendAnthropicUsd: number;
  readonly spendElevenLabsUsd: number;
  readonly spendDeepgramUsd: number;
  readonly spendTrialUsd: number;
  /** Faturalanan MRR para birimine göre (sent; `daily_revenue_metrics`). */
  readonly invoicedMrr: readonly CurrencyMrr[];
}

/** Bir gün: anlık görüntü ya da yoksa (Cron çalışmadı ya da tablo yoktu) null. */
export interface TrendDay {
  readonly day: string;
  readonly snapshot: TrendSnapshot | null;
}

/** Gün başına tahsilat ve iade (sent). */
export interface RevenueDay {
  readonly day: string;
  readonly paidCents: number;
  readonly refundedCents: number;
}

/**
 * Para birimi başına gerçek gelir (sent). `mrrCents`: şu an yenilenecek ödenmiş aboneliklerin son ücretli faturasının
 * vergisiz tutarı (yıllık /12; `invoicedMrrByCurrency`); `arpuCents` = MRR / ödeyen abonelik (yoksa null). Pencere
 * toplamları: tahsilat (vergi dahil), vergi, indirim, iade (vergi dahil) ve net = tahsilat − vergi − iade. `ltvCents` =
 * tüm zamanların neti / ücretli faturası olmuş farklı abonelik (abonelik başına; yoksa null).
 */
export interface CurrencyRevenue {
  readonly currency: string;
  readonly mrrCents: number;
  readonly payingSubscriptions: number;
  readonly arpuCents: number | null;
  readonly paidLast30DaysCents: number;
  readonly taxLast30DaysCents: number;
  readonly discountLast30DaysCents: number;
  readonly refundedLast30DaysCents: number;
  readonly netLast30DaysCents: number;
  readonly paidAllTimeCents: number;
  readonly netAllTimeCents: number;
  readonly paidSubscriptionsAllTime: number;
  readonly ltvCents: number | null;
  readonly daily: readonly RevenueDay[];
}

/**
 * Gerçek gelir özeti. `firstPaymentsLast30Days`: ilk ücretli ödemesi son 30 günde olan hesaplar
 * (`subscriptions.first_paid_at`); `medianDaysToFirstPayment`: hesap açılışından ilk ücretli ödemeye geçen günlerin
 * ortancası (ödemiş hesap yoksa null).
 */
export interface RevenueSummary {
  readonly currencies: readonly CurrencyRevenue[];
  readonly firstPaymentsLast30Days: number;
  readonly medianDaysToFirstPayment: number | null;
}

/** Token kovasının penceredeki toplamı. */
export interface TokenBucketTotal {
  readonly bucket: LLMUsageBucket;
  readonly calls: number;
  readonly streamedCalls: number;
  readonly inputTokens: number;
  readonly outputTokens: number;
}

/** İstenen ve algılanan dil çiftinin penceredeki toplamı. */
export interface LanguageTotal {
  readonly requested: string;
  readonly detected: string;
  readonly requests: number;
  readonly audioHours: number;
}

/** Ayrıntı başına sayı. */
export interface TrendCount {
  readonly detail: string;
  readonly count: number;
}

/** Kampanya başına indirme. */
export interface CampaignCount {
  readonly source: string;
  readonly campaign: string;
  readonly count: number;
}

/** `GET /v1/admin/trends` yanıtı. Günler `YYYY-MM-DD` (UTC), eskiden yeniye. */
export interface AdminTrends {
  readonly generatedAt: string;
  readonly days: number;
  readonly windowDays: number;
  readonly daily: readonly TrendDay[];
  readonly revenue: RevenueSummary;
  /** Kovalar sabit sırada (`llmUsageBuckets`); kullanılmayan kova sıfırdır. */
  readonly tokenBuckets: readonly TokenBucketTotal[];
  readonly languages: readonly LanguageTotal[];
  readonly accountDeletions: readonly TrendCount[];
  readonly retries: readonly TrendCount[];
  readonly campaigns: readonly CampaignCount[];
}

interface SnapshotRow {
  readonly day: string;
  readonly users_total: number;
  readonly users_new: number;
  readonly active_users_day: number;
  readonly active_users_7d: number;
  readonly active_users_30d: number;
  readonly meetings_trial: number;
  readonly meetings_subscription: number;
  readonly trials_started: number;
  readonly trials_active: number;
  readonly trials_exhausted: number;
  readonly subscriptions_active: number;
  readonly subscriptions_grace: number;
  readonly subscriptions_ending: number;
  readonly subscriptions_canceled: number;
  readonly subscriptions_monthly: number;
  readonly subscriptions_yearly: number;
  readonly subscriptions_complimentary: number;
  readonly subscriptions_free_invite_month: number;
  readonly mrr_list_cents: number;
  readonly spend_anthropic_micro_usd: number;
  readonly spend_elevenlabs_micro_usd: number;
  readonly spend_deepgram_micro_usd: number;
  readonly spend_trial_micro_usd: number;
}

interface RevenueMetricRow {
  readonly day: string;
  readonly currency: string;
  readonly mrr_cents: number;
  readonly paying_subscriptions: number;
}

interface CurrencyTotalsRow {
  readonly currency: string;
  readonly paid_recent: number;
  readonly tax_recent: number;
  readonly discount_recent: number;
  readonly paid_all: number;
  readonly tax_all: number;
  readonly subscriptions_all: number;
}

interface RefundTotalsRow {
  readonly currency: string;
  readonly refunded_recent: number;
  readonly refunded_all: number;
}

interface RevenueDayRow {
  readonly day: string;
  readonly currency: string;
  readonly cents: number;
}

interface BucketRow {
  readonly bucket: string;
  readonly calls: number;
  readonly streamed_calls: number;
  readonly input_tokens: number;
  readonly output_tokens: number;
}

interface LanguageRow {
  readonly requested: string;
  readonly detected: string;
  readonly requests: number;
  readonly audio_seconds: number;
}

/** Mikro dolar → dolar. Saf fonksiyondur. */
function usdOf(microUsd: number): number {
  return microUsd / 1_000_000;
}

/** Anlık görüntü satırı ve günün gelir satırları. Saf fonksiyondur. */
function snapshotOf(row: SnapshotRow, revenue: readonly RevenueMetricRow[]): TrendSnapshot {
  return {
    usersTotal: row.users_total,
    usersNew: row.users_new,
    activeUsersDay: row.active_users_day,
    activeUsers7d: row.active_users_7d,
    activeUsers30d: row.active_users_30d,
    meetingsTrial: row.meetings_trial,
    meetingsSubscription: row.meetings_subscription,
    trialsStarted: row.trials_started,
    trialsActive: row.trials_active,
    trialsExhausted: row.trials_exhausted,
    subscriptionsActive: row.subscriptions_active,
    subscriptionsGrace: row.subscriptions_grace,
    subscriptionsEnding: row.subscriptions_ending,
    subscriptionsCanceled: row.subscriptions_canceled,
    subscriptionsMonthly: row.subscriptions_monthly,
    subscriptionsYearly: row.subscriptions_yearly,
    subscriptionsComplimentary: row.subscriptions_complimentary,
    subscriptionsFreeInviteMonth: row.subscriptions_free_invite_month,
    mrrListUsd: row.mrr_list_cents / 100,
    spendAnthropicUsd: usdOf(row.spend_anthropic_micro_usd),
    spendElevenLabsUsd: usdOf(row.spend_elevenlabs_micro_usd),
    spendDeepgramUsd: usdOf(row.spend_deepgram_micro_usd),
    spendTrialUsd: usdOf(row.spend_trial_micro_usd),
    invoicedMrr: revenue
      .filter((item: RevenueMetricRow): boolean => item.day === row.day)
      .map((item: RevenueMetricRow): CurrencyMrr => ({ currency: item.currency, mrrCents: item.mrr_cents, payingSubscriptions: item.paying_subscriptions })),
  };
}

/** Sıralı sayıların ortancası; boşsa null. Saf fonksiyondur. */
export function median(values: readonly number[]): number | null {
  if (values.length === 0) {
    return null;
  }
  const sorted: number[] = [...values].sort((left: number, right: number): number => left - right);
  const middle: number = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? (sorted[middle] ?? null) : ((sorted[middle - 1] ?? 0) + (sorted[middle] ?? 0)) / 2;
}

/** Para biriminin gün serisi (eksik gün 0). Saf fonksiyondur. */
function revenueDays(days: readonly string[], currency: string, paid: readonly RevenueDayRow[], refunded: readonly RevenueDayRow[]): RevenueDay[] {
  const paidByDay: Map<string, number> = new Map(paid.filter((row): boolean => row.currency === currency).map((row): [string, number] => [row.day, row.cents]));
  const refundedByDay: Map<string, number> = new Map(refunded.filter((row): boolean => row.currency === currency).map((row): [string, number] => [row.day, row.cents]));
  return days.map((day: string): RevenueDay => ({ day, paidCents: paidByDay.get(day) ?? 0, refundedCents: refundedByDay.get(day) ?? 0 }));
}

/** Para birimi başına gelir özeti; para birimleri tüm zamanların tahsilatına göre çoktan aza. Saf fonksiyondur. */
export function currencyRevenues(
  days: readonly string[],
  mrr: readonly CurrencyMrr[],
  totals: readonly CurrencyTotalsRow[],
  refunds: readonly RefundTotalsRow[],
  paidDays: readonly RevenueDayRow[],
  refundDays: readonly RevenueDayRow[],
): CurrencyRevenue[] {
  const currencies: string[] = [...new Set([...totals.map((row): string => row.currency), ...mrr.map((row): string => row.currency)])];
  return currencies
    .map((currency: string): CurrencyRevenue => {
      const total: CurrencyTotalsRow | undefined = totals.find((row): boolean => row.currency === currency);
      const refund: RefundTotalsRow | undefined = refunds.find((row): boolean => row.currency === currency);
      const current: CurrencyMrr | undefined = mrr.find((row): boolean => row.currency === currency);
      const refundedRecent: number = refund?.refunded_recent ?? 0;
      const netAll: number = (total?.paid_all ?? 0) - (total?.tax_all ?? 0) - (refund?.refunded_all ?? 0);
      const paying: number = current?.payingSubscriptions ?? 0;
      const subscriptionsAll: number = total?.subscriptions_all ?? 0;
      return {
        currency,
        mrrCents: current?.mrrCents ?? 0,
        payingSubscriptions: paying,
        arpuCents: paying === 0 ? null : Math.round((current?.mrrCents ?? 0) / paying),
        paidLast30DaysCents: total?.paid_recent ?? 0,
        taxLast30DaysCents: total?.tax_recent ?? 0,
        discountLast30DaysCents: total?.discount_recent ?? 0,
        refundedLast30DaysCents: refundedRecent,
        netLast30DaysCents: (total?.paid_recent ?? 0) - (total?.tax_recent ?? 0) - refundedRecent,
        paidAllTimeCents: total?.paid_all ?? 0,
        netAllTimeCents: netAll,
        paidSubscriptionsAllTime: subscriptionsAll,
        ltvCents: subscriptionsAll === 0 ? null : Math.round(netAll / subscriptionsAll),
        daily: revenueDays(days, currency, paidDays, refundDays),
      };
    })
    .sort((left: CurrencyRevenue, right: CurrencyRevenue): number => right.paidAllTimeCents - left.paidAllTimeCents || left.currency.localeCompare(right.currency));
}

/**
 * Yönetim panelinin "Trends" görünümü: son `trendDays` günün anlık görüntüleri (`daily_metrics`) ve gelir serisi,
 * gerçek gelir özeti (`revenue_invoices`, `revenue_refunds`) ve son `trendWindowDays` günün token kovaları, konuşma
 * tanıma dilleri, hesap silmeleri ve üst servis yeniden denemeleri (`ops_events`) ve indirme kampanyaları. Yalnızca
 * toplamlar; hesap kimliği dönmez.
 */
export async function adminTrends(db: D1Database, now: Date): Promise<AdminTrends> {
  const days: string[] = lastDays(now, trendDays);
  const firstDay: string = days[0] ?? dayKey(now);
  const windowFirstDay: string = lastDays(now, trendWindowDays)[0] ?? dayKey(now);
  const windowStartMs: number = Date.parse(`${windowFirstDay}T00:00:00Z`);
  const [snapshotRows, revenueMetricRows, mrr, totalRows, refundRows, paidDayRows, refundDayRows, firstPaidRow, delayRows, bucketRows, languageRows, opsRows, campaignRows] =
    await Promise.all([
      db.prepare("SELECT * FROM daily_metrics WHERE day >= ? ORDER BY day").bind(firstDay).all<SnapshotRow>(),
      db.prepare("SELECT day, currency, mrr_cents, paying_subscriptions FROM daily_revenue_metrics WHERE day >= ?").bind(firstDay).all<RevenueMetricRow>(),
      invoicedMrrByCurrency(db, now.getTime()),
      db
        .prepare(
          `SELECT currency,
             COALESCE(SUM(CASE WHEN day >= ?1 THEN amount_paid ELSE 0 END), 0) AS paid_recent,
             COALESCE(SUM(CASE WHEN day >= ?1 THEN tax ELSE 0 END), 0) AS tax_recent,
             COALESCE(SUM(CASE WHEN day >= ?1 THEN discount ELSE 0 END), 0) AS discount_recent,
             COALESCE(SUM(amount_paid), 0) AS paid_all,
             COALESCE(SUM(tax), 0) AS tax_all,
             COUNT(DISTINCT CASE WHEN amount_paid > 0 THEN subscription_id END) AS subscriptions_all
           FROM revenue_invoices GROUP BY currency`,
        )
        .bind(windowFirstDay)
        .all<CurrencyTotalsRow>(),
      db
        .prepare(
          `SELECT currency, COALESCE(SUM(CASE WHEN day >= ?1 THEN amount_refunded ELSE 0 END), 0) AS refunded_recent,
             COALESCE(SUM(amount_refunded), 0) AS refunded_all
           FROM revenue_refunds GROUP BY currency`,
        )
        .bind(windowFirstDay)
        .all<RefundTotalsRow>(),
      db.prepare("SELECT day, currency, SUM(amount_paid) AS cents FROM revenue_invoices WHERE day >= ? GROUP BY day, currency").bind(firstDay).all<RevenueDayRow>(),
      db.prepare("SELECT day, currency, SUM(amount_refunded) AS cents FROM revenue_refunds WHERE day >= ? GROUP BY day, currency").bind(firstDay).all<RevenueDayRow>(),
      db.prepare("SELECT COUNT(*) AS value FROM subscriptions WHERE first_paid_at >= ?").bind(windowStartMs).first<{ value: number }>(),
      db
        .prepare("SELECT s.first_paid_at - u.created_at AS ms FROM subscriptions s JOIN users u ON u.id = s.user_id WHERE s.first_paid_at IS NOT NULL")
        .all<{ ms: number }>(),
      db
        .prepare(
          `SELECT bucket, SUM(calls) AS calls, SUM(streamed_calls) AS streamed_calls, SUM(input_tokens) AS input_tokens,
             SUM(output_tokens) AS output_tokens
           FROM llm_usage_daily WHERE day >= ? GROUP BY bucket`,
        )
        .bind(windowFirstDay)
        .all<BucketRow>(),
      db
        .prepare(
          `SELECT requested, detected, SUM(requests) AS requests, SUM(audio_seconds) AS audio_seconds
           FROM transcription_languages_daily WHERE day >= ? GROUP BY requested, detected ORDER BY requests DESC, requested, detected`,
        )
        .bind(windowFirstDay)
        .all<LanguageRow>(),
      db
        .prepare(
          `SELECT kind, detail, SUM(count) AS count FROM ops_events WHERE day >= ? AND kind IN ('account_deleted', 'retry')
           GROUP BY kind, detail ORDER BY count DESC, detail`,
        )
        .bind(windowFirstDay)
        .all<{ kind: string; detail: string; count: number }>(),
      db
        .prepare(
          `SELECT utm_source AS source, utm_campaign AS campaign, SUM(count) AS count FROM download_campaigns WHERE day >= ?
           GROUP BY utm_source, utm_campaign ORDER BY count DESC, source, campaign`,
        )
        .bind(windowFirstDay)
        .all<CampaignCount>(),
    ]);
  const snapshots: Map<string, SnapshotRow> = new Map(snapshotRows.results.map((row: SnapshotRow): [string, SnapshotRow] => [row.day, row]));
  const buckets: Map<string, BucketRow> = new Map(bucketRows.results.map((row: BucketRow): [string, BucketRow] => [row.bucket, row]));
  const countsOf = (kind: string): TrendCount[] =>
    opsRows.results.filter((row): boolean => row.kind === kind).map((row): TrendCount => ({ detail: row.detail, count: row.count }));
  const medianMs: number | null = median(delayRows.results.map((row: { ms: number }): number => row.ms));
  return {
    generatedAt: now.toISOString(),
    days: trendDays,
    windowDays: trendWindowDays,
    daily: days.map((day: string): TrendDay => {
      const row: SnapshotRow | undefined = snapshots.get(day);
      return { day, snapshot: row === undefined ? null : snapshotOf(row, revenueMetricRows.results) };
    }),
    revenue: {
      currencies: currencyRevenues(days, mrr, totalRows.results, refundRows.results, paidDayRows.results, refundDayRows.results),
      firstPaymentsLast30Days: firstPaidRow?.value ?? 0,
      medianDaysToFirstPayment: medianMs === null ? null : Math.round((medianMs / dayMs) * 10) / 10,
    },
    tokenBuckets: llmUsageBuckets.map((bucket: LLMUsageBucket): TokenBucketTotal => {
      const row: BucketRow | undefined = buckets.get(bucket);
      return {
        bucket,
        calls: row?.calls ?? 0,
        streamedCalls: row?.streamed_calls ?? 0,
        inputTokens: row?.input_tokens ?? 0,
        outputTokens: row?.output_tokens ?? 0,
      };
    }),
    languages: languageRows.results.map(
      (row: LanguageRow): LanguageTotal => ({ requested: row.requested, detected: row.detected, requests: row.requests, audioHours: Math.round((row.audio_seconds / 3600) * 100) / 100 }),
    ),
    accountDeletions: countsOf("account_deleted"),
    retries: countsOf("retry"),
    campaigns: campaignRows.results,
  };
}
