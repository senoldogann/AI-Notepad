// Yönetim panelinin kullanıcılar görünümü: kimlik önekiyle aranan, plana ve giriş sağlayıcısına göre süzülen, imleçli
// tablo ve tek kullanıcının ayrıntısı (alanlar, bu ayın kullanımı ölçerlerle, toplantılar, zaman çizelgesi, raporlar).
// Sunucu kimlik jetonu, sağlayıcı kimliği, e-posta ya da IP döndürmez; burada da gösterilmez.
import {
  type ReportKind,
  type ReportStatus,
  type TimelineEntry,
  type UserCancellation,
  type UserDetail,
  type UserFilter,
  type UserMeeting,
  type UserPage,
  type UserReport,
  type UserSubscription,
  type UserSummary,
  fetchUser,
  fetchUsers,
  userProviderOf,
  userSegmentOf,
} from "./admin-api";
import {
  fillCounts,
  fillTable,
  formatCount,
  formatDate,
  formatOptionalTime,
  formatRelative,
  formatTime,
  node,
  pill,
  shortId,
  tableRow,
} from "./admin-format";
import { type AdminClientCopy, clientCopy, fill } from "./copy";
import { element } from "./dom";
import type { BillingPlan } from "../lib/plans";

const adminText: AdminClientCopy = clientCopy.admin;

/** Bildirimi bildirim kutusunda açan işleyici. */
export type OpenReport = (id: string, kind: ReportKind, status: ReportStatus) => void;

/** Kullanıcılar görünümünün dışarıya açtığı işlemler. */
export interface UsersView {
  /** İlk açılışta listeyi yükler (sonrakilerde bir şey yapmaz). */
  readonly ensureLoaded: () => Promise<void>;
  /** Listeyi (ve açıksa ayrıntıyı) yeniden yükler. */
  readonly refresh: () => Promise<void>;
  /** Kullanıcının ayrıntısını açar. */
  readonly openUser: (id: string) => Promise<void>;
}

/** Görünümün durumu. */
interface UsersState {
  filter: UserFilter;
  items: UserSummary[];
  nextCursor: string | null;
  loaded: boolean;
  openId: string | null;
}

/** Aboneliğin rozeti: erişim ve planlanmış iptale göre. Saf fonksiyondur (yeni öğe üretir). */
function subscriptionBadge(subscription: UserSubscription | null): HTMLElement | string {
  if (subscription === null) {
    return adminText.none;
  }
  if (subscription.access === "active") {
    return subscription.cancelAt === null ? pill(adminText.subscriptionPills.active, "ok") : pill(adminText.subscriptionPills.ending, "warn");
  }
  if (subscription.access === "grace") {
    return pill(adminText.subscriptionPills.grace, "warn");
  }
  const ended: HTMLSpanElement = pill(adminText.subscriptionPills.ended, "");
  ended.title = subscription.status;
  return ended;
}

/**
 * Planın rozeti: abonede aylık ya da yıllık da yazılır (fiyat tanınmıyorsa yalnızca "abone"). Saf fonksiyondur (yeni öğe
 * üretir).
 */
function planBadge(user: UserSummary): HTMLSpanElement {
  const billing: BillingPlan | null = user.plan === "subscription" && user.subscription !== null ? user.subscription.plan : null;
  const label: string = billing === null ? adminText.plans[user.plan] : `${adminText.plans[user.plan]} · ${adminText.billingPlans[billing]}`;
  return pill(label, user.plan === "subscription" ? "ok" : "");
}

/** Deneme hücresinin metni. Saf fonksiyondur. */
function trialText(user: UserSummary): string {
  return user.trial.startedAt === null && user.trial.used === 0 ? adminText.trialNotStarted : fillCounts(adminText.trialCell, { used: user.trial.used, left: user.trial.left });
}

/** Sağlayıcı adı. Saf fonksiyondur. */
function providerText(user: UserSummary): string {
  return user.provider === null ? adminText.none : adminText.providers[user.provider];
}

/** Kimlik düğmesi: satırın klavyeyle açılan bağlantısı. */
function idButton(id: string, onOpen: (id: string) => void): HTMLButtonElement {
  const button: HTMLButtonElement = node("button", "id-button", shortId(id));
  button.type = "button";
  button.title = id;
  button.addEventListener("click", (event: MouseEvent): void => {
    event.stopPropagation();
    onOpen(id);
  });
  return button;
}

/** Hata kodu: eş aralıklı, uzun kod kısaltılmadan (tablo yatay kayar). */
function failureCode(code: string): HTMLSpanElement {
  return node("span", "mono failure-code", code);
}

/** Kullanıcının "ne ters gitti" hücresi: hatalı toplantı sayısı ve en son kod (ipucunda açıklaması); yoksa "—". */
function userProblems(user: UserSummary): HTMLElement | string {
  if (user.failedMeetings === 0 || user.lastFailureCode === null) {
    return adminText.none;
  }
  const cell: HTMLSpanElement = failureCode(fill(adminText.meetingFailure, { count: formatCount(user.failedMeetings), code: user.lastFailureCode }));
  cell.classList.add("failure-code--warn");
  cell.title = fillCounts(adminText.failedMeetings, { count: user.failedMeetings });
  return cell;
}

/** Kullanıcı tablosunun satırı. */
function userRow(user: UserSummary, nowMs: number, onOpen: (id: string) => void): HTMLTableRowElement {
  const row: HTMLTableRowElement = tableRow([
    idButton(user.id, onOpen),
    providerText(user),
    formatDate(user.createdAt),
    planBadge(user),
    trialText(user),
    subscriptionBadge(user.subscription),
    formatCount(user.meetingsTotal),
    formatCount(user.hoursThisMonth),
    user.lastActiveAt === null ? adminText.none : formatRelative(user.lastActiveAt, nowMs),
    userProblems(user),
  ]);
  row.className = "is-clickable";
  row.addEventListener("click", (): void => onOpen(user.id));
  return row;
}

/** Kullanıcı listesini çizer. */
function renderUsers(state: UsersState, onOpen: (id: string) => void): void {
  const nowMs: number = Date.now();
  fillTable(
    element("users-rows", HTMLTableSectionElement),
    state.items.map((user: UserSummary): HTMLTableRowElement => userRow(user, nowMs, onOpen)),
  );
  element("users-empty", HTMLElement).classList.toggle("hidden", state.items.length > 0);
  element("users-more", HTMLButtonElement).classList.toggle("hidden", state.nextCursor === null);
  element("users-shown", HTMLElement).textContent = fillCounts(adminText.shown, { count: state.items.length });
}

/** Toplantının not rozetleri (not hazır, sonradan işlenen, yeniden işlenen, Deepgram, doğrulanmış Mac). */
function meetingNotes(meeting: UserMeeting): HTMLElement {
  const notes: HTMLElement = node("span", "pill-row", "");
  if (meeting.noteCompleted) {
    notes.append(pill(adminText.noteDone, "ok"));
  }
  const labels: readonly string[] = [
    meeting.deferred ? adminText.meetingNotes.deferred : "",
    meeting.reprocessCount > 0 ? fillCounts(adminText.meetingNotes.reprocessed, { count: meeting.reprocessCount }) : "",
    meeting.deepgram ? adminText.meetingNotes.deepgram : "",
    meeting.attested ? adminText.meetingNotes.attested : "",
  ].filter((label: string): boolean => label !== "");
  notes.append(...labels.map((label: string): HTMLSpanElement => pill(label, "")));
  return notes;
}

/** Toplantının durum rozeti. */
function meetingStateBadge(meeting: UserMeeting): HTMLSpanElement {
  const tone: "" | "ok" | "warn" = meeting.state === "open" ? "ok" : meeting.state === "expired" ? "warn" : "";
  return pill(adminText.meetingStates[meeting.state], tone);
}

/** Toplantının "ne ters gitti" hücresi: başarısız istek sayısı ve son kod (ipucunda anı); yoksa "—". */
function meetingProblem(meeting: UserMeeting): HTMLElement | string {
  if (meeting.failureCount === 0 || meeting.lastFailureCode === null) {
    return adminText.none;
  }
  const cell: HTMLSpanElement = failureCode(fill(adminText.meetingFailure, { count: formatCount(meeting.failureCount), code: meeting.lastFailureCode }));
  cell.classList.add("failure-code--warn");
  cell.title = formatOptionalTime(meeting.lastFailureAt);
  return cell;
}

/** Toplantı tablosunun satırı. */
function meetingRow(meeting: UserMeeting): HTMLTableRowElement {
  return tableRow([
    formatTime(meeting.startedAt),
    adminText.meetingKinds[meeting.kind],
    meetingStateBadge(meeting),
    fill(adminText.minutes, { minutes: formatCount(meeting.durationMinutes) }),
    fill(adminText.minutes, { minutes: formatCount(meeting.audioMinutes) }),
    fill(adminText.ofCap, { used: formatCount(meeting.tokensUsed), cap: formatCount(meeting.tokenBudget) }),
    meetingProblem(meeting),
    meetingNotes(meeting),
  ]);
}

/** İptal nedeninin metni: portal seçeneği, Stripe nedeni ve yorum; nedeni saklanmamışsa "—". Saf fonksiyondur. */
function cancellationText(cancellation: UserCancellation | null): string {
  if (cancellation === null) {
    return adminText.none;
  }
  const feedback: string =
    cancellation.feedback === null ? adminText.cancellationNoFeedback : (adminText.cancellationFeedback[cancellation.feedback] ?? cancellation.feedback);
  const reason: string | null = cancellation.reason === null ? null : (adminText.cancellationReasons[cancellation.reason] ?? cancellation.reason);
  return [feedback, reason, cancellation.comment === null ? null : `“${cancellation.comment}”`, formatDate(cancellation.at)]
    .filter((part: string | null): part is string => part !== null)
    .join(" · ");
}

/** Zaman çizelgesi satırı. */
function timelineItem(entry: TimelineEntry, nowMs: number): HTMLLIElement {
  const item: HTMLLIElement = document.createElement("li");
  item.append(
    node("span", "", fill(adminText.timeline[entry.kind], { detail: entry.detail ?? "" })),
    node("span", "timeline__time", `${formatTime(entry.at)} · ${formatRelative(entry.at, nowMs)}`),
  );
  return item;
}

/** Raporun bağlantı satırı (bildirim kutusunda açılır). */
function reportItem(report: UserReport, onOpenReport: OpenReport): HTMLLIElement {
  const item: HTMLLIElement = document.createElement("li");
  const button: HTMLButtonElement = node("button", "link-list__item", "");
  button.type = "button";
  button.append(node("span", "link-list__title", report.summary), node("span", "link-list__meta", `${report.kind} · ${report.status} · ${formatTime(report.createdAt)}`));
  button.addEventListener("click", (): void => onOpenReport(report.id, report.kind, report.status));
  item.append(button);
  return item;
}

/** Ölçeri ve metnini doldurur; %80'i aşınca uyarı rengi. */
function setMeter(id: string, used: number, cap: number, format: (value: number) => string): void {
  const meter: HTMLProgressElement = element(`user-meter-${id}`, HTMLProgressElement);
  meter.max = Math.max(cap, 0.01);
  meter.value = Math.min(used, meter.max);
  meter.classList.toggle("meter--warn", cap > 0 && used >= cap * 0.8);
  element(`user-meter-${id}-text`, HTMLElement).textContent = fill(adminText.ofCap, { used: format(used), cap: format(cap) });
}

/** Aboneliğin ayrıntı metni. Saf fonksiyondur. */
function subscriptionText(subscription: UserSubscription | null): string {
  if (subscription === null) {
    return adminText.none;
  }
  const end: number = subscription.graceEndsAt ?? subscription.cancelAt ?? subscription.currentPeriodEnd;
  const plan: string = subscription.plan === null ? "" : `${adminText.billingPlans[subscription.plan]} · `;
  return `${plan}${subscription.status} · ${formatDate(end)}`;
}

/** Kullanıcı ayrıntısını çizer. */
function renderDetail(detail: UserDetail, onOpenReport: OpenReport): void {
  const nowMs: number = Date.now();
  const user: UserSummary = detail.user;
  element("user-title", HTMLElement).textContent = fill(adminText.userTitle, { id: user.id });
  element("user-pills", HTMLElement).replaceChildren(
    ...[planBadge(user), subscriptionBadge(user.subscription)].filter((badge: HTMLElement | string): badge is HTMLElement => typeof badge !== "string"),
  );
  const fields: Readonly<Record<string, string>> = {
    provider: providerText(user),
    created: formatTime(user.createdAt),
    "last-active": user.lastActiveAt === null ? adminText.none : `${formatTime(user.lastActiveAt)} · ${formatRelative(user.lastActiveAt, nowMs)}`,
    subscription: subscriptionText(user.subscription),
    trial: trialText(user),
    "trial-device": formatOptionalTime(detail.trialDeviceVerifiedAt),
    stripe: detail.stripeCustomerId ?? adminText.none,
    cancellation: cancellationText(detail.cancellation),
  };
  for (const [id, value] of Object.entries(fields)) {
    element(`user-field-${id}`, HTMLElement).textContent = value;
  }
  setMeter("hours", detail.usage.usedHours, detail.usage.capHours, formatCount);
  setMeter("tokens", detail.usage.tokens, detail.usage.tokenCap, formatCount);
  setMeter("account", detail.usage.accountTokens, detail.usage.accountTokenCap, formatCount);
  element("user-audio", HTMLElement).textContent = fill(adminText.hours, { hours: formatCount(detail.usage.audioHours) });
  fillTable(element("user-meetings", HTMLTableSectionElement), detail.meetings.map(meetingRow));
  element("user-meetings-empty", HTMLElement).classList.toggle("hidden", detail.meetings.length > 0);
  element("user-timeline", HTMLElement).replaceChildren(...detail.timeline.map((entry: TimelineEntry): HTMLLIElement => timelineItem(entry, nowMs)));
  element("user-reports", HTMLElement).replaceChildren(...detail.reports.map((report: UserReport): HTMLLIElement => reportItem(report, onOpenReport)));
  element("user-reports-empty", HTMLElement).classList.toggle("hidden", detail.reports.length > 0);
}

/** Liste ile ayrıntı arasında geçiş. */
function showDetailView(show: boolean): void {
  element("users-list-view", HTMLElement).classList.toggle("hidden", show);
  element("user-detail-view", HTMLElement).classList.toggle("hidden", !show);
}

/** Formdaki süzgeci okur. Saf olmayan (DOM okur). */
function readFilter(): UserFilter {
  const query: string = element("users-query", HTMLInputElement).value.trim().toLowerCase();
  return {
    query: query === "" ? null : query,
    segment: userSegmentOf(element("users-segment", HTMLSelectElement).value),
    provider: userProviderOf(element("users-provider", HTMLSelectElement).value),
  };
}

/** Kullanıcılar görünümünü bağlar; hatalar `onFailure`'a, rapor açma `onOpenReport`'a gider. */
export function createUsersView(onFailure: (error: unknown) => void, onOpenReport: OpenReport): UsersView {
  const state: UsersState = { filter: { query: null, segment: null, provider: null }, items: [], nextCursor: null, loaded: false, openId: null };

  const openUser = async (id: string): Promise<void> => {
    state.openId = id;
    const detail: UserDetail = await fetchUser(id);
    renderDetail(detail, onOpenReport);
    showDetailView(true);
    element("user-detail-view", HTMLElement).scrollIntoView({ block: "start" });
  };
  const open = (id: string): void => {
    openUser(id).catch(onFailure);
  };

  const loadList = async (append: boolean): Promise<void> => {
    const page: UserPage = await fetchUsers(state.filter, append ? state.nextCursor : null);
    state.items = append ? [...state.items, ...page.items] : [...page.items];
    state.nextCursor = page.nextCursor;
    state.loaded = true;
    renderUsers(state, open);
  };

  element("users-form", HTMLFormElement).addEventListener("submit", (event: SubmitEvent): void => {
    event.preventDefault();
    state.filter = readFilter();
    showDetailView(false);
    loadList(false).catch(onFailure);
  });
  for (const id of ["users-segment", "users-provider"]) {
    element(id, HTMLSelectElement).addEventListener("change", (): void => {
      state.filter = readFilter();
      loadList(false).catch(onFailure);
    });
  }
  element("users-more", HTMLButtonElement).addEventListener("click", (): void => {
    loadList(true).catch(onFailure);
  });
  element("user-back", HTMLButtonElement).addEventListener("click", (): void => {
    state.openId = null;
    showDetailView(false);
  });

  return {
    ensureLoaded: async (): Promise<void> => {
      if (!state.loaded) {
        await loadList(false);
      }
    },
    refresh: async (): Promise<void> => {
      await loadList(false);
      if (state.openId !== null) {
        renderDetail(await fetchUser(state.openId), onOpenReport);
      }
    },
    openUser,
  };
}
