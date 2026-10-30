// Hesap sayfası: `/v1/me`'den tek plan kartı (plan adı ve durum etiketi, tek durum satırı, denemede kalan toplantı ya da
// abonede aylık saat ölçeri ve duruma uyan eylem: Abone ol, Aboneliği yönet ya da ücretsiz erişimde hiçbiri). Abone
// olurken plan seçimi (yıllık seçili) ve davet kodu (`POST /v1/referral/validate`) Checkout'a taşınır; abonenin davet
// kartı `GET /v1/referral`'dan; çıkış ve onaylı hesap silme (`DELETE /v1/me`). Adresteki `?plan=`, `?code=` ve
// `?checkout=1` (fiyat ve davet sayfalarından) girişten önce saklanır; oturum yoksa giriş sayfasına geçilir. Plan
// seçimi tarayıcıda kalıcıdır (giriş başka bir sekmede bitse de kaybolmaz); `?checkout=1` niyeti giriş bitince hesap
// sayfasını doğrudan Stripe Checkout'a gönderir.
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

/** Sürmekte olan denemenin göstergesi: kalan ve toplam toplantı. */
interface TrialMeter {
  readonly left: number;
  readonly total: number;
}

/** Abonenin aylık saat göstergesi: metin ("3,4 / 10 saat"), kullanılan (sınırda kesilir) ve sınır. */
interface HoursMeter {
  readonly text: string;
  readonly used: number;
  readonly cap: number;
}

/** Deneme durumu: başlamadı, sürüyor ya da bitti (toplantılar harcandı veya süre doldu). */
type TrialPhase = "notStarted" | "running" | "ended";

/** Hesap sayfasında gösterilecek değerler. */
interface AccountView {
  readonly plan: string;
  readonly planPill: Pill;
  /** Plan kartının tek durum satırı: abonelik durumu ya da deneme. */
  readonly status: string;
  /** Deneme sürüyorsa kalan toplantı göstergesi; yoksa null. */
  readonly trialMeter: TrialMeter | null;
  /** Aylık saat yalnızca abonelik erişiminde görünür (sınır aboneliğindir; denemede kafa karıştırır); yoksa null. */
  readonly hours: HoursMeter | null;
  readonly canSubscribe: boolean;
  readonly canManage: boolean;
}

/** Tarihi sitenin yerel ayarında yazar. Saf fonksiyondur. */
function formatDate(iso: string, locale: string): string {
  return new Intl.DateTimeFormat(locale, { dateStyle: "long" }).format(new Date(iso));
}

/** Saati sitenin yerel ayarında (en çok bir ondalık) yazar. Saf fonksiyondur. */
function formatHours(hours: number, locale: string): string {
  return new Intl.NumberFormat(locale, { maximumFractionDigits: 1 }).format(hours);
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

/** Deneme satırının metni: başlamadıysa toplantı ve gün; bittiyse "bitti"; sürüyorsa kalan ve bitiş. Saf fonksiyondur. */
function trialText(me: Entitlements, text: ClientCopy, locale: string, now: Date): string {
  const phase: TrialPhase = trialPhase(me, now);
  if (phase === "notStarted" || me.trialEndsAt === null) {
    return fill(text.trialNotStarted, { total: String(me.trialMeetingsTotal), days: String(me.trialDays) });
  }
  if (phase === "ended") {
    return text.trialEnded;
  }
  return fill(text.trialLeft, { left: String(me.trialMeetingsLeft), total: String(me.trialMeetingsTotal), date: formatDate(me.trialEndsAt, locale) });
}

/**
 * Aboneliğin durum satırı. Ücretsiz erişimde ödeme ve yenileme yoktur: bitiş tarihi varsa o yazılır, bittiyse "ücretsiz
 * erişim bitti" (abonelik bitti değil: hiç ödeme yapılmadı). Saf fonksiyondur.
 */
function subscriptionText(subscription: SubscriptionInfo, text: ClientCopy, locale: string): string {
  if (subscription.complimentary) {
    if (subscription.access === "none") {
      return text.subscriptionComplimentaryEnded;
    }
    return subscription.cancelAt === null
      ? text.subscriptionComplimentary
      : fill(text.subscriptionComplimentaryUntil, { date: formatDate(subscription.cancelAt, locale) });
  }
  if (subscription.access === "active" && subscription.cancelAt !== null) {
    return fill(text.subscriptionCanceling, { date: formatDate(subscription.cancelAt, locale) });
  }
  if (subscription.access === "active") {
    return fill(text.subscriptionActive, { date: formatDate(subscription.currentPeriodEnd, locale) });
  }
  if (subscription.access === "grace") {
    return fill(text.subscriptionGrace, { date: formatDate(subscription.graceEndsAt, locale) });
  }
  if (isPaymentOverdue(subscription)) {
    return text.subscriptionPaymentOverdue;
  }
  return text.subscriptionEnded;
}

/**
 * Yenileme ödemesi alınamadı ve ek süre bitti mi: Stripe'ta abonelik sürer (`past_due`/`unpaid`), erişim yok; kart
 * "Manage subscription"dan güncellenince erişim döner. Saf fonksiyondur.
 */
function isPaymentOverdue(subscription: SubscriptionInfo): boolean {
  return subscription.access === "none" && !subscription.complimentary && (subscription.status === "past_due" || subscription.status === "unpaid");
}

/** Plan kartının durum satırı: abonelik anlatılıyorsa abonelik, değilse deneme. Saf fonksiyondur. */
function statusText(me: Entitlements, text: ClientCopy, locale: string, now: Date): string {
  return me.subscription !== null && describesSubscription(me, now) ? subscriptionText(me.subscription, text, locale) : trialText(me, text, locale, now);
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

/**
 * Sunucu yanıtından gösterilecek değerleri üretir. Aboneliği yönetme yalnızca Stripe'ta karşılığı olan (ücretsiz erişim
 * olmayan) abonelikte vardır: ücretsiz erişim bitmiş olsa da Portal'da yönetilecek bir şey yoktur. Saf fonksiyondur.
 */
export function accountView(me: Entitlements, text: ClientCopy, locale: string, now: Date): AccountView {
  const subscribed: boolean = me.plan === "subscription";
  return {
    plan: planName(me, text, now),
    planPill: planPill(me, text, now),
    status: statusText(me, text, locale, now),
    trialMeter: !subscribed && trialPhase(me, now) === "running" ? { left: me.trialMeetingsLeft, total: me.trialMeetingsTotal } : null,
    hours: subscribed
      ? {
          text: fill(text.hours, { used: formatHours(me.monthlyHoursUsed, locale), cap: formatHours(me.monthlyHoursCap, locale) }),
          used: Math.min(me.monthlyHoursUsed, me.monthlyHoursCap),
          cap: me.monthlyHoursCap,
        }
      : null,
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

/** Ölçerleri yazar: deneme ölçeri ve abonenin saat bloğu, olmayan gizlenir. */
function renderMeters(trial: TrialMeter | null, hours: HoursMeter | null): void {
  const trialMeter: HTMLProgressElement = element("trial-meter", HTMLProgressElement);
  trialMeter.classList.toggle("hidden", trial === null);
  if (trial !== null) {
    trialMeter.max = trial.total;
    trialMeter.value = trial.left;
  }
  element("hours-card", HTMLElement).classList.toggle("hidden", hours === null);
  if (hours !== null) {
    element("hours-value", HTMLElement).textContent = hours.text;
    const meter: HTMLProgressElement = element("hours-meter", HTMLProgressElement);
    meter.max = hours.cap;
    meter.value = hours.used;
    meter.textContent = hours.text;
  }
}

/** Değerleri sayfaya yazar. */
function render(view: AccountView): void {
  element("plan-value", HTMLElement).textContent = view.plan;
  renderPill(element("plan-pill", HTMLElement), view.planPill);
  element("plan-status", HTMLElement).textContent = view.status;
  renderMeters(view.trialMeter, view.hours);
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

/** Davet kartının sayı satırı; bekleyen ödül varsa en yakınının tahmini tarihi eklenir. Saf fonksiyondur. */
function referralStatsText(referral: ReferralInfo, text: ClientCopy, locale: string): string {
  const stats: string = fill(text.referralStats, {
    joined: String(referral.joined),
    rewarded: String(referral.rewarded),
    pending: String(referral.pending),
    left: String(referral.rewardsLeftThisYear),
    cap: String(referral.rewardsPerYear),
  });
  return referral.nextRewardAt === null ? stats : `${stats} · ${fill(text.referralNextReward, { date: formatDate(referral.nextRewardAt, locale) })}`;
}

/**
 * Ücretsiz erişimli hesabın davet kartı satırı: arkadaşlar yine davet indirimini alır, ama ödenecek fatura olmadığından
 * 5,99 $ ödülü uygulanmaz (sunucu `referrer_complimentary` ile düşürür). Saf fonksiyondur.
 */
function complimentaryReferralStatsText(referral: ReferralInfo, text: ClientCopy): string {
  return fill(text.referralStatsComplimentary, { joined: String(referral.joined) });
}

/**
 * Davet kartını çizer: program açık ve kod varsa (abonelik erişimi) görünür. Davetin ücretsiz ilk ayındaki hesapta sunucu
 * kod vermez: kart kodsuz görünür ve kodun ilk ücretli aydan sonra açılacağını söyler. `stats` kartın sayı satırıdır.
 */
function renderReferral(referral: ReferralInfo, stats: string, text: ClientCopy, notice: HTMLElement): void {
  const card: HTMLElement = element("referral-card", HTMLElement);
  const share: HTMLElement = element("referral-share", HTMLElement);
  const inviteUrl: string | null = referral.inviteUrl;
  if (!referral.enabled) {
    card.classList.add("hidden");
    return;
  }
  if (referral.code === null || inviteUrl === null) {
    share.classList.add("hidden");
    element("referral-stats", HTMLElement).textContent = text.referralCodeAfterFirstPayment;
    card.classList.remove("hidden");
    return;
  }
  share.classList.remove("hidden");
  element("referral-code", HTMLElement).textContent = referral.code;
  element("referral-stats", HTMLElement).textContent = stats;
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

/**
 * Abonenin davet kartını yükler; yüklenemezse kart gizli kalır ve hata konsola yazılır (hesabın geri kalanı çalışır).
 * Ücretsiz erişimli hesapta sayı satırı ödülün uygulanmadığını söyler.
 */
async function loadReferral(text: ClientCopy, notice: HTMLElement): Promise<void> {
  try {
    const referral: ReferralInfo = await fetchReferral();
    const stats: string = referral.complimentary ? complimentaryReferralStatsText(referral, text) : referralStatsText(referral, text, siteLocale);
    renderReferral(referral, stats, text, notice);
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

  try {
    const me: Entitlements = paymentDone ? await fetchMeAfterPayment() : await fetchMe();
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
