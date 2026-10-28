// Tarayıcı betiklerinin gösterdiği, sunucu yanıtına bağlı kısa metinler (giriş, hesap). Sayfa metinlerinden ayrı tutulur:
// betik paketine yalnızca bunlar girer.
import type { Lang } from "./routes";

/** Tarayıcı betiklerinin metinleri. */
export interface ClientCopy {
  readonly errors: {
    readonly network: string;
    readonly rateLimited: string;
    readonly turnstile: string;
    readonly invalidLink: string;
    readonly appleFailed: string;
    readonly appleUnavailable: string;
    readonly upstream: string;
    /** Bilinmeyen hata; `{code}` sunucunun hata koduyla değişir. */
    readonly generic: string;
  };
  readonly plan: { readonly trial: string; readonly subscription: string };
  /** `{left}` ve `{total}` sayılarla değişir. */
  readonly trialLeft: string;
  readonly trialNotUsed: string;
  /** `{used}` ve `{cap}` saatlerle değişir. */
  readonly hours: string;
  readonly subscriptionNone: string;
  /** `{date}` tarihle değişir. */
  readonly subscriptionActive: string;
  readonly subscriptionGrace: string;
  readonly subscriptionEnded: string;
  readonly pillActive: string;
  readonly pillGrace: string;
  readonly pillEnded: string;
  readonly pillTrial: string;
  readonly working: string;
}

const tr: ClientCopy = {
  errors: {
    network: "Sunucuya ulaşılamadı. Bağlantını kontrol edip yeniden dene.",
    rateLimited: "Çok fazla deneme oldu. Bir dakika bekleyip yeniden dene.",
    turnstile: "Güvenlik doğrulaması geçmedi. Yeniden dene.",
    invalidLink: "Bu giriş bağlantısı geçersiz, kullanılmış ya da süresi dolmuş. Yeni bir bağlantı iste.",
    appleFailed: "Apple ile giriş tamamlanamadı. Yeniden dene ya da e-posta bağlantısı kullan.",
    appleUnavailable: "Apple ile giriş şu an yüklenemedi. E-posta bağlantısını kullanabilirsin.",
    upstream: "Bağlı bir servis şu an yanıt vermiyor. Biraz sonra yeniden dene.",
    generic: "Bir şeyler ters gitti (kod: {code}). Yeniden dene.",
  },
  plan: { trial: "Ücretsiz deneme", subscription: "AI-Notepad aylık" },
  trialLeft: "{left} / {total} toplantı kaldı",
  trialNotUsed: "Abonelikte deneme sayılmaz",
  hours: "{used} / {cap} saat",
  subscriptionNone: "Abonelik yok",
  subscriptionActive: "Sonraki yenileme: {date}",
  subscriptionGrace: "Ödeme alınamadı. Kartını {date} tarihine kadar güncelle; o zamana kadar kullanmaya devam edersin.",
  subscriptionEnded: "Aboneliğin sona erdi.",
  pillActive: "Etkin",
  pillGrace: "Ödeme bekleniyor",
  pillEnded: "Bitti",
  pillTrial: "Deneme",
  working: "Bekle…",
};

const en: ClientCopy = {
  errors: {
    network: "Couldn't reach the server. Check your connection and try again.",
    rateLimited: "Too many attempts. Wait a minute and try again.",
    turnstile: "The security check didn't pass. Try again.",
    invalidLink: "This sign-in link is invalid, already used or expired. Request a new one.",
    appleFailed: "Sign in with Apple didn't complete. Try again or use an email link.",
    appleUnavailable: "Sign in with Apple couldn't load right now. You can use an email link.",
    upstream: "A connected service isn't responding right now. Try again shortly.",
    generic: "Something went wrong (code: {code}). Try again.",
  },
  plan: { trial: "Free trial", subscription: "AI-Notepad monthly" },
  trialLeft: "{left} / {total} meetings left",
  trialNotUsed: "Not counted while subscribed",
  hours: "{used} / {cap} hours",
  subscriptionNone: "No subscription",
  subscriptionActive: "Renews on {date}",
  subscriptionGrace: "Payment failed. Update your card by {date}; you keep access until then.",
  subscriptionEnded: "Your subscription has ended.",
  pillActive: "Active",
  pillGrace: "Payment due",
  pillEnded: "Ended",
  pillTrial: "Trial",
  working: "Working…",
};

/** Dile göre tarayıcı metinleri. */
export const clientCopy: Readonly<Record<Lang, ClientCopy>> = { tr, en };

/** `{ad}` yer tutucularını değerlerle doldurur. Saf fonksiyondur. */
export function fill(template: string, values: Readonly<Record<string, string>>): string {
  return template.replace(/\{(\w+)\}/g, (match: string, key: string): string => values[key] ?? match);
}
