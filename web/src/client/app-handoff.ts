// Mac uygulamasından başlatılan Apple ya da Google ile giriş (Developer ID ile dağıtılan uygulama Apple ile girişi
// kendisi yapamaz: Apple bu yetkiyi yalnızca App Store uygulamalarına verir). Uygulama giriş sayfasını kendi giriş
// penceresinde (ASWebAuthenticationSession) `/sign-in?app=1&nonce=<64 hex>&provider=<apple|google>` ile açar; `nonce`
// uygulamanın kendi ham nonce'unun SHA-256 özetidir ve sağlayıcıya olduğu gibi verilir. Sağlayıcı uygulamada
// seçildiyse sayfa düğme göstermeden ona yönlendirir; `provider` yoksa (0.1.4) iki düğme gösterilir. O pencerede açılır pencereler güvenilir çalışmadığı
// için sayfa sağlayıcıya yönlendirir (Apple: `response_mode=fragment`, kapsamsız; Google: OAuth 2.0 örtük `id_token`);
// sağlayıcı `/sign-in#…` adresine döner. Yönlendirme boyunca sağlayıcı, rastgele `state` ve nonce özeti
// `sessionStorage`'da durur; dönüşte `state` denetlenir. Kimlik jetonu sunucuya gönderilmez:
// `com.senoldogan.ainotepad.hosted://auth/<apple|google>#idToken=…` ile uygulamaya iletilir, uygulama jetonu kendi ham
// nonce'uyla sunucuya yollar.

/** Abonelik uygulamasının giriş dönüş şeması (ASWebAuthenticationSession bu şemayı yakalar). */
export const appUrlScheme: string = "com.senoldogan.ainotepad.hosted";

/** Giriş isteğinin türü: sitenin kendi girişi, uygulama adına giriş ya da bozuk uygulama isteği. */
export type SignInMode =
  | { readonly kind: "site" }
  | { readonly kind: "app"; readonly hashedNonce: string; readonly provider: AppSignInProvider | null }
  | { readonly kind: "invalid-app" };

/** SHA-256 onaltılık özet biçimi (64 küçük ya da büyük harf onaltılık). */
const hashedNoncePattern: RegExp = /^[0-9a-fA-F]{64}$/;

/** Rastgele `state` biçimi (32 küçük harf onaltılık). */
const statePattern: RegExp = /^[0-9a-f]{32}$/;

/** Uygulama adına girişin sağlayıcısı (dönüş adresinin yolu). */
export type AppSignInProvider = "apple" | "google";

/**
 * Adresin sorgusundan giriş türünü çıkarır: `app=1` varsa geçerli bir `nonce` da olmalı; `provider` yoksa null,
 * varsa `apple` ya da `google` olmalı (başka değer bozuk istek sayılır). Saf fonksiyondur.
 */
export function signInMode(search: string): SignInMode {
  const params: URLSearchParams = new URLSearchParams(search);
  if (params.get("app") !== "1") {
    return { kind: "site" };
  }
  const nonce: string | null = params.get("nonce");
  const provider: string | null = params.get("provider");
  if (nonce === null || !hashedNoncePattern.test(nonce)) {
    return { kind: "invalid-app" };
  }
  if (provider === null) {
    return { kind: "app", hashedNonce: nonce.toLowerCase(), provider: null };
  }
  return provider === "apple" || provider === "google" ? { kind: "app", hashedNonce: nonce.toLowerCase(), provider } : { kind: "invalid-app" };
}

/** Kimlik jetonunu uygulamaya ileten adres (jeton `#` parçasında: sunuculara ve geçmişe gitmez). Saf fonksiyondur. */
export function appSignInUrl(provider: AppSignInProvider, idToken: string): string {
  return `${appUrlScheme}://auth/${provider}#idToken=${encodeURIComponent(idToken)}`;
}

/** Uygulama adına giriş sayfasının yolu (sağlayıcıdan hatayla dönünce sayfa bu adrese geri alınır). Saf fonksiyondur. */
export function appSignInPagePath(signInPath: string, hashedNonce: string): string {
  return `${signInPath}?app=1&nonce=${hashedNonce}`;
}

/** Sağlayıcıya yönlendirmeden önce saklanan, dönüşte beklenen deneme. */
export interface PendingAppSignIn {
  readonly provider: AppSignInProvider;
  readonly state: string;
  readonly hashedNonce: string;
}

/** Bekleyen denemenin `sessionStorage` anahtarı. */
export const pendingAppSignInKey: string = "gistsmith.appSignIn";

/** Bekleyen denemeyi saklanacak metne çevirir. Saf fonksiyondur. */
export function serializePendingAppSignIn(pending: PendingAppSignIn): string {
  return JSON.stringify(pending);
}

/** Saklanan metinden bekleyen denemeyi okur; yoksa ya da biçimi bozuksa null. Saf fonksiyondur. */
export function parsePendingAppSignIn(text: string | null): PendingAppSignIn | null {
  if (text === null) {
    return null;
  }
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    // Bozuk kayıt bekleyen deneme sayılmaz; çağıran "geçersiz dönüş" gösterir.
    return null;
  }
  if (typeof value !== "object" || value === null) {
    return null;
  }
  const record: Readonly<Record<string, unknown>> = value as Readonly<Record<string, unknown>>;
  const provider: unknown = record["provider"];
  const state: unknown = record["state"];
  const hashedNonce: unknown = record["hashedNonce"];
  if ((provider !== "apple" && provider !== "google") || typeof state !== "string" || typeof hashedNonce !== "string") {
    return null;
  }
  if (!statePattern.test(state) || !hashedNoncePattern.test(hashedNonce)) {
    return null;
  }
  return { provider, state, hashedNonce: hashedNonce.toLowerCase() };
}

/** Sorgu değerlerini `%20` ile kodlar (Apple `response_type` boşluğunu `+` yerine böyle bekler). Saf fonksiyondur. */
function query(params: ReadonlyArray<readonly [string, string]>): string {
  return params.map(([key, value]: readonly [string, string]): string => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`).join("&");
}

/**
 * Apple'ın yetkilendirme adresi: kapsam istenmez (e-posta gerekmez), bu yüzden `response_mode=fragment` kullanılabilir
 * ve kimlik jetonu dönüş adresinin `#` parçasına gelir. `aud` Services ID'dir. Saf fonksiyondur.
 */
export function appleAuthorizeRedirect(authorizeUrl: string, clientId: string, redirectUri: string, state: string, hashedNonce: string): string {
  return `${authorizeUrl}?${query([
    ["client_id", clientId],
    ["redirect_uri", redirectUri],
    ["response_type", "code id_token"],
    ["response_mode", "fragment"],
    ["state", state],
    ["nonce", hashedNonce],
  ])}`;
}

/** Google'ın OAuth 2.0 örtük akış adresi: yalnızca `id_token`, hesap seçimi her seferinde sorulur. Saf fonksiyondur. */
export function googleAuthorizeRedirect(authorizeUrl: string, clientId: string, redirectUri: string, state: string, hashedNonce: string): string {
  return `${authorizeUrl}?${query([
    ["response_type", "id_token"],
    ["client_id", clientId],
    ["redirect_uri", redirectUri],
    ["scope", "openid"],
    ["nonce", hashedNonce],
    ["state", state],
    ["prompt", "select_account"],
  ])}`;
}

/** Sağlayıcıdan dönüşte `#` parçasının anlamı. */
export type ProviderReturn =
  | { readonly kind: "none" }
  | { readonly kind: "token"; readonly state: string; readonly idToken: string }
  | { readonly kind: "error"; readonly state: string | null; readonly error: string };

/** Kimlik jetonu biçimi: üç base64url bölümü. */
const jwtPattern: RegExp = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;

/**
 * Adresin `#` parçasını sağlayıcı dönüşü olarak okur: `id_token` ve `state` varsa jeton, `error` varsa hata (ör. Apple
 * `user_cancelled_authorize`, Google `access_denied`), ikisi de yoksa dönüş değil. Jeton JWT biçiminde değilse
 * `invalid_id_token` hatası. Saf fonksiyondur.
 */
export function providerReturn(hash: string): ProviderReturn {
  const params: URLSearchParams = new URLSearchParams(hash.startsWith("#") ? hash.slice(1) : hash);
  const state: string | null = params.get("state");
  const error: string | null = params.get("error");
  if (error !== null) {
    return { kind: "error", state, error };
  }
  const idToken: string | null = params.get("id_token");
  if (idToken === null) {
    return { kind: "none" };
  }
  if (state === null) {
    return { kind: "error", state: null, error: "missing_state" };
  }
  if (!jwtPattern.test(idToken)) {
    return { kind: "error", state, error: "invalid_id_token" };
  }
  return { kind: "token", state, idToken };
}

/** Kullanıcının vazgeçtiğini bildiren sağlayıcı hata kodları. */
export function isCancellation(error: string): boolean {
  return error === "user_cancelled_authorize" || error === "access_denied";
}
