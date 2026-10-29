// Mac uygulamasından başlatılan Google ile giriş. Uygulama giriş sayfasını `/sign-in?app=1&nonce=<64 hex>` ile açar;
// `nonce` uygulamanın kendi ham nonce'unun SHA-256 özetidir ve Google'a olduğu gibi verilir. Google'ın kimlik jetonu
// sunucuya gönderilmez: `com.senoldogan.ainotepad.hosted://auth/google#idToken=…` ile uygulamaya iletilir, uygulama
// jetonu kendi ham nonce'uyla sunucuya yollar.

/** Abonelik uygulamasının adres şeması (App/Hosted, Info.plist `CFBundleURLSchemes`). */
export const appUrlScheme: string = "com.senoldogan.ainotepad.hosted";

/** Giriş isteğinin türü: sitenin kendi girişi, uygulama adına giriş ya da bozuk uygulama isteği. */
export type SignInMode =
  | { readonly kind: "site" }
  | { readonly kind: "app"; readonly hashedNonce: string }
  | { readonly kind: "invalid-app" };

/** SHA-256 onaltılık özet biçimi (64 küçük ya da büyük harf onaltılık). */
const hashedNoncePattern: RegExp = /^[0-9a-fA-F]{64}$/;

/** Adresin sorgusundan giriş türünü çıkarır: `app=1` varsa geçerli bir `nonce` da olmalı. Saf fonksiyondur. */
export function signInMode(search: string): SignInMode {
  const params: URLSearchParams = new URLSearchParams(search);
  if (params.get("app") !== "1") {
    return { kind: "site" };
  }
  const nonce: string | null = params.get("nonce");
  return nonce !== null && hashedNoncePattern.test(nonce) ? { kind: "app", hashedNonce: nonce.toLowerCase() } : { kind: "invalid-app" };
}

/** Google kimlik jetonunu uygulamaya ileten adres (jeton `#` parçasında: sunuculara ve geçmişe gitmez). Saf fonksiyondur. */
export function appGoogleSignInUrl(idToken: string): string {
  return `${appUrlScheme}://auth/google#idToken=${encodeURIComponent(idToken)}`;
}
