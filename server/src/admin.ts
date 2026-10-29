import type { Config, StripeMode } from "./config";
import { type DeepgramUsage, deepgramUsage } from "./deepgram";
import { type ElevenLabsUsage, elevenLabsUsage } from "./elevenLabsCapacity";
import { ForbiddenIdentityError } from "./errors";
import { log } from "./log";
import { utcDayStartMs } from "./reports";
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
    readonly mrrUsd: number;
  };
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
}

/**
 * Kullanıcının kimlikleri `<sağlayıcı>:<sub>` biçiminde; biri `ADMIN_IDENTITIES` listesindeyse geçer. Değilse
 * `403 forbidden`, gövdede çağıranın kendi kimlikleri (virgülle) — sahip kendi kimliğini listeye kopyalayabilsin.
 * Liste boşsa kimse yönetici değildir.
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
  throw new ForbiddenIdentityError("Bu hesap yönetici değil.", identities.join(","));
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
 * `active`/`trialing` dönem sonuna dek, `past_due` `past_due_since` + ek süreye dek. Bağlar: ?1 = şimdi, ?2 = ek süre (ms).
 */
const activeAccessSql: string = "s.status IN ('active', 'trialing') AND s.current_period_end > ?1";
const graceAccessSql: string = "s.status = 'past_due' AND s.past_due_since + ?2 > ?1";

interface SubscriptionCounts {
  readonly active: number;
  readonly grace: number;
  readonly ending: number;
  readonly canceled: number;
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
 * - `mrrUsd` = (`active` − `ending`) × `PRICE_USD_MONTHLY`: yenilenecek ödenmiş abonelikler. Ödemesi başarısız
 *   (`grace`) ve iptal edilmiş olanlar sayılmaz; vergi ve Stripe ücreti düşülmez.
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
    tokenRow,
    reportRows,
    elevenLabs,
    deepgram,
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
           COALESCE(SUM(CASE WHEN s.status = 'canceled' THEN 1 ELSE 0 END), 0) AS canceled
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
    db
      .prepare("SELECT COALESCE(SUM(input_tokens + output_tokens), 0) AS value FROM monthly_usage WHERE month = ?")
      .bind(monthKey(now))
      .first<{ value: number }>(),
    db.prepare("SELECT kind AS key, COUNT(*) AS count FROM reports WHERE status = 'open' GROUP BY kind").all<KeyCountRow>(),
    elevenLabsUsage(db, config, now),
    deepgramUsage(db, config),
  ]);

  const downloadsByDay: number[] = valuesByDay(days, dayMap(downloadRows.results));
  const newUsersByDay: number[] = valuesByDay(days, dayMap(newUserRows.results));
  const spendByDay: number[] = valuesByDay(days, dayMap(spendRows.results));
  const trialByDay: number[] = valuesByDay(days, kindDayMap(meetingRows.results, "trial"));
  const subscriptionByDay: number[] = valuesByDay(days, kindDayMap(meetingRows.results, "subscription"));
  const providers: Map<string, number> = keyMap(providerRows.results);
  const openReports: Map<string, number> = keyMap(reportRows.results);
  const subscriptions: SubscriptionCounts = subscriptionRow ?? { active: 0, grace: 0, ending: 0, canceled: 0 };

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
      mrrUsd: roundCents((subscriptions.active - subscriptions.ending) * config.priceUsdMonthly),
    },
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
    tokens: { thisMonth: tokenRow?.value ?? 0 },
    reports: {
      openFeedback: openReports.get("feedback") ?? 0,
      openCrash: openReports.get("crash") ?? 0,
      openContact: openReports.get("contact") ?? 0,
    },
    stripe: { mode: config.stripeMode },
    elevenLabs,
    deepgram,
  };
}
