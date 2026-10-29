// Yönetim panelinin işletim görünümü: şu an açık toplantılar, bitirilmeden süresi dolanlar, takılı kullanım ayırmaları,
// gerçek süreye indirilmemiş Deepgram tahminleri, Stripe webhook'unun son olayları ve son çökme raporları. Uyarı eşiği
// aşılan kutu (ör. bir günden eski bekleyen ayırma) uyarı görünümüne geçer.
import { type OpenMeeting, type Operations, type RecentCrash, fetchOperations } from "./admin-api";
import { fillCounts, formatCount, formatRelative, formatTime, node, pill, shortId, tableRow } from "./admin-format";
import type { OpenReport } from "./admin-users";
import { type AdminClientCopy, clientCopy, fill } from "./copy";
import { element } from "./dom";

const adminText: AdminClientCopy = clientCopy.admin;

const dayMs: number = 86_400_000;

/** İşletim görünümünün dışarıya açtığı işlemler. */
export interface OperationsView {
  /** Görünümü (yeniden) yükler. */
  readonly refresh: () => Promise<void>;
  /** İlk açılışta yükler (sonrakilerde bir şey yapmaz). */
  readonly ensureLoaded: () => Promise<void>;
}

/** Kutunun değerini, alt satırını ve uyarı görünümünü yazar. */
function setOpsKpi(id: string, value: string, sub: string, warn: boolean): void {
  element(`kpi-ops-${id}`, HTMLElement).textContent = value;
  element(`kpi-ops-${id}-sub`, HTMLElement).textContent = sub;
  element(`kpi-ops-${id}-card`, HTMLElement).classList.toggle("kpi--warn", warn);
}

/** Açık toplantının satırı. */
function openMeetingRow(meeting: OpenMeeting, nowMs: number, onOpenUser: (id: string) => void): HTMLTableRowElement {
  const user: HTMLButtonElement = node("button", "id-button", shortId(meeting.userId));
  user.type = "button";
  user.title = meeting.userId;
  user.addEventListener("click", (): void => onOpenUser(meeting.userId));
  const notes: HTMLElement = node("span", "pill-row", "");
  if (meeting.deferred) {
    notes.append(pill(adminText.meetingNotes.deferred, ""));
  }
  if (meeting.deepgram) {
    notes.append(pill(adminText.meetingNotes.deepgram, ""));
  }
  return tableRow([user, adminText.meetingKinds[meeting.kind], formatRelative(meeting.startedAt, nowMs), formatTime(meeting.maxEndsAt), notes]);
}

/** Çökme raporunun bağlantı satırı (bildirim kutusunda açılır). */
function crashItem(crash: RecentCrash, onOpenReport: OpenReport): HTMLLIElement {
  const item: HTMLLIElement = document.createElement("li");
  const button: HTMLButtonElement = node("button", "link-list__item", "");
  button.type = "button";
  const meta: string = [crash.appVersion, crash.os, formatTime(crash.createdAt)].filter((part: string | null): part is string => part !== null).join(" · ");
  button.append(node("span", "link-list__title", crash.summary), node("span", "link-list__meta", meta));
  button.addEventListener("click", (): void => onOpenReport(crash.id, "crash", crash.status));
  item.append(button);
  return item;
}

/** İşletim görünümünü çizer. */
function renderOperations(ops: Operations, onOpenUser: (id: string) => void, onOpenReport: OpenReport): void {
  const nowMs: number = ops.generatedAt;
  setOpsKpi("open", formatCount(ops.meetings.open), adminText.opsOpenSub, false);
  setOpsKpi("unended", formatCount(ops.meetings.unendedLast7Days), adminText.opsUnendedSub, false);
  const oldest: number | null = ops.reservations.oldestExpiredAt;
  setOpsKpi(
    "reservations",
    formatCount(ops.reservations.active),
    oldest === null ? adminText.opsReservationsOk : fill(adminText.opsReservationsSub, { expired: formatCount(ops.reservations.expired), oldest: formatRelative(oldest, nowMs) }),
    oldest !== null && nowMs - oldest > dayMs,
  );
  setOpsKpi("deepgram", formatCount(ops.deepgram.unsettled), fillCounts(adminText.opsDeepgramSub, { stale: ops.deepgram.stale }), ops.deepgram.stale > 0);
  const lastEvent: number | null = ops.stripe.lastEventAt;
  setOpsKpi(
    "webhook",
    lastEvent === null ? adminText.none : formatRelative(lastEvent, nowMs),
    lastEvent === null ? adminText.opsWebhookNever : fillCounts(adminText.opsWebhookSub, { count: ops.stripe.eventsLast24Hours }),
    false,
  );
  const reports: Operations["reports"]["last7Days"] = ops.reports.last7Days;
  setOpsKpi("reports", formatCount(reports.feedback + reports.crash + reports.contact), fillCounts(adminText.opsReportsSub, reports), false);

  element("ops-open-rows", HTMLElement).replaceChildren(...ops.meetings.openItems.map((meeting: OpenMeeting): HTMLTableRowElement => openMeetingRow(meeting, nowMs, onOpenUser)));
  element("ops-open-empty", HTMLElement).classList.toggle("hidden", ops.meetings.openItems.length > 0);
  element("ops-stripe-rows", HTMLElement).replaceChildren(
    ...ops.stripe.last7DaysByType.map((entry: { readonly type: string; readonly count: number }): HTMLTableRowElement => {
      const row: HTMLTableRowElement = tableRow([node("span", "mono", entry.type), formatCount(entry.count)]);
      row.cells.item(1)?.classList.add("numeric");
      return row;
    }),
  );
  element("ops-stripe-empty", HTMLElement).classList.toggle("hidden", ops.stripe.last7DaysByType.length > 0);
  element("ops-crashes", HTMLElement).replaceChildren(...ops.reports.recentCrashes.map((crash: RecentCrash): HTMLLIElement => crashItem(crash, onOpenReport)));
  element("ops-crashes-empty", HTMLElement).classList.toggle("hidden", ops.reports.recentCrashes.length > 0);
}

/** İşletim görünümünü bağlar. */
export function createOperationsView(onOpenUser: (id: string) => void, onOpenReport: OpenReport): OperationsView {
  const state: { loaded: boolean } = { loaded: false };
  const refresh = async (): Promise<void> => {
    renderOperations(await fetchOperations(), onOpenUser, onOpenReport);
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
