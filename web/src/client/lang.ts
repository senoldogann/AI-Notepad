// Dil tercihi: sitede gezilen dil sekme boyunca hatırlanır (sessionStorage), dile özgü olmayan adresler (ör. Stripe'tan
// dönüş `/hesap`) kullanıcıyı aynı dile götürür. Hatırlanan dil yoksa tarayıcının dil sırası kullanılır.
import type { Lang } from "../i18n/routes";

const storageKey: string = "ainotepad.lang";

/** Değer sitenin dillerinden biri mi. Saf fonksiyondur. */
export function isLang(value: string | null): value is Lang {
  return value === "tr" || value === "en";
}

/** Sayfanın dilini sekme için hatırlar. */
export function rememberLang(lang: string): void {
  if (isLang(lang)) {
    sessionStorage.setItem(storageKey, lang);
  }
}

/** Tarayıcı dil sırasında Türkçe İngilizceden önce geliyorsa Türkçe, değilse İngilizce. Saf fonksiyondur. */
export function langFromPreferences(preferences: readonly string[]): Lang {
  for (const preference of preferences) {
    const primary: string = preference.toLowerCase().split("-")[0] ?? "";
    if (primary === "tr") {
      return "tr";
    }
    if (primary === "en") {
      return "en";
    }
  }
  return "en";
}

/** Bu sekmede hatırlanan dil, yoksa tarayıcının dil tercihi. */
export function preferredLang(): Lang {
  const remembered: string | null = sessionStorage.getItem(storageKey);
  return isLang(remembered) ? remembered : langFromPreferences(navigator.languages);
}
