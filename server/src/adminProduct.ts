import { activeAccessSql, lastDays, paidSubscriptionSql } from "./admin";
import type { DetailCount } from "./adminInsights";
import type { Config } from "./config";
import { deepgramStreamsPerMeeting } from "./deepgram";
import { freeInviteMonthSql } from "./referrals";
import { utcDayStartMs } from "./reports";
import { dayKey, haikuShortInputUsdPerMTok, haikuShortOutputUsdPerMTok, monthKey } from "./usage";

/**
 * Yönetim panelinin "Ürün" görünümü (`GET /v1/admin/product`): etkinlik (WAU/MAU, haftalık etkin kullanıcı ve
 * toplantı), kayıt haftası kohortları, D7/D30 tutunma, ilk adımlara geçen süre, deneme sonuçları, yarım kalan Checkout,
 * güvenilirlik (toplantı hataları, not tamamlanması, Deepgram yeniden bağlanmaları, günlük "Sorunlar" sayaçları),
 * yaklaşık birim ekonomisi (liste fiyatı) ve sürüme göre çökmeler. Hepsi mevcut tablolardan toplama sorgularıyla; yanıtta
 * hesap kimliği yoktur. Haftalar pazartesi 00:00 UTC'de başlar; günler `YYYY-MM-DD`, aylar `YYYY-MM` (UTC).
 */

const dayMs: number = 86_400_000;
const weekMs: number = 7 * dayMs;

/** Haftalık etkinlik satırı ve kayıt kohortu sayısı (bu hafta dahil). */
export const productWeeks: number = 8;

/** Kohort tablosunun hafta sütunları: kayıttan sonraki 0.–4. haftalar. */
export const cohortWeekColumns: number = 5;

/** Tutunmanın uygun kayıtlarının geriye bakışı: toplantılar 13 ay tutulur, en uzun pencere (D30 + 7 gün) içinde kalır. */
export const retentionLookbackDays: number = 360;

/** Tutunma penceresinin uzunluğu (gün): Dn, n. günden başlayan 7 günde en az bir toplantı. */
export const retentionWindowDays: number = 7;

/** İlk adımlara geçen sürenin kohortu: son 90 günde açılan hesaplar. */
export const timeToStepDays: number = 90;

/** Güvenilirlik penceresi ve günlük sayaç serisi (gün, bugün dahil). */
export const reliabilityDays: number = 30;

/** Birim ekonomisi ayları (bu ay dahil; bu ay kısmi). */
export const economicsMonths: number = 3;

/** Günlük harcama serisinin gün sayısı (bugün dahil). */
export const dailySpendDays: number = 30;

/** Sürüme göre çökmelerde listelenen en çok sürüm. */
export const crashVersionLimit: number = 50;

/** Çökme tablosundaki kısa pencere (gün, bugün dahil). */
export const crashRecentDays: number = 30;

/**
 * Yeniden bağlanmasız bir Deepgram toplantısının jeton sayısı: istemci önce bir yoklama jetonu alır (hakkı ve
 * seçenekleri doğrular, kullanılmaz), sonra her akış ("Sen", "Diğerleri") kendi bağlantısı için bir jeton.
 */
export const deepgramBaselineGrants: number = 1 + deepgramStreamsPerMeeting;

/** Toplama sorgusu satır döndürmedi (D1 her toplama sorgusunda tek satır döndürür; olmaması sorgu hatasıdır). */
export class MissingAggregateRowError extends Error {
  override readonly name: string = "MissingAggregateRowError";

  constructor(query: string) {
    super(`Toplama sorgusu satır döndürmedi: ${query}`);
  }
}

/** Kayıt haftası kohortu: `activeByWeek[k]` kayıttan sonraki k. haftada (7k–7k+7. gün) toplantı başlatan hesap; o hafta henüz hiçbir hesap için başlamadıysa null. */
export interface SignupCohort {
  readonly weekStart: string;
  readonly signups: number;
  readonly activeByWeek: readonly (number | null)[];
}

/** Takvim haftasının etkinliği: toplantı başlatan farklı hesap, başlatılan toplantı ve etkin hesap başına toplantı (etkin yoksa null). */
export interface ActiveWeek {
  readonly weekStart: string;
  readonly activeUsers: number;
  readonly meetings: number;
  readonly meetingsPerActiveUser: number | null;
}

/** Toplantıya göre etkinlik: son 7 ve 30 günde (şimdiden geriye) toplantı başlatan farklı hesap ve haftalık seri. */
export interface Engagement {
  readonly activeLast7Days: number;
  readonly activeLast30Days: number;
  readonly weeks: readonly ActiveWeek[];
}

/**
 * Dn tutunması: `eligible` penceresi tamamlanmış kayıtlar (son `retentionLookbackDays` günde açılmış ve en az n + 7 gün
 * önce), `retained` bunlardan kayıttan sonraki [n, n + 7) günde en az bir toplantı başlatanlar.
 */
export interface Retention {
  readonly day: number;
  readonly eligible: number;
  readonly retained: number;
}

/** Bir adıma geçen sürenin ortancası (saniye) ve hesaplandığı hesap sayısı; hesap yoksa null. */
export interface MedianDuration {
  readonly users: number;
  readonly medianSeconds: number | null;
}

/** Son `timeToStepDays` günde açılan hesapların ilk adımlara geçen süreleri. */
export interface TimeToStep {
  readonly days: number;
  readonly signupToFirstMeeting: MedianDuration;
  readonly firstMeetingToFirstNote: MedianDuration;
  readonly signupToFirstNote: MedianDuration;
}

/**
 * Denemeye başlamış hesapların (`users.trial_started_at` dolu) sonucu; sırayla ilk uyan sayılır, toplamları `started`:
 * `converted` ödemesi tamamlanmış aboneliği var, `exhausted` tüm deneme toplantılarını kullandı, `expired` deneme süresi
 * doldu, `active` deneme sürüyor. Silinen hesaplar sayılmaz.
 */
export interface TrialOutcomes {
  readonly started: number;
  readonly converted: number;
  readonly exhausted: number;
  readonly expired: number;
  readonly active: number;
}

/**
 * Checkout'a gidip ödemeyen hesaplar: `started` Stripe müşterisi açılmış (ilk Checkout'ta açılır) hesaplar, `paid`
 * bunlardan ödemesi tamamlanmış aboneliği olanlar, `abandoned` = `started` − `paid`; `…Last30Days` müşterisi son 30
 * günde açılanlar.
 */
export interface CheckoutAbandonment {
  readonly started: number;
  readonly paid: number;
  readonly abandoned: number;
  readonly startedLast30Days: number;
  readonly abandonedLast30Days: number;
}

/** Günün "Sorunlar" sayaçları türe göre (`ops_events`). */
export interface OpsDay {
  readonly day: string;
  readonly refusal: number;
  readonly providerError: number;
  readonly serverError: number;
}

/**
 * Penceredeki Deepgram toplantıları: `grants` verilen jetonların toplamı, `withReconnects` jetonu
 * `baselineGrants`'tan fazla olan (yeniden bağlanan) toplantılar, `reconnects` fazladan jetonların toplamı.
 */
export interface DeepgramReliability {
  readonly meetings: number;
  readonly baselineGrants: number;
  readonly grants: number;
  readonly withReconnects: number;
  readonly reconnects: number;
}

/**
 * Son `reliabilityDays` günde başlayan toplantıların güvenilirliği. `failedMeetings` en az bir isteği başarısız olan,
 * `failuresByCode` bunların son hata koduna göre dökümü (çoktan aza); `endedMeetings` bitmiş (ya da yenisiyle
 * kapanmış), `notedMeetings` bunlardan notu tamamlanan, `medianNoteSeconds` not anı − bitiş ortancası;
 * `superseded` yeni toplantı başlayınca kapanan, `unended` bitirilmeden en çok süresi dolan, `open` süren;
 * `budgetExhausted` yapay zekâ bütçesi dolan (token bütçeye ulaştı ya da son hata `meeting_budget_exhausted`);
 * `onDevice` Deepgram jetonu almamış (canlı metni Mac'te üretilen) toplantılar. `opsDays` son 30 günün sayaçları.
 */
export interface Reliability {
  readonly days: number;
  readonly meetings: number;
  readonly failedMeetings: number;
  readonly failuresByCode: readonly DetailCount[];
  readonly endedMeetings: number;
  readonly notedMeetings: number;
  readonly medianNoteSeconds: number | null;
  readonly superseded: number;
  readonly unended: number;
  readonly open: number;
  readonly budgetExhausted: number;
  readonly deepgram: DeepgramReliability;
  readonly onDevice: number;
  readonly opsDays: readonly OpsDay[];
}

/** Toplantıların tahmini maliyeti (USD) servise göre. */
export interface MeetingCost {
  readonly llm: number;
  readonly elevenLabs: number;
  readonly deepgram: number;
  readonly total: number;
}

/**
 * Şu an ödeyen abonelerin (faturalı, erişimi süren, planı bilinen, davetin ücretsiz ilk ayında olmayan) o aydaki
 * kullanımının maliyeti ve liste fiyatıyla bir aylık geliri (aylık fiyat; yıllıkta fiyatın 1/12'si). Vergi, indirim ve
 * Stripe ücreti düşülmez. `grossMarginPercent` = (gelir − maliyet) / gelir × 100; gelir yoksa null.
 */
export interface PayerEconomics {
  readonly users: number;
  readonly costUsd: number;
  readonly costPerUserUsd: number | null;
  readonly listRevenueUsd: number;
  readonly grossMarginPercent: number | null;
}

/**
 * Ayın yaklaşık birim ekonomisi. `meetings` ve `meetingHours` o ay başlayan toplantılar; `meetingCostUsd` toplantıların
 * maliyeti (yapay zekâ: aylık kullanımdaki girdi/çıktı tokenı × kısa istem fiyatı, toplantı dışı token payı düşülür;
 * ElevenLabs: yazıya dökülen ses × temel saat fiyatı, anahtar terim eki yok; Deepgram: ilk jetonu o ay olan
 * toplantıların akış saniyesi × dakika fiyatı); `accountLlmUsd` toplantı dışı yapay zekâ çağrıları; `perMeeting` ve
 * `perMeetingHour` toplantı başına ve toplantı saati başına (payda 0 ise null). Hepsi alt sınır tahminidir.
 */
export interface EconomicsMonth {
  readonly month: string;
  readonly partial: boolean;
  readonly meetings: number;
  readonly meetingHours: number;
  readonly meetingCostUsd: MeetingCost;
  readonly accountLlmUsd: number;
  readonly perMeeting: MeetingCost | null;
  readonly perMeetingHour: MeetingCost | null;
  readonly payers: PayerEconomics;
}

/** Tahminde kullanılan fiyatlar. */
export interface EconomicsRates {
  readonly llmInputUsdPerMTok: number;
  readonly llmOutputUsdPerMTok: number;
  readonly elevenLabsUsdPerHour: number;
  readonly deepgramUsdPerMinute: number;
  readonly priceUsdMonthly: number;
  readonly priceUsdYearly: number;
}

/** Günün tahmini harcaması (Anthropic + ElevenLabs; `daily_spend`) ve deneme kısmı. */
export interface DaySpendSplit {
  readonly day: string;
  readonly usd: number;
  readonly trialUsd: number;
}

/** Yaklaşık birim ekonomisi: fiyatlar, son `economicsMonths` ay (eskiden yeniye) ve günlük harcama serisi. */
export interface UnitEconomics {
  readonly rates: EconomicsRates;
  readonly months: readonly EconomicsMonth[];
  readonly dailySpend: readonly DaySpendSplit[];
}

/** Sürümün çökme raporları (saklanan, en çok 180 gün): toplam, son 30 gün ve sonuncunun anı. Bilinmeyen sürüm `""`. */
export interface VersionCrashes {
  readonly version: string;
  readonly total: number;
  readonly recent: number;
  readonly lastAt: string;
}

/** Sürüme göre çökmeler (çoktan aza, en çok `crashVersionLimit` sürüm) ve saklanan tüm çökmelerin sayısı. */
export interface CrashesByVersion {
  readonly total: number;
  readonly recentDays: number;
  readonly versions: readonly VersionCrashes[];
}

/** `GET /v1/admin/product` yanıtı. */
export interface AdminProduct {
  readonly generatedAt: string;
  readonly engagement: Engagement;
  readonly cohorts: readonly SignupCohort[];
  readonly retention: { readonly d7: Retention; readonly d30: Retention };
  readonly timeToStep: TimeToStep;
  readonly trialOutcomes: TrialOutcomes;
  readonly checkout: CheckoutAbandonment;
  readonly reliability: Reliability;
  readonly economics: UnitEconomics;
  readonly crashes: CrashesByVersion;
}

interface CohortQueryRow {
  readonly cohort: number;
  readonly signups: number;
  readonly [week: `w${number}`]: number;
}

interface ActiveWeekRow {
  readonly week: number;
  readonly active_users: number;
  readonly meetings: number;
}

interface FirstStepsRow {
  readonly created_at: number;
  readonly first_meeting: number | null;
  readonly first_note: number | null;
}

interface ReliabilityRow {
  readonly meetings: number;
  readonly failed: number;
  readonly ended: number;
  readonly noted: number;
  readonly superseded: number;
  readonly unended: number;
  readonly open: number;
  readonly budget: number;
  readonly deepgram: number;
  readonly grants: number;
  readonly with_reconnects: number;
  readonly reconnects: number;
}

interface KeyCountRow {
  readonly key: string;
  readonly count: number;
}

interface OpsDayRow {
  readonly day: string;
  readonly kind: string;
  readonly count: number;
}

interface MonthMeetingsRow {
  readonly month: string;
  readonly meetings: number;
  readonly duration_ms: number;
}

interface MonthUsageRow {
  readonly month: string;
  readonly input_tokens: number;
  readonly output_tokens: number;
  readonly account_tokens: number;
  readonly audio_seconds: number;
}

interface MonthSecondsRow {
  readonly month: string;
  readonly seconds: number;
}

interface PayerPlansRow {
  readonly monthly: number;
  readonly yearly: number;
}

interface DaySpendRow {
  readonly day: string;
  readonly micro_usd: number;
  readonly trial_micro_usd: number;
}

interface CrashRow {
  readonly version: string;
  readonly total: number;
  readonly recent: number;
  readonly last_at: number;
}

/** Toplama sorgusunun tek satırı; yoksa `MissingAggregateRowError`. Saf fonksiyondur. */
function requiredRow<Row>(row: Row | null, query: string): Row {
  if (row === null) {
    throw new MissingAggregateRowError(query);
  }
  return row;
}

/** Zamanın haftasının başı (pazartesi 00:00 UTC), ms. Saf fonksiyondur. */
function weekStartMs(now: Date): number {
  return utcDayStartMs(now) - ((now.getUTCDay() + 6) % 7) * dayMs;
}

/** Sayıların ortancası (çift sayıda ortadaki ikisinin ortalaması); boşsa null. Saf fonksiyondur. */
function medianOf(values: readonly number[]): number | null {
  const sorted: number[] = [...values].sort((left: number, right: number): number => left - right);
  const middle: number = Math.floor(sorted.length / 2);
  const upper: number | undefined = sorted[middle];
  if (upper === undefined) {
    return null;
  }
  const lower: number | undefined = sorted.length % 2 === 0 ? sorted[middle - 1] : upper;
  return lower === undefined ? null : (lower + upper) / 2;
}

/** Ms farklarının ortancası saniye olarak (tam sayıya yuvarlanır) ve sayısı. Saf fonksiyondur. */
function medianDuration(differencesMs: readonly number[]): MedianDuration {
  const median: number | null = medianOf(differencesMs);
  return { users: differencesMs.length, medianSeconds: median === null ? null : Math.round(median / 1000) };
}

/** Dolar tutarı, 1/10.000 hassasiyetle (toplantı başına maliyet sentin altında olabilir). Saf fonksiyondur. */
function roundUsd(value: number): number {
  return Math.round(value * 10_000) / 10_000;
}

/** Yüzde bir hassasiyet (oran, saat). Saf fonksiyondur. */
function roundHundredths(value: number): number {
  return Math.round(value * 100) / 100;
}

/** Bugün dahil son `count` UTC ayı (`YYYY-MM`), eskiden yeniye. Saf fonksiyondur. */
function lastMonths(now: Date, count: number): string[] {
  return Array.from({ length: count }, (_: unknown, index: number): string =>
    monthKey(new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - (count - 1 - index), 1))),
  );
}

/** Yapay zekâ maliyeti (USD): girdi ve çıktı tokenı × kısa istem fiyatı (uzun istem fiyatı sayılmaz: alt sınır). Saf fonksiyondur. */
function llmUsd(inputTokens: number, outputTokens: number): number {
  return (inputTokens * haikuShortInputUsdPerMTok + outputTokens * haikuShortOutputUsdPerMTok) / 1_000_000;
}

/** Toplantı maliyetini bölene böler (bölen 0 ise null). Saf fonksiyondur. */
function costPer(cost: MeetingCost, divisor: number): MeetingCost | null {
  if (divisor <= 0) {
    return null;
  }
  return {
    llm: roundUsd(cost.llm / divisor),
    elevenLabs: roundUsd(cost.elevenLabs / divisor),
    deepgram: roundUsd(cost.deepgram / divisor),
    total: roundUsd(cost.total / divisor),
  };
}

/** Ayın kullanım satırı; o ay kullanım yoksa sıfırlar. Saf fonksiyondur. */
function usageOf(rows: readonly MonthUsageRow[], month: string): MonthUsageRow {
  return rows.find((row: MonthUsageRow): boolean => row.month === month) ?? { month, input_tokens: 0, output_tokens: 0, account_tokens: 0, audio_seconds: 0 };
}

/** Ayın saniye toplamı; yoksa 0. Saf fonksiyondur. */
function secondsOf(rows: readonly MonthSecondsRow[], month: string): number {
  return rows.find((row: MonthSecondsRow): boolean => row.month === month)?.seconds ?? 0;
}

/** Ayın birim ekonomisinin girdileri. */
interface EconomicsMonthInput {
  readonly month: string;
  readonly partial: boolean;
  readonly meetings: number;
  readonly meetingMs: number;
  readonly usage: MonthUsageRow;
  readonly deepgramSeconds: number;
  readonly payerUsage: MonthUsageRow;
  readonly payerDeepgramSeconds: number;
  readonly payerPlans: PayerPlansRow;
  readonly rates: EconomicsRates;
}

/** Ayın birim ekonomisi (tanımlar `EconomicsMonth`'ta). Saf fonksiyondur. */
function economicsMonth(input: EconomicsMonthInput): EconomicsMonth {
  const { usage, rates } = input;
  const llmTotal: number = llmUsd(usage.input_tokens, usage.output_tokens);
  const tokens: number = usage.input_tokens + usage.output_tokens;
  const accountLlm: number = tokens === 0 ? 0 : (llmTotal * usage.account_tokens) / tokens;
  const elevenLabs: number = (usage.audio_seconds / 3600) * rates.elevenLabsUsdPerHour;
  const deepgram: number = (input.deepgramSeconds / 60) * rates.deepgramUsdPerMinute;
  const meetingLlm: number = llmTotal - accountLlm;
  const meetingCost: MeetingCost = {
    llm: roundUsd(meetingLlm),
    elevenLabs: roundUsd(elevenLabs),
    deepgram: roundUsd(deepgram),
    total: roundUsd(meetingLlm + elevenLabs + deepgram),
  };
  const exactCost: MeetingCost = { llm: meetingLlm, elevenLabs, deepgram, total: meetingLlm + elevenLabs + deepgram };
  const meetingHours: number = input.meetingMs / 3_600_000;
  const payerCost: number =
    llmUsd(input.payerUsage.input_tokens, input.payerUsage.output_tokens) +
    (input.payerUsage.audio_seconds / 3600) * rates.elevenLabsUsdPerHour +
    (input.payerDeepgramSeconds / 60) * rates.deepgramUsdPerMinute;
  const payers: number = input.payerPlans.monthly + input.payerPlans.yearly;
  const revenue: number = input.payerPlans.monthly * rates.priceUsdMonthly + (input.payerPlans.yearly * rates.priceUsdYearly) / 12;
  return {
    month: input.month,
    partial: input.partial,
    meetings: input.meetings,
    meetingHours: roundHundredths(meetingHours),
    meetingCostUsd: meetingCost,
    accountLlmUsd: roundUsd(accountLlm),
    perMeeting: costPer(exactCost, input.meetings),
    perMeetingHour: costPer(exactCost, meetingHours),
    payers: {
      users: payers,
      costUsd: roundUsd(payerCost),
      costPerUserUsd: payers === 0 ? null : roundUsd(payerCost / payers),
      listRevenueUsd: roundUsd(revenue),
      grossMarginPercent: revenue === 0 ? null : roundHundredths(((revenue - payerCost) / revenue) * 100),
    },
  };
}

/** Kohort satırlarından son `productWeeks` haftanın tablosu (boş haftalar 0; başlamamış hafta sütunları null). Saf fonksiyondur. */
function signupCohorts(rows: readonly CohortQueryRow[], firstWeekMs: number, nowMs: number): SignupCohort[] {
  return Array.from({ length: productWeeks }, (_: unknown, index: number): SignupCohort => {
    const startMs: number = firstWeekMs + index * weekMs;
    const row: CohortQueryRow | undefined = rows.find((candidate: CohortQueryRow): boolean => candidate.cohort === index);
    return {
      weekStart: dayKey(new Date(startMs)),
      signups: row?.signups ?? 0,
      activeByWeek: Array.from({ length: cohortWeekColumns }, (__: unknown, week: number): number | null =>
        startMs + week * weekMs > nowMs ? null : (row?.[`w${week}`] ?? 0),
      ),
    };
  });
}

/** Haftalık etkinlik satırlarından son `productWeeks` haftanın serisi (boş haftalar 0). Saf fonksiyondur. */
function activeWeeks(rows: readonly ActiveWeekRow[], firstWeekMs: number): ActiveWeek[] {
  return Array.from({ length: productWeeks }, (_: unknown, index: number): ActiveWeek => {
    const row: ActiveWeekRow | undefined = rows.find((candidate: ActiveWeekRow): boolean => candidate.week === index);
    const activeUsers: number = row?.active_users ?? 0;
    const meetings: number = row?.meetings ?? 0;
    return {
      weekStart: dayKey(new Date(firstWeekMs + index * weekMs)),
      activeUsers,
      meetings,
      meetingsPerActiveUser: activeUsers === 0 ? null : roundHundredths(meetings / activeUsers),
    };
  });
}

/** Son 30 günün sayaç serisi (boş günler 0). Saf fonksiyondur. */
function opsDays(days: readonly string[], rows: readonly OpsDayRow[]): OpsDay[] {
  const countOf = (day: string, kind: string): number =>
    rows.find((row: OpsDayRow): boolean => row.day === day && row.kind === kind)?.count ?? 0;
  return days.map((day: string): OpsDay => ({
    day,
    refusal: countOf(day, "refusal"),
    providerError: countOf(day, "provider_error"),
    serverError: countOf(day, "server_error"),
  }));
}

/** İlk adım satırlarından geçen sürelerin ortancaları. Saf fonksiyondur. */
function timeToStep(rows: readonly FirstStepsRow[]): TimeToStep {
  const toMeeting: number[] = [];
  const meetingToNote: number[] = [];
  const toNote: number[] = [];
  for (const row of rows) {
    if (row.first_meeting !== null) {
      toMeeting.push(row.first_meeting - row.created_at);
    }
    if (row.first_meeting !== null && row.first_note !== null) {
      meetingToNote.push(row.first_note - row.first_meeting);
    }
    if (row.first_note !== null) {
      toNote.push(row.first_note - row.created_at);
    }
  }
  return {
    days: timeToStepDays,
    signupToFirstMeeting: medianDuration(toMeeting),
    firstMeetingToFirstNote: medianDuration(meetingToNote),
    signupToFirstNote: medianDuration(toNote),
  };
}

/** Kayıttan sonraki k. haftada toplantı var mı (k = 0…4) sütunlarının SQL'i (`users u`). */
function cohortWeekSql(): string {
  return Array.from(
    { length: cohortWeekColumns },
    (_: unknown, week: number): string =>
      `COALESCE(SUM(EXISTS (SELECT 1 FROM meeting_sessions m WHERE m.user_id = u.id
         AND m.started_at >= u.created_at + ${week * weekMs} AND m.started_at < u.created_at + ${(week + 1) * weekMs})), 0) AS w${week}`,
  ).join(",\n");
}

/** Dn tutunması (tanım `Retention`'da). */
async function retention(db: D1Database, nowMs: number, day: number): Promise<Retention> {
  const query: string = `SELECT COUNT(*) AS eligible,
       COALESCE(SUM(EXISTS (SELECT 1 FROM meeting_sessions m WHERE m.user_id = u.id
         AND m.started_at >= u.created_at + ?3 AND m.started_at < u.created_at + ?4)), 0) AS retained
     FROM users u WHERE u.created_at >= ?1 AND u.created_at <= ?2`;
  const row: { eligible: number; retained: number } = requiredRow(
    await db
      .prepare(query)
      .bind(nowMs - retentionLookbackDays * dayMs, nowMs - (day + retentionWindowDays) * dayMs, day * dayMs, (day + retentionWindowDays) * dayMs)
      .first<{ eligible: number; retained: number }>(),
    "retention",
  );
  return { day, eligible: row.eligible, retained: row.retained };
}

/** Şu an ödeyen abonelerin (`PayerEconomics`) CTE'si. Bağ: ?1 = şimdi. */
const payersCte: string = `WITH payers AS (
  SELECT s.user_id, s.plan FROM subscriptions s
  WHERE s.complimentary = 0 AND s.plan IN ('monthly', 'yearly') AND ${activeAccessSql} AND NOT ${freeInviteMonthSql}
)`;

/**
 * Ürün görünümü. Kohort, tutunma ve ilk adımlar `users_created` ve `meeting_sessions_user`; pencere sorguları
 * `meeting_sessions_started`, `monthly_usage_month` ve sayaç tablolarının gün anahtarlarıyla dizinlidir.
 */
export async function adminProduct(db: D1Database, config: Config, now: Date): Promise<AdminProduct> {
  const nowMs: number = now.getTime();
  const firstWeekMs: number = weekStartMs(now) - (productWeeks - 1) * weekMs;
  const reliabilityFrom: number = utcDayStartMs(now) - (reliabilityDays - 1) * dayMs;
  const reliabilityDayKeys: string[] = lastDays(now, reliabilityDays);
  const spendDayKeys: string[] = lastDays(now, dailySpendDays);
  const months: string[] = lastMonths(now, economicsMonths);
  const firstMonth: string = months[0] ?? monthKey(now);
  const firstMonthMs: number = Date.parse(`${firstMonth}-01T00:00:00Z`);
  const checkoutFrom: number = utcDayStartMs(now) - 29 * dayMs;
  const crashFrom: number = utcDayStartMs(now) - (crashRecentDays - 1) * dayMs;

  const [
    cohortRows,
    activeRow,
    weekRows,
    d7,
    d30,
    firstStepRows,
    trialRow,
    checkoutRow,
    reliabilityRow,
    failureRows,
    noteRows,
    opsRows,
    monthMeetingRows,
    monthUsageRows,
    monthDeepgramRows,
    payerPlansRow,
    payerUsageRows,
    payerDeepgramRows,
    spendRows,
    crashTotalRow,
    crashRows,
  ] = await Promise.all([
    db
      .prepare(
        `SELECT CAST((u.created_at - ?1) / ${weekMs} AS INTEGER) AS cohort, COUNT(*) AS signups,
           ${cohortWeekSql()}
         FROM users u WHERE u.created_at >= ?1 GROUP BY cohort`,
      )
      .bind(firstWeekMs)
      .all<CohortQueryRow>(),
    db
      .prepare(
        `SELECT COUNT(DISTINCT CASE WHEN started_at >= ?1 THEN user_id END) AS last7, COUNT(DISTINCT user_id) AS last30
         FROM meeting_sessions WHERE started_at >= ?2`,
      )
      .bind(nowMs - 7 * dayMs, nowMs - 30 * dayMs)
      .first<{ last7: number; last30: number }>(),
    db
      .prepare(
        `SELECT CAST((started_at - ?1) / ${weekMs} AS INTEGER) AS week, COUNT(DISTINCT user_id) AS active_users, COUNT(*) AS meetings
         FROM meeting_sessions WHERE started_at >= ?1 GROUP BY week`,
      )
      .bind(firstWeekMs)
      .all<ActiveWeekRow>(),
    retention(db, nowMs, 7),
    retention(db, nowMs, 30),
    db
      .prepare(
        `SELECT u.created_at,
           (SELECT MIN(m.started_at) FROM meeting_sessions m WHERE m.user_id = u.id) AS first_meeting,
           (SELECT MIN(m.first_note_at) FROM meeting_sessions m WHERE m.user_id = u.id) AS first_note
         FROM users u WHERE u.created_at >= ?`,
      )
      .bind(nowMs - timeToStepDays * dayMs)
      .all<FirstStepsRow>(),
    db
      .prepare(
        `SELECT COUNT(*) AS started,
           COALESCE(SUM(t.paid), 0) AS converted,
           COALESCE(SUM(CASE WHEN t.paid = 0 AND t.used >= ?2 THEN 1 ELSE 0 END), 0) AS exhausted,
           COALESCE(SUM(CASE WHEN t.paid = 0 AND t.used < ?2 AND t.started_at + ?3 <= ?1 THEN 1 ELSE 0 END), 0) AS expired,
           COALESCE(SUM(CASE WHEN t.paid = 0 AND t.used < ?2 AND t.started_at + ?3 > ?1 THEN 1 ELSE 0 END), 0) AS active
         FROM (
           SELECT u.trial_started_at AS started_at,
             u.carried_trial_meetings + (SELECT COUNT(*) FROM meeting_sessions m WHERE m.user_id = u.id AND m.kind = 'trial') AS used,
             EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = u.id AND ${paidSubscriptionSql}) AS paid
           FROM users u WHERE u.trial_started_at IS NOT NULL
         ) t`,
      )
      .bind(nowMs, config.trialMeetings, config.trialDurationMs)
      .first<TrialOutcomes>(),
    db
      .prepare(
        `SELECT COUNT(*) AS started, COALESCE(SUM(t.paid), 0) AS paid,
           COALESCE(SUM(CASE WHEN t.created_at >= ?1 THEN 1 ELSE 0 END), 0) AS started_recent,
           COALESCE(SUM(CASE WHEN t.created_at >= ?1 AND t.paid = 0 THEN 1 ELSE 0 END), 0) AS abandoned_recent
         FROM (
           SELECT c.created_at, EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = c.user_id AND ${paidSubscriptionSql}) AS paid
           FROM stripe_customers c
         ) t`,
      )
      .bind(checkoutFrom)
      .first<{ started: number; paid: number; started_recent: number; abandoned_recent: number }>(),
    db
      .prepare(
        `SELECT COUNT(*) AS meetings,
           COALESCE(SUM(CASE WHEN m.failure_count > 0 THEN 1 ELSE 0 END), 0) AS failed,
           COALESCE(SUM(CASE WHEN m.ended_at IS NOT NULL THEN 1 ELSE 0 END), 0) AS ended,
           COALESCE(SUM(CASE WHEN m.ended_at IS NOT NULL AND m.first_note_at IS NOT NULL THEN 1 ELSE 0 END), 0) AS noted,
           COALESCE(SUM(CASE WHEN m.end_reason = 'superseded' THEN 1 ELSE 0 END), 0) AS superseded,
           COALESCE(SUM(CASE WHEN m.ended_at IS NULL AND m.max_ends_at <= ?2 THEN 1 ELSE 0 END), 0) AS unended,
           COALESCE(SUM(CASE WHEN m.ended_at IS NULL AND m.max_ends_at > ?2 THEN 1 ELSE 0 END), 0) AS open,
           COALESCE(SUM(CASE WHEN m.tokens_used >= m.token_budget OR m.last_failure_code = 'meeting_budget_exhausted' THEN 1 ELSE 0 END), 0) AS budget,
           COALESCE(SUM(CASE WHEN d.meeting_id IS NOT NULL THEN 1 ELSE 0 END), 0) AS deepgram,
           COALESCE(SUM(d.grants), 0) AS grants,
           COALESCE(SUM(CASE WHEN d.grants > ?3 THEN 1 ELSE 0 END), 0) AS with_reconnects,
           COALESCE(SUM(MAX(0, d.grants - ?3)), 0) AS reconnects
         FROM meeting_sessions m LEFT JOIN deepgram_live_meetings d ON d.meeting_id = m.id
         WHERE m.started_at >= ?1`,
      )
      .bind(reliabilityFrom, nowMs, deepgramBaselineGrants)
      .first<ReliabilityRow>(),
    db
      .prepare(
        `SELECT COALESCE(last_failure_code, '') AS key, COUNT(*) AS count FROM meeting_sessions
         WHERE started_at >= ? AND failure_count > 0 GROUP BY key ORDER BY count DESC, key`,
      )
      .bind(reliabilityFrom)
      .all<KeyCountRow>(),
    db
      .prepare("SELECT first_note_at - ended_at AS value FROM meeting_sessions WHERE started_at >= ? AND ended_at IS NOT NULL AND first_note_at IS NOT NULL")
      .bind(reliabilityFrom)
      .all<{ value: number }>(),
    db
      .prepare("SELECT day, kind, SUM(count) AS count FROM ops_events WHERE day >= ? GROUP BY day, kind")
      .bind(reliabilityDayKeys[0] ?? dayKey(now))
      .all<OpsDayRow>(),
    db
      .prepare(
        `SELECT strftime('%Y-%m', started_at / 1000, 'unixepoch') AS month, COUNT(*) AS meetings,
           COALESCE(SUM(MAX(0, MIN(COALESCE(ended_at, ?1), max_ends_at, ?1) - started_at)), 0) AS duration_ms
         FROM meeting_sessions WHERE started_at >= ?2 GROUP BY month`,
      )
      .bind(nowMs, firstMonthMs)
      .all<MonthMeetingsRow>(),
    db
      .prepare(
        `SELECT month, SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens, SUM(account_tokens) AS account_tokens,
           SUM(audio_seconds) AS audio_seconds
         FROM monthly_usage WHERE month >= ? GROUP BY month`,
      )
      .bind(firstMonth)
      .all<MonthUsageRow>(),
    db
      .prepare(
        `SELECT strftime('%Y-%m', first_grant_at / 1000, 'unixepoch') AS month, SUM(charged_seconds) AS seconds
         FROM deepgram_live_meetings WHERE first_grant_at >= ? GROUP BY month`,
      )
      .bind(firstMonthMs)
      .all<MonthSecondsRow>(),
    db
      .prepare(
        `${payersCte}
         SELECT COALESCE(SUM(CASE WHEN plan = 'monthly' THEN 1 ELSE 0 END), 0) AS monthly,
           COALESCE(SUM(CASE WHEN plan = 'yearly' THEN 1 ELSE 0 END), 0) AS yearly
         FROM payers`,
      )
      .bind(nowMs)
      .first<PayerPlansRow>(),
    db
      .prepare(
        `${payersCte}
         SELECT u.month AS month, SUM(u.input_tokens) AS input_tokens, SUM(u.output_tokens) AS output_tokens,
           SUM(u.account_tokens) AS account_tokens, SUM(u.audio_seconds) AS audio_seconds
         FROM monthly_usage u JOIN payers p ON p.user_id = u.user_id WHERE u.month >= ?2 GROUP BY u.month`,
      )
      .bind(nowMs, firstMonth)
      .all<MonthUsageRow>(),
    db
      .prepare(
        `${payersCte}
         SELECT strftime('%Y-%m', d.first_grant_at / 1000, 'unixepoch') AS month, SUM(d.charged_seconds) AS seconds
         FROM deepgram_live_meetings d JOIN meeting_sessions m ON m.id = d.meeting_id JOIN payers p ON p.user_id = m.user_id
         WHERE d.first_grant_at >= ?2 GROUP BY month`,
      )
      .bind(nowMs, firstMonthMs)
      .all<MonthSecondsRow>(),
    db
      .prepare("SELECT day, micro_usd, trial_micro_usd FROM daily_spend WHERE day >= ?")
      .bind(spendDayKeys[0] ?? dayKey(now))
      .all<DaySpendRow>(),
    db.prepare("SELECT COUNT(*) AS value FROM reports WHERE kind = 'crash'").first<{ value: number }>(),
    db
      .prepare(
        `SELECT COALESCE(app_version, '') AS version, COUNT(*) AS total,
           COALESCE(SUM(CASE WHEN created_at >= ?1 THEN 1 ELSE 0 END), 0) AS recent, MAX(created_at) AS last_at
         FROM reports WHERE kind = 'crash' GROUP BY version ORDER BY total DESC, last_at DESC LIMIT ?2`,
      )
      .bind(crashFrom, crashVersionLimit)
      .all<CrashRow>(),
  ]);

  const active: { last7: number; last30: number } = requiredRow(activeRow, "engagement");
  const reliability: ReliabilityRow = requiredRow(reliabilityRow, "reliability");
  const checkout: { started: number; paid: number; started_recent: number; abandoned_recent: number } = requiredRow(checkoutRow, "checkout");
  const payerPlans: PayerPlansRow = requiredRow(payerPlansRow, "payers");
  const rates: EconomicsRates = {
    llmInputUsdPerMTok: haikuShortInputUsdPerMTok,
    llmOutputUsdPerMTok: haikuShortOutputUsdPerMTok,
    elevenLabsUsdPerHour: config.transcribe.usdPerHour,
    deepgramUsdPerMinute: config.deepgram.microUsdPerMinute / 1_000_000,
    priceUsdMonthly: config.priceUsdMonthly,
    priceUsdYearly: config.priceUsdYearly,
  };
  const currentMonth: string = monthKey(now);
  const spendByDay: Map<string, DaySpendRow> = new Map(spendRows.results.map((row: DaySpendRow): [string, DaySpendRow] => [row.day, row]));

  return {
    generatedAt: now.toISOString(),
    engagement: { activeLast7Days: active.last7, activeLast30Days: active.last30, weeks: activeWeeks(weekRows.results, firstWeekMs) },
    cohorts: signupCohorts(cohortRows.results, firstWeekMs, nowMs),
    retention: { d7, d30 },
    timeToStep: timeToStep(firstStepRows.results),
    trialOutcomes: requiredRow(trialRow, "trial_outcomes"),
    checkout: {
      started: checkout.started,
      paid: checkout.paid,
      abandoned: checkout.started - checkout.paid,
      startedLast30Days: checkout.started_recent,
      abandonedLast30Days: checkout.abandoned_recent,
    },
    reliability: {
      days: reliabilityDays,
      meetings: reliability.meetings,
      failedMeetings: reliability.failed,
      failuresByCode: failureRows.results.map((row: KeyCountRow): DetailCount => ({ detail: row.key, count: row.count })),
      endedMeetings: reliability.ended,
      notedMeetings: reliability.noted,
      medianNoteSeconds: medianDuration(noteRows.results.map((row: { value: number }): number => row.value)).medianSeconds,
      superseded: reliability.superseded,
      unended: reliability.unended,
      open: reliability.open,
      budgetExhausted: reliability.budget,
      deepgram: {
        meetings: reliability.deepgram,
        baselineGrants: deepgramBaselineGrants,
        grants: reliability.grants,
        withReconnects: reliability.with_reconnects,
        reconnects: reliability.reconnects,
      },
      onDevice: reliability.meetings - reliability.deepgram,
      opsDays: opsDays(reliabilityDayKeys, opsRows.results),
    },
    economics: {
      rates,
      months: months.map(
        (month: string): EconomicsMonth => {
          const meetingRow: MonthMeetingsRow | undefined = monthMeetingRows.results.find((row: MonthMeetingsRow): boolean => row.month === month);
          return economicsMonth({
            month,
            partial: month === currentMonth,
            meetings: meetingRow?.meetings ?? 0,
            meetingMs: meetingRow?.duration_ms ?? 0,
            usage: usageOf(monthUsageRows.results, month),
            deepgramSeconds: secondsOf(monthDeepgramRows.results, month),
            payerUsage: usageOf(payerUsageRows.results, month),
            payerDeepgramSeconds: secondsOf(payerDeepgramRows.results, month),
            payerPlans,
            rates,
          });
        },
      ),
      dailySpend: spendDayKeys.map((day: string): DaySpendSplit => {
        const row: DaySpendRow | undefined = spendByDay.get(day);
        return { day, usd: (row?.micro_usd ?? 0) / 1_000_000, trialUsd: (row?.trial_micro_usd ?? 0) / 1_000_000 };
      }),
    },
    crashes: {
      total: requiredRow(crashTotalRow, "crashes").value,
      recentDays: crashRecentDays,
      versions: crashRows.results.map(
        (row: CrashRow): VersionCrashes => ({ version: row.version, total: row.total, recent: row.recent, lastAt: new Date(row.last_at).toISOString() }),
      ),
    },
  };
}
