// Tarayıcı betiklerinin gösterdiği, sunucu yanıtına bağlı kısa metinler (giriş, hesap, iletişim, yönetim). Sayfa
// metinlerinden ayrı tutulur: betik paketine yalnızca bunlar girer.
import { productName } from "../config";

/** Tarayıcı betiklerinin metinleri. */
export interface ClientCopy {
  readonly errors: {
    readonly network: string;
    readonly rateLimited: string;
    readonly turnstile: string;
    readonly appleFailed: string;
    readonly appleUnavailable: string;
    readonly googleFailed: string;
    readonly googleUnavailable: string;
    /** Uygulamadan gelen giriş adresi eksik ya da bozuk (`app=1` ile geçerli `nonce` yok). */
    readonly appRequestInvalid: string;
    /** Sağlayıcıdan dönüş bu denemeye ait değil (`state` eşleşmiyor). */
    readonly appReturnInvalid: string;
    /** Tarayıcı depolaması kullanılamıyor (uygulama adına giriş yönlendirme boyunca ona yazar). */
    readonly storageUnavailable: string;
    readonly upstream: string;
    readonly messageTooLong: string;
    /** Bilinmeyen hata; `{code}` sunucunun hata koduyla değişir. */
    readonly generic: string;
  };
  readonly plan: { readonly trial: string; readonly subscription: string };
  /** Deneme sürüyor: `{left}`, `{total}` toplantı ve `{date}` bitiş tarihi. */
  readonly trialLeft: string;
  /** Deneme başlamadı: `{total}` toplantı, `{days}` gün. */
  readonly trialNotStarted: string;
  /** Deneme bitti (toplantılar harcandı ya da süre doldu). */
  readonly trialEnded: string;
  /** `{used}` ve `{cap}` saatlerle değişir. */
  readonly hours: string;
  readonly subscriptionNone: string;
  /** `{date}` tarihle değişir. */
  readonly subscriptionActive: string;
  /** İptal edilmiş, dönem sonuna dek süren abonelik. */
  readonly subscriptionCanceling: string;
  readonly subscriptionGrace: string;
  readonly subscriptionEnded: string;
  readonly pillActive: string;
  readonly pillCanceling: string;
  readonly pillGrace: string;
  readonly pillEnded: string;
  readonly pillTrial: string;
  readonly working: string;
  /** `{count}` ve `{max}` karakter sayısıyla değişir. */
  readonly characters: string;
  readonly admin: AdminClientCopy;
}

/** Yönetim panelinin değerlere bağlı metinleri. */
export interface AdminClientCopy {
  /** `{time}` saatle değişir. */
  readonly updated: string;
  /** `{count}` sayıyla değişir. */
  readonly downloadsSub: string;
  /** `{count}`, `{apple}`, `{google}`. */
  readonly usersSub: string;
  /** `{count}`. */
  readonly trialsSub: string;
  /** `{grace}`, `{ending}`, `{canceled}`. */
  readonly subscribersSub: string;
  readonly mrrSub: string;
  /** MRR alt satırına eklenir: Stripe'ın modu. */
  readonly stripeTest: string;
  readonly stripeLive: string;
  readonly elevenLabsSub: string;
  readonly deepgramSub: string;
  /** `{ceiling}`. */
  readonly spendSub: string;
  readonly hoursSub: string;
  /** Grafik özeti: `{total}`, `{peak}`, `{day}`. */
  readonly chartSummary: string;
  /** Hiç değer olmayan grafik. */
  readonly chartEmpty: string;
  /** Çubuk ipucu: `{day}`, `{value}`. */
  readonly barTitle: string;
  /** Toplantı çubuğu ipucu: `{day}`, `{trial}`, `{subscription}`. */
  readonly meetingBarTitle: string;
  readonly anonymous: string;
  readonly noSummary: string;
  readonly noMessage: string;
  /** Kullanıcılar kutusu alt satırına eklenir: `{today}`, `{week}`. */
  readonly usersRecent: string;
  /** `{rate}`, `{converted}`, `{started}`, `{recentRate}`, `{direct}`. */
  readonly conversionSub: string;
  /** `{pastDue}`, `{unpaid}`, `{ending}`. */
  readonly churnSub: string;
  /** `{refunds}`, `{disputes}`, `{failed}`, `{duplicates}`. */
  readonly paymentsSub: string;
  /** `{open}`, `{deferred}`, `{reprocessed}`. */
  readonly meetingsSub: string;
  /** `{minutes}` Deepgram akış dakikası. */
  readonly audioSub: string;
  /** `{account}`, `{near}`, `{cap}`. */
  readonly tokensUsageSub: string;
  /** `{device}`, `{ip}`, `{exhausted}`, `{expired}`, `{today}`. */
  readonly refusalsSub: string;
  /** Değer yok. */
  readonly none: string;
  readonly plans: { readonly subscription: string; readonly trial: string; readonly free: string };
  readonly providers: { readonly apple: string; readonly google: string };
  /** Abonelik durumu rozetleri (Stripe durumu ve erişim). */
  readonly subscriptionPills: { readonly active: string; readonly ending: string; readonly grace: string; readonly ended: string };
  /** Deneme hücresi: `{used}`, `{left}`. */
  readonly trialCell: string;
  readonly trialNotStarted: string;
  readonly meetingKinds: { readonly trial: string; readonly subscription: string };
  readonly meetingStates: { readonly open: string; readonly ended: string; readonly superseded: string; readonly expired: string };
  readonly meetingNotes: { readonly deferred: string; readonly reprocessed: string; readonly deepgram: string; readonly attested: string };
  /** `{minutes}`. */
  readonly minutes: string;
  /** `{hours}`. */
  readonly hours: string;
  readonly timeline: {
    readonly account_created: string;
    readonly trial_started: string;
    readonly trial_device_verified: string;
    readonly trial_ends: string;
    readonly subscription_updated: string;
    readonly subscription_past_due: string;
    readonly subscription_cancel_at: string;
    readonly subscription_period_end: string;
  };
  /** Ölçer metni: `{used}`, `{cap}`. */
  readonly ofCap: string;
  /** Kullanıcı başlığı: `{id}`. */
  readonly userTitle: string;
  /** `{count}` gösterilen satır. */
  readonly shown: string;
  readonly opsOpenSub: string;
  readonly opsUnendedSub: string;
  /** `{expired}`, `{oldest}`. */
  readonly opsReservationsSub: string;
  readonly opsReservationsOk: string;
  /** `{stale}`. */
  readonly opsDeepgramSub: string;
  /** `{count}` son 24 saat. */
  readonly opsWebhookSub: string;
  readonly opsWebhookNever: string;
  /** `{feedback}`, `{crash}`, `{contact}`. */
  readonly opsReportsSub: string;
  /** Göreli zaman: `{value}` önce. */
  readonly ago: string;
}

/** Tarayıcı metinleri. */
export const clientCopy: ClientCopy = {
  errors: {
    network: "Couldn't reach the server. Check your connection and try again.",
    rateLimited: "Too many requests. Please wait a few minutes and try again.",
    turnstile: "The security check didn't pass. Try again.",
    appleFailed: "Sign in with Apple didn't complete. Try again or continue with Google.",
    appleUnavailable: "Sign in with Apple couldn't load right now. You can continue with Google.",
    googleFailed: "Sign in with Google didn't complete. Try again or continue with Apple.",
    googleUnavailable: "Sign in with Google isn't available right now. You can continue with Apple.",
    appRequestInvalid: `This sign-in link from the app is incomplete. Start signing in again from ${productName}.`,
    appReturnInvalid: "This sign-in didn't come back as expected. Choose Apple or Google again.",
    storageUnavailable: "Your browser blocked the storage this sign-in needs. Allow site data for this page and try again.",
    upstream: "A connected service isn't responding right now. Try again shortly.",
    messageTooLong: "Your message is too long. Please shorten it to 5,000 characters.",
    generic: "Something went wrong (code: {code}). Try again.",
  },
  plan: { trial: "Free trial", subscription: `${productName} monthly` },
  trialLeft: "{left} of {total} meetings left · Trial ends {date}",
  trialNotStarted: "Not started yet: {total} meetings or {days} days from your first meeting, whichever comes first",
  trialEnded: "Your free trial has ended. Subscribe to start new meetings.",
  hours: "{used} / {cap} hours",
  subscriptionNone: "No subscription",
  subscriptionActive: "Renews on {date}",
  subscriptionCanceling: "Cancelled; you can use it until {date}. It won't renew.",
  subscriptionGrace: "Payment failed. Update your card by {date}; you keep access until then.",
  subscriptionEnded: "Your subscription has ended.",
  pillActive: "Active",
  pillCanceling: "Ending",
  pillGrace: "Payment due",
  pillEnded: "Ended",
  pillTrial: "Trial",
  working: "Working…",
  characters: "{count} / {max}",
  admin: {
    updated: "Updated {time}",
    downloadsSub: "{count} in the last 30 days",
    usersSub: "{count} new in 30 days · Apple {apple} · Google {google}",
    trialsSub: "{count} used up",
    subscribersSub: "{grace} in grace · {ending} ending · {canceled} cancelled in total",
    mrrSub: "From renewing subscriptions, taxes included",
    stripeTest: "Stripe test mode",
    stripeLive: "Stripe live",
    elevenLabsSub: "{used} of {cap} audio hours this ElevenLabs plan cycle",
    deepgramSub: "{used} of {budget} Deepgram credit (estimate); then live text runs on the Mac",
    spendSub: "of {ceiling} daily ceiling",
    hoursSub: "Recorded across all users",
    chartSummary: "{total} in total over 30 days; highest {peak} on {day}.",
    chartEmpty: "Nothing in the last 30 days.",
    barTitle: "{day}: {value}",
    meetingBarTitle: "{day}: {trial} trial, {subscription} subscription",
    anonymous: "Not signed in",
    noSummary: "(no summary)",
    noMessage: "(no message)",
    usersRecent: "{today} today · {week} in 7 days",
    conversionSub: "{converted} of {started} trials converted · last 30 days {recentRate} · {direct} paid without a trial",
    churnSub: "{ending} set to end · {pastDue} payment due · {unpaid} unpaid",
    paymentsSub: "{refunds} refunds · {disputes} disputes · {failed} failed payments in 30 days · {duplicates} duplicate subscriptions refunded",
    meetingsSub: "{open} live now · {deferred} processed later · {reprocessed} reprocessed",
    audioSub: "Cloud transcription; Deepgram live text used {minutes} stream minutes in total",
    tokensUsageSub: "{account} outside meetings · {near} accounts above 80% of the {cap} monthly cap",
    refusalsSub: "Mac already used {device} · same network {ip} · used up {exhausted} · expired {expired} · {today} today",
    none: "—",
    plans: { subscription: "Subscribed", trial: "Trial", free: "No plan" },
    providers: { apple: "Apple", google: "Google" },
    subscriptionPills: { active: "Active", ending: "Ending", grace: "Payment due", ended: "Ended" },
    trialCell: "{used} used · {left} left",
    trialNotStarted: "Not started",
    meetingKinds: { trial: "Trial", subscription: "Subscription" },
    meetingStates: { open: "Live", ended: "Ended", superseded: "Replaced", expired: "Never ended" },
    meetingNotes: { deferred: "Processed later", reprocessed: "Reprocessed ×{count}", deepgram: "Deepgram", attested: "Verified Mac" },
    minutes: "{minutes} min",
    hours: "{hours} h",
    timeline: {
      account_created: "Account created",
      trial_started: "Trial started",
      trial_device_verified: "Trial tied to a Mac",
      trial_ends: "Trial period ends",
      subscription_updated: "Subscription last updated ({detail})",
      subscription_past_due: "Payment failed",
      subscription_cancel_at: "Cancelled; access ends",
      subscription_period_end: "Current period ends ({detail})",
    },
    ofCap: "{used} of {cap}",
    userTitle: "Account {id}",
    shown: "{count} shown",
    opsOpenSub: "Started and not yet ended or timed out",
    opsUnendedSub: "The app didn't report the end (crash, network or a closed Mac)",
    opsReservationsSub: "{expired} expired, waiting for the daily cleanup · oldest {oldest}",
    opsReservationsOk: "No expired reservations waiting",
    opsDeepgramSub: "{stale} older than the longest meeting (should have settled)",
    opsWebhookSub: "{count} events in the last 24 hours",
    opsWebhookNever: "No events stored in the last 90 days",
    opsReportsSub: "{feedback} feedback · {crash} crashes · {contact} contact",
    ago: "{value} ago",
  },
};

/** `{ad}` yer tutucularını değerlerle doldurur. Saf fonksiyondur. */
export function fill(template: string, values: Readonly<Record<string, string>>): string {
  return template.replace(/\{(\w+)\}/g, (match: string, key: string): string => values[key] ?? match);
}
