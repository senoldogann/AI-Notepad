// Yönetim panelinin ürün görünümü (`/v1/admin/product`): etkinlik (WAU/MAU, haftalık etkin hesaplar), kayıt haftası
// kohortları, D7/D30 tutunma, ilk adımlara geçen süre, deneme sonuçları, yarım kalan Checkout; güvenilirlik (toplantı
// hataları, not tamamlanması, Deepgram yeniden bağlanmaları, günlük "Sorunlar" grafikleri); yaklaşık birim ekonomisi
// (liste fiyatı) ve sürüme göre çökmeler. Yanıt burada katı biçimde doğrulanır; yanıtta hesap kimliği yoktur.
import {
  ApiResponseError,
  booleanField,
  type JsonObject,
  type JsonValue,
  type RawResponse,
  numberField,
  objectArrayField,
  objectField,
  parseObject,
  stringField,
} from "./api";
import { fillCounts, fillTable, formatCount, formatDay, formatDayLong, formatRate, formatTime, node, tableRow } from "./admin-format";
import { type AdminProductCopy, adminProductCopy } from "./admin-product-copy";
import { type AdminClientCopy, clientCopy, fill } from "./copy";
import { element } from "./dom";
import { authorizedSend } from "./session";
import { siteLocale } from "../config";

const productText: AdminProductCopy = adminProductCopy;
const adminText: AdminClientCopy = clientCopy.admin;
const svgNamespace: string = "http://www.w3.org/2000/svg";

/** Grafik çizim alanı (SVG birimi; genel bakıştaki grafiklerle aynı). */
const chartWidth: number = 300;
const chartHeight: number = 60;
const barGap: number = 3;

/** Ayrıntı başına sayı. */
interface DetailCount {
  readonly detail: string;
  readonly count: number;
}

/** Kayıt haftası kohortu; hafta sütunu henüz başlamadıysa null. */
interface SignupCohort {
  readonly weekStart: string;
  readonly signups: number;
  readonly activeByWeek: readonly (number | null)[];
}

/** Takvim haftasının etkinliği. */
interface ActiveWeek {
  readonly weekStart: string;
  readonly activeUsers: number;
  readonly meetings: number;
  readonly meetingsPerActiveUser: number | null;
}

/** Dn tutunması. */
interface Retention {
  readonly day: number;
  readonly eligible: number;
  readonly retained: number;
}

/** Adıma geçen sürenin ortancası (saniye). */
interface MedianDuration {
  readonly users: number;
  readonly medianSeconds: number | null;
}

/** Günün "Sorunlar" sayaçları. */
interface OpsDay {
  readonly day: string;
  readonly refusal: number;
  readonly providerError: number;
  readonly serverError: number;
}

/** Toplantı maliyeti (USD) servise göre. */
interface MeetingCost {
  readonly llm: number;
  readonly elevenLabs: number;
  readonly deepgram: number;
  readonly total: number;
}

/** Ödeyen abonelerin ayı. */
interface PayerEconomics {
  readonly users: number;
  readonly costUsd: number;
  readonly costPerUserUsd: number | null;
  readonly listRevenueUsd: number;
  readonly grossMarginPercent: number | null;
}

/** Ayın birim ekonomisi. */
interface EconomicsMonth {
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

/** Günün harcaması ve deneme kısmı. */
interface DaySpendSplit {
  readonly day: string;
  readonly usd: number;
  readonly trialUsd: number;
}

/** Sürümün çökmeleri. */
interface VersionCrashes {
  readonly version: string;
  readonly total: number;
  readonly recent: number;
  readonly lastAt: number;
}

/** `GET /v1/admin/product` yanıtı (tanımlar sunucuda: server/src/adminProduct.ts). */
export interface Product {
  readonly engagement: { readonly activeLast7Days: number; readonly activeLast30Days: number; readonly weeks: readonly ActiveWeek[] };
  readonly cohorts: readonly SignupCohort[];
  readonly retention: { readonly d7: Retention; readonly d30: Retention };
  readonly timeToStep: {
    readonly days: number;
    readonly signupToFirstMeeting: MedianDuration;
    readonly firstMeetingToFirstNote: MedianDuration;
    readonly signupToFirstNote: MedianDuration;
  };
  readonly trialOutcomes: { readonly started: number; readonly converted: number; readonly exhausted: number; readonly expired: number; readonly active: number };
  readonly checkout: { readonly started: number; readonly paid: number; readonly abandoned: number; readonly startedLast30Days: number; readonly abandonedLast30Days: number };
  readonly reliability: {
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
    readonly deepgram: { readonly meetings: number; readonly baselineGrants: number; readonly grants: number; readonly withReconnects: number; readonly reconnects: number };
    readonly onDevice: number;
    readonly opsDays: readonly OpsDay[];
  };
  readonly economics: {
    readonly rates: {
      readonly llmInputUsdPerMTok: number;
      readonly llmOutputUsdPerMTok: number;
      readonly elevenLabsUsdPerHour: number;
      readonly deepgramUsdPerMinute: number;
      readonly priceUsdMonthly: number;
      readonly priceUsdYearly: number;
    };
    readonly months: readonly EconomicsMonth[];
    readonly dailySpend: readonly DaySpendSplit[];
  };
  readonly crashes: { readonly total: number; readonly recentDays: number; readonly versions: readonly VersionCrashes[] };
}

/** Ürün görünümünün dışarıya açtığı işlemler. */
export interface ProductView {
  /** Görünümü (yeniden) yükler. */
  readonly refresh: () => Promise<void>;
  /** İlk açılışta yükler (sonrakilerde bir şey yapmaz). */
  readonly ensureLoaded: () => Promise<void>;
}

/** Grafikteki bir günün yığılmış çubuk parçaları (alttan üste). */
interface ChartDay {
  readonly day: string;
  readonly parts: readonly { readonly value: number; readonly tone: "main" | "accent" }[];
  readonly title: string;
}

/** Sayı ya da null alanı. */
function nullableNumberField(object: JsonObject, key: string, response: RawResponse, path: string): number | null {
  return object[key] === null ? null : numberField(object, key, response, path);
}

/** Sayı ya da null dizisi alanı. */
function nullableNumberArrayField(object: JsonObject, key: string, response: RawResponse, path: string): (number | null)[] {
  const value: JsonValue | undefined = object[key];
  if (!Array.isArray(value)) {
    throw new ApiResponseError(path, response.status, `"${key}" dizi değil`, response.text);
  }
  return value.map((item: JsonValue, index: number): number | null => {
    if (item === null || (typeof item === "number" && Number.isFinite(item))) {
      return item;
    }
    throw new ApiResponseError(path, response.status, `"${key}[${index}]" sayı ya da null değil`, response.text);
  });
}

/** ISO 8601 zaman alanı; ms döner. */
function isoField(object: JsonObject, key: string, response: RawResponse, path: string): number {
  const value: string = stringField(object, key, response, path);
  const ms: number = Date.parse(value);
  if (Number.isNaN(ms)) {
    throw new ApiResponseError(path, response.status, `"${key}" zaman değil`, response.text);
  }
  return ms;
}

/** Toplantı maliyetini okur. */
function parseMeetingCost(object: JsonObject, response: RawResponse, path: string): MeetingCost {
  return {
    llm: numberField(object, "llm", response, path),
    elevenLabs: numberField(object, "elevenLabs", response, path),
    deepgram: numberField(object, "deepgram", response, path),
    total: numberField(object, "total", response, path),
  };
}

/** Toplantı maliyeti ya da null alanını okur. */
function nullableMeetingCost(owner: JsonObject, key: string, response: RawResponse, path: string): MeetingCost | null {
  return owner[key] === null ? null : parseMeetingCost(objectField(owner, key, response, path), response, path);
}

/** Ortanca süreyi okur. */
function parseMedian(owner: JsonObject, key: string, response: RawResponse, path: string): MedianDuration {
  const object: JsonObject = objectField(owner, key, response, path);
  return { users: numberField(object, "users", response, path), medianSeconds: nullableNumberField(object, "medianSeconds", response, path) };
}

/** Tutunmayı okur. */
function parseRetention(owner: JsonObject, key: string, response: RawResponse, path: string): Retention {
  const object: JsonObject = objectField(owner, key, response, path);
  return { day: numberField(object, "day", response, path), eligible: numberField(object, "eligible", response, path), retained: numberField(object, "retained", response, path) };
}

/** `GET /v1/admin/product` yanıtını okur. */
export function parseProduct(response: RawResponse, path: string): Product {
  const body: JsonObject = parseObject(response, path);
  const engagement: JsonObject = objectField(body, "engagement", response, path);
  const retention: JsonObject = objectField(body, "retention", response, path);
  const steps: JsonObject = objectField(body, "timeToStep", response, path);
  const trials: JsonObject = objectField(body, "trialOutcomes", response, path);
  const checkout: JsonObject = objectField(body, "checkout", response, path);
  const reliability: JsonObject = objectField(body, "reliability", response, path);
  const deepgram: JsonObject = objectField(reliability, "deepgram", response, path);
  const economics: JsonObject = objectField(body, "economics", response, path);
  const rates: JsonObject = objectField(economics, "rates", response, path);
  const crashes: JsonObject = objectField(body, "crashes", response, path);
  const count = (object: JsonObject, key: string): number => numberField(object, key, response, path);
  return {
    engagement: {
      activeLast7Days: count(engagement, "activeLast7Days"),
      activeLast30Days: count(engagement, "activeLast30Days"),
      weeks: objectArrayField(engagement, "weeks", response, path).map(
        (item: JsonObject): ActiveWeek => ({
          weekStart: stringField(item, "weekStart", response, path),
          activeUsers: count(item, "activeUsers"),
          meetings: count(item, "meetings"),
          meetingsPerActiveUser: nullableNumberField(item, "meetingsPerActiveUser", response, path),
        }),
      ),
    },
    cohorts: objectArrayField(body, "cohorts", response, path).map(
      (item: JsonObject): SignupCohort => ({
        weekStart: stringField(item, "weekStart", response, path),
        signups: count(item, "signups"),
        activeByWeek: nullableNumberArrayField(item, "activeByWeek", response, path),
      }),
    ),
    retention: { d7: parseRetention(retention, "d7", response, path), d30: parseRetention(retention, "d30", response, path) },
    timeToStep: {
      days: count(steps, "days"),
      signupToFirstMeeting: parseMedian(steps, "signupToFirstMeeting", response, path),
      firstMeetingToFirstNote: parseMedian(steps, "firstMeetingToFirstNote", response, path),
      signupToFirstNote: parseMedian(steps, "signupToFirstNote", response, path),
    },
    trialOutcomes: {
      started: count(trials, "started"),
      converted: count(trials, "converted"),
      exhausted: count(trials, "exhausted"),
      expired: count(trials, "expired"),
      active: count(trials, "active"),
    },
    checkout: {
      started: count(checkout, "started"),
      paid: count(checkout, "paid"),
      abandoned: count(checkout, "abandoned"),
      startedLast30Days: count(checkout, "startedLast30Days"),
      abandonedLast30Days: count(checkout, "abandonedLast30Days"),
    },
    reliability: {
      days: count(reliability, "days"),
      meetings: count(reliability, "meetings"),
      failedMeetings: count(reliability, "failedMeetings"),
      failuresByCode: objectArrayField(reliability, "failuresByCode", response, path).map(
        (item: JsonObject): DetailCount => ({ detail: stringField(item, "detail", response, path), count: count(item, "count") }),
      ),
      endedMeetings: count(reliability, "endedMeetings"),
      notedMeetings: count(reliability, "notedMeetings"),
      medianNoteSeconds: nullableNumberField(reliability, "medianNoteSeconds", response, path),
      superseded: count(reliability, "superseded"),
      unended: count(reliability, "unended"),
      open: count(reliability, "open"),
      budgetExhausted: count(reliability, "budgetExhausted"),
      deepgram: {
        meetings: count(deepgram, "meetings"),
        baselineGrants: count(deepgram, "baselineGrants"),
        grants: count(deepgram, "grants"),
        withReconnects: count(deepgram, "withReconnects"),
        reconnects: count(deepgram, "reconnects"),
      },
      onDevice: count(reliability, "onDevice"),
      opsDays: objectArrayField(reliability, "opsDays", response, path).map(
        (item: JsonObject): OpsDay => ({
          day: stringField(item, "day", response, path),
          refusal: count(item, "refusal"),
          providerError: count(item, "providerError"),
          serverError: count(item, "serverError"),
        }),
      ),
    },
    economics: {
      rates: {
        llmInputUsdPerMTok: count(rates, "llmInputUsdPerMTok"),
        llmOutputUsdPerMTok: count(rates, "llmOutputUsdPerMTok"),
        elevenLabsUsdPerHour: count(rates, "elevenLabsUsdPerHour"),
        deepgramUsdPerMinute: count(rates, "deepgramUsdPerMinute"),
        priceUsdMonthly: count(rates, "priceUsdMonthly"),
        priceUsdYearly: count(rates, "priceUsdYearly"),
      },
      months: objectArrayField(economics, "months", response, path).map((item: JsonObject): EconomicsMonth => {
        const payers: JsonObject = objectField(item, "payers", response, path);
        return {
          month: stringField(item, "month", response, path),
          partial: booleanField(item, "partial", response, path),
          meetings: count(item, "meetings"),
          meetingHours: count(item, "meetingHours"),
          meetingCostUsd: parseMeetingCost(objectField(item, "meetingCostUsd", response, path), response, path),
          accountLlmUsd: count(item, "accountLlmUsd"),
          perMeeting: nullableMeetingCost(item, "perMeeting", response, path),
          perMeetingHour: nullableMeetingCost(item, "perMeetingHour", response, path),
          payers: {
            users: count(payers, "users"),
            costUsd: count(payers, "costUsd"),
            costPerUserUsd: nullableNumberField(payers, "costPerUserUsd", response, path),
            listRevenueUsd: count(payers, "listRevenueUsd"),
            grossMarginPercent: nullableNumberField(payers, "grossMarginPercent", response, path),
          },
        };
      }),
      dailySpend: objectArrayField(economics, "dailySpend", response, path).map(
        (item: JsonObject): DaySpendSplit => ({ day: stringField(item, "day", response, path), usd: count(item, "usd"), trialUsd: count(item, "trialUsd") }),
      ),
    },
    crashes: {
      total: count(crashes, "total"),
      recentDays: count(crashes, "recentDays"),
      versions: objectArrayField(crashes, "versions", response, path).map(
        (item: JsonObject): VersionCrashes => ({
          version: stringField(item, "version", response, path),
          total: count(item, "total"),
          recent: count(item, "recent"),
          lastAt: isoField(item, "lastAt", response, path),
        }),
      ),
    },
  };
}

/** Ürün görünümü. */
export async function fetchProduct(): Promise<Product> {
  const path: string = "/v1/admin/product";
  return parseProduct(await authorizedSend({ method: "GET", path, body: null, attempts: 3 }), path);
}

/** Küçük dolar tutarı: 1 $'ın altında dört ondalığa dek (toplantı başına maliyet sentin altında olabilir). Saf fonksiyondur. */
function formatSmallUsd(value: number): string {
  return new Intl.NumberFormat(siteLocale, {
    style: "currency",
    currency: "USD",
    currencyDisplay: "narrowSymbol",
    minimumFractionDigits: 2,
    maximumFractionDigits: Math.abs(value) < 1 ? 4 : 2,
  }).format(value);
}

/** Dolar tutarı ya da yoksa "—". Saf fonksiyondur. */
function formatOptionalUsd(value: number | null): string {
  return value === null ? adminText.none : formatSmallUsd(value);
}

/** Süre (saniye) en uygun birimle; yoksa "—". Saf fonksiyondur. */
function formatSeconds(seconds: number | null): string {
  if (seconds === null) {
    return adminText.none;
  }
  const units: readonly (readonly [number, string])[] = [
    [86_400, productText.durations.days],
    [3_600, productText.durations.hours],
    [60, productText.durations.minutes],
  ];
  for (const [size, template] of units) {
    if (Math.abs(seconds) >= size) {
      return fill(template, { value: formatCount(seconds / size) });
    }
  }
  return fill(productText.durations.seconds, { value: formatCount(seconds) });
}

/** `YYYY-MM` ayını yazar ("Oct 2026"; UTC). Saf fonksiyondur. */
function formatMonth(month: string): string {
  return new Intl.DateTimeFormat(siteLocale, { month: "short", year: "numeric", timeZone: "UTC" }).format(new Date(`${month}-01T00:00:00Z`));
}

/** Kutunun değerini ve alt satırını yazar. */
function setProductKpi(id: string, value: string, sub: string, warn: boolean): void {
  element(`kpi-product-${id}`, HTMLElement).textContent = value;
  element(`kpi-product-${id}-sub`, HTMLElement).textContent = sub;
  element(`kpi-product-${id}-card`, HTMLElement).classList.toggle("kpi--warn", warn);
}

/** Sayı ve paya göre oranı tek hücrede ("3 · 50%"; payda 0 ise yalnızca sayı). Saf fonksiyondur. */
function countWithRate(part: number, whole: number): string {
  return whole === 0 ? formatCount(part) : `${formatCount(part)} · ${formatRate(part, whole)}`;
}

/** Tablonun gövdesini doldurur; boş bildirimi varsa açar ya da kapatır. */
function fillProductTable(id: string, rows: readonly HTMLTableRowElement[], hasEmpty: boolean): void {
  fillTable(element(`${id}-rows`, HTMLTableSectionElement), rows);
  if (hasEmpty) {
    element(`${id}-empty`, HTMLElement).classList.toggle("hidden", rows.length > 0);
  }
}

/** SVG öğesi oluşturur. */
function svgElement(name: string, attributes: Readonly<Record<string, string>>): SVGElement {
  const created: SVGElement = document.createElementNS(svgNamespace, name) as SVGElement;
  for (const [key, value] of Object.entries(attributes)) {
    created.setAttribute(key, value);
  }
  return created;
}

/** Grafiğin metin özeti: toplam ve en yüksek gün. Saf fonksiyondur. */
function chartSummary(days: readonly ChartDay[], format: (value: number) => string): string {
  const totals: number[] = days.map((day: ChartDay): number => day.parts.reduce((sum: number, part): number => sum + part.value, 0));
  const total: number = totals.reduce((sum: number, value: number): number => sum + value, 0);
  if (total === 0) {
    return adminText.chartEmpty;
  }
  const peak: number = Math.max(...totals);
  const peakDay: ChartDay | undefined = days[totals.indexOf(peak)];
  return fill(adminText.chartSummary, { total: format(total), peak: format(peak), day: peakDay === undefined ? "" : formatDay(peakDay.day) });
}

/** Günlük yığılmış çubuk grafiğini çizer (genel bakış grafikleriyle aynı biçim); özeti `figcaption`'a yazar. */
function renderChart(id: string, days: readonly ChartDay[], format: (value: number) => string): void {
  const totals: number[] = days.map((day: ChartDay): number => day.parts.reduce((sum: number, part): number => sum + part.value, 0));
  const max: number = Math.max(0, ...totals);
  const barWidth: number = days.length === 0 ? 0 : (chartWidth - barGap * (days.length - 1)) / days.length;
  const svg: SVGElement = svgElement("svg", { viewBox: `0 0 ${chartWidth} ${chartHeight}`, class: "chart__svg", role: "img", "aria-labelledby": `chart-${id}-summary` });
  days.forEach((day: ChartDay, index: number): void => {
    const x: number = index * (barWidth + barGap);
    const group: SVGElement = svgElement("g", {});
    const title: SVGElement = svgElement("title", {});
    title.textContent = day.title;
    group.append(title, svgElement("rect", { x: x.toFixed(2), y: String(chartHeight - 1.5), width: barWidth.toFixed(2), height: "1.5", rx: "0.75", class: "chart__base" }));
    let top: number = chartHeight;
    for (const part of day.parts) {
      if (part.value <= 0 || max === 0) {
        continue;
      }
      const height: number = Math.max(2, (part.value / max) * (chartHeight - 4));
      top -= height;
      group.append(svgElement("rect", { x: x.toFixed(2), y: top.toFixed(2), width: barWidth.toFixed(2), height: height.toFixed(2), rx: "1", class: `chart__bar chart__bar--${part.tone}` }));
    }
    svg.append(group);
  });
  const axis: HTMLElement = node("div", "chart__axis", "");
  axis.setAttribute("aria-hidden", "true");
  const first: ChartDay | undefined = days[0];
  const last: ChartDay | undefined = days.at(-1);
  axis.append(node("span", "", first === undefined ? "" : formatDay(first.day)), node("span", "", last === undefined ? "" : formatDay(last.day)));
  element(`chart-${id}`, HTMLElement).replaceChildren(svg, axis);
  element(`chart-${id}-summary`, HTMLElement).textContent = chartSummary(days, format);
}

/** Bir sayaç türünün günlük grafiği. Saf fonksiyondur. */
function opsChartDays(days: readonly OpsDay[], value: (day: OpsDay) => number): ChartDay[] {
  return days.map((day: OpsDay): ChartDay => ({
    day: day.day,
    parts: [{ value: value(day), tone: "main" }],
    title: fill(adminText.barTitle, { day: formatDay(day.day), value: formatCount(value(day)) }),
  }));
}

/** Kohort tablosunun satırları. */
function cohortRows(cohorts: readonly SignupCohort[]): HTMLTableRowElement[] {
  return cohorts.map((cohort: SignupCohort): HTMLTableRowElement =>
    tableRow([
      formatDayLong(cohort.weekStart),
      formatCount(cohort.signups),
      ...cohort.activeByWeek.map((active: number | null): string => (active === null ? adminText.none : countWithRate(active, cohort.signups))),
    ]),
  );
}

/** Etkinlik ve edinim bölümünü çizer. */
function renderEngagement(product: Product): void {
  const engagement: Product["engagement"] = product.engagement;
  setProductKpi(
    "wau",
    formatCount(engagement.activeLast7Days),
    fill(productText.kpiSubs.wau, { mau: formatCount(engagement.activeLast30Days), ratio: formatRate(engagement.activeLast7Days, engagement.activeLast30Days) }),
    false,
  );
  for (const retention of [product.retention.d7, product.retention.d30]) {
    setProductKpi(
      `d${retention.day}`,
      formatRate(retention.retained, retention.eligible),
      fillCounts(productText.kpiSubs.retention, { retained: retention.retained, eligible: retention.eligible, from: retention.day, to: retention.day + 6 }),
      false,
    );
  }
  const checkout: Product["checkout"] = product.checkout;
  setProductKpi(
    "checkout",
    formatRate(checkout.abandoned, checkout.started),
    fillCounts(productText.kpiSubs.checkout, { abandoned: checkout.abandoned, started: checkout.started, recent: checkout.abandonedLast30Days, recentStarted: checkout.startedLast30Days }),
    false,
  );
  fillProductTable("product-cohorts", cohortRows(product.cohorts), false);
  fillProductTable(
    "product-weeks",
    engagement.weeks.map((week: ActiveWeek): HTMLTableRowElement =>
      tableRow([
        formatDayLong(week.weekStart),
        formatCount(week.activeUsers),
        formatCount(week.meetings),
        week.meetingsPerActiveUser === null ? adminText.none : formatCount(week.meetingsPerActiveUser),
      ]),
    ),
    false,
  );
  const steps: Product["timeToStep"] = product.timeToStep;
  const stepLines: ReadonlyArray<readonly [string, MedianDuration]> = [
    [productText.steps.signupToFirstMeeting, steps.signupToFirstMeeting],
    [productText.steps.firstMeetingToFirstNote, steps.firstMeetingToFirstNote],
    [productText.steps.signupToFirstNote, steps.signupToFirstNote],
  ];
  element("product-steps-note", HTMLElement).textContent = fillCounts(productText.notes.steps, { days: steps.days });
  fillProductTable(
    "product-steps",
    stepLines.map(([label, median]: readonly [string, MedianDuration]): HTMLTableRowElement => tableRow([label, formatCount(median.users), formatSeconds(median.medianSeconds)])),
    false,
  );
  const trials: Product["trialOutcomes"] = product.trialOutcomes;
  const trialLines: ReadonlyArray<readonly [string, number]> = [
    [productText.trialOutcomes.converted, trials.converted],
    [productText.trialOutcomes.exhausted, trials.exhausted],
    [productText.trialOutcomes.expired, trials.expired],
    [productText.trialOutcomes.active, trials.active],
  ];
  fillProductTable(
    "product-trials",
    [
      ...trialLines.map(([label, value]: readonly [string, number]): HTMLTableRowElement => tableRow([label, formatCount(value), formatRate(value, trials.started)])),
      tableRow([productText.trialOutcomes.started, formatCount(trials.started), adminText.none]),
    ],
    false,
  );
}

/** Güvenilirlik bölümünü çizer. */
function renderReliability(reliability: Product["reliability"]): void {
  const meetings: number = reliability.meetings;
  setProductKpi(
    "failed",
    formatRate(reliability.failedMeetings, meetings),
    fillCounts(productText.kpiSubs.failed, { failed: reliability.failedMeetings, meetings }),
    reliability.failedMeetings > 0,
  );
  setProductKpi(
    "notes",
    formatRate(reliability.notedMeetings, reliability.endedMeetings),
    fillCounts(productText.kpiSubs.notes, { noted: reliability.notedMeetings, ended: reliability.endedMeetings }),
    false,
  );
  setProductKpi("note-time", formatSeconds(reliability.medianNoteSeconds), fillCounts(productText.kpiSubs.noteTime, { noted: reliability.notedMeetings }), false);
  setProductKpi(
    "on-device",
    formatRate(reliability.onDevice, meetings),
    fillCounts(productText.kpiSubs.onDevice, { onDevice: reliability.onDevice, meetings, deepgram: reliability.deepgram.meetings }),
    false,
  );
  fillProductTable(
    "product-failures",
    reliability.failuresByCode.map((item: DetailCount): HTMLTableRowElement =>
      tableRow([node("span", "mono", item.detail === "" ? adminText.none : item.detail), formatCount(item.count), formatRate(item.count, meetings)]),
    ),
    true,
  );
  const deepgram: Product["reliability"]["deepgram"] = reliability.deepgram;
  const outcomeLines: ReadonlyArray<readonly [string, number, number | null]> = [
    [productText.outcomes.ended, reliability.endedMeetings, meetings],
    [productText.outcomes.noted, reliability.notedMeetings, reliability.endedMeetings],
    [productText.outcomes.superseded, reliability.superseded, meetings],
    [productText.outcomes.unended, reliability.unended, meetings],
    [productText.outcomes.open, reliability.open, meetings],
    [productText.outcomes.budget, reliability.budgetExhausted, meetings],
    [productText.outcomes.deepgram, deepgram.meetings, meetings],
    [productText.outcomes.reconnecting, deepgram.withReconnects, deepgram.meetings],
    [productText.outcomes.reconnects, deepgram.reconnects, null],
    [productText.outcomes.onDevice, reliability.onDevice, meetings],
  ];
  fillProductTable(
    "product-outcomes",
    outcomeLines.map(([label, value, whole]: readonly [string, number, number | null]): HTMLTableRowElement =>
      tableRow([label, formatCount(value), whole === null ? adminText.none : formatRate(value, whole)]),
    ),
    false,
  );
  element("product-outcomes-note", HTMLElement).textContent = fillCounts(productText.notes.outcomes, { baseline: deepgram.baselineGrants });
  renderChart("product-refusals", opsChartDays(reliability.opsDays, (day: OpsDay): number => day.refusal), formatCount);
  renderChart("product-provider", opsChartDays(reliability.opsDays, (day: OpsDay): number => day.providerError), formatCount);
  renderChart("product-server", opsChartDays(reliability.opsDays, (day: OpsDay): number => day.serverError), formatCount);
}

/** Ayın etiketi (bu ay kısmi). Saf fonksiyondur. */
function monthLabel(month: EconomicsMonth): string {
  return month.partial ? fill(productText.partialMonth, { month: formatMonth(month.month) }) : formatMonth(month.month);
}

/** Birim ekonomisi bölümünü çizer. */
function renderEconomics(economics: Product["economics"]): void {
  fillProductTable(
    "product-costs",
    economics.months.map((month: EconomicsMonth): HTMLTableRowElement =>
      tableRow([
        monthLabel(month),
        formatCount(month.meetings),
        formatCount(month.meetingHours),
        formatSmallUsd(month.meetingCostUsd.llm),
        formatSmallUsd(month.meetingCostUsd.elevenLabs),
        formatSmallUsd(month.meetingCostUsd.deepgram),
        formatOptionalUsd(month.perMeeting?.total ?? null),
        formatOptionalUsd(month.perMeetingHour?.total ?? null),
        formatSmallUsd(month.accountLlmUsd),
      ]),
    ),
    false,
  );
  const rates: Product["economics"]["rates"] = economics.rates;
  element("product-costs-note", HTMLElement).textContent = fill(productText.notes.costs, {
    input: formatSmallUsd(rates.llmInputUsdPerMTok),
    output: formatSmallUsd(rates.llmOutputUsdPerMTok),
    elevenLabs: formatSmallUsd(rates.elevenLabsUsdPerHour),
    deepgram: formatSmallUsd(rates.deepgramUsdPerMinute),
  });
  fillProductTable(
    "product-payers",
    economics.months.map((month: EconomicsMonth): HTMLTableRowElement =>
      tableRow([
        monthLabel(month),
        formatCount(month.payers.users),
        formatOptionalUsd(month.payers.costPerUserUsd),
        formatSmallUsd(month.payers.listRevenueUsd),
        month.payers.grossMarginPercent === null ? adminText.none : `${formatCount(month.payers.grossMarginPercent)}%`,
      ]),
    ),
    false,
  );
  element("product-payers-note", HTMLElement).textContent = fill(productText.notes.payers, {
    monthly: formatSmallUsd(rates.priceUsdMonthly),
    yearly: formatSmallUsd(rates.priceUsdYearly),
  });
  renderChart(
    "product-spend",
    economics.dailySpend.map((day: DaySpendSplit): ChartDay => ({
      day: day.day,
      parts: [
        { value: day.usd - day.trialUsd, tone: "main" },
        { value: day.trialUsd, tone: "accent" },
      ],
      title: fill(productText.spendBarTitle, { day: formatDay(day.day), trial: formatSmallUsd(day.trialUsd), paid: formatSmallUsd(day.usd - day.trialUsd) }),
    })),
    formatSmallUsd,
  );
}

/** Sürüme göre çökmeleri çizer. */
function renderCrashes(crashes: Product["crashes"]): void {
  fillProductTable(
    "product-crashes",
    crashes.versions.map((version: VersionCrashes): HTMLTableRowElement =>
      tableRow([
        version.version === "" ? productText.unknownVersion : node("span", "mono", version.version),
        formatCount(version.total),
        formatCount(version.recent),
        formatTime(version.lastAt),
      ]),
    ),
    true,
  );
}

/** Ürün görünümünü çizer. */
function renderProduct(product: Product): void {
  renderEngagement(product);
  renderReliability(product.reliability);
  renderEconomics(product.economics);
  renderCrashes(product.crashes);
}

/** Ürün görünümünü bağlar. */
export function createProductView(): ProductView {
  const state: { loaded: boolean } = { loaded: false };
  const refresh = async (): Promise<void> => {
    renderProduct(await fetchProduct());
    state.loaded = true;
  };
  return {
    refresh,
    ensureLoaded: async (): Promise<void> => {
      if (!state.loaded) {
        await refresh();
      }
    },
  };
}
