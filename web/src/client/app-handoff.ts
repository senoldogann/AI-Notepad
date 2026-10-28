// Uygulamadan başlatılan e-posta girişi: Mac uygulaması giriş sayfasını `?app=1` ile açar. Site bunu bu tarayıcıda 15
// dakika (bağlantının ömrü) hatırlar; e-posta bağlantısı açılınca jeton siteye giriş yapmak yerine uygulamaya
// (`com.senoldogan.ainotepad.hosted://auth/email?token=…`) iletilir. Bağlantı başka bir tarayıcıda açılırsa site
// normal girişi yapar.

/** Abonelik uygulamasının adres şeması (App/Hosted, Info.plist `CFBundleURLSchemes`). */
export const appUrlScheme: string = "com.senoldogan.ainotepad.hosted";

/** Hatırlamanın saklandığı anahtar (değer: bitiş anı, ms). */
const storageKey: string = "ainotepad.appSignIn";

/** Hatırlama süresi: e-posta bağlantısının ömrü. */
const rememberMs: number = 15 * 60_000;

/** Giriş sayfası uygulamadan mı açıldı (`?app=1`). Saf fonksiyondur. */
export function isAppSignInRequest(search: string): boolean {
  return new URLSearchParams(search).get("app") === "1";
}

/** Saklanan değer hâlâ geçerli mi. Saf fonksiyondur. */
export function isAppSignInPending(stored: string | null, nowMs: number): boolean {
  if (stored === null || !/^\d+$/.test(stored)) {
    return false;
  }
  return Number(stored) > nowMs;
}

/** Jetonu uygulamaya ileten adres. Saf fonksiyondur. */
export function appSignInUrl(token: string): string {
  return `${appUrlScheme}://auth/email?token=${encodeURIComponent(token)}`;
}

/** Uygulamadan başlatılan girişi bu tarayıcıda hatırlar. */
export function rememberAppSignIn(nowMs: number): void {
  window.localStorage.setItem(storageKey, String(nowMs + rememberMs));
}

/** Uygulamadan başlatılmış bir giriş bekliyor mu; bekliyorsa (tek seferlik) silinir. */
export function consumeAppSignIn(nowMs: number): boolean {
  const pending: boolean = isAppSignInPending(window.localStorage.getItem(storageKey), nowMs);
  window.localStorage.removeItem(storageKey);
  return pending;
}
