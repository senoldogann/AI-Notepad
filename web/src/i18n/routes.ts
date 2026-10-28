// Sayfaların dile göre adresleri. Dil değiştirici ve hreflang aynı sayfanın öbür dildeki adresini buradan bulur.

/** Sitenin dilleri. */
export type Lang = "tr" | "en";

/** Tüm diller (sıra: dil değiştirici ve site haritası sırası). */
export const langs: readonly Lang[] = ["tr", "en"];

/** Sayfa kimlikleri. */
export type PageKey = "home" | "pricing" | "download" | "signIn" | "emailLink" | "account" | "privacy" | "terms";

/** Sayfaların dile göre yolları (sonda eğik çizgi yok). */
export const routes: Readonly<Record<PageKey, Readonly<Record<Lang, string>>>> = {
  home: { tr: "/tr", en: "/en" },
  pricing: { tr: "/tr/fiyat", en: "/en/pricing" },
  download: { tr: "/tr/indir", en: "/en/download" },
  signIn: { tr: "/tr/giris", en: "/en/sign-in" },
  emailLink: { tr: "/tr/giris/eposta", en: "/en/sign-in/email" },
  account: { tr: "/tr/hesap", en: "/en/account" },
  privacy: { tr: "/tr/gizlilik", en: "/en/privacy" },
  terms: { tr: "/tr/sartlar", en: "/en/terms" },
};

/** Arama motorlarına açık sayfalar (giriş bağlantısı ve hesap kişiye özeldir). */
export const indexedPages: readonly PageKey[] = ["home", "pricing", "download", "signIn", "privacy", "terms"];

/** Sayfanın verilen dildeki yolu. Saf fonksiyondur. */
export function pagePath(page: PageKey, lang: Lang): string {
  return routes[page][lang];
}

/** Sayfanın verilen dildeki mutlak adresi. Saf fonksiyondur. */
export function pageUrl(page: PageKey, lang: Lang, origin: string): string {
  return `${origin}${routes[page][lang]}`;
}

/** Dilin HTML `lang` değeri ve Open Graph yerel ayarı. */
export const langMeta: Readonly<Record<Lang, { readonly htmlLang: string; readonly ogLocale: string; readonly name: string }>> = {
  tr: { htmlLang: "tr", ogLocale: "tr_TR", name: "Türkçe" },
  en: { htmlLang: "en", ogLocale: "en_US", name: "English" },
};

/** Dile özgü olmayan, okuyanın diline yönlendiren adres. */
export interface NeutralRoute {
  /** Yol (sonda eğik çizgi yok). */
  readonly path: string;
  /** Yönlendirilen sayfa. */
  readonly page: PageKey;
}

/**
 * Sunucunun sabit yazdığı adresler (server/src/billing.ts ve `EMAIL_LINK_URL`): Stripe Checkout dönüşü `/hesap`,
 * Checkout iptali `/fiyat`, Müşteri Portalı dönüşü `/hesap`, giriş bağlantısı `/giris/eposta#token=…`; Mac uygulaması
 * giriş sayfasını `/giris?app=1` ile açar. Bu sayfalar
 * sorgu dizgisini ve `#` parçasını koruyarak okuyanın dilindeki sayfaya geçer.
 */
export const neutralRoutes: readonly NeutralRoute[] = [
  { path: "/hesap", page: "account" },
  { path: "/fiyat", page: "pricing" },
  { path: "/giris/eposta", page: "emailLink" },
  // Mac uygulamasının açtığı giriş sayfası (`/giris?app=1`).
  { path: "/giris", page: "signIn" },
];
