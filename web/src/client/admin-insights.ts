// Yönetim panelinin içgörüler verisi (`/v1/admin/insights`; öğeleri gelir, büyüme ve güvenilirlik görünümlerinde, sorunlar
// genel bakışın "dikkat" listesinde de): sorunlar (son 7 ve 30 gün: tavan retleri, koda göre
// retler, servis hataları, 5xx), son 30 günün hunisi (her adımın sayısı, temel adıma oranı ve kayıp), indirmelerin
// düğmeye ve yönlendiren siteye göre dağılımı, Stripe iptal nedenleri ve davet programının özeti (son 30 gün, nedene
// göre düşen davetler, en çok davet edenler). Kimlik olarak yalnızca hesap UUID'si gelir.
import {
  type DetailCount,
  type FunnelStep,
  type InviteReferrer,
  type InviteSummary,
  type Insights,
  type ProblemWindow,
  type RecentCancellation,
  fetchInsights,
} from "./admin-api";
import { fillCounts, fillTable, formatCount, formatDate, formatRate, node, shortId, tableRow } from "./admin-format";
import { type AdminInviteCopy, adminInviteCopy, inviteVoidReasonLabel } from "./admin-invites-copy";
import { type AdminClientCopy, clientCopy, fill } from "./copy";
import { element } from "./dom";

const adminText: AdminClientCopy = clientCopy.admin;
const inviteText: AdminInviteCopy = adminInviteCopy;

/** `subscribed` adımının alt kümesi olan adımlar: oranları ve kayıpları önceki satıra değil abonelere göredir. */
const subscribedSubsets: ReadonlySet<FunnelStep> = new Set<FunnelStep>(["subscribed_via_invite", "canceled"]);

/** Ayrıca satırı olan tavan retleri (ret listesinde yinelenmez). */
const ceilingCodes: ReadonlySet<string> = new Set(["trial_capacity_reached", "spend_ceiling_reached"]);

/** İçgörüler görünümünün dışarıya açtığı işlemler. */
export interface InsightsView {
  /** Görünümü (yeniden) yükler. */
  readonly refresh: () => Promise<void>;
  /** İlk açılışta yükler (sonrakilerde bir şey yapmaz). */
  readonly ensureLoaded: () => Promise<void>;
}

/** Sorun tablosunun satırı: etiket, 7 ve 30 günlük sayı; uyarı satırı vurgulanır. */
interface ProblemLine {
  readonly label: string;
  readonly mono: boolean;
  readonly last7: number;
  readonly last30: number;
  readonly warn: boolean;
}

/** Ayrıntının sayısı (yoksa 0). Saf fonksiyondur. */
function countOf(counts: readonly DetailCount[], detail: string): number {
  return counts.find((item: DetailCount): boolean => item.detail === detail)?.count ?? 0;
}

/**
 * Bir türün satırları: iki pencerenin ayrıntılarının birleşimi, 30 günlük sayıya göre çoktan aza. Saf fonksiyondur.
 */
function detailLines(
  short: readonly DetailCount[],
  long: readonly DetailCount[],
  label: (detail: string) => string,
  skip: ReadonlySet<string>,
): ProblemLine[] {
  const details: string[] = [...new Set([...long, ...short].map((item: DetailCount): string => item.detail))].filter((detail: string): boolean => !skip.has(detail));
  return details
    .map((detail: string): ProblemLine => ({ label: label(detail), mono: true, last7: countOf(short, detail), last30: countOf(long, detail), warn: false }))
    .sort((left: ProblemLine, right: ProblemLine): number => right.last30 - left.last30 || left.label.localeCompare(right.label));
}

/** Sorun tablosunun satırları: önce tavanlar ve 5xx toplamı, sonra retler, servis hataları ve 5xx kodları. Saf fonksiyondur. */
export function problemLines(short: ProblemWindow, long: ProblemWindow): ProblemLine[] {
  const rows: ProblemLine[] = [
    { label: adminText.problemRows.trialCapacity, mono: false, last7: short.trialCapacityReached, last30: long.trialCapacityReached, warn: short.trialCapacityReached > 0 },
    { label: adminText.problemRows.spendCeiling, mono: false, last7: short.spendCeilingReached, last30: long.spendCeilingReached, warn: short.spendCeilingReached > 0 },
    { label: adminText.problemRows.serverErrors, mono: false, last7: short.serverErrorsTotal, last30: long.serverErrorsTotal, warn: short.serverErrorsTotal > 0 },
    ...detailLines(short.refusals, long.refusals, (code: string): string => fill(adminText.problemRows.refusal, { code }), ceilingCodes),
    ...detailLines(short.providerErrors, long.providerErrors, (service: string): string => fill(adminText.problemRows.provider, { service }), new Set()),
    ...detailLines(short.serverErrors, long.serverErrors, (code: string): string => fill(adminText.problemRows.server, { code }), new Set()),
  ];
  return rows;
}

/** Sorun satırı. */
function problemRow(line: ProblemLine): HTMLTableRowElement {
  const row: HTMLTableRowElement = tableRow([line.mono ? node("span", "mono", line.label) : line.label, formatCount(line.last7), formatCount(line.last30)]);
  if (line.warn) {
    row.className = "is-warn";
  }
  return row;
}

/** Huni adımının hücresi: adı ve en büyük adıma göre çubuğu (CSP: satır içi stil yerine `<progress>`). */
function funnelStepCell(step: FunnelStep, count: number, max: number): HTMLElement {
  const cell: HTMLElement = node("span", "funnel__step", "");
  const bar: HTMLProgressElement = document.createElement("progress");
  bar.className = "meter funnel__bar";
  bar.max = Math.max(max, 1);
  bar.value = count;
  bar.setAttribute("aria-hidden", "true");
  cell.append(node("span", "", funnelStepLabel(step)), bar);
  return cell;
}

/** Huni adımının adı. Saf fonksiyondur. */
function funnelStepLabel(step: FunnelStep): string {
  return step === "subscribed_via_invite" ? inviteText.funnelStep : adminText.funnelSteps[step];
}

/**
 * Huni satırları: sayı, temel adıma oranı ve kayıp (ilk adımda ve artışta "—"). Temel adım önceki satırdır; abonelerin
 * alt kümesi olan adımlarda (`subscribedSubsets`) abonelerdir.
 */
function funnelRows(steps: Insights["funnel"]["steps"]): HTMLTableRowElement[] {
  const max: number = Math.max(0, ...steps.map((step: { readonly count: number }): number => step.count));
  const subscribed: number | null = steps.find((step: { readonly step: FunnelStep }): boolean => step.step === "subscribed")?.count ?? null;
  return steps.map((step: { readonly step: FunnelStep; readonly count: number }, index: number): HTMLTableRowElement => {
    const previous: number | null = index === 0 ? null : subscribedSubsets.has(step.step) ? subscribed : (steps[index - 1]?.count ?? null);
    const lost: number | null = previous === null ? null : previous - step.count;
    return tableRow([
      funnelStepCell(step.step, step.count, max),
      formatCount(step.count),
      previous === null ? adminText.none : formatRate(step.count, previous),
      lost === null || lost <= 0 ? adminText.none : formatCount(lost),
    ]);
  });
}

/** Ayrıntı → etiket ile sayı tablosunun satırları. */
function countRows(counts: readonly DetailCount[], label: (detail: string) => string): HTMLTableRowElement[] {
  return counts.map((item: DetailCount): HTMLTableRowElement => tableRow([label(item.detail), formatCount(item.count)]));
}

/** İndirme düğmesinin adı. Saf fonksiyondur. */
function sourceLabel(source: string): string {
  return adminText.downloadSources[source] ?? source;
}

/** Yönlendiren sitenin adı (boş: Referer yok). Saf fonksiyondur. */
function referrerLabel(host: string): string {
  if (host === "") {
    return adminText.referrerNone;
  }
  return host === "other" ? adminText.referrerOther : host;
}

/** Portal iptal seçeneğinin adı (boş: seçilmemiş). Saf fonksiyondur. */
function feedbackLabel(feedback: string): string {
  return feedback === "" ? adminText.cancellationNoFeedback : (adminText.cancellationFeedback[feedback] ?? feedback);
}

/** Stripe nedenlerinin özet satırı. Saf fonksiyondur. */
function reasonsLine(reasons: readonly DetailCount[]): string {
  const list: string = reasons
    .filter((item: DetailCount): boolean => item.detail !== "")
    .map((item: DetailCount): string => `${adminText.cancellationReasons[item.detail] ?? item.detail} ${formatCount(item.count)}`)
    .join(" · ");
  return list === "" ? "" : fill(adminText.cancellationReasonsLine, { list });
}

/** Son iptalin satırı: hesap (ayrıntıda açılır), seçenek, yorum ve tarih. */
function cancellationItem(cancellation: RecentCancellation, onOpenUser: (id: string) => void): HTMLLIElement {
  const item: HTMLLIElement = document.createElement("li");
  const button: HTMLButtonElement = node("button", "link-list__item", "");
  button.type = "button";
  button.title = cancellation.userId;
  const title: string = cancellation.comment === null ? feedbackLabel(cancellation.feedback ?? "") : `“${cancellation.comment}”`;
  const meta: string = [shortId(cancellation.userId), feedbackLabel(cancellation.feedback ?? ""), formatDate(cancellation.at)].join(" · ");
  button.append(node("span", "link-list__title link-list__title--wrap", title), node("span", "link-list__meta", meta));
  button.addEventListener("click", (): void => onOpenUser(cancellation.userId));
  item.append(button);
  return item;
}

/** Davet özetinin satırları: son 30 günün sayıları ve şu an ücretsiz aydakiler. Saf fonksiyondur (yeni öğe üretir). */
function inviteRows(invites: InviteSummary): HTMLTableRowElement[] {
  const rows: ReadonlyArray<readonly [string, number]> = [
    [inviteText.insightsRows.checkouts, invites.checkouts],
    [inviteText.insightsRows.joined, invites.joined],
    [inviteText.insightsRows.firstPayments, invites.firstPayments],
    [inviteText.insightsRows.granted, invites.granted],
    [inviteText.insightsRows.inFreeMonth, invites.inFreeMonth],
  ];
  return rows.map(([label, count]: readonly [string, number]): HTMLTableRowElement => tableRow([label, formatCount(count)]));
}

/** Düşen davetlerin nedene göre özet satırı. Saf fonksiyondur. */
function inviteVoidedLine(voided: readonly DetailCount[]): string {
  if (voided.length === 0) {
    return inviteText.insightsNoVoided;
  }
  const list: string = voided.map((item: DetailCount): string => `${inviteVoidReasonLabel(item.detail)} ${formatCount(item.count)}`).join(" · ");
  return fill(inviteText.insightsVoided, { list });
}

/** En çok davet edenin satırı: hesap (ayrıntıda açılır) ve sayaçları. */
function referrerItem(referrer: InviteReferrer, onOpenUser: (id: string) => void): HTMLLIElement {
  const item: HTMLLIElement = document.createElement("li");
  const button: HTMLButtonElement = node("button", "link-list__item", "");
  button.type = "button";
  button.title = referrer.userId;
  const meta: string = fillCounts(inviteText.topReferrerMeta, { joined: referrer.joined, pending: referrer.pending, granted: referrer.granted, voided: referrer.voided });
  button.append(node("span", "link-list__title mono", shortId(referrer.userId)), node("span", "link-list__meta", meta));
  button.addEventListener("click", (): void => onOpenUser(referrer.userId));
  item.append(button);
  return item;
}

/** Tablonun gövdesini doldurur ve boş bildirimini açar ya da kapatır. */
function fillCountTable(id: string, rows: readonly HTMLTableRowElement[]): void {
  fillTable(element(`${id}-rows`, HTMLTableSectionElement), rows);
  element(`${id}-empty`, HTMLElement).classList.toggle("hidden", rows.length > 0);
}

/** İçgörüler görünümünü çizer. */
function renderInsights(insights: Insights, onOpenUser: (id: string) => void): void {
  const problems: ProblemLine[] = problemLines(insights.problems.last7Days, insights.problems.last30Days);
  const anyProblem: boolean = problems.some((line: ProblemLine): boolean => line.last30 > 0);
  fillTable(element("insights-problems-rows", HTMLTableSectionElement), problems.map(problemRow));
  element("insights-problems-empty", HTMLElement).classList.toggle("hidden", anyProblem);
  fillTable(element("insights-funnel-rows", HTMLTableSectionElement), funnelRows(insights.funnel.steps));
  fillCountTable("insights-sources", countRows(insights.downloads.bySource, sourceLabel));
  fillCountTable("insights-referrers", countRows(insights.downloads.byReferrerHost, referrerLabel));
  fillCountTable("insights-feedback", countRows(insights.cancellations.byFeedback, feedbackLabel));
  element("insights-reasons", HTMLElement).textContent = reasonsLine(insights.cancellations.byReason);
  element("insights-cancellations", HTMLElement).replaceChildren(
    ...insights.cancellations.recent.map((cancellation: RecentCancellation): HTMLLIElement => cancellationItem(cancellation, onOpenUser)),
  );
  element("insights-cancellations-empty", HTMLElement).classList.toggle("hidden", insights.cancellations.recent.length > 0);
  fillTable(element("insights-invites-rows", HTMLTableSectionElement), inviteRows(insights.invites));
  element("insights-invites-voided", HTMLElement).textContent = inviteVoidedLine(insights.invites.voided);
  element("insights-referrers-top", HTMLElement).replaceChildren(
    ...insights.invites.topReferrers.map((referrer: InviteReferrer): HTMLLIElement => referrerItem(referrer, onOpenUser)),
  );
  element("insights-referrers-top-empty", HTMLElement).classList.toggle("hidden", insights.invites.topReferrers.length > 0);
}

/**
 * İçgörüler verisini bağlar; hesaba tıklanınca kullanıcı ayrıntısı açılır. `onLoaded` her yüklemeden sonra yanıtı alır
 * (genel bakıştaki "dikkat" listesi).
 */
export function createInsightsView(onOpenUser: (id: string) => void, onLoaded: (insights: Insights) => void): InsightsView {
  const state: { loaded: boolean } = { loaded: false };
  const refresh = async (): Promise<void> => {
    const insights: Insights = await fetchInsights();
    renderInsights(insights, onOpenUser);
    onLoaded(insights);
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
