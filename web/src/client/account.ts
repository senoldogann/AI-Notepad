// Hesap sayfası: `/v1/me`'den tek plan kartı (plan adı ve durum etiketi; cümle gerektiren durumda tek ileti satırı,
// tarihler için etiket/değer satırları; denemede kalan toplantı ya da abonede aylık saat ölçeri; ödeme alınamadıysa
// eylemin yanında uyarı ve duruma uyan eylem: Abone ol, Aboneliği yönet ya da ücretsiz erişimde hiçbiri). Hesap
// yüklenemezse hata ve yeniden deneme düğmesi görünür. Abone olurken plan seçimi (yıllık seçili) ve davet kodu
// (`POST /v1/referral/validate`) Checkout'a taşınır; abonenin davet kartı `GET /v1/referral`'dan; çıkış ve onaylı hesap
// silme (`DELETE /v1/me`). Adresteki `?plan=`, `?code=` ve `?checkout=1` (fiyat ve davet sayfalarından) girişten önce
// saklanır; oturum yoksa giriş sayfasına geçilir. Plan seçimi tarayıcıda kalıcıdır (giriş başka bir sekmede bitse de
// kaybolmaz); `?checkout=1` niyeti giriş bitince hesap sayfasını doğrudan Stripe Checkout'a gönderir.
import {
  ApiRequestError,
  type Entitlements,
  type JsonObject,
  type RawResponse,
  type ReferralInfo,
  type SubscriptionInfo,
  parseEntitlements,
  parseRedirectUrl,
  parseReferral,
  parseValidatedReferralCode,
} from "./api";
import {
  checkoutIntended,
  forgetCheckoutIntent,
  forgetInviteCode,
  forgetPlan,
  storeCheckoutIntent,
  storeInviteCode,
  storePlan,
  storedInviteCode,
  storedPlan,
} from "./checkout-choice";
import { type ClientCopy, clientCopy, fill } from "./copy";
import { dataValue, element, errorText, hideNotice, showNotice } from "./dom";
import { SignedOutError, authorizedSend, claimTabSession, clearSession, hasSession, signOut } from "./session";
import { siteLocale } from "../config";
import { type BillingPlan, billingPlanOf, normalizedInviteCode, recommendedPlan } from "../lib/plans";

/** Ödeme dönüşünde aboneliğin görünmesi için en çok kaç kez, kaç ms arayla yeniden bakılır (webhook gecikmesi). */
const paymentPollAttempts: number = 6;
const paymentPollIntervalMs: number = 2000;
/** Ödeme bildirimi bu kadar görünür kalır, sonra solup kaybolur. */
const paymentNoticeMs: number = 6000;
/** Solma süresi (global.css `.notice--fading`). */
const noticeFadeMs: number = 400;
/** Hesap silinince ana sayfaya geçmeden önce bekleme. */
const deletedRedirectMs: number = 3000;

/** Etiket görünümü. */
type PillTone = "ok" | "warn" | "plain";

/** Başlıktaki plan durumu etiketi. */
interface Pill {
  readonly text: string;
  readonly tone: PillTone;
}

/** Plan kartının bir etiket/değer satırı (ör. "Renews" · "30 November 2026"). */
interface Fact {
  readonly label: string;
  readonly value: string;
}

/** Plan kartının durumu: cümle gerektiren durumda ileti (yoksa null) ve etiket/değer satırları (boş olabilir). */
interface PlanStatus {
  readonly message: string | null;
  readonly facts: readonly Fact[];
}

/** Sürmekte olan denemenin göstergesi: değer metni ("2 of 3"), kalan ve toplam toplantı, son toplantıda uyarı. */
interface TrialMeter {
  readonly text: string;
  readonly left: number;
  readonly total: number;
  readonly warn: boolean;
}

/**
 * Abonenin aylık saat göstergesi: değer metni ("3.4 / 10.0 hours"), kullanılan (sınırda kesilir), sınır, sınırın
 * %80'inde uyarı, ikincil değer (kalan saat) ve sınır dolduysa sıfırlanma günlü uyarı satırı (dolmadıysa null).
 */
interface HoursMeter {
  readonly text: string;
  readonly used: number;
  readonly cap: number;
  readonly warn: boolean;
  readonly left: string;
  readonly limitReached: string | null;
}

/** Deneme durumu: başlamadı, sürüyor ya da bitti (toplantılar harcandı veya süre doldu). */
type TrialPhase = "notStarted" | "running" | "ended";

/** Hesap sayfasında gösterilecek değerler. */
interface AccountView {
  readonly plan: string;
  readonly planPill: Pill;
  /** Plan kartının ileti satırı ve etiket/değer satırları: abonelik durumu ya da deneme. */
  readonly status: PlanStatus;
  /** Deneme sürüyorsa kalan toplantı göstergesi; yoksa null. */
  readonly trialMeter: TrialMeter | null;
  /** Aylık saat yalnızca abonelik erişiminde görünür (sınır aboneliğindir; denemede kafa karıştırır); yoksa null. */
  readonly hours: HoursMeter | null;
  /** Ödeme alınamadıysa (ek süre ya da süresi geçmiş ödeme) Aboneliği yönet düğmesinin yanındaki uyarı; yoksa null. */
  readonly alert: string | null;
  readonly canSubscribe: boolean;
  readonly canManage: boolean;
}

/** Saat ölçeri kullanımın bu oranından sonra uyarır. */
const hoursWarnRatio: number = 0.8;
/** Deneme ölçeri bu kadar toplantı kalınca uyarır. */
const trialWarnMeetingsLeft: number = 1;

/** Tarihi sitenin yerel ayarında, tarayıcının saat diliminde yazar. Saf fonksiyondur. */
function formatDate(iso: string, locale: string): string {
  return new Intl.DateTimeFormat(locale, { dateStyle: "long" }).format(new Date(iso));
}

/** Tarihi sitenin yerel ayarında, UTC'de yazar (aylık sınır UTC ayının başında sıfırlanır). Saf fonksiyondur. */
function formatUtcDate(iso: string, locale: string): string {
  return new Intl.DateTimeFormat(locale, { dateStyle: "long", timeZone: "UTC" }).format(new Date(iso));
}

/** Saati sitenin yerel ayarında hep bir ondalıkla yazar (değer değişince genişlik oynamaz). Saf fonksiyondur. */
function formatHours(hours: number, locale: string): string {
  return new Intl.NumberFormat(locale, { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(hours);
}

/** Deneme durumu (bkz. `TrialPhase`). Saf fonksiyondur. */
function trialPhase(me: Entitlements, now: Date): TrialPhase {
  if (me.trialEndsAt === null) {
    return "notStarted";
  }
  return me.trialMeetingsLeft === 0 || new Date(me.trialEndsAt).getTime() <= now.getTime() ? "ended" : "running";
}

/**
 * Plan kartı aboneliği mi anlatır: abonelik erişimi varsa ya da abonelik (ücretli ya da ücretsiz erişim) bitmiş ve
 * deneme de kalmamışsa. Bitmiş abonelikte deneme hâlâ kullanılabiliyorsa kart denemeyi anlatır. Saf fonksiyondur.
 */
function describesSubscription(me: Entitlements, now: Date): boolean {
  return me.subscription !== null && (me.plan === "subscription" || trialPhase(me, now) === "ended");
}

/**
 * Planın adı: abonelik erişiminde aylık, yıllık, ücretsiz erişim ya da (fiyat tanınmıyorsa) yalnızca ürün adı;
 * aboneliği bitmiş ve denemesi kalmamış hesapta "plan yok"; diğerlerinde deneme. Saf fonksiyondur.
 */
function planName(me: Entitlements, text: ClientCopy, now: Date): string {
  const subscription: SubscriptionInfo | null = me.subscription;
  if (me.plan === "subscription" && subscription !== null) {
    if (subscription.complimentary) {
      return text.plan.complimentary;
    }
    return subscription.plan === null ? text.plan.subscription : text.plan[subscription.plan];
  }
  return describesSubscription(me, now) ? text.plan.none : text.plan.trial;
}

/**
 * Denemenin durumu: başlamadıysa kapsamı ve başlangıcı, sürüyorsa bitiş tarihi (kalan toplantı ölçerdedir) satır
 * olarak; bittiyse ileti. Saf fonksiyondur.
 */
function trialStatus(me: Entitlements, text: ClientCopy, locale: string, now: Date): PlanStatus {
  const phase: TrialPhase = trialPhase(me, now);
  if (phase === "notStarted" || me.trialEndsAt === null) {
    return {
      message: null,
      facts: [
        { label: text.facts.trialIncludes, value: fill(text.facts.trialIncludesValue, { total: String(me.trialMeetingsTotal), days: String(me.trialDays) }) },
        { label: text.facts.trialStarts, value: text.facts.trialStartsValue },
      ],
    };
  }
  if (phase === "ended") {
    return { message: text.trialEnded, facts: [] };
  }
  return { message: null, facts: [{ label: text.facts.trialEnds, value: formatDate(me.trialEndsAt, locale) }] };
}

/**
 * Aboneliğin durumu. Ücretsiz erişimde ödeme ve yenileme yoktur: ileti yazılır (bitiş tarihi varsa onunla), bittiyse
 * "ücretsiz erişim bitti" (abonelik bitti değil: hiç ödeme yapılmadı). Etkin, iptal edilmiş ve ek süredeki abonelik
 * tarihleri satır olarak gösterir; ödeme alınamadıysa neden eylemin yanındaki uyarıdadır (`paymentAlert`). Saf
 * fonksiyondur.
 */
function subscriptionStatus(subscription: SubscriptionInfo, text: ClientCopy, locale: string): PlanStatus {
  if (subscription.complimentary) {
    if (subscription.access === "none") {
      return { message: text.subscriptionComplimentaryEnded, facts: [] };
    }
    const message: string =
      subscription.cancelAt === null ? text.subscriptionComplimentary : fill(text.subscriptionComplimentaryUntil, { date: formatDate(subscription.cancelAt, locale) });
    return { message, facts: [] };
  }
  if (subscription.access === "active" && subscription.cancelAt !== null) {
    return {
      message: null,
      facts: [
        { label: text.facts.renewal, value: text.facts.renewalCancelled },
        { label: text.facts.accessUntil, value: formatDate(subscription.cancelAt, locale) },
      ],
    };
  }
  if (subscription.access === "active") {
    return { message: null, facts: [{ label: text.facts.renews, value: formatDate(subscription.currentPeriodEnd, locale) }] };
  }
  if (subscription.access === "grace") {
    return { message: null, facts: [{ label: text.facts.accessUntil, value: formatDate(subscription.graceEndsAt, locale) }] };
  }
  if (isPaymentOverdue(subscription)) {
    return { message: null, facts: [] };
  }
  return { message: text.subscriptionEnded, facts: [] };
}

/**
 * Yenileme ödemesi alınamadı ve ek süre bitti mi: Stripe'ta abonelik sürer (`past_due`/`unpaid`), erişim yok; kart
 * "Manage subscription"dan güncellenince erişim döner. Saf fonksiyondur.
 */
function isPaymentOverdue(subscription: SubscriptionInfo): boolean {
  return subscription.access === "none" && !subscription.complimentary && (subscription.status === "past_due" || subscription.status === "unpaid");
}

/** Ödeme alınamadıysa Aboneliği yönet düğmesinin yanındaki uyarı: ek sürede ya da süresi geçmiş ödemede. Saf fonksiyondur. */
function paymentAlert(subscription: SubscriptionInfo | null, text: ClientCopy): string | null {
  if (subscription === null || subscription.complimentary) {
    return null;
  }
  if (subscription.access === "grace") {
    return text.subscriptionGraceAlert;
  }
  return isPaymentOverdue(subscription) ? text.subscriptionPaymentOverdue : null;
}

/** Plan kartının durumu: abonelik anlatılıyorsa abonelik, değilse deneme. Saf fonksiyondur. */
function planStatus(me: Entitlements, text: ClientCopy, locale: string, now: Date): PlanStatus {
  return me.subscription !== null && describesSubscription(me, now) ? subscriptionStatus(me.subscription, text, locale) : trialStatus(me, text, locale, now);
}

/**
 * Plan adının yanındaki durum etiketi: ücretsiz erişim (bitiş tarihi olsa da "bitiyor" uyarısı değil), ek süre,
 * iptal edilmiş, etkin; abonelik erişimi yoksa bitmiş ya da deneme. Saf fonksiyondur.
 */
function planPill(me: Entitlements, text: ClientCopy, now: Date): Pill {
  const subscription: SubscriptionInfo | null = me.subscription;
  if (me.plan === "subscription" && subscription !== null) {
    if (subscription.complimentary) {
      return { text: text.pillComplimentary, tone: "ok" };
    }
    if (subscription.access === "grace") {
      return { text: text.pillGrace, tone: "warn" };
    }
    if (subscription.cancelAt !== null) {
      return { text: text.pillCanceling, tone: "warn" };
    }
    return { text: text.pillActive, tone: "ok" };
  }
  if (subscription !== null && isPaymentOverdue(subscription)) {
    return { text: text.pillGrace, tone: "warn" };
  }
  return trialPhase(me, now) === "ended" ? { text: text.pillEnded, tone: "plain" } : { text: text.pillTrial, tone: "plain" };
}

/** Sürmekte olan denemenin ölçeri: son toplantıda uyarır. Saf fonksiyondur. */
function trialMeter(me: Entitlements, text: ClientCopy): TrialMeter {
  return {
    text: fill(text.trialMeetings, { left: String(me.trialMeetingsLeft), total: String(me.trialMeetingsTotal) }),
    left: me.trialMeetingsLeft,
    total: me.trialMeetingsTotal,
    warn: me.trialMeetingsLeft <= trialWarnMeetingsLeft,
  };
}

/** Abonenin aylık saat ölçeri: sınırın %80'inde uyarır; sınır dolunca sıfırlanma günü (UTC) yazılır. Saf fonksiyondur. */
function hoursMeter(me: Entitlements, text: ClientCopy, locale: string): HoursMeter {
  const cap: number = me.monthlyHoursCap;
  const used: number = me.monthlyHoursUsed;
  return {
    text: fill(text.hours, { used: formatHours(used, locale), cap: formatHours(cap, locale) }),
    used: Math.min(used, cap),
    cap,
    warn: used >= cap * hoursWarnRatio,
    left: fill(text.hoursLeft, { left: formatHours(Math.max(cap - used, 0), locale) }),
    limitReached: used >= cap ? fill(text.hoursLimitReached, { date: formatUtcDate(me.monthlyResetsAt, locale) }) : null,
  };
}

/**
 * Sunucu yanıtından gösterilecek değerleri üretir. Aboneliği yönetme yalnızca Stripe'ta karşılığı olan (ücretsiz erişim
 * olmayan) abonelikte vardır: ücretsiz erişim bitmiş olsa da Portal'da yönetilecek bir şey yoktur. Saf fonksiyondur.
 */
export function accountView(me: Entitlements, text: ClientCopy, locale: string, now: Date): AccountView {
  const subscribed: boolean = me.plan === "subscription";
  return {
    plan: planName(me, text, now),
    planPill: planPill(me, text, now),
    status: planStatus(me, text, locale, now),
    trialMeter: !subscribed && trialPhase(me, now) === "running" ? trialMeter(me, text) : null,
    hours: subscribed ? hoursMeter(me, text, locale) : null,
    alert: paymentAlert(me.subscription, text),
    canSubscribe: !subscribed,
    canManage: me.subscription !== null && !me.subscription.complimentary,
  };
}

/** Etiketi günceller. */
function renderPill(pill: HTMLElement, value: Pill): void {
  pill.classList.remove("hidden");
  pill.classList.toggle("pill--ok", value.tone === "ok");
  pill.classList.toggle("pill--warn", value.tone === "warn");
  pill.textContent = value.text;
}

/** Plan kartının ileti satırını ve etiket/değer satırlarını yazar; boş olan gizlenir. */
function renderStatus(status: PlanStatus): void {
  const message: HTMLElement = element("plan-status", HTMLElement);
  message.classList.toggle("hidden", status.message === null);
  message.textContent = status.message ?? "";
  const facts: HTMLElement = element("plan-facts", HTMLElement);
  facts.classList.toggle("hidden", status.facts.length === 0);
  facts.replaceChildren(
    ...status.facts.flatMap((fact: Fact): HTMLElement[] => {
      const label: HTMLElement = document.createElement("dt");
      label.textContent = fact.label;
      const value: HTMLElement = document.createElement("dd");
      value.textContent = fact.value;
      return [label, value];
    }),
  );
}

/** Ölçerleri yazar: deneme ölçeri ve abonenin saat bloğu, olmayan gizlenir; sınıra yaklaşan ölçer sarıdır. */
function renderMeters(trial: TrialMeter | null, hours: HoursMeter | null): void {
  element("trial-card", HTMLElement).classList.toggle("hidden", trial === null);
  if (trial !== null) {
    element("trial-value", HTMLElement).textContent = trial.text;
    const trialMeter: HTMLProgressElement = element("trial-meter", HTMLProgressElement);
    trialMeter.max = trial.total;
    trialMeter.value = trial.left;
    trialMeter.textContent = trial.text;
    trialMeter.classList.toggle("meter--warn", trial.warn);
  }
  element("hours-card", HTMLElement).classList.toggle("hidden", hours === null);
  if (hours !== null) {
    element("hours-value", HTMLElement).textContent = hours.text;
    const meter: HTMLProgressElement = element("hours-meter", HTMLProgressElement);
    meter.max = hours.cap;
    meter.value = hours.used;
    meter.textContent = hours.text;
    meter.classList.toggle("meter--warn", hours.warn);
    element("hours-left", HTMLElement).textContent = hours.left;
    element("hours-foot", HTMLElement).classList.toggle("hidden", hours.limitReached !== null);
    const limit: HTMLElement = element("hours-limit", HTMLElement);
    limit.classList.toggle("hidden", hours.limitReached === null);
    limit.textContent = hours.limitReached ?? "";
  }
}

/** Değerleri sayfaya yazar. */
function render(view: AccountView): void {
  element("plan-value", HTMLElement).textContent = view.plan;
  renderPill(element("plan-pill", HTMLElement), view.planPill);
  renderStatus(view.status);
  renderMeters(view.trialMeter, view.hours);
  const alert: HTMLElement = element("plan-alert", HTMLElement);
  alert.classList.toggle("hidden", view.alert === null);
  alert.textContent = view.alert ?? "";
  element("subscribe-button", HTMLButtonElement).classList.toggle("hidden", !view.canSubscribe);
  element("plan-choice", HTMLElement).classList.toggle("hidden", !view.canSubscribe);
  element("invite", HTMLElement).classList.toggle("hidden", !view.canSubscribe);
  element("manage-button", HTMLButtonElement).classList.toggle("hidden", !view.canManage);
  element("subscribe-note", HTMLElement).classList.toggle("hidden", !view.canSubscribe);
  element("manage-note", HTMLElement).classList.toggle("hidden", view.canSubscribe || !view.canManage);
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
async function openBilling(path: "/v1/billing/checkout" | "/v1/billing/portal", body: JsonObject): Promise<void> {
  const response: RawResponse = await authorizedSend({ method: "POST", path, body, attempts: 1 });
  window.location.assign(parseRedirectUrl(response, path));
}

/** Checkout gövdesi: seçilen plan ve (doğrulanmışsa) davet kodu. Saf fonksiyondur. */
export function checkoutBody(plan: BillingPlan, referralCode: string | null): JsonObject {
  return referralCode === null ? { plan } : { plan, referralCode };
}

/** Davet hatasının kodu (sunucunun `referral_*` kodları); başka hata null. Saf fonksiyondur. */
function inviteErrorCode(error: unknown): keyof ClientCopy["inviteErrors"] | null {
  if (!(error instanceof ApiRequestError)) {
    return null;
  }
  const codes: readonly (keyof ClientCopy["inviteErrors"])[] = ["referral_invalid", "referral_self", "referral_not_eligible", "referral_unavailable", "referral_limit_reached"];
  return codes.find((code: keyof ClientCopy["inviteErrors"]): boolean => code === error.code) ?? null;
}

/** Plan seçimi ve davet kodu alanının durumu (sayfa ömrünce). */
interface CheckoutForm {
  /** Sunucunun doğruladığı kod; yoksa null. */
  validatedCode: string | null;
}

/** Seçili plan (radyo düğmeleri; biri her zaman seçilidir). */
function selectedPlan(): BillingPlan {
  const checked: HTMLInputElement | null = document.querySelector<HTMLInputElement>('#plan-choice input[name="plan"]:checked');
  const plan: BillingPlan | null = billingPlanOf(checked === null ? null : checked.value);
  if (plan === null) {
    throw new Error("Plan seçimi okunamadı: seçili radyo düğmesi yok.");
  }
  return plan;
}

/** Planı seçer. */
function selectPlan(plan: BillingPlan): void {
  const input: HTMLInputElement | null = document.querySelector<HTMLInputElement>(`#plan-choice input[name="plan"][value="${plan}"]`);
  if (input === null) {
    throw new Error(`Plan seçiminde "${plan}" düğmesi yok.`);
  }
  input.checked = true;
}

/** Davet durum satırını gösterir (`ok`: uygulandı, `error`: hata, `plain`: denetleniyor); metin null ise gizler. */
function showInviteStatus(message: string | null, tone: "ok" | "error" | "plain"): void {
  const status: HTMLElement = element("invite-status", HTMLElement);
  status.classList.toggle("hidden", message === null);
  status.classList.toggle("invite__ok", tone === "ok");
  status.classList.toggle("invite__error", tone === "error");
  status.textContent = message ?? "";
}

/** Uygulanan kodun satırını seçili plana göre yazar; kaldır düğmesi yalnızca kod uygulanınca görünür. */
function renderAppliedInvite(form: CheckoutForm, text: ClientCopy): void {
  element("invite-remove", HTMLButtonElement).classList.toggle("hidden", form.validatedCode === null);
  if (form.validatedCode !== null) {
    showInviteStatus(text.inviteApplied[selectedPlan()], "ok");
  }
}

/**
 * Alandaki kodu sunucuda doğrular. Geçerliyse kaydedilir ve true; biçimsiz ya da sunucu reddederse satırda neden yazar
 * ve false. Ağ ve beklenmeyen hatalar fırlatılır (düğmenin bildirimi gösterir).
 */
async function applyInvite(form: CheckoutForm, text: ClientCopy): Promise<boolean> {
  const input: HTMLInputElement = element("invite-input", HTMLInputElement);
  form.validatedCode = null;
  renderAppliedInvite(form, text);
  const code: string | null = normalizedInviteCode(input.value);
  if (code === null) {
    showInviteStatus(text.inviteErrors.format, "error");
    return false;
  }
  showInviteStatus(text.inviteChecking, "plain");
  const path: string = "/v1/referral/validate";
  try {
    const response: RawResponse = await authorizedSend({ method: "POST", path, body: { code }, attempts: 1 });
    form.validatedCode = parseValidatedReferralCode(response, path);
  } catch (error: unknown) {
    const reason: keyof ClientCopy["inviteErrors"] | null = inviteErrorCode(error);
    if (reason === null) {
      showInviteStatus(null, "plain");
      throw error;
    }
    if (reason !== "referral_unavailable" && reason !== "referral_limit_reached") {
      // Bu hesapta kullanılamayan kod saklanmaz: sonraki ziyarette yeniden denenmez (geçici redler saklanır).
      forgetInviteCode();
    }
    showInviteStatus(text.inviteErrors[reason], "error");
    return false;
  }
  input.value = form.validatedCode;
  storeInviteCode(form.validatedCode);
  renderAppliedInvite(form, text);
  return true;
}

/** Davet kodunu kaldırır: alan boşalır, kayıt silinir. */
function removeInvite(form: CheckoutForm, text: ClientCopy): void {
  form.validatedCode = null;
  element("invite-input", HTMLInputElement).value = "";
  forgetInviteCode();
  renderAppliedInvite(form, text);
  showInviteStatus(null, "plain");
}

/**
 * Alanda uygulanmış koddan farklı bir şey yazılı mı: boş değil ve biçimsiz ya da doğrulanan koddan farklı. Biçimsiz
 * metin de sayılır (yoksa yazım hatalı bir kod sessizce atlanır ve Checkout tam fiyatla açılır). Saf fonksiyondur.
 */
function hasUnappliedInvite(typed: string, validatedCode: string | null): boolean {
  if (typed === "") {
    return false;
  }
  const typedCode: string | null = normalizedInviteCode(typed);
  return typedCode === null || typedCode !== validatedCode;
}

/**
 * Abone ol: alanda uygulanmamış bir kod varsa önce doğrulanır; biçimsiz ya da geçersizse Checkout açılmaz, davet alanı
 * açılır ve satırda neden yazar. Bitmemiş abonelik varsa sunucu 409 döner, Portal açılır; Checkout davet kodunu
 * reddederse neden satırda yazar.
 */
async function subscribe(form: CheckoutForm, text: ClientCopy): Promise<void> {
  const typed: string = element("invite-input", HTMLInputElement).value.trim();
  if (hasUnappliedInvite(typed, form.validatedCode) && !(await applyInvite(form, text))) {
    element("invite", HTMLDetailsElement).open = true;
    return;
  }
  try {
    await openBilling("/v1/billing/checkout", checkoutBody(selectedPlan(), form.validatedCode));
  } catch (error: unknown) {
    if (error instanceof ApiRequestError && error.code === "subscription_exists") {
      await openBilling("/v1/billing/portal", {});
      return;
    }
    const reason: keyof ClientCopy["inviteErrors"] | null = inviteErrorCode(error);
    if (reason !== null) {
      form.validatedCode = null;
      renderAppliedInvite(form, text);
      element("invite", HTMLDetailsElement).open = true;
      showInviteStatus(text.inviteErrors[reason], "error");
      return;
    }
    throw error;
  }
}

/** Plan seçimini ve davet alanını bağlar; kayıtlı plan ve kod alanlara yazılır (kod sayfa açılınca doğrulanır). */
function bindCheckoutForm(form: CheckoutForm, text: ClientCopy, notice: HTMLElement, signInPath: string): void {
  selectPlan(storedPlan() ?? recommendedPlan);
  for (const input of Array.from(document.querySelectorAll<HTMLInputElement>('#plan-choice input[name="plan"]'))) {
    input.addEventListener("change", (): void => {
      storePlan(selectedPlan());
      renderAppliedInvite(form, text);
    });
  }
  bindAction(element("invite-apply", HTMLButtonElement), notice, text, signInPath, async (): Promise<void> => {
    await applyInvite(form, text);
  });
  element("invite-remove", HTMLButtonElement).addEventListener("click", (): void => {
    removeInvite(form, text);
  });
  element("invite-input", HTMLInputElement).addEventListener("keydown", (event: KeyboardEvent): void => {
    if (event.key === "Enter") {
      event.preventDefault();
      element("invite-apply", HTMLButtonElement).click();
    }
  });
}

/** Kayıtlı davet kodu varsa alanı açar, kodu yazar ve doğrular (abone olabilen hesapta). */
async function prefillInvite(form: CheckoutForm, text: ClientCopy): Promise<void> {
  const code: string | null = storedInviteCode();
  if (code === null) {
    return;
  }
  element("invite", HTMLDetailsElement).open = true;
  element("invite-input", HTMLInputElement).value = code;
  await applyInvite(form, text);
}

/** `GET /v1/referral`. */
async function fetchReferral(): Promise<ReferralInfo> {
  const path: string = "/v1/referral";
  const response: RawResponse = await authorizedSend({ method: "GET", path, body: null, attempts: 3 });
  return parseReferral(response, path);
}

/** Davet kartının bir sayısı: etiket, değer ve (bu yıl kalan ödülde) yıllık sınır metni; sınır yoksa null. */
interface ReferralStat {
  readonly label: string;
  readonly value: string;
  readonly cap: string | null;
}

/** Davet kartının değerleri: sayı satırı (boş olabilir) ve altındaki kısa not (yoksa null). */
interface ReferralView {
  readonly stats: readonly ReferralStat[];
  readonly note: string | null;
}

/**
 * Davet kartının değerleri. Davetin ücretsiz ilk ayındaki hesapta sunucu kod vermez: sayı yok, not kodun ilk ücretli
 * aydan sonra açılacağını söyler. Ücretsiz erişimli hesapta arkadaşlar yine davet indirimini alır, ama ödenecek fatura
 * olmadığından 5,99 $ ödülü uygulanmaz (sunucu `referrer_complimentary` ile düşürür): yalnızca katılanlar ve bunu
 * anlatan not. Diğerlerinde dört sayı ve bekleyen ödül varsa en yakınının tahmini tarihi. Saf fonksiyondur.
 */
function referralView(referral: ReferralInfo, text: ClientCopy, locale: string): ReferralView {
  if (referral.code === null || referral.inviteUrl === null) {
    return { stats: [], note: text.referralCodeAfterFirstPayment };
  }
  const joined: ReferralStat = { label: text.referralStats.joined, value: String(referral.joined), cap: null };
  if (referral.complimentary) {
    return { stats: [joined], note: text.referralComplimentaryNote };
  }
  return {
    stats: [
      joined,
      { label: text.referralStats.rewarded, value: String(referral.rewarded), cap: null },
      { label: text.referralStats.pending, value: String(referral.pending), cap: null },
      {
        label: text.referralStats.left,
        value: String(referral.rewardsLeftThisYear),
        cap: fill(text.referralStats.ofCap, { cap: String(referral.rewardsPerYear) }),
      },
    ],
    note: referral.nextRewardAt === null ? null : fill(text.referralNextReward, { date: formatDate(referral.nextRewardAt, locale) }),
  };
}

/** Davet kartının sayı satırını ve notunu yazar; boş olan gizlenir. */
function renderReferralView(view: ReferralView): void {
  const stats: HTMLElement = element("referral-stats", HTMLElement);
  stats.classList.toggle("hidden", view.stats.length === 0);
  stats.replaceChildren(
    ...view.stats.map((stat: ReferralStat): HTMLElement => {
      const item: HTMLElement = document.createElement("div");
      item.className = "stat";
      const label: HTMLElement = document.createElement("dt");
      label.className = "stat__label";
      label.textContent = stat.label;
      const value: HTMLElement = document.createElement("dd");
      value.className = "stat__value";
      value.textContent = stat.value;
      if (stat.cap !== null) {
        const cap: HTMLElement = document.createElement("span");
        cap.className = "stat__cap";
        cap.textContent = ` ${stat.cap}`;
        value.append(cap);
      }
      item.append(label, value);
      return item;
    }),
  );
  const note: HTMLElement = element("referral-note", HTMLElement);
  note.classList.toggle("hidden", view.note === null);
  note.textContent = view.note ?? "";
}

/** Davet kartını çizer: program açık ve kod varsa (abonelik erişimi) paylaşım alanıyla, kod yoksa yalnızca notla görünür. */
function renderReferral(referral: ReferralInfo, text: ClientCopy, locale: string, notice: HTMLElement): void {
  const card: HTMLElement = element("referral-card", HTMLElement);
  const share: HTMLElement = element("referral-share", HTMLElement);
  const inviteUrl: string | null = referral.inviteUrl;
  if (!referral.enabled) {
    card.classList.add("hidden");
    return;
  }
  renderReferralView(referralView(referral, text, locale));
  if (referral.code === null || inviteUrl === null) {
    share.classList.add("hidden");
    card.classList.remove("hidden");
    return;
  }
  share.classList.remove("hidden");
  element("referral-code", HTMLElement).textContent = referral.code;
  const copied: HTMLElement = element("referral-copied", HTMLElement);
  const button: HTMLButtonElement = element("referral-copy", HTMLButtonElement);
  button.onclick = (): void => {
    hideNotice(notice);
    navigator.clipboard
      .writeText(inviteUrl)
      .then((): void => {
        copied.classList.remove("hidden");
      })
      .catch((error: unknown): void => {
        console.error("invite_link_copy_failed", { error: error instanceof Error ? error.message : String(error) });
        showNotice(notice, fill(text.errors.generic, { code: "clipboard" }));
      });
  };
  card.classList.remove("hidden");
}

/** Abonenin davet kartını yükler; yüklenemezse kart gizli kalır ve hata konsola yazılır (hesabın geri kalanı çalışır). */
async function loadReferral(text: ClientCopy, notice: HTMLElement): Promise<void> {
  try {
    const referral: ReferralInfo = await fetchReferral();
    renderReferral(referral, text, siteLocale, notice);
  } catch (error: unknown) {
    if (error instanceof SignedOutError) {
      throw error;
    }
    console.error("referral_load_failed", { error: error instanceof Error ? error.message : String(error) });
    element("referral-card", HTMLElement).classList.add("hidden");
  }
}

/**
 * Adresteki `?plan=` ve `?code=` seçimlerini saklar (girişe yönlendirmeden önce; sorgu adresten silinir). Biçimsiz kod
 * saklanmaz.
 */
function rememberQueryChoices(params: URLSearchParams): boolean {
  const plan: BillingPlan | null = billingPlanOf(params.get("plan"));
  const rawCode: string | null = params.get("code");
  const code: string | null = rawCode === null ? null : normalizedInviteCode(rawCode);
  const checkout: boolean = params.get("checkout") === "1";
  if (plan !== null) {
    storePlan(plan);
  }
  if (code !== null) {
    storeInviteCode(code);
  }
  if (checkout) {
    // Fiyat sayfasındaki plan düğmesi: seçim yapıldı, ödeme sayfasına gidilecek (giriş gerekirse sonra).
    storeCheckoutIntent();
  }
  return params.has("plan") || params.has("code") || checkout;
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

/** Ödeme bildirimini gösterir; `paymentNoticeMs` sonra solar ve gizlenir. */
function showPaymentNotice(): void {
  const notice: HTMLElement = element("payment-done", HTMLElement);
  notice.classList.remove("hidden");
  setTimeout((): void => {
    notice.classList.add("notice--fading");
    setTimeout((): void => {
      notice.classList.add("hidden");
    }, noticeFadeMs);
  }, paymentNoticeMs);
}

/**
 * Silme penceresini bağlar: onay kelimesi yazılınca silme düğmesi açılır. Alanda Enter, pencereyi kapatan örtük form
 * gönderimi (`method="dialog"`) yerine silme düğmesine basar (düğme kapalıysa hiçbir şey olmaz); Escape pencereyi kapatır.
 */
function bindDeletion(text: ClientCopy, signInPath: string, homePath: string): void {
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
    confirm.disabled = input.value.trim().toUpperCase() !== confirmWord;
  });
  input.addEventListener("keydown", (event: KeyboardEvent): void => {
    if (event.key !== "Enter") {
      return;
    }
    event.preventDefault();
    if (!confirm.disabled) {
      confirm.click();
    }
  });
  bindAction(confirm, dialogNotice, text, signInPath, async (): Promise<void> => {
    await authorizedSend({ method: "DELETE", path: "/v1/me", body: null, attempts: 1 });
    clearSession();
    dialog.close();
    element("account-content", HTMLElement).classList.add("hidden");
    // Oturum yok: çıkış düğmesi de gizlenir.
    element("signout-button", HTMLButtonElement).classList.add("hidden");
    const deleted: HTMLElement = element("account-deleted", HTMLElement);
    deleted.classList.remove("hidden");
    deleted.focus();
    // Kısa bir süre "hesabın silindi" görünür, sonra ana sayfaya geçilir (elle dönüş bağlantısı da durur).
    setTimeout((): void => {
      window.location.assign(homePath);
    }, deletedRedirectMs);
  });
}

/** Oturumsuz ödeme dönüşü: yükleniyor ve hesap düğmeleri gizlenir, "ödeme alındı" kartı görünür. */
function showPaidSignedOut(): void {
  element("account-loading", HTMLElement).classList.add("hidden");
  element("signout-button", HTMLButtonElement).classList.add("hidden");
  element("payment-done-signed-out", HTMLElement).classList.remove("hidden");
}

/**
 * Yüklenen hesabı çizer ve sonrasını yürütür: abone olabilen hesapta kayıtlı davet kodu doğrulanır, abonede davet kartı
 * yüklenir, fiyat sayfasından gelen ödeme niyeti varsa Checkout açılır.
 */
async function showAccount(me: Entitlements, form: CheckoutForm, text: ClientCopy, notice: HTMLElement): Promise<void> {
  const view: AccountView = accountView(me, text, siteLocale, new Date());
  render(view);
  element("account-loading", HTMLElement).classList.add("hidden");
  element("account-content", HTMLElement).classList.remove("hidden");
  if (view.canSubscribe) {
    await prefillInvite(form, text);
  }
  if (me.plan === "subscription") {
    await loadReferral(text, notice);
  }
  // Fiyat sayfasından gelen ziyaretçi planını seçti ve giriş yaptı: artık doğrudan Ödeme sayfasına geçilir
  // (niyet yalnızca seçimin yapıldığı sekmede tutulur ve bir kez kullanılır).
  if (checkoutIntended()) {
    forgetCheckoutIntent();
    if (view.canSubscribe) {
      await subscribe(form, text);
    }
  }
}

/** Hesap sayfasının hatasını gösterir: oturum düştüyse giriş sayfasına geçilir, değilse "yükleniyor" gizlenip hata yazılır. */
function reportAccountError(error: unknown, text: ClientCopy, notice: HTMLElement, signInPath: string): void {
  if (error instanceof SignedOutError) {
    window.location.replace(signInPath);
    return;
  }
  element("account-loading", HTMLElement).classList.add("hidden");
  showNotice(notice, errorText(error, text));
}

/**
 * Hesabı `fetchAccount` ile okuyup gösterir. Okunamazsa hatanın altında yeniden deneme düğmesi de görünür (oturum
 * düşmediyse); gösterdikten sonraki bir hata (davet kodu, Checkout) yalnızca bildirimde yazar.
 */
async function loadAccount(fetchAccount: () => Promise<Entitlements>, form: CheckoutForm, text: ClientCopy, notice: HTMLElement, signInPath: string): Promise<void> {
  let me: Entitlements;
  try {
    me = await fetchAccount();
  } catch (error: unknown) {
    reportAccountError(error, text, notice, signInPath);
    element("account-retry", HTMLButtonElement).classList.toggle("hidden", error instanceof SignedOutError);
    return;
  }
  try {
    await showAccount(me, form, text, notice);
  } catch (error: unknown) {
    reportAccountError(error, text, notice, signInPath);
  }
}

/** Yeniden deneme düğmesini bağlar: bildirim ve düğme gizlenir, "yükleniyor" görünür, hesap yeniden okunur. */
function bindRetry(form: CheckoutForm, text: ClientCopy, notice: HTMLElement, signInPath: string): void {
  const retry: HTMLButtonElement = element("account-retry", HTMLButtonElement);
  retry.addEventListener("click", (): void => {
    retry.classList.add("hidden");
    hideNotice(notice);
    element("account-loading", HTMLElement).classList.remove("hidden");
    void loadAccount(fetchMe, form, text, notice, signInPath);
  });
}

/** Sayfayı başlatır. */
async function main(): Promise<void> {
  const root: HTMLElement = element("account", HTMLElement);
  const signInPath: string = dataValue(root, "signInPath");
  const notice: HTMLElement = element("account-error", HTMLElement);
  const homePath: string = dataValue(root, "homePath");
  const text: ClientCopy = clientCopy;
  const params: URLSearchParams = new URLSearchParams(window.location.search);
  // Stripe Checkout dönüşü: `/account?payment=done`. Sorgu hemen silinir; yenilemede bildirim yeniden görünmez.
  const paymentDone: boolean = params.get("payment") === "done";
  if (rememberQueryChoices(params) && !paymentDone) {
    history.replaceState(null, "", window.location.pathname);
  }
  if (paymentDone) {
    // Ödeme tamamlandı: davet kodu kullanıldı (ya da artık gerekmiyor), seçilen plan aboneliğe dönüştü.
    forgetInviteCode();
    forgetPlan();
    forgetCheckoutIntent();
  }
  await claimTabSession();
  if (!hasSession()) {
    if (paymentDone) {
      // Ödeme uygulamadan açıldı (bu sekmede oturum yok): giriş sayfası yerine "ödeme alındı, uygulamaya dön".
      showPaidSignedOut();
      history.replaceState(null, "", window.location.pathname);
      return;
    }
    window.location.replace(signInPath);
    return;
  }
  if (paymentDone) {
    showPaymentNotice();
    history.replaceState(null, "", window.location.pathname);
  }

  const form: CheckoutForm = { validatedCode: null };
  bindCheckoutForm(form, text, notice, signInPath);
  bindAction(element("subscribe-button", HTMLButtonElement), notice, text, signInPath, (): Promise<void> => subscribe(form, text));
  bindAction(element("manage-button", HTMLButtonElement), notice, text, signInPath, (): Promise<void> => openBilling("/v1/billing/portal", {}));
  bindAction(element("signout-button", HTMLButtonElement), notice, text, signInPath, async (): Promise<void> => {
    try {
      await signOut();
    } finally {
      window.location.assign(homePath);
    }
  });
  bindDeletion(text, signInPath, homePath);
  bindRetry(form, text, notice, signInPath);
  await loadAccount(paymentDone ? fetchMeAfterPayment : fetchMe, form, text, notice, signInPath);
}

void main();
