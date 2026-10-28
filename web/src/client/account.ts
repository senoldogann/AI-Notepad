// Hesap sayfası: `/v1/me` (plan, kalan deneme, aylık saat, abonelik ve ek süre), Abone ol (Checkout), Aboneliği yönet
// (Portal), çıkış ve onaylı hesap silme (`DELETE /v1/me`). Oturum yoksa giriş sayfasına geçilir.
import { ApiRequestError, type Entitlements, type RawResponse, type SubscriptionInfo, parseEntitlements, parseRedirectUrl } from "./api";
import { dataValue, element, errorText, hideNotice, pageCopy, pageLang, showNotice } from "./dom";
import { SignedOutError, authorizedSend, clearSession, hasSession, signOut } from "./session";
import { type ClientCopy, fill } from "../i18n/client-copy";
import type { Lang } from "../i18n/routes";

/** Ödeme dönüşünde aboneliğin görünmesi için en çok kaç kez, kaç ms arayla yeniden bakılır (webhook gecikmesi). */
const paymentPollAttempts: number = 6;
const paymentPollIntervalMs: number = 2000;

/** Etiket görünümü. */
type PillTone = "ok" | "warn" | "plain";

/** Hesap kartlarında gösterilecek değerler. */
interface AccountView {
  readonly plan: string;
  readonly planPill: { readonly text: string; readonly tone: PillTone };
  readonly trial: string;
  readonly hours: string;
  readonly hoursUsed: number;
  readonly hoursCap: number;
  readonly subscription: string;
  readonly subscriptionPill: { readonly text: string; readonly tone: PillTone } | null;
  readonly canSubscribe: boolean;
  readonly canManage: boolean;
}

/** Tarihi sayfa dilinde yazar. Saf fonksiyondur. */
function formatDate(iso: string, lang: Lang): string {
  return new Intl.DateTimeFormat(lang, { dateStyle: "long" }).format(new Date(iso));
}

/** Saati sayfa dilinde (en çok bir ondalık) yazar. Saf fonksiyondur. */
function formatHours(hours: number, lang: Lang): string {
  return new Intl.NumberFormat(lang, { maximumFractionDigits: 1 }).format(hours);
}

/** Sunucu yanıtından gösterilecek değerleri üretir. Saf fonksiyondur. */
export function accountView(me: Entitlements, text: ClientCopy, lang: Lang): AccountView {
  const subscription: SubscriptionInfo | null = me.subscription;
  const subscribed: boolean = me.plan === "subscription";
  let subscriptionText: string = text.subscriptionNone;
  let subscriptionPill: AccountView["subscriptionPill"] = null;
  if (subscription !== null && subscription.access === "active") {
    subscriptionText = fill(text.subscriptionActive, { date: formatDate(subscription.currentPeriodEnd, lang) });
    subscriptionPill = { text: text.pillActive, tone: "ok" };
  } else if (subscription !== null && subscription.access === "grace") {
    subscriptionText = fill(text.subscriptionGrace, { date: formatDate(subscription.graceEndsAt, lang) });
    subscriptionPill = { text: text.pillGrace, tone: "warn" };
  } else if (subscription !== null) {
    subscriptionText = text.subscriptionEnded;
    subscriptionPill = { text: text.pillEnded, tone: "plain" };
  }
  return {
    plan: subscribed ? text.plan.subscription : text.plan.trial,
    planPill: subscribed ? { text: text.pillActive, tone: "ok" } : { text: text.pillTrial, tone: "plain" },
    trial: subscribed ? text.trialNotUsed : fill(text.trialLeft, { left: String(me.trialMeetingsLeft), total: String(me.trialMeetingsTotal) }),
    hours: fill(text.hours, { used: formatHours(me.monthlyHoursUsed, lang), cap: formatHours(me.monthlyHoursCap, lang) }),
    hoursUsed: Math.min(me.monthlyHoursUsed, me.monthlyHoursCap),
    hoursCap: me.monthlyHoursCap,
    subscription: subscriptionText,
    subscriptionPill,
    canSubscribe: !subscribed,
    canManage: subscription !== null,
  };
}

/** Etiketi günceller. */
function renderPill(pill: HTMLElement, value: { readonly text: string; readonly tone: PillTone } | null): void {
  pill.classList.toggle("hidden", value === null);
  pill.classList.toggle("pill--ok", value?.tone === "ok");
  pill.classList.toggle("pill--warn", value?.tone === "warn");
  pill.textContent = value?.text ?? "";
}

/** Değerleri sayfaya yazar. */
function render(view: AccountView): void {
  element("plan-value", HTMLElement).textContent = view.plan;
  renderPill(element("plan-pill", HTMLElement), view.planPill);
  element("trial-value", HTMLElement).textContent = view.trial;
  element("hours-value", HTMLElement).textContent = view.hours;
  const meter: HTMLProgressElement = element("hours-meter", HTMLProgressElement);
  meter.max = view.hoursCap;
  meter.value = view.hoursUsed;
  meter.textContent = view.hours;
  element("subscription-value", HTMLElement).textContent = view.subscription;
  renderPill(element("subscription-pill", HTMLElement), view.subscriptionPill);
  element("subscribe-button", HTMLButtonElement).classList.toggle("hidden", !view.canSubscribe);
  element("manage-button", HTMLButtonElement).classList.toggle("hidden", !view.canManage);
  element("subscribe-note", HTMLElement).classList.toggle("hidden", !view.canSubscribe);
}

/** `GET /v1/me`. */
async function fetchMe(): Promise<Entitlements> {
  const path: string = "/v1/me";
  const response: RawResponse = await authorizedSend({ method: "GET", path, body: null, attempts: 3 });
  return parseEntitlements(response, path);
}

/** Bekler. */
function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve: () => void): void => {
    setTimeout(resolve, milliseconds);
  });
}

/** Ödeme dönüşünde abonelik görünene dek (en çok `paymentPollAttempts` kez) yeniden bakar. */
async function fetchMeAfterPayment(): Promise<Entitlements> {
  let me: Entitlements = await fetchMe();
  for (let attempt: number = 1; attempt < paymentPollAttempts && me.plan !== "subscription"; attempt += 1) {
    await delay(paymentPollIntervalMs);
    me = await fetchMe();
  }
  return me;
}

/** Checkout ya da Portal adresini alıp oraya geçer. */
async function openBilling(path: "/v1/billing/checkout" | "/v1/billing/portal"): Promise<void> {
  const response: RawResponse = await authorizedSend({ method: "POST", path, body: {}, attempts: 1 });
  window.location.assign(parseRedirectUrl(response, path));
}

/** Abone ol: bitmemiş abonelik varsa sunucu 409 döner, Portal açılır. */
async function subscribe(): Promise<void> {
  try {
    await openBilling("/v1/billing/checkout");
  } catch (error: unknown) {
    if (error instanceof ApiRequestError && error.code === "subscription_exists") {
      await openBilling("/v1/billing/portal");
      return;
    }
    throw error;
  }
}

/** Düğmeye uzun süren bir işlem bağlar: süre boyunca düğme kapalı, hata bildirimde. */
function bindAction(button: HTMLButtonElement, notice: HTMLElement, text: ClientCopy, signInPath: string, action: () => Promise<void>): void {
  button.addEventListener("click", (): void => {
    hideNotice(notice);
    button.disabled = true;
    action()
      .catch((error: unknown): void => {
        if (error instanceof SignedOutError) {
          window.location.replace(signInPath);
          return;
        }
        showNotice(notice, errorText(error, text));
      })
      .finally((): void => {
        button.disabled = false;
      });
  });
}

/** Silme penceresini bağlar: onay kelimesi yazılınca silme düğmesi açılır. */
function bindDeletion(text: ClientCopy, signInPath: string): void {
  const dialog: HTMLDialogElement = element("delete-dialog", HTMLDialogElement);
  const input: HTMLInputElement = element("confirm-input", HTMLInputElement);
  const confirm: HTMLButtonElement = element("confirm-delete", HTMLButtonElement);
  const dialogNotice: HTMLElement = element("delete-error", HTMLElement);
  const confirmWord: string = dataValue(dialog, "confirmWord");

  element("delete-button", HTMLButtonElement).addEventListener("click", (): void => {
    input.value = "";
    confirm.disabled = true;
    hideNotice(dialogNotice);
    dialog.showModal();
  });
  element("cancel-delete", HTMLButtonElement).addEventListener("click", (): void => {
    dialog.close();
  });
  input.addEventListener("input", (): void => {
    confirm.disabled = input.value.trim().toLocaleUpperCase(pageLang()) !== confirmWord;
  });
  bindAction(confirm, dialogNotice, text, signInPath, async (): Promise<void> => {
    await authorizedSend({ method: "DELETE", path: "/v1/me", body: null, attempts: 1 });
    clearSession();
    dialog.close();
    element("account-content", HTMLElement).classList.add("hidden");
    const deleted: HTMLElement = element("account-deleted", HTMLElement);
    deleted.classList.remove("hidden");
    deleted.focus();
  });
}

/** Sayfayı başlatır. */
async function main(): Promise<void> {
  const root: HTMLElement = element("account", HTMLElement);
  const signInPath: string = dataValue(root, "signInPath");
  const notice: HTMLElement = element("account-error", HTMLElement);
  const text: ClientCopy = pageCopy();
  const lang: Lang = pageLang();
  if (!hasSession()) {
    window.location.replace(signInPath);
    return;
  }
  const params: URLSearchParams = new URLSearchParams(window.location.search);
  const paymentDone: boolean = params.get("odeme") === "tamam";
  if (paymentDone) {
    element("payment-done", HTMLElement).classList.remove("hidden");
    history.replaceState(null, "", window.location.pathname);
  }

  bindAction(element("subscribe-button", HTMLButtonElement), notice, text, signInPath, subscribe);
  bindAction(element("manage-button", HTMLButtonElement), notice, text, signInPath, (): Promise<void> => openBilling("/v1/billing/portal"));
  bindAction(element("signout-button", HTMLButtonElement), notice, text, signInPath, async (): Promise<void> => {
    try {
      await signOut();
    } finally {
      window.location.assign(dataValue(root, "homePath"));
    }
  });
  bindDeletion(text, signInPath);

  try {
    const me: Entitlements = paymentDone ? await fetchMeAfterPayment() : await fetchMe();
    render(accountView(me, text, lang));
    element("account-loading", HTMLElement).classList.add("hidden");
    element("account-content", HTMLElement).classList.remove("hidden");
  } catch (error: unknown) {
    if (error instanceof SignedOutError) {
      window.location.replace(signInPath);
      return;
    }
    element("account-loading", HTMLElement).classList.add("hidden");
    showNotice(notice, errorText(error, text));
  }
}

void main();
