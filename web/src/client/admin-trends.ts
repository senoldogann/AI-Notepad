// Yönetim panelinin "Trends" görünümü: `/v1/admin/trends` (son 90 günün günlük anlık görüntüleri, gerçek gelir, son 30
// günün token kovaları, konuşma tanıma dilleri, hesap silmeleri, yeniden denemeler ve indirme kampanyaları) ve
// `/v1/admin/site-analytics` (Cloudflare Web Analytics). Site istatistikleri ayrı yüklenir: sunucuda ayarlı değilse
// (`503 analytics_unavailable`) ya da Cloudflare'e ulaşılamazsa yalnızca o bölüm hatayı gösterir. Yanıtlar katı
// biçimde doğrulanır. Grafikler satır içi SVG çubuklardır (genel bakışınkiyle aynı sınıflar; her çubuğun başlığı
// değeridir, her grafiğin metin özeti var).
import {
  ApiRequestError,
  ApiResponseError,
  type JsonObject,
  type JsonValue,
  type RawResponse,
  numberField,
  objectArrayField,
  objectField,
  parseObject,
  stringField,
} from "./api";
import { fillTable, formatCompact, formatCount, formatDay, formatUsd, node, tableRow } from "./admin-format";
import { type AdminTrendsCopy, type TrendChartId, type TrendTokenBucket, adminTrendsCopy } from "./admin-trends-copy";
import { type ClientCopy, clientCopy, fill } from "./copy";
import { element, errorText, hideNotice, showNotice } from "./dom";
import { siteLocale } from "../config";
import { authorizedSend } from "./session";

const text: AdminTrendsCopy = adminTrendsCopy;
const siteText: ClientCopy = clientCopy;

const svgNamespace: string = "http://www.w3.org/2000/svg";
const chartWidth: number = 300;
const chartHeight: number = 60;
/** 90 çubukta okunur aralık (genel bakışın 30 günlük grafiğinden dar). */
const barGap: number = 1;

const tokenBuckets: readonly TrendTokenBucket[] = ["meeting_note", "meeting_live_structured", "meeting_live_text", "account_note", "account_quick"];

/** Para birimi başına faturalanan MRR (sent). */
interface CurrencyMrr {
  readonly currency: string;
  readonly mrrCents: number;
  readonly payingSubscriptions: number;
}

/** Günün anlık görüntüsünün panelde kullanılan alanları. */
interface TrendSnapshot {
  readonly subscriptionsMonthly: number;
  readonly subscriptionsYearly: number;
  readonly activeUsers7d: number;
  readonly mrrListUsd: number;
  readonly spendAnthropicUsd: number;
  readonly spendElevenLabsUsd: number;
  readonly spendDeepgramUsd: number;
  readonly invoicedMrr: readonly CurrencyMrr[];
}

interface TrendDay {
  readonly day: string;
  readonly snapshot: TrendSnapshot | null;
}

interface RevenueDay {
  readonly day: string;
  readonly paidCents: number;
  readonly refundedCents: number;
}

interface CurrencyRevenue {
  readonly currency: string;
  readonly mrrCents: number;
  readonly payingSubscriptions: number;
  readonly arpuCents: number | null;
  readonly paidLast30DaysCents: number;
  readonly refundedLast30DaysCents: number;
  readonly netLast30DaysCents: number;
  readonly ltvCents: number | null;
  readonly daily: readonly RevenueDay[];
}

interface CountItem {
  readonly detail: string;
  readonly count: number;
}

/** `GET /v1/admin/trends` yanıtı (panelin kullandığı alanlar). */
export interface AdminTrends {
  readonly windowDays: number;
  readonly daily: readonly TrendDay[];
  readonly revenue: { readonly currencies: readonly CurrencyRevenue[]; readonly firstPaymentsLast30Days: number; readonly medianDaysToFirstPayment: number | null };
  readonly tokenBuckets: readonly { readonly bucket: TrendTokenBucket; readonly calls: number; readonly inputTokens: number; readonly outputTokens: number }[];
  readonly languages: readonly { readonly requested: string; readonly detected: string; readonly requests: number; readonly audioHours: number }[];
  readonly accountDeletions: readonly CountItem[];
  readonly retries: readonly CountItem[];
  readonly campaigns: readonly { readonly source: string; readonly campaign: string; readonly count: number }[];
}

interface SiteEntry {
  readonly key: string;
  readonly pageViews: number;
  readonly visits: number;
}

/** `GET /v1/admin/site-analytics` yanıtı. */
export interface SiteAnalytics {
  readonly days: number;
  readonly pageViews: number;
  readonly visits: number;
  readonly daily: readonly { readonly day: string; readonly pageViews: number; readonly visits: number }[];
  readonly topPaths: readonly SiteEntry[];
  readonly topReferrers: readonly SiteEntry[];
}

/** Sayı ya da null alan. */
function nullableNumberField(object: JsonObject, key: string, response: RawResponse, path: string): number | null {
  return object[key] === null ? null : numberField(object, key, response, path);
}

/** Token kovası alanı. */
function bucketField(object: JsonObject, response: RawResponse, path: string): TrendTokenBucket {
  const value: string = stringField(object, "bucket", response, path);
  const bucket: TrendTokenBucket | undefined = tokenBuckets.find((candidate: TrendTokenBucket): boolean => candidate === value);
  if (bucket === undefined) {
    throw new ApiResponseError(path, response.status, `bilinmeyen token kovası "${value}"`, response.text);
  }
  return bucket;
}

/** Ayrıntı sayıları dizisi. */
function countItems(owner: JsonObject, key: string, response: RawResponse, path: string): CountItem[] {
  return objectArrayField(owner, key, response, path).map((item: JsonObject): CountItem => ({ detail: stringField(item, "detail", response, path), count: numberField(item, "count", response, path) }));
}

/** Para birimi başına MRR dizisi. */
function currencyMrrs(owner: JsonObject, response: RawResponse, path: string): CurrencyMrr[] {
  return objectArrayField(owner, "invoicedMrr", response, path).map(
    (item: JsonObject): CurrencyMrr => ({
      currency: stringField(item, "currency", response, path),
      mrrCents: numberField(item, "mrrCents", response, path),
      payingSubscriptions: numberField(item, "payingSubscriptions", response, path),
    }),
  );
}

/** Günün anlık görüntüsü ya da null. */
function snapshotField(item: JsonObject, response: RawResponse, path: string): TrendSnapshot | null {
  const value: JsonValue | undefined = item["snapshot"];
  if (value === null) {
    return null;
  }
  const snapshot: JsonObject = objectField(item, "snapshot", response, path);
  return {
    subscriptionsMonthly: numberField(snapshot, "subscriptionsMonthly", response, path),
    subscriptionsYearly: numberField(snapshot, "subscriptionsYearly", response, path),
    activeUsers7d: numberField(snapshot, "activeUsers7d", response, path),
    mrrListUsd: numberField(snapshot, "mrrListUsd", response, path),
    spendAnthropicUsd: numberField(snapshot, "spendAnthropicUsd", response, path),
    spendElevenLabsUsd: numberField(snapshot, "spendElevenLabsUsd", response, path),
    spendDeepgramUsd: numberField(snapshot, "spendDeepgramUsd", response, path),
    invoicedMrr: currencyMrrs(snapshot, response, path),
  };
}

/** `GET /v1/admin/trends` yanıtını okur. */
export function parseTrends(response: RawResponse, path: string): AdminTrends {
  const body: JsonObject = parseObject(response, path);
  const revenue: JsonObject = objectField(body, "revenue", response, path);
  return {
    windowDays: numberField(body, "windowDays", response, path),
    daily: objectArrayField(body, "daily", response, path).map((item: JsonObject): TrendDay => ({ day: stringField(item, "day", response, path), snapshot: snapshotField(item, response, path) })),
    revenue: {
      currencies: objectArrayField(revenue, "currencies", response, path).map(
        (item: JsonObject): CurrencyRevenue => ({
          currency: stringField(item, "currency", response, path),
          mrrCents: numberField(item, "mrrCents", response, path),
          payingSubscriptions: numberField(item, "payingSubscriptions", response, path),
          arpuCents: nullableNumberField(item, "arpuCents", response, path),
          paidLast30DaysCents: numberField(item, "paidLast30DaysCents", response, path),
          refundedLast30DaysCents: numberField(item, "refundedLast30DaysCents", response, path),
          netLast30DaysCents: numberField(item, "netLast30DaysCents", response, path),
          ltvCents: nullableNumberField(item, "ltvCents", response, path),
          daily: objectArrayField(item, "daily", response, path).map(
            (day: JsonObject): RevenueDay => ({
              day: stringField(day, "day", response, path),
              paidCents: numberField(day, "paidCents", response, path),
              refundedCents: numberField(day, "refundedCents", response, path),
            }),
          ),
        }),
      ),
      firstPaymentsLast30Days: numberField(revenue, "firstPaymentsLast30Days", response, path),
      medianDaysToFirstPayment: nullableNumberField(revenue, "medianDaysToFirstPayment", response, path),
    },
    tokenBuckets: objectArrayField(body, "tokenBuckets", response, path).map((item: JsonObject) => ({
      bucket: bucketField(item, response, path),
      calls: numberField(item, "calls", response, path),
      inputTokens: numberField(item, "inputTokens", response, path),
      outputTokens: numberField(item, "outputTokens", response, path),
    })),
    languages: objectArrayField(body, "languages", response, path).map((item: JsonObject) => ({
      requested: stringField(item, "requested", response, path),
      detected: stringField(item, "detected", response, path),
      requests: numberField(item, "requests", response, path),
      audioHours: numberField(item, "audioHours", response, path),
    })),
    accountDeletions: countItems(body, "accountDeletions", response, path),
    retries: countItems(body, "retries", response, path),
    campaigns: objectArrayField(body, "campaigns", response, path).map((item: JsonObject) => ({
      source: stringField(item, "source", response, path),
      campaign: stringField(item, "campaign", response, path),
      count: numberField(item, "count", response, path),
    })),
  };
}

/** Site sayfası ya da yönlendiren satırları. */
function siteEntries(owner: JsonObject, key: string, response: RawResponse, path: string): SiteEntry[] {
  return objectArrayField(owner, key, response, path).map(
    (item: JsonObject): SiteEntry => ({
      key: stringField(item, "key", response, path),
      pageViews: numberField(item, "pageViews", response, path),
      visits: numberField(item, "visits", response, path),
    }),
  );
}

/** `GET /v1/admin/site-analytics` yanıtını okur. */
export function parseSiteAnalytics(response: RawResponse, path: string): SiteAnalytics {
  const body: JsonObject = parseObject(response, path);
  return {
    days: numberField(body, "days", response, path),
    pageViews: numberField(body, "pageViews", response, path),
    visits: numberField(body, "visits", response, path),
    daily: objectArrayField(body, "daily", response, path).map((item: JsonObject) => ({
      day: stringField(item, "day", response, path),
      pageViews: numberField(item, "pageViews", response, path),
      visits: numberField(item, "visits", response, path),
    })),
    topPaths: siteEntries(body, "topPaths", response, path),
    topReferrers: siteEntries(body, "topReferrers", response, path),
  };
}

/** Eğilim verisi. */
async function fetchTrends(): Promise<AdminTrends> {
  const path: string = "/v1/admin/trends";
  return parseTrends(await authorizedSend({ method: "GET", path, body: null, attempts: 3 }), path);
}

/** Site istatistikleri. */
async function fetchSiteAnalytics(): Promise<SiteAnalytics> {
  const path: string = "/v1/admin/site-analytics";
  return parseSiteAnalytics(await authorizedSend({ method: "GET", path, body: null, attempts: 2 }), path);
}

/** Para birimi tutarı (sent → birim). Saf fonksiyondur. */
export function formatCents(cents: number, currency: string): string {
  return new Intl.NumberFormat(siteLocale, { style: "currency", currency: currency.toUpperCase(), currencyDisplay: "narrowSymbol", maximumFractionDigits: 2 }).format(cents / 100);
}

/** Grafikteki gün: yığılmış parçalar (alttan üste) ya da anlık görüntü yoksa null. */
interface TrendBar {
  readonly day: string;
  readonly parts: readonly { readonly value: number; readonly tone: "main" | "accent" }[] | null;
  readonly title: string;
}

function svgElement(name: string, attributes: Readonly<Record<string, string>>): SVGElement {
  const created: SVGElement = document.createElementNS(svgNamespace, name) as SVGElement;
  for (const [key, value] of Object.entries(attributes)) {
    created.setAttribute(key, value);
  }
  return created;
}

/** Çubuk grafiği çizer (verisiz gün yalnızca taban çizgisi) ve özeti yazar. */
function renderBars(id: TrendChartId, bars: readonly TrendBar[], summary: string): void {
  const totals: number[] = bars.map((bar: TrendBar): number => (bar.parts ?? []).reduce((sum: number, part): number => sum + part.value, 0));
  const max: number = Math.max(0, ...totals);
  const barWidth: number = bars.length === 0 ? 0 : (chartWidth - barGap * (bars.length - 1)) / bars.length;
  const svg: SVGElement = svgElement("svg", { viewBox: `0 0 ${chartWidth} ${chartHeight}`, class: "chart__svg", role: "img", "aria-labelledby": `chart-trend-${id}-summary` });
  bars.forEach((bar: TrendBar, index: number): void => {
    const x: number = index * (barWidth + barGap);
    const group: SVGElement = svgElement("g", {});
    const title: SVGElement = svgElement("title", {});
    title.textContent = bar.title;
    group.append(title, svgElement("rect", { x: x.toFixed(2), y: String(chartHeight - 1.5), width: barWidth.toFixed(2), height: "1.5", class: "chart__base" }));
    let top: number = chartHeight;
    for (const part of bar.parts ?? []) {
      if (part.value <= 0 || max === 0) {
        continue;
      }
      const height: number = Math.max(2, (part.value / max) * (chartHeight - 4));
      top -= height;
      group.append(svgElement("rect", { x: x.toFixed(2), y: top.toFixed(2), width: barWidth.toFixed(2), height: height.toFixed(2), rx: "0.5", class: `chart__bar chart__bar--${part.tone}` }));
    }
    svg.append(group);
  });
  const axis: HTMLElement = node("div", "chart__axis", "");
  axis.setAttribute("aria-hidden", "true");
  axis.append(node("span", "", bars[0] === undefined ? "" : formatDay(bars[0].day)), node("span", "", bars.at(-1) === undefined ? "" : formatDay(bars.at(-1)?.day ?? "")));
  element(`chart-trend-${id}`, HTMLElement).replaceChildren(svg, axis);
  element(`chart-trend-${id}-summary`, HTMLElement).textContent = summary;
}

/** Anlık görüntü serisinden grafik günleri. Saf fonksiyondur. */
function snapshotBars(daily: readonly TrendDay[], parts: (snapshot: TrendSnapshot) => readonly { readonly value: number; readonly tone: "main" | "accent" }[], format: (value: number) => string): TrendBar[] {
  return daily.map((item: TrendDay): TrendBar => {
    if (item.snapshot === null) {
      return { day: item.day, parts: null, title: fill(text.noSnapshot, { day: formatDay(item.day) }) };
    }
    const values = parts(item.snapshot);
    const total: number = values.reduce((sum: number, part): number => sum + part.value, 0);
    return { day: item.day, parts: values, title: fill(text.barTitle, { day: formatDay(item.day), value: format(total) }) };
  });
}

/** Grafiklerin özeti: anlık görüntü sayısı ve son değer. Saf fonksiyondur. */
function snapshotSummary(daily: readonly TrendDay[], latest: (snapshot: TrendSnapshot) => string): string {
  const present: TrendDay[] = daily.filter((item: TrendDay): boolean => item.snapshot !== null);
  const last: TrendDay | undefined = present.at(-1);
  if (last === undefined || last.snapshot === null) {
    return text.noSnapshots;
  }
  return fill(text.snapshotSummary, { days: formatCount(present.length), latest: `${latest(last.snapshot)} (${formatDay(last.day)})` });
}

/** Görünümün grafikleri. */
function renderCharts(trends: AdminTrends): void {
  const daily: readonly TrendDay[] = trends.daily;
  renderBars("mrr", snapshotBars(daily, (s) => [{ value: s.mrrListUsd, tone: "main" }], formatUsd), snapshotSummary(daily, (s) => formatUsd(s.mrrListUsd)));
  renderBars(
    "subscribers",
    snapshotBars(daily, (s) => [{ value: s.subscriptionsMonthly, tone: "main" }, { value: s.subscriptionsYearly, tone: "accent" }], formatCount),
    snapshotSummary(daily, (s) => formatCount(s.subscriptionsMonthly + s.subscriptionsYearly)),
  );
  renderBars("active", snapshotBars(daily, (s) => [{ value: s.activeUsers7d, tone: "main" }], formatCount), snapshotSummary(daily, (s) => formatCount(s.activeUsers7d)));
  renderBars(
    "spend",
    snapshotBars(daily, (s) => [{ value: s.spendAnthropicUsd, tone: "main" }, { value: s.spendElevenLabsUsd + s.spendDeepgramUsd, tone: "accent" }], formatUsd),
    snapshotSummary(daily, (s) => formatUsd(s.spendAnthropicUsd + s.spendElevenLabsUsd + s.spendDeepgramUsd)),
  );
  // Gelir grafiği tüm zamanların en çok tahsilat yapılan para birimidir; diğerleri tabloda.
  const top: CurrencyRevenue | undefined = trends.revenue.currencies[0];
  if (top === undefined) {
    renderBars("revenue", [], text.noRevenue);
    return;
  }
  const format = (cents: number): string => formatCents(cents, top.currency);
  const bars: TrendBar[] = top.daily.map((day: RevenueDay): TrendBar => ({
    day: day.day,
    parts: [{ value: day.paidCents, tone: "main" }, { value: day.refundedCents, tone: "accent" }],
    title: fill(text.barTitle, { day: formatDay(day.day), value: `${format(day.paidCents)} / −${format(day.refundedCents)}` }),
  }));
  const paid: number = top.daily.reduce((sum: number, day: RevenueDay): number => sum + day.paidCents, 0);
  const refunded: number = top.daily.reduce((sum: number, day: RevenueDay): number => sum + day.refundedCents, 0);
  renderBars("revenue", bars, fill(text.revenueSummary, { currency: top.currency.toUpperCase(), paid: format(paid), refunded: format(refunded) }));
}

/** Tabloyu doldurur ve boş bildirimini açar ya da kapatır. */
function fillTrendTable(id: string, rows: readonly HTMLTableRowElement[]): void {
  fillTable(element(`trend-${id}-rows`, HTMLTableSectionElement), rows);
  element(`trend-${id}-empty`, HTMLElement).classList.toggle("hidden", rows.length > 0);
}

/** Tutar ya da yoksa "—". Saf fonksiyondur. */
function optionalCents(cents: number | null, currency: string): string {
  return cents === null ? text.none : formatCents(cents, currency);
}

/** Görünümün tabloları. */
function renderTables(trends: AdminTrends): void {
  fillTrendTable(
    "revenue",
    trends.revenue.currencies.map((item: CurrencyRevenue): HTMLTableRowElement =>
      tableRow([
        item.currency.toUpperCase(),
        formatCents(item.mrrCents, item.currency),
        formatCount(item.payingSubscriptions),
        optionalCents(item.arpuCents, item.currency),
        formatCents(item.paidLast30DaysCents, item.currency),
        formatCents(item.refundedLast30DaysCents, item.currency),
        formatCents(item.netLast30DaysCents, item.currency),
        optionalCents(item.ltvCents, item.currency),
      ]),
    ),
  );
  const median: number | null = trends.revenue.medianDaysToFirstPayment;
  element("trend-revenue-paid", HTMLElement).textContent = [
    fill(text.firstPayments, { days: formatCount(trends.windowDays), count: formatCount(trends.revenue.firstPaymentsLast30Days) }),
    median === null ? text.noMedian : fill(text.medianToPaid, { days: formatCount(median) }),
  ].join(" · ");
  fillTrendTable(
    "tokens",
    trends.tokenBuckets
      .filter((bucket): boolean => bucket.calls > 0)
      .map((bucket): HTMLTableRowElement => tableRow([text.buckets[bucket.bucket], formatCount(bucket.calls), formatCompact(bucket.inputTokens), formatCompact(bucket.outputTokens)])),
  );
  fillTrendTable(
    "languages",
    trends.languages.map((item): HTMLTableRowElement =>
      tableRow([node("span", "mono", item.requested === "auto" ? text.autoLanguage : item.requested), node("span", "mono", item.detected), formatCount(item.requests), formatCount(item.audioHours)]),
    ),
  );
  fillTrendTable("events", [
    ...trends.accountDeletions.map((item: CountItem): HTMLTableRowElement => tableRow([text.eventKinds.deletion, node("span", "mono", item.detail), formatCount(item.count)])),
    ...trends.retries.map((item: CountItem): HTMLTableRowElement => tableRow([text.eventKinds.retry, node("span", "mono", item.detail), formatCount(item.count)])),
  ]);
  fillTrendTable(
    "campaigns",
    trends.campaigns.map((item): HTMLTableRowElement =>
      tableRow([node("span", "mono", item.source), node("span", "mono", item.campaign === "" ? text.noCampaign : item.campaign), formatCount(item.count)]),
    ),
  );
}

/** Site istatistikleri bölümü. */
function renderSite(site: SiteAnalytics): void {
  hideNotice(element("trend-site-error", HTMLElement));
  element("trend-site-summary", HTMLElement).textContent = fill(text.siteSummary, {
    days: formatCount(site.days),
    views: formatCount(site.pageViews),
    visits: formatCount(site.visits),
  });
  const entryRow = (entry: SiteEntry, label: string): HTMLTableRowElement => tableRow([node("span", "mono", label), formatCount(entry.pageViews), formatCount(entry.visits)]);
  fillTrendTable("paths", site.topPaths.map((entry: SiteEntry): HTMLTableRowElement => entryRow(entry, entry.key)));
  fillTrendTable("referrers", site.topReferrers.map((entry: SiteEntry): HTMLTableRowElement => entryRow(entry, entry.key === "" ? text.direct : entry.key)));
}

/** Site istatistikleri alınamadı: ayarlı değilse açıklama, başka hatada hata metni; tablolar boşalır. */
function renderSiteFailure(error: unknown): void {
  const message: string = error instanceof ApiRequestError && error.code === "analytics_unavailable" ? text.siteUnavailable : errorText(error, siteText);
  showNotice(element("trend-site-error", HTMLElement), message);
  element("trend-site-summary", HTMLElement).textContent = "";
  fillTrendTable("paths", []);
  fillTrendTable("referrers", []);
}

/** Görünümün dışarıya açtığı işlemler. */
export interface TrendsView {
  readonly refresh: () => Promise<void>;
  readonly ensureLoaded: () => Promise<void>;
}

/** Eğilimler görünümünü bağlar. Site istatistiklerinin hatası görünümü düşürmez, yalnızca kendi bölümünde görünür. */
export function createTrendsView(): TrendsView {
  const state: { loaded: boolean } = { loaded: false };
  const refresh = async (): Promise<void> => {
    const [trends] = await Promise.all([
      fetchTrends(),
      fetchSiteAnalytics().then(renderSite, renderSiteFailure),
    ]);
    renderCharts(trends);
    renderTables(trends);
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
