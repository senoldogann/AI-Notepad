// Yönetim paneli: beş görünüm — genel bakış (özet kutuları ve son 30 günün çubuk grafikleri; satır içi SVG,
// kütüphanesiz, her grafiğin metin özeti var), içgörüler (admin-insights.ts: sorunlar, huni, indirme kaynakları, iptal
// nedenleri), kullanıcılar (admin-users.ts), işletim (admin-ops.ts) ve bildirim kutusu
// (geri bildirim, çökme, iletişim; açık/bitti süzgeci, ayrıntı, "bitti" işaretleme). Panel yalnızca `/v1/admin/stats`
// başarılı olunca şablondan eklenir; oturum yoksa ya da sunucu 403 (veya yenilemesi başarısız 401) dönerse standart
// "sayfa bulunamadı" görünümü gösterilir, girişe yönlendirilmez (panelin varlığı belli olmaz). Kullanıcılar ve işletim
// görünümleri (ve içgörüler) ilk açılışlarında yüklenir; "Yenile" açık görünümü ve özet istatistikleri yeniler.
import { ApiRequestError } from "./api";
import {
  type AdminStats,
  type DayCount,
  type DayMeetings,
  type ReportDetail,
  type ReportKind,
  type ReportPage,
  type ReportStatus,
  type ReportSummary,
  fetchReport,
  fetchReports,
  fetchStats,
  setReportStatus,
} from "./admin-api";
import { fillCounts, formatCount, formatCompact, formatDay, formatRate, formatTime, formatUsd } from "./admin-format";
import { type InsightsView, createInsightsView } from "./admin-insights";
import { type OperationsView, createOperationsView } from "./admin-ops";
import { type UsersView, createUsersView } from "./admin-users";
import { type AdminClientCopy, type ClientCopy, clientCopy, fill } from "./copy";
import { MissingElementError, dataValue, element, errorText, hideNotice, showNotice } from "./dom";
import { SignedOutError, claimTabSession, hasSession } from "./session";

const svgNamespace: string = "http://www.w3.org/2000/svg";

/** Grafik çizim alanı (SVG birimi). */
const chartWidth: number = 300;
const chartHeight: number = 60;
const barGap: number = 3;

/** Panelin görünümleri. */
type AdminView = "overview" | "insights" | "users" | "operations" | "inbox";
const adminViews: readonly AdminView[] = ["overview", "insights", "users", "operations", "inbox"];

/** Grafikteki bir günün çubuk parçaları (yığılmış: alttan üste). */
interface ChartDay {
  readonly day: string;
  readonly parts: readonly { readonly value: number; readonly tone: "main" | "accent" }[];
  readonly title: string;
}

/** Bildirim kutusunun durumu. */
interface InboxState {
  kind: ReportKind;
  status: ReportStatus;
  items: ReportSummary[];
  nextBefore: number | null;
  selectedId: string | null;
}

const text: ClientCopy = clientCopy;
const adminText: AdminClientCopy = clientCopy.admin;

/** Grafiğin metin özeti: toplam ve en yüksek gün. Saf fonksiyondur. */
export function chartSummary(days: readonly ChartDay[], format: (value: number) => string): string {
  const totals: number[] = days.map((day: ChartDay): number => day.parts.reduce((sum: number, part): number => sum + part.value, 0));
  const total: number = totals.reduce((sum: number, value: number): number => sum + value, 0);
  if (total === 0) {
    return adminText.chartEmpty;
  }
  const peak: number = Math.max(...totals);
  const peakDay: ChartDay | undefined = days[totals.indexOf(peak)];
  return fill(adminText.chartSummary, { total: format(total), peak: format(peak), day: peakDay === undefined ? "" : formatDay(peakDay.day) });
}

/** SVG öğesi oluşturur. */
function svgElement(name: string, attributes: Readonly<Record<string, string>>): SVGElement {
  const node: SVGElement = document.createElementNS(svgNamespace, name) as SVGElement;
  for (const [key, value] of Object.entries(attributes)) {
    node.setAttribute(key, value);
  }
  return node;
}

/** Çubuk grafiği çizer; özeti `figcaption`'a yazar. */
function renderChart(id: string, days: readonly ChartDay[], format: (value: number) => string): void {
  const plot: HTMLElement = element(`chart-${id}`, HTMLElement);
  const summary: HTMLElement = element(`chart-${id}-summary`, HTMLElement);
  const totals: number[] = days.map((day: ChartDay): number => day.parts.reduce((sum: number, part): number => sum + part.value, 0));
  const max: number = Math.max(0, ...totals);
  const barWidth: number = days.length === 0 ? 0 : (chartWidth - barGap * (days.length - 1)) / days.length;
  const svg: SVGElement = svgElement("svg", {
    viewBox: `0 0 ${chartWidth} ${chartHeight}`,
    class: "chart__svg",
    role: "img",
    "aria-labelledby": `chart-${id}-summary`,
  });
  days.forEach((day: ChartDay, index: number): void => {
    const x: number = index * (barWidth + barGap);
    const group: SVGElement = svgElement("g", {});
    const title: SVGElement = svgElement("title", {});
    title.textContent = day.title;
    group.append(title);
    // Değersiz gün ince bir taban çizgisi olarak görünür (sıfır ile eksik veri ayırt edilsin).
    group.append(svgElement("rect", { x: x.toFixed(2), y: String(chartHeight - 1.5), width: barWidth.toFixed(2), height: "1.5", rx: "0.75", class: "chart__base" }));
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
  const first: ChartDay | undefined = days[0];
  const last: ChartDay | undefined = days.at(-1);
  const axis: HTMLElement = document.createElement("div");
  axis.className = "chart__axis";
  axis.setAttribute("aria-hidden", "true");
  const start: HTMLSpanElement = document.createElement("span");
  start.textContent = first === undefined ? "" : formatDay(first.day);
  const end: HTMLSpanElement = document.createElement("span");
  end.textContent = last === undefined ? "" : formatDay(last.day);
  axis.append(start, end);
  plot.replaceChildren(svg, axis);
  summary.textContent = chartSummary(days, format);
}

/** Tek değerli günleri grafiğe çevirir. Saf fonksiyondur. */
function countDays(days: readonly DayCount[], format: (value: number) => string): ChartDay[] {
  return days.map((day: DayCount): ChartDay => ({ day: day.day, parts: [{ value: day.count, tone: "main" }], title: fill(adminText.barTitle, { day: formatDay(day.day), value: format(day.count) }) }));
}

/** Son `count` günün toplamı (seri eskiden yeniye). Saf fonksiyondur. */
function lastDaysTotal(days: readonly DayCount[], count: number): number {
  return days.slice(-count).reduce((total: number, day: DayCount): number => total + day.count, 0);
}

/** Kutunun değerini ve alt satırını yazar. */
function setKpi(id: string, value: string, sub: string): void {
  element(`kpi-${id}`, HTMLElement).textContent = value;
  element(`kpi-${id}-sub`, HTMLElement).textContent = sub;
}

/** Ölçerli kutunun uyarı görünümünü (ölçer rengi, kenar, alt satır) açar ya da kapatır. */
function setKpiWarning(id: string, meter: HTMLProgressElement, warn: boolean): void {
  meter.classList.toggle("meter--warn", warn);
  element(`kpi-${id}-card`, HTMLElement).classList.toggle("kpi--warn", warn);
}

/** Kutunun ölçerini doldurur (`max` en az 0,01: boş ölçer). */
function setMeter(id: string, value: number, max: number): HTMLProgressElement {
  const meter: HTMLProgressElement = element(`kpi-${id}-meter`, HTMLProgressElement);
  meter.max = Math.max(max, 0.01);
  meter.value = Math.min(value, meter.max);
  return meter;
}

/** Büyüme ve gelir kutuları. */
function renderGrowthAndRevenue(stats: AdminStats): void {
  const sum = (days: readonly DayCount[]): number => lastDaysTotal(days, days.length);
  setKpi("downloads", formatCount(stats.downloads.total), fill(adminText.downloadsSub, { count: formatCount(sum(stats.downloads.last30Days)) }));
  setKpi(
    "users",
    formatCount(stats.users.total),
    `${fill(adminText.usersSub, { count: formatCount(sum(stats.users.newLast30Days)), apple: formatCount(stats.users.byProvider.apple), google: formatCount(stats.users.byProvider.google) })} · ${fillCounts(adminText.usersRecent, { today: lastDaysTotal(stats.users.newLast30Days, 1), week: lastDaysTotal(stats.users.newLast30Days, 7) })}`,
  );
  setKpi("trials", formatCount(stats.trials.activeTrialUsers), fill(adminText.trialsSub, { count: formatCount(stats.trials.exhaustedTrialUsers) }));
  setKpi(
    "subscribers",
    formatCount(stats.subscriptions.active),
    `${fill(adminText.subscribersSub, {
      monthly: formatCount(stats.subscriptions.monthly),
      yearly: formatCount(stats.subscriptions.yearly),
      grace: formatCount(stats.subscriptions.grace),
      ending: formatCount(stats.subscriptions.ending),
      canceled: formatCount(stats.subscriptions.canceledTotal),
      free: formatCount(stats.subscriptions.complimentary),
    })}. ${fillCounts(adminText.referralsSub, {
      joined: stats.referrals.joined,
      pending: stats.referrals.pending,
      granted: stats.referrals.granted,
      voided: stats.referrals.voided,
    })}`,
  );
  setKpi("mrr", formatUsd(stats.subscriptions.mrrUsd), `${adminText.mrrSub} · ${stats.stripe.mode === "live" ? adminText.stripeLive : adminText.stripeTest}`);

  const conversion: AdminStats["conversion"] = stats.conversion;
  setKpi(
    "conversion",
    formatRate(conversion.converted, conversion.trialStarted),
    fill(adminText.conversionSub, {
      converted: formatCount(conversion.converted),
      started: formatCount(conversion.trialStarted),
      recentRate: formatRate(conversion.convertedLast30Days, conversion.startedLast30Days),
      direct: formatCount(conversion.subscribedWithoutTrial),
    }),
  );
  setMeter("conversion", conversion.converted, conversion.trialStarted);
  setKpi("churn", formatCount(stats.churn.canceledLast30Days), fillCounts(adminText.churnSub, { ending: stats.subscriptions.ending, pastDue: stats.churn.pastDue, unpaid: stats.churn.unpaid }));
  const billing: AdminStats["billing"] = stats.billing;
  const paymentIssues: number = billing.refundsLast30Days + billing.disputesLast30Days + billing.paymentFailuresLast30Days;
  setKpi(
    "payments",
    formatCount(paymentIssues),
    fillCounts(adminText.paymentsSub, {
      refunds: billing.refundsLast30Days,
      disputes: billing.disputesLast30Days,
      failed: billing.paymentFailuresLast30Days,
      duplicates: stats.churn.duplicateSubscriptions,
    }),
  );
  // İtiraz her zaman uyarıdır (Stripe ücreti ve hesap riski); iade ve başarısız ödeme yalnızca bilgi.
  element("kpi-payments-card", HTMLElement).classList.toggle("kpi--warn", billing.disputesLast30Days > 0);
}

/** Kullanım, maliyet ve kapasite kutuları. */
function renderUsageAndCosts(stats: AdminStats): void {
  const usage: AdminStats["usage"] = stats.usage;
  setKpi("meetings", formatCount(usage.meetingsThisMonth), fillCounts(adminText.meetingsSub, { open: usage.openMeetings, deferred: usage.deferredThisMonth, reprocessed: usage.reprocessedThisMonth }));
  setKpi("hours", formatCount(stats.meetings.hoursThisMonth), adminText.hoursSub);
  setKpi("audio", fill(adminText.hours, { hours: formatCount(usage.audioHoursThisMonth) }), fillCounts(adminText.audioSub, { minutes: stats.deepgram.streamMinutes }));
  setKpi(
    "tokens",
    formatCompact(stats.tokens.thisMonth),
    fill(adminText.tokensUsageSub, { account: formatCompact(usage.accountTokensThisMonth), near: formatCount(usage.usersNearTokenCap), cap: formatCompact(usage.monthlyTokenCapPerUser) }),
  );
  element("kpi-tokens-card", HTMLElement).classList.toggle("kpi--warn", usage.usersNearTokenCap > 0);

  setKpi("spend", formatUsd(stats.spend.todayUsd), fill(adminText.spendSub, { ceiling: formatUsd(stats.spend.ceilingUsd) }));
  setKpiWarning("spend", setMeter("spend", stats.spend.todayUsd, stats.spend.ceilingUsd), stats.spend.todayUsd >= stats.spend.ceilingUsd * 0.8);
  setKpi(
    "elevenlabs",
    `${Math.round(stats.elevenLabs.percent)}%`,
    fill(adminText.elevenLabsSub, { used: formatCount(stats.elevenLabs.usedHours), cap: formatCount(stats.elevenLabs.capHours) }),
  );
  setKpiWarning("elevenlabs", setMeter("elevenlabs", stats.elevenLabs.usedHours, stats.elevenLabs.capHours), stats.elevenLabs.percent >= 80);
  setKpi("deepgram", `${Math.round(stats.deepgram.percent)}%`, fill(adminText.deepgramSub, { used: formatUsd(stats.deepgram.estimatedUsd), budget: formatUsd(stats.deepgram.budgetUsd) }));
  setKpiWarning("deepgram", setMeter("deepgram", stats.deepgram.estimatedUsd, stats.deepgram.budgetUsd), stats.deepgram.percent >= 80);
  const refusals: AdminStats["trialRefusals"] = stats.trialRefusals;
  const refusalTotal = (counts: AdminStats["trialRefusals"]["today"]): number => counts.deviceUsed + counts.exhausted + counts.expired + counts.ipDailyLimit;
  setKpi(
    "refusals",
    formatCount(refusalTotal(refusals.last30Days)),
    fillCounts(adminText.refusalsSub, {
      device: refusals.last30Days.deviceUsed,
      ip: refusals.last30Days.ipDailyLimit,
      exhausted: refusals.last30Days.exhausted,
      expired: refusals.last30Days.expired,
      today: refusalTotal(refusals.today),
    }),
  );
}

/** Özet kutularını, grafikleri ve bildirim sayaçlarını çizer. */
function renderStats(stats: AdminStats): void {
  element("admin-updated", HTMLElement).textContent = fill(adminText.updated, { time: formatTime(stats.generatedAt) });
  renderGrowthAndRevenue(stats);
  renderUsageAndCosts(stats);

  renderChart("downloads", countDays(stats.downloads.last30Days, formatCount), formatCount);
  renderChart("users", countDays(stats.users.newLast30Days, formatCount), formatCount);
  renderChart(
    "meetings",
    stats.meetings.last30Days.map(
      (day: DayMeetings): ChartDay => ({
        day: day.day,
        parts: [
          { value: day.subscription, tone: "main" },
          { value: day.trial, tone: "accent" },
        ],
        title: fill(adminText.meetingBarTitle, { day: formatDay(day.day), trial: formatCount(day.trial), subscription: formatCount(day.subscription) }),
      }),
    ),
    formatCount,
  );
  renderChart(
    "spend",
    stats.spend.last30Days.map((day): ChartDay => ({ day: day.day, parts: [{ value: day.usd, tone: "main" }], title: fill(adminText.barTitle, { day: formatDay(day.day), value: formatUsd(day.usd) }) })),
    formatUsd,
  );

  element("count-feedback", HTMLElement).textContent = formatCount(stats.reports.openFeedback);
  element("count-crash", HTMLElement).textContent = formatCount(stats.reports.openCrash);
  element("count-contact", HTMLElement).textContent = formatCount(stats.reports.openContact);
  const openReports: number = stats.reports.openFeedback + stats.reports.openCrash + stats.reports.openContact;
  element("count-inbox", HTMLElement).textContent = openReports === 0 ? "" : formatCount(openReports);
}

/** Bildirimin kim/ne zaman satırı. Saf fonksiyondur. */
function reportMeta(report: ReportSummary): string {
  const who: string = report.email ?? report.userId ?? adminText.anonymous;
  return [who, report.appVersion, report.os, formatTime(report.createdAt)].filter((part: string | null): part is string => part !== null && part !== "").join(" · ");
}

/** Bildirim listesini çizer. */
function renderList(state: InboxState, onSelect: (id: string) => void): void {
  const list: HTMLElement = element("inbox-list", HTMLElement);
  const nodes: HTMLLIElement[] = state.items.map((report: ReportSummary): HTMLLIElement => {
    const item: HTMLLIElement = document.createElement("li");
    const button: HTMLButtonElement = document.createElement("button");
    button.type = "button";
    button.className = "inbox__item";
    if (report.id === state.selectedId) {
      button.setAttribute("aria-current", "true");
    }
    const summary: HTMLSpanElement = document.createElement("span");
    summary.className = "inbox__summary";
    summary.textContent = report.summary ?? adminText.noSummary;
    const meta: HTMLSpanElement = document.createElement("span");
    meta.className = "inbox__meta";
    meta.textContent = reportMeta(report);
    button.append(summary, meta);
    button.addEventListener("click", (): void => onSelect(report.id));
    item.append(button);
    return item;
  });
  list.replaceChildren(...nodes);
  element("inbox-empty", HTMLElement).classList.toggle("hidden", state.items.length > 0);
  element("inbox-more", HTMLButtonElement).classList.toggle("hidden", state.nextBefore === null);
}

/** Çökme raporu JSON'unu okunur biçimde yazar; JSON değilse olduğu gibi (uyarıyla). */
function prettyPayload(payload: string): string {
  try {
    return JSON.stringify(JSON.parse(payload) as unknown, null, 2);
  } catch (error: unknown) {
    console.warn("crash_payload_not_json", { error: error instanceof Error ? error.message : String(error) });
    return payload;
  }
}

/** Ayrıntı panelini çizer. */
function renderDetail(report: ReportDetail): void {
  element("detail-empty", HTMLElement).classList.add("hidden");
  const body: HTMLElement = element("detail-body", HTMLElement);
  body.classList.remove("hidden");
  element("detail-received", HTMLElement).textContent = formatTime(report.createdAt);
  element("detail-email", HTMLElement).textContent = report.email ?? "—";
  element("detail-user", HTMLElement).textContent = report.userId ?? adminText.anonymous;
  element("detail-app", HTMLElement).textContent = report.appVersion ?? "—";
  element("detail-os", HTMLElement).textContent = report.os ?? "—";
  element("detail-message", HTMLElement).textContent = report.message ?? adminText.noMessage;
  element("detail-payload-block", HTMLElement).classList.toggle("hidden", report.payload === null);
  element("detail-payload", HTMLElement).textContent = report.payload === null ? "" : prettyPayload(report.payload);
  const toggle: HTMLButtonElement = element("detail-toggle", HTMLButtonElement);
  toggle.dataset["next"] = report.status === "open" ? "done" : "open";
  toggle.textContent = report.status === "open" ? toggle.dataset["labelDone"] ?? "" : toggle.dataset["labelReopen"] ?? "";
  element("detail-status", HTMLElement).textContent = report.status === "open" ? element("status-open", HTMLButtonElement).textContent : element("status-done", HTMLButtonElement).textContent;
  element("detail-status", HTMLElement).classList.toggle("pill--ok", report.status === "done");
}

/** Ayrıntı panelini boşaltır. */
function clearDetail(): void {
  element("detail-body", HTMLElement).classList.add("hidden");
  element("detail-empty", HTMLElement).classList.remove("hidden");
}

/** Oturum yok (yenileme de başarısız) ya da sunucu yönetici erişimini reddetti (403). Saf fonksiyondur. */
function isAccessDenied(error: unknown): boolean {
  return error instanceof SignedOutError || (error instanceof ApiRequestError && (error.status === 403 || error.status === 401));
}

/** Panelin yerine standart "sayfa bulunamadı" görünümünü koyar (panel varsa kaldırılır). */
function showNotFound(): void {
  const notFound: HTMLElement = element("admin-not-found", HTMLElement);
  element("admin", HTMLElement).remove();
  document.documentElement.classList.remove("admin-app");
  notFound.hidden = false;
  document.title = dataValue(notFound, "title");
}

/** Erişim yoksa "sayfa bulunamadı"; başka hatada (ağ, sunucu) nötr bir bildirim. */
function showFailure(error: unknown): void {
  if (isAccessDenied(error)) {
    showNotFound();
    return;
  }
  element("admin-loading", HTMLElement).classList.add("hidden");
  showNotice(element("admin-error", HTMLElement), errorText(error, text));
}

/** Panel şablonunu sayfaya ekler ve sekme başlığını panelinkiyle değiştirir (erişim doğrulandıktan sonra). */
function mountDashboard(): void {
  const root: HTMLElement = element("admin", HTMLElement);
  const template: HTMLTemplateElement | null = document.querySelector<HTMLTemplateElement>("template#admin-template");
  if (template === null) {
    throw new MissingElementError("template#admin-template bulunamadı.");
  }
  element("admin-mount", HTMLElement).replaceChildren(template.content.cloneNode(true));
  element("admin-loading", HTMLElement).classList.add("hidden");
  // Sitenin üst çubuğu ve alt bilgisi gizlenir; panel tam ekran kabuk olur (admin.astro).
  document.documentElement.classList.add("admin-app");
  document.title = dataValue(root, "title");
}

/** Görünümü gösterir (menü düğmesinin basılı durumu, panelin görünürlüğü ve üst çubuktaki başlık). */
function showView(view: AdminView): void {
  for (const other of adminViews) {
    element(`view-${other}`, HTMLButtonElement).setAttribute("aria-pressed", String(other === view));
    element(`panel-${other}`, HTMLElement).classList.toggle("hidden", other !== view);
  }
  element("admin-view-title", HTMLElement).textContent = dataValue(element(`view-${view}`, HTMLButtonElement), "title");
}

/** Adres çubuğundaki `#users` gibi görünüm adı; yoksa genel bakış. Saf fonksiyondur. */
function viewFromHash(hash: string): AdminView {
  return adminViews.find((view: AdminView): boolean => `#${view}` === hash) ?? "overview";
}

/** Sayfayı başlatır. */
async function main(): Promise<void> {
  await claimTabSession();
  if (!hasSession()) {
    showNotFound();
    return;
  }
  // Önce erişim doğrulanır; başarısızsa (403, oturum yok) panel hiç eklenmez.
  const firstStats: AdminStats = await fetchStats();
  mountDashboard();
  const notice: HTMLElement = element("admin-error", HTMLElement);
  const state: InboxState = { kind: "feedback", status: "open", items: [], nextBefore: null, selectedId: null };
  const view: { current: AdminView } = { current: "overview" };

  const select = (id: string): void => {
    state.selectedId = id;
    renderList(state, select);
    fetchReport(id)
      .then((report: ReportDetail): void => {
        renderDetail(report);
        // Dar ekranda ayrıntı listenin altında: görünür alana kaydırılır.
        element("inbox-detail", HTMLElement).scrollIntoView({ block: "nearest" });
      })
      .catch(showFailure);
  };

  const loadList = async (append: boolean): Promise<void> => {
    const page: ReportPage = await fetchReports(state.kind, state.status, append ? state.nextBefore : null);
    state.items = append ? [...state.items, ...page.items] : [...page.items];
    state.nextBefore = page.nextBefore;
    renderList(state, select);
  };

  const kinds: readonly ReportKind[] = ["feedback", "crash", "contact"];
  const statuses: readonly ReportStatus[] = ["open", "done"];
  const setInboxFilter = (kind: ReportKind, status: ReportStatus): void => {
    state.kind = kind;
    state.status = status;
    state.selectedId = null;
    for (const other of kinds) {
      element(`tab-${other}`, HTMLButtonElement).setAttribute("aria-pressed", String(other === kind));
    }
    for (const other of statuses) {
      element(`status-${other}`, HTMLButtonElement).setAttribute("aria-pressed", String(other === status));
    }
    clearDetail();
  };

  const switchView = (next: AdminView): void => {
    view.current = next;
    showView(next);
    history.replaceState(null, "", next === "overview" ? location.pathname : `#${next}`);
    if (next === "users") {
      users.ensureLoaded().catch(showFailure);
    }
    if (next === "insights") {
      insights.ensureLoaded().catch(showFailure);
    }
    if (next === "operations") {
      operations.ensureLoaded().catch(showFailure);
    }
  };

  // Kullanıcı ayrıntısındaki ya da işletimdeki rapor bildirim kutusunda, kendi türü ve durumuyla açılır.
  const openReport = (id: string, kind: ReportKind, status: ReportStatus): void => {
    setInboxFilter(kind, status);
    switchView("inbox");
    loadList(false)
      .then((): void => select(id))
      .catch(showFailure);
  };
  const users: UsersView = createUsersView(showFailure, openReport);
  const openUser = (id: string): void => {
    switchView("users");
    users.openUser(id).catch(showFailure);
  };
  const operations: OperationsView = createOperationsView(openUser, openReport);
  const insights: InsightsView = createInsightsView(openUser);

  const refresh = async (): Promise<void> => {
    hideNotice(notice);
    const current: AdminView = view.current;
    const [stats] = await Promise.all([
      fetchStats(),
      current === "inbox" ? loadList(false) : Promise.resolve(),
      current === "users" ? users.refresh() : Promise.resolve(),
      current === "operations" ? operations.refresh() : Promise.resolve(),
      current === "insights" ? insights.refresh() : Promise.resolve(),
    ]);
    renderStats(stats);
  };

  for (const kind of kinds) {
    element(`tab-${kind}`, HTMLButtonElement).addEventListener("click", (): void => {
      setInboxFilter(kind, state.status);
      loadList(false).catch(showFailure);
    });
  }
  for (const status of statuses) {
    element(`status-${status}`, HTMLButtonElement).addEventListener("click", (): void => {
      setInboxFilter(state.kind, status);
      loadList(false).catch(showFailure);
    });
  }
  element("inbox-more", HTMLButtonElement).addEventListener("click", (): void => {
    loadList(true).catch(showFailure);
  });
  const toggle: HTMLButtonElement = element("detail-toggle", HTMLButtonElement);
  toggle.addEventListener("click", (): void => {
    const id: string | null = state.selectedId;
    const next: string | undefined = toggle.dataset["next"];
    if (id === null || (next !== "open" && next !== "done")) {
      return;
    }
    toggle.disabled = true;
    setReportStatus(id, next)
      .then(async (): Promise<void> => {
        renderDetail(await fetchReport(id));
        await refresh();
      })
      .catch(showFailure)
      .finally((): void => {
        toggle.disabled = false;
      });
  });
  for (const each of adminViews) {
    element(`view-${each}`, HTMLButtonElement).addEventListener("click", (): void => switchView(each));
  }
  const refreshButton: HTMLButtonElement = element("admin-refresh", HTMLButtonElement);
  refreshButton.addEventListener("click", (): void => {
    refreshButton.disabled = true;
    refresh()
      .catch(showFailure)
      .finally((): void => {
        refreshButton.disabled = false;
      });
  });

  renderStats(firstStats);
  await loadList(false);
  switchView(viewFromHash(location.hash));
}

main().catch(showFailure);
