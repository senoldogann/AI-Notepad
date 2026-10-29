import type { Config, StripeMode } from "./config";
import { type DeepgramUsage, deepgramUsage } from "./deepgram";
import { type ElevenLabsUsage, elevenLabsUsage } from "./elevenLabsCapacity";
import { subscriptionRenewalGraceMs } from "./entitlements";
import { ApiError } from "./errors";
import { log } from "./log";
import { utcDayStartMs } from "./reports";
import type { TrialRefusalReason } from "./trialRefusals";
import { dayKey, monthKey, monthStartMs } from "./usage";

const dayMs: number = 86_400_000;

/** İstatistik serilerinin gün sayısı (bugün dahil). */
export const statsDays: number = 30;

/** Gün başına sayı. */
export interface DayCount {
  readonly day: string;
  readonly count: number;
}

/** Gün başına türlere göre toplantı başlatma. */
export interface DayMeetings {
  readonly day: string;
  readonly trial: number;
  readonly subscription: number;
}

/** Gün başına tahmini harcama. */
export interface DayUsd {
  readonly day: string;
  readonly usd: number;
}

/** `GET /v1/admin/stats` yanıtı. Günler `YYYY-MM-DD` (UTC), 30 gün, eskiden yeniye, boş günler 0. */
export interface AdminStats {
  readonly generatedAt: string;
  readonly downloads: { readonly total: number; readonly last30Days: readonly DayCount[] };
  readonly users: {
    readonly total: number;
    readonly newLast30Days: readonly DayCount[];
    readonly byProvider: { readonly apple: number; readonly google: number };
  };
  readonly trials: { readonly activeTrialUsers: number; readonly exhaustedTrialUsers: number };
  readonly subscriptions: {
    readonly active: number;
    readonly grace: number;
    readonly ending: number;
    readonly canceledTotal: number;
    /** Yenilenecek ödenmiş abonelikler plan başına (`active` − `ending`; planı tanınmayanlar ikisine de girmez). */
    readonly monthly: number;
    readonly yearly: number;
    readonly mrrUsd: number;
  };
  readonly referrals: ReferralStats;
  readonly meetings: { readonly last30Days: readonly DayMeetings[]; readonly hoursThisMonth: number };
  readonly spend: {
    readonly todayUsd: number;
    readonly ceilingUsd: number;
    /** Bugünkü harcamanın deneme kısmı (deneme toplantıları ve denemedeki hesap çağrıları) ve ayrı tavanı. */
    readonly trialTodayUsd: number;
    readonly trialCeilingUsd: number;
    readonly last30Days: readonly DayUsd[];
  };
  readonly tokens: { readonly thisMonth: number };
  readonly reports: { readonly openFeedback: number; readonly openCrash: number; readonly openContact: number };
  /** Stripe anahtarının modu: canlıya geçişte `live` olmalı. */
  readonly stripe: { readonly mode: StripeMode };
  /** ElevenLabs bu faturalama dönemindeki ses saati / plan saati (kredi bitince konuşma tanıma durur). */
  readonly elevenLabs: ElevenLabsUsage;
  /** Deepgram canlı metni: politika, ömür boyu bütçe ve tahmini harcama (bütçeye ulaşınca yeni toplantılar Mac'e geçer). */
  readonly deepgram: DeepgramUsage;
  readonly conversion: ConversionStats;
  readonly churn: ChurnStats;
  readonly billing: BillingStats;
  readonly usage: UsageStats;
  readonly trialRefusals: TrialRefusalStats;
}

/**
 * Denemeden aboneliğe dönüşüm. `trialStarted`: denemeye başlamış hesaplar (`users.trial_started_at` dolu);
 * `converted`: bunlardan abonelik satırı olanlar (ödemesi tamamlanmamış `incomplete`/`incomplete_expired` sayılmaz;
 * sonradan iptal edilen de dönüşmüş sayılır). `…Last30Days` alanları denemesi son 30 günde başlayan kohorttur.
 * `subscribedWithoutTrial`: denemeye hiç başlamadan abone olanlar. Silinen hesaplar sayılmaz.
 */
export interface ConversionStats {
  readonly trialStarted: number;
  readonly converted: number;
  readonly startedLast30Days: number;
  readonly convertedLast30Days: number;
  readonly subscribedWithoutTrial: number;
}

/**
 * Kayıp ve ödeme sorunları. `canceledLast30Days`: durumu `canceled` olup son güncellemesi (iptal olayının işlendiği an)
 * son 30 günde olanlar; `pastDue`: ödemesi başarısız (`past_due`; ek sürede ya da sonrasında); `unpaid`: Stripe'ın
 * yeniden denemeleri bitmiş; `duplicateSubscriptions`: iade edilen kopya abonelik kayıtları (400 gün tutulur).
 */
export interface ChurnStats {
  readonly canceledLast30Days: number;
  readonly pastDue: number;
  readonly unpaid: number;
  readonly duplicateSubscriptions: number;
}

/**
 * Davet programı (`referral_redemptions`; silinen hesapların anonim satırları dahil): `joined` kodla abone olan (ilk
 * faturası ödenmiş), `pending` ödülü bekleyen (`joined`, `qualified`), `granted` verilen ödül, `voided` verilmeyen
 * (iade, itiraz, kendi kendini davet, davet eden silindi ya da yıllık sınır).
 */
export interface ReferralStats {
  readonly joined: number;
  readonly pending: number;
  readonly granted: number;
  readonly voided: number;
}

/**
 * Aylık yinelenen gelir tahmini (USD): aylık abonelik × aylık fiyat + yıllık abonelik × yıllık fiyat / 12; yüzde bir
 * hassasiyet. Saf fonksiyondur.
 */
export function monthlyRecurringRevenueUsd(monthly: number, yearly: number, priceUsdMonthly: number, priceUsdYearly: number): number {
  return roundCents(monthly * priceUsdMonthly + (yearly * priceUsdYearly) / 12);
}

/** Son 30 günde işlenen Stripe olaylarından ödeme sorunları (olaylar 90 gün tutulur). */
export interface BillingStats {
  readonly refundsLast30Days: number;
  readonly disputesLast30Days: number;
  readonly paymentFailuresLast30Days: number;
}

/**
 * Bu ayın (UTC) kullanımı. `meetingsThisMonth`, `deferredThisMonth`, `reprocessedThisMonth`: bu ay başlayan
 * toplantılar, bunların sonradan işlenenleri ve en az bir kez yeniden işlenenleri; `openMeetings`: şu an açık (bitmemiş,
 * en çok süresi dolmamış) toplantılar; `audioHoursThisMonth`: yazıya dökülen kesinleşmiş ses; `accountTokensThisMonth`:
 * kesinleşmiş toplantı dışı token (tümü `tokens.thisMonth`); `usersNearTokenCap`: kullanıcı başına aylık token
 * sınırının (`MONTHLY_TOKEN_CAP`) en az %80'ine ulaşan kullanıcılar.
 */
export interface UsageStats {
  readonly meetingsThisMonth: number;
  readonly deferredThisMonth: number;
  readonly reprocessedThisMonth: number;
  readonly openMeetings: number;
  readonly audioHoursThisMonth: number;
  readonly accountTokensThisMonth: number;
  readonly monthlyTokenCapPerUser: number;
  readonly monthlyAccountTokenCapPerUser: number;
  readonly usersNearTokenCap: number;
}

/** Neden başına reddedilen deneme başlatma sayısı (eksik neden 0). */
export type TrialRefusalCounts = Readonly<Record<TrialRefusalReason, number>>;

/** Reddedilen deneme başlatmaları (`trial_refusals`): son 30 gün (bugün dahil) ve bugün. */
export interface TrialRefusalStats {
  readonly last30Days: TrialRefusalCounts;
  readonly today: TrialRefusalCounts;
}

/**
 * Kullanıcının kimlikleri `<sağlayıcı>:<sub>` biçiminde; biri `ADMIN_IDENTITIES` listesindeyse geçer. Değilse düz
 * `403 forbidden` (gövdede kimlik yok; `admin_forbidden` uyarısı yalnızca kullanıcı kimliğini loglar). Liste boşsa kimse
 * yönetici değildir.
 */
export async function requireAdmin(db: D1Database, config: Config, userId: string): Promise<void> {
  const rows = await db
    .prepare("SELECT provider || ':' || subject AS identity FROM auth_identities WHERE user_id = ? ORDER BY provider, subject")
    .bind(userId)
    .all<{ identity: string }>();
  const identities: string[] = rows.results.map((row: { identity: string }): string => row.identity);
  if (identities.some((identity: string): boolean => config.adminIdentities.includes(identity))) {
    return;
  }
  log("warn", "admin_forbidden", { userId });
  throw new ApiError("forbidden", "Bu işleme izin yok.");
}

/** Bugün dahil son `count` UTC günü, eskiden yeniye. Saf fonksiyondur. */
export function lastDays(now: Date, count: number): string[] {
  const today: number = utcDayStartMs(now);
  return Array.from({ length: count }, (_: unknown, index: number): string => dayKey(new Date(today - (count - 1 - index) * dayMs)));
}

/** Gün → değer eşlemini her gün için (yoksa 0) diziye çevirir. Saf fonksiyondur. */
function valuesByDay(days: readonly string[], values: ReadonlyMap<string, number>): number[] {
  return days.map((day: string): number => values.get(day) ?? 0);
}

/** Yüzde bir hassasiyet (para, saat). Saf fonksiyondur. */
function roundCents(value: number): number {
  return Math.round(value * 100) / 100;
}

/**
 * Abonelik erişimi olan satır (`subscriptions s`) için SQL koşulu; `entitlements.subscriptionAccess` ile aynıdır:
 * `active`/`trialing` dönem sonuna dek (yenilenecekse + `subscriptionRenewalGraceMs`, bkz. `paidAccessEndsAtMs`),
 * `past_due` `past_due_since` + ek süreye dek. Bağlar: ?1 = şimdi, ?2 = ek süre (ms).
 */
const activeAccessSql: string = `s.status IN ('active', 'trialing') AND (CASE WHEN s.cancel_at IS NULL OR s.cancel_at > s.current_period_end
  THEN s.current_period_end + ${subscriptionRenewalGraceMs} ELSE s.current_period_end END) > ?1`;
const graceAccessSql: string = "s.status = 'past_due' AND s.past_due_since + ?2 > ?1";

interface SubscriptionCounts {
  readonly active: number;
  readonly grace: number;
  readonly ending: number;
  readonly canceled: number;
  readonly monthly: number;
  readonly yearly: number;
}

interface DayValueRow {
  readonly day: string;
  readonly value: number;
}

interface DayKindRow {
  readonly day: string;
  readonly kind: string;
  readonly count: number;
}

interface KeyCountRow {
  readonly key: string;
  readonly count: number;
}

interface ConversionRow {
  readonly started: number;
  readonly converted: number;
  readonly started_recent: number;
  readonly converted_recent: number;
  readonly direct: number;
}

interface ChurnRow {
  readonly canceled_recent: number;
  readonly past_due: number;
  readonly unpaid: number;
  readonly duplicates: number;
}

interface MeetingMonthRow {
  readonly started: number;
  readonly deferred: number;
  readonly reprocessed: number;
  readonly open: number;
}

interface MonthlyUsageRow {
  readonly audio_seconds: number;
  readonly tokens: number;
  readonly account_tokens: number;
  readonly near_cap: number;
}

/** Ödemesi tamamlanmış (abone olmuş) sayılan abonelik satırı için SQL koşulu (`subscriptions s`). */
export const paidSubscriptionSql: string = "s.status NOT IN ('incomplete', 'incomplete_expired')";

/** Ms zamanını ISO 8601'e çevirir (null korunur). Saf fonksiyondur. */
export function isoOrNull(ms: number | null): string | null {
  return ms === null ? null : new Date(ms).toISOString();
}

/** Açık toplantı aramasının geriye bakış süresi: en uzun toplantı süresi (dizinli `started_at` aralığı için). Saf fonksiyondur. */
export function longestMeetingMs(config: Config): number {
  return Math.max(config.trialMaxMeetingMinutes, config.subscriberMaxMeetingMinutes) * 60_000;
}

/** Neden → sayı satırlarını tüm nedenleri içeren sayaca çevirir (eksikler 0). Saf fonksiyondur. */
function refusalCounts(rows: readonly KeyCountRow[]): TrialRefusalCounts {
  const counts: Map<string, number> = keyMap(rows);
  return {
    device_used: counts.get("device_used") ?? 0,
    exhausted: counts.get("exhausted") ?? 0,
    expired: counts.get("expired") ?? 0,
    ip_daily_limit: counts.get("ip_daily_limit") ?? 0,
  };
}

/** Satırları gün → değer eşlemine çevirir. Saf fonksiyondur. */
function dayMap(rows: readonly DayValueRow[]): Map<string, number> {
  return new Map(rows.map((row: DayValueRow): [string, number] => [row.day, row.value]));
}

/** Bir toplantı türünün gün → sayı eşlemi. Saf fonksiyondur. */
function kindDayMap(rows: readonly DayKindRow[], kind: string): Map<string, number> {
  return new Map(rows.filter((row: DayKindRow): boolean => row.kind === kind).map((row: DayKindRow): [string, number] => [row.day, row.count]));
}

/** Satırları anahtar → sayı eşlemine çevirir. Saf fonksiyondur. */
function keyMap(rows: readonly KeyCountRow[]): Map<string, number> {
  return new Map(rows.map((row: KeyCountRow): [string, number] => [row.key, row.count]));
}

/**
 * Yönetici istatistikleri; tümü mevcut tablolardan, toplama sorgularıyla (aralıklar dizinli). Tanımlar:
 * - `trials.activeTrialUsers`: abonelik erişimi olmayan, en az bir deneme toplantısı başlatmış ve denemesi bitmemiş
 *   kullanıcılar; `exhaustedTrialUsers`: abonelik erişimi olmayan, tüm deneme toplantılarını kullanmış kullanıcılar.
 *   Harcanan deneme, aynı kimliğin silinmiş hesaplarından devralınanı da içerir (`users.carried_trial_meetings`);
 *   deneme süresi (`TRIAL_DAYS`) dolmuş olan da `exhaustedTrialUsers`'a sayılır.
 * - `subscriptions.active`: erişimi `active` (ödenmiş dönem); `grace`: `past_due` ek sürede; `ending`: `active` olup
 *   iptal edilmiş (`cancel_at` dolu, dönem sonunda biter); `canceledTotal`: durumu `canceled` olan satırlar (hesabı
 *   silinenler sayılmaz).
 * - `monthly`, `yearly`: yenilenecek ödenmiş abonelikler (`active` ve iptal edilmemiş) plan başına.
 * - `mrrUsd` = `monthly` × `PRICE_USD_MONTHLY` + `yearly` × `PRICE_USD_YEARLY` / 12 (`monthlyRecurringRevenueUsd`).
 *   Ödemesi başarısız (`grace`), iptal edilmiş ve planı tanınmayan abonelikler sayılmaz; vergi, davet indirimleri ve
 *   Stripe ücreti düşülmez.
 * - `referrals`: davet programı sayaçları (`ReferralStats`).
 * - `meetings.hoursThisMonth`: bu ay (UTC) başlayan toplantıların süresi (açık olanlar şimdiye ya da en çok süreye dek).
 * - `spend`: `daily_spend` tahmini (Anthropic + ElevenLabs); `trialTodayUsd` bugünkü harcamanın deneme kısmı (ayrı
 *   tavanı `trialCeilingUsd`); `tokens.thisMonth`: bu ayki kesinleşmiş girdi + çıktı.
 * - `deepgram`: canlı metnin tahmini harcaması (`deepgram.ts`; açık toplantılar kalan en çok süreleriyle peşin sayılır).
 * - `users.byProvider`: kimlik sayısı (hesaplar arası bağlama yoktur: kullanıcı başına bir kimlik).
 */
export async function adminStats(db: D1Database, config: Config, now: Date): Promise<AdminStats> {
  const days: string[] = lastDays(now, statsDays);
  const firstDay: string = days[0] ?? dayKey(now);
  const firstDayMs: number = utcDayStartMs(now) - (statsDays - 1) * dayMs;
  const nowMs: number = now.getTime();
  const [
    downloadTotal,
    downloadRows,
    userTotal,
    newUserRows,
    providerRows,
    trialRow,
    subscriptionRow,
    meetingRows,
    meetingMsRow,
    spendRows,
    trialSpendRow,
    reportRows,
    elevenLabs,
    deepgram,
    conversionRow,
    churnRow,
    billingRows,
    meetingMonthRow,
    monthlyUsageRow,
    refusalRows,
    refusalTodayRows,
    referralRow,
  ] = await Promise.all([
    db.prepare("SELECT COALESCE(SUM(count), 0) AS value FROM downloads").first<{ value: number }>(),
    db.prepare("SELECT day, count AS value FROM downloads WHERE day >= ?").bind(firstDay).all<DayValueRow>(),
    db.prepare("SELECT COUNT(*) AS value FROM users").first<{ value: number }>(),
    db
      .prepare(
        `SELECT strftime('%Y-%m-%d', created_at / 1000, 'unixepoch') AS day, COUNT(*) AS value
         FROM users WHERE created_at >= ? GROUP BY day`,
      )
      .bind(firstDayMs)
      .all<DayValueRow>(),
    db.prepare("SELECT provider AS key, COUNT(*) AS count FROM auth_identities GROUP BY provider").all<KeyCountRow>(),
    db
      .prepare(
        `SELECT COALESCE(SUM(CASE WHEN t.used < ?3 AND NOT t.expired THEN 1 ELSE 0 END), 0) AS active,
           COALESCE(SUM(CASE WHEN t.used >= ?3 OR t.expired THEN 1 ELSE 0 END), 0) AS exhausted
         FROM (
           SELECT u.id AS user_id,
             u.carried_trial_meetings + (SELECT COUNT(*) FROM meeting_sessions m WHERE m.user_id = u.id AND m.kind = 'trial') AS used,
             COALESCE(u.trial_started_at + ?4 <= ?1, 0) AS expired
           FROM users u
         ) t
         WHERE t.used > 0 AND NOT EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = t.user_id AND ((${activeAccessSql}) OR (${graceAccessSql})))`,
      )
      .bind(nowMs, config.pastDueGraceMs, config.trialMeetings, config.trialDurationMs)
      .first<{ active: number; exhausted: number }>(),
    db
      .prepare(
        `SELECT COALESCE(SUM(CASE WHEN ${activeAccessSql} THEN 1 ELSE 0 END), 0) AS active,
           COALESCE(SUM(CASE WHEN ${graceAccessSql} THEN 1 ELSE 0 END), 0) AS grace,
           COALESCE(SUM(CASE WHEN ${activeAccessSql} AND s.cancel_at IS NOT NULL THEN 1 ELSE 0 END), 0) AS ending,
           COALESCE(SUM(CASE WHEN s.status = 'canceled' THEN 1 ELSE 0 END), 0) AS canceled,
           COALESCE(SUM(CASE WHEN ${activeAccessSql} AND s.cancel_at IS NULL AND s.plan = 'monthly' THEN 1 ELSE 0 END), 0) AS monthly,
           COALESCE(SUM(CASE WHEN ${activeAccessSql} AND s.cancel_at IS NULL AND s.plan = 'yearly' THEN 1 ELSE 0 END), 0) AS yearly
         FROM subscriptions s`,
      )
      .bind(nowMs, config.pastDueGraceMs)
      .first<SubscriptionCounts>(),
    db
      .prepare(
        `SELECT strftime('%Y-%m-%d', started_at / 1000, 'unixepoch') AS day, kind, COUNT(*) AS count
         FROM meeting_sessions WHERE started_at >= ? GROUP BY day, kind`,
      )
      .bind(firstDayMs)
      .all<DayKindRow>(),
    db
      .prepare(
        `SELECT COALESCE(SUM(MAX(0, MIN(COALESCE(ended_at, ?1), max_ends_at, ?1) - started_at)), 0) AS value
         FROM meeting_sessions WHERE started_at >= ?2`,
      )
      .bind(nowMs, monthStartMs(now))
      .first<{ value: number }>(),
    db.prepare("SELECT day, micro_usd AS value FROM daily_spend WHERE day >= ?").bind(firstDay).all<DayValueRow>(),
    db.prepare("SELECT trial_micro_usd AS value FROM daily_spend WHERE day = ?").bind(dayKey(now)).first<{ value: number }>(),
    db.prepare("SELECT kind AS key, COUNT(*) AS count FROM reports WHERE status = 'open' GROUP BY kind").all<KeyCountRow>(),
    elevenLabsUsage(db, config, now),
    deepgramUsage(db, config),
    db
      .prepare(
        `SELECT
           (SELECT COUNT(*) FROM users WHERE trial_started_at IS NOT NULL) AS started,
           (SELECT COUNT(*) FROM users u WHERE u.trial_started_at IS NOT NULL
             AND EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = u.id AND ${paidSubscriptionSql})) AS converted,
           (SELECT COUNT(*) FROM users WHERE trial_started_at >= ?1) AS started_recent,
           (SELECT COUNT(*) FROM users u WHERE u.trial_started_at >= ?1
             AND EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = u.id AND ${paidSubscriptionSql})) AS converted_recent,
           (SELECT COUNT(*) FROM subscriptions s JOIN users u ON u.id = s.user_id
             WHERE u.trial_started_at IS NULL AND ${paidSubscriptionSql}) AS direct`,
      )
      .bind(firstDayMs)
      .first<ConversionRow>(),
    db
      .prepare(
        `SELECT COALESCE(SUM(CASE WHEN status = 'canceled' AND updated_at >= ?1 THEN 1 ELSE 0 END), 0) AS canceled_recent,
           COALESCE(SUM(CASE WHEN status = 'past_due' THEN 1 ELSE 0 END), 0) AS past_due,
           COALESCE(SUM(CASE WHEN status = 'unpaid' THEN 1 ELSE 0 END), 0) AS unpaid,
           (SELECT COUNT(*) FROM duplicate_subscriptions) AS duplicates
         FROM subscriptions`,
      )
      .bind(firstDayMs)
      .first<ChurnRow>(),
    db
      .prepare(
        `SELECT type AS key, COUNT(*) AS count FROM stripe_events
         WHERE processed_at >= ? AND type IN ('charge.refunded', 'charge.dispute.created', 'invoice.payment_failed') GROUP BY type`,
      )
      .bind(firstDayMs)
      .all<KeyCountRow>(),
    db
      .prepare(
        `SELECT
           (SELECT COUNT(*) FROM meeting_sessions WHERE started_at >= ?1) AS started,
           (SELECT COALESCE(SUM(deferred), 0) FROM meeting_sessions WHERE started_at >= ?1) AS deferred,
           (SELECT COUNT(*) FROM meeting_sessions WHERE started_at >= ?1 AND reprocess_count > 0) AS reprocessed,
           (SELECT COUNT(*) FROM meeting_sessions WHERE started_at >= ?3 AND ended_at IS NULL AND max_ends_at > ?2) AS open`,
      )
      .bind(monthStartMs(now), nowMs, nowMs - longestMeetingMs(config))
      .first<MeetingMonthRow>(),
    db
      .prepare(
        `SELECT COALESCE(SUM(audio_seconds), 0) AS audio_seconds, COALESCE(SUM(input_tokens + output_tokens), 0) AS tokens,
           COALESCE(SUM(account_tokens), 0) AS account_tokens,
           COALESCE(SUM(CASE WHEN input_tokens + output_tokens >= ?2 * 0.8 THEN 1 ELSE 0 END), 0) AS near_cap
         FROM monthly_usage WHERE month = ?1`,
      )
      .bind(monthKey(now), config.monthlyTokenCap)
      .first<MonthlyUsageRow>(),
    db.prepare("SELECT reason AS key, SUM(count) AS count FROM trial_refusals WHERE day >= ? GROUP BY reason").bind(firstDay).all<KeyCountRow>(),
    db.prepare("SELECT reason AS key, count FROM trial_refusals WHERE day = ?").bind(dayKey(now)).all<KeyCountRow>(),
    db
      .prepare(
        `SELECT COALESCE(SUM(CASE WHEN joined_at IS NOT NULL THEN 1 ELSE 0 END), 0) AS joined,
           COALESCE(SUM(CASE WHEN status IN ('joined', 'qualified') THEN 1 ELSE 0 END), 0) AS pending,
           COALESCE(SUM(CASE WHEN status = 'granted' THEN 1 ELSE 0 END), 0) AS granted,
           COALESCE(SUM(CASE WHEN status IN ('void', 'capped') THEN 1 ELSE 0 END), 0) AS voided
         FROM referral_redemptions`,
      )
      .first<ReferralStats>(),
  ]);

  const downloadsByDay: number[] = valuesByDay(days, dayMap(downloadRows.results));
  const newUsersByDay: number[] = valuesByDay(days, dayMap(newUserRows.results));
  const spendByDay: number[] = valuesByDay(days, dayMap(spendRows.results));
  const trialByDay: number[] = valuesByDay(days, kindDayMap(meetingRows.results, "trial"));
  const subscriptionByDay: number[] = valuesByDay(days, kindDayMap(meetingRows.results, "subscription"));
  const providers: Map<string, number> = keyMap(providerRows.results);
  const openReports: Map<string, number> = keyMap(reportRows.results);
  const subscriptions: SubscriptionCounts = subscriptionRow ?? { active: 0, grace: 0, ending: 0, canceled: 0, monthly: 0, yearly: 0 };
  const billingEvents: Map<string, number> = keyMap(billingRows.results);
  const monthly: MonthlyUsageRow = monthlyUsageRow ?? { audio_seconds: 0, tokens: 0, account_tokens: 0, near_cap: 0 };

  return {
    generatedAt: now.toISOString(),
    downloads: {
      total: downloadTotal?.value ?? 0,
      last30Days: days.map((day: string, index: number): DayCount => ({ day, count: downloadsByDay[index] ?? 0 })),
    },
    users: {
      total: userTotal?.value ?? 0,
      newLast30Days: days.map((day: string, index: number): DayCount => ({ day, count: newUsersByDay[index] ?? 0 })),
      byProvider: { apple: providers.get("apple") ?? 0, google: providers.get("google") ?? 0 },
    },
    trials: { activeTrialUsers: trialRow?.active ?? 0, exhaustedTrialUsers: trialRow?.exhausted ?? 0 },
    subscriptions: {
      active: subscriptions.active,
      grace: subscriptions.grace,
      ending: subscriptions.ending,
      canceledTotal: subscriptions.canceled,
      monthly: subscriptions.monthly,
      yearly: subscriptions.yearly,
      mrrUsd: monthlyRecurringRevenueUsd(subscriptions.monthly, subscriptions.yearly, config.priceUsdMonthly, config.priceUsdYearly),
    },
    referrals: referralRow ?? { joined: 0, pending: 0, granted: 0, voided: 0 },
    meetings: {
      last30Days: days.map(
        (day: string, index: number): DayMeetings => ({ day, trial: trialByDay[index] ?? 0, subscription: subscriptionByDay[index] ?? 0 }),
      ),
      hoursThisMonth: roundCents((meetingMsRow?.value ?? 0) / 3_600_000),
    },
    spend: {
      todayUsd: (spendByDay[spendByDay.length - 1] ?? 0) / 1_000_000,
      ceilingUsd: config.dailySpendCeilingMicroUsd / 1_000_000,
      trialTodayUsd: (trialSpendRow?.value ?? 0) / 1_000_000,
      trialCeilingUsd: config.dailyTrialSpendCeilingMicroUsd / 1_000_000,
      last30Days: days.map((day: string, index: number): DayUsd => ({ day, usd: (spendByDay[index] ?? 0) / 1_000_000 })),
    },
    tokens: { thisMonth: monthly.tokens },
    reports: {
      openFeedback: openReports.get("feedback") ?? 0,
      openCrash: openReports.get("crash") ?? 0,
      openContact: openReports.get("contact") ?? 0,
    },
    stripe: { mode: config.stripeMode },
    elevenLabs,
    deepgram,
    conversion: {
      trialStarted: conversionRow?.started ?? 0,
      converted: conversionRow?.converted ?? 0,
      startedLast30Days: conversionRow?.started_recent ?? 0,
      convertedLast30Days: conversionRow?.converted_recent ?? 0,
      subscribedWithoutTrial: conversionRow?.direct ?? 0,
    },
    churn: {
      canceledLast30Days: churnRow?.canceled_recent ?? 0,
      pastDue: churnRow?.past_due ?? 0,
      unpaid: churnRow?.unpaid ?? 0,
      duplicateSubscriptions: churnRow?.duplicates ?? 0,
    },
    billing: {
      refundsLast30Days: billingEvents.get("charge.refunded") ?? 0,
      disputesLast30Days: billingEvents.get("charge.dispute.created") ?? 0,
      paymentFailuresLast30Days: billingEvents.get("invoice.payment_failed") ?? 0,
    },
    usage: {
      meetingsThisMonth: meetingMonthRow?.started ?? 0,
      deferredThisMonth: meetingMonthRow?.deferred ?? 0,
      reprocessedThisMonth: meetingMonthRow?.reprocessed ?? 0,
      openMeetings: meetingMonthRow?.open ?? 0,
      audioHoursThisMonth: roundCents(monthly.audio_seconds / 3600),
      accountTokensThisMonth: monthly.account_tokens,
      monthlyTokenCapPerUser: config.monthlyTokenCap,
      monthlyAccountTokenCapPerUser: config.monthlyAccountTokenCap,
      usersNearTokenCap: monthly.near_cap,
    },
    trialRefusals: { last30Days: refusalCounts(refusalRows.results), today: refusalCounts(refusalTodayRows.results) },
  };
}
