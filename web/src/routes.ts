// Sayfaların adresleri (sonda eğik çizgi yok). Sunucu ve Mac uygulaması bu adreslerin bir kısmını sabit yazar:
// Stripe Checkout dönüşü `/account?payment=done`, Checkout iptali `/pricing`, Müşteri Portalı dönüşü `/account`, Mac
// uygulaması `/sign-in?app=1&nonce=…`, Apple ile giriş dönüşü `/sign-in`. Burada değişen adres oralarda da değişmelidir.

/** Sayfa kimlikleri. */
export type PageKey = "home" | "pricing" | "download" | "signIn" | "account" | "contact" | "admin" | "privacy" | "terms" | "notFound";

/** Sayfaların yolları. */
export const routes: Readonly<Record<PageKey, string>> = {
  home: "/",
  pricing: "/pricing",
  download: "/download",
  signIn: "/sign-in",
  account: "/account",
  contact: "/contact",
  admin: "/admin",
  privacy: "/privacy",
  terms: "/terms",
  notFound: "/404",
};

/** Arama motorlarına açık sayfalar (hesap, yönetim ve 404 kişiye özel ya da içeriksizdir). */
export const indexedPages: readonly PageKey[] = ["home", "pricing", "download", "signIn", "contact", "privacy", "terms"];

/** Önbelleğe alınmayan kişiye özel sayfalar. */
export const privatePages: readonly PageKey[] = ["account", "admin"];

/** Sayfanın mutlak adresi (ana sayfa sonda eğik çizgiyle: `https://alan/`). Saf fonksiyondur. */
export function pageUrl(page: PageKey, origin: string): string {
  return `${origin}${routes[page]}`;
}
