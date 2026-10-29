// Giriş sayfası. Sitenin kendi girişi: Apple ile giriş (açılır pencere) ve Google ile giriş (Google'a yönlendirme; açılır
// pencere iOS Safari'de güvenilir çalışmaz); tarayıcı rastgele bir ham nonce üretir, sağlayıcıya özetini verir, kimlik
// jetonunu ham nonce'la sunucuya yollar; başarılı girişte oturum saklanır ve hesap sayfasına geçilir. Mac uygulaması adına giriş (app-handoff.ts):
// açılır pencere yok, sayfa sağlayıcıya yönlendirir ve `#` parçasıyla geri döner; nonce özeti uygulamanındır ve jeton
// sunucuya değil uygulamaya iletilir.
import { type RawResponse, parseSession, send } from "./api";
import {
  type AppSignInProvider,
  type PendingAppSignIn,
  type ProviderReturn,
  type SignInMode,
  appSignInPagePath,
  appSignInUrl,
  appleAuthorizeRedirect,
  googleAuthorizeRedirect,
  isCancellation,
  parsePendingAppSignIn,
  pendingAppSignInKey,
  providerReturn,
  serializePendingAppSignIn,
  signInMode,
} from "./app-handoff";
import { type ClientCopy, clientCopy } from "./copy";
import { dataValue, element, errorText, hideNotice, loadScript, showNotice } from "./dom";
import { saveSession } from "./session";
import { appleAuthScriptUrl, appleAuthorizeUrl, googleAuthorizeUrl } from "../config";
import { siteConfig } from "../site";

/** Apple yanıtındaki `state` gönderdiğimizle aynı değil. */
class AppleStateError extends Error {
  override readonly name: string = "AppleStateError";
}

/** Sağlayıcıya verilen tek kullanımlık değerler: ham nonce sunucuya, özeti sağlayıcıya gider. */
interface Nonce {
  readonly raw: string;
  readonly hashed: string;
}

/** Sitenin Google girişinde yönlendirme süresince saklanan deneme (`sessionStorage`, sekmeye özgü, tek kullanımlık). */
const pendingSiteGoogleKey: string = "gistsmith.siteSignIn";

/** Google'a yönlendirilen site girişi: dönüşte `state` karşılaştırılır, ham nonce sunucuya gider. */
interface PendingSiteGoogle {
  readonly state: string;
  readonly rawNonce: string;
}

/** Bayt dizisinin onaltılık yazımı. Saf fonksiyondur. */
function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte: number): string => byte.toString(16).padStart(2, "0")).join("");
}

/** Rastgele onaltılık değer. */
function randomHex(byteCount: number): string {
  return hex(crypto.getRandomValues(new Uint8Array(byteCount)));
}

/** Metnin SHA-256 onaltılık özeti (sunucunun `sha256hex(nonce)` beklentisi). */
async function sha256Hex(text: string): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))));
}

/** Yeni nonce. Tek kullanımlıktır (sunucu ikinci kez kabul etmez); her denemeden sonra yenilenir. */
async function newNonce(): Promise<Nonce> {
  const raw: string = randomHex(32);
  return { raw, hashed: await sha256Hex(raw) };
}

/** Girişten dönen oturumu saklar ve hesap sayfasına geçer. */
function finishSignIn(response: RawResponse, path: string, accountPath: string): void {
  saveSession(parseSession(response, path));
  window.location.assign(accountPath);
}

/** Apple'ı nonce özeti ve state ile hazırlar. `init` tıklamadan önce yapılır: açılır pencere tıklamayla eş zamanlı açılmalı. */
function prepareApple(apple: AppleIdGlobal, redirectUri: string, hashedNonce: string, state: string): void {
  apple.auth.init({
    clientId: siteConfig.appleServiceId,
    // Kimlik bilgisi istenmez (ad, e-posta): sunucu yalnızca Apple'ın kullanıcı kimliğini kullanır ve e-posta saklamaz.
    scope: "",
    redirectURI: redirectUri,
    state,
    nonce: hashedNonce,
    usePopup: true,
  });
}

/** Apple'a hangi nonce özetinin verileceği ve kimlik jetonunun ne yapılacağı. */
interface AppleFlow {
  /** Apple'a verilecek nonce özeti (her denemede yeni olabilir). */
  readonly nextHashedNonce: () => Promise<string>;
  /** Kimlik jetonu geldiğinde. Hata fırlatırsa bildirim gösterilir ve yeni nonce'la yeniden hazırlanır. */
  readonly onIdentityToken: (identityToken: string) => Promise<void>;
}

/** Apple düğmesini bağlar. Betik yüklenemezse düğme kapalı kalır ve Google önerilir. */
async function setUpApple(text: ClientCopy, notice: HTMLElement, redirectUri: string, flow: AppleFlow): Promise<void> {
  const button: HTMLButtonElement = element("apple-button", HTMLButtonElement);
  try {
    await loadScript(appleAuthScriptUrl);
  } catch (error: unknown) {
    showNotice(notice, text.errors.appleUnavailable);
    console.error("apple_script_failed", { error: error instanceof Error ? error.message : String(error) });
    return;
  }
  const apple: AppleIdGlobal | undefined = window.AppleID;
  if (apple === undefined) {
    showNotice(notice, text.errors.appleUnavailable);
    console.error("apple_script_failed", { error: "window.AppleID tanımsız" });
    return;
  }
  let state: string = randomHex(16);
  prepareApple(apple, redirectUri, await flow.nextHashedNonce(), state);
  button.disabled = false;
  button.addEventListener("click", (): void => {
    hideNotice(notice);
    button.disabled = true;
    const attemptState: string = state;
    void apple.auth
      .signIn()
      .then(async (result: AppleSignInResponse): Promise<void> => {
        if (result.authorization.state !== attemptState) {
          throw new AppleStateError("Apple yanıtındaki state eşleşmiyor.");
        }
        await flow.onIdentityToken(result.authorization.id_token);
      })
      .catch(async (error: unknown): Promise<void> => {
        // Apple penceresi kapatıldıysa ya da iptal edildiyse (Apple `{error: "popup_closed_by_user"}` gibi düz nesne
        // döndürür) sessiz kalınmaz: ayrıntı konsola, kısa metin kullanıcıya.
        if (error instanceof AppleStateError || !(error instanceof Error)) {
          console.warn("apple_sign_in_failed", { error: error instanceof Error ? error.message : JSON.stringify(error) });
          showNotice(notice, text.errors.appleFailed);
        } else {
          showNotice(notice, errorText(error, text));
        }
        state = randomHex(16);
        prepareApple(apple, redirectUri, await flow.nextHashedNonce(), state);
        button.disabled = false;
      });
  });
}

/** "Uygulamaya dönülüyor…" durumunu ve yedek düğmeyi gösterip uygulamayı açar. */
function handOffToApp(url: string): void {
  element("signin-panel", HTMLElement).classList.add("hidden");
  element("signin-app-intro", HTMLElement).classList.add("hidden");
  element("signin-app-open", HTMLAnchorElement).href = url;
  const panel: HTMLElement = element("signin-app-return", HTMLElement);
  panel.classList.remove("hidden");
  panel.focus();
  window.location.href = url;
}

/** Sitenin kendi girişi için nonce kaynağı: her denemede yeni ham nonce; jeton gelince ham hali sunucuya gider. */
interface SiteNonces {
  readonly next: () => Promise<string>;
  readonly raw: () => string;
}

/** Yeni site nonce kaynağı. */
function siteNonces(): SiteNonces {
  let pending: Nonce | null = null;
  return {
    next: async (): Promise<string> => {
      pending = await newNonce();
      return pending.hashed;
    },
    raw: (): string => {
      if (pending === null) {
        throw new Error("Nonce hazırlanmadan jeton geldi.");
      }
      return pending.raw;
    },
  };
}

/** Kimlik jetonunu ham nonce'la sunucuya yollar, oturumu saklar ve hesap sayfasına geçer. */
async function signInOnSite(path: "/v1/auth/apple" | "/v1/auth/google", identityToken: string, rawNonce: string, accountPath: string): Promise<void> {
  const response: RawResponse = await send({ method: "POST", path, body: { identityToken, nonce: rawNonce }, accessToken: null, attempts: 1 });
  finishSignIn(response, path, accountPath);
}

/** Saklanan site Google denemesini okur ve siler (tek kullanımlık); yoksa ya da bozuksa null. */
function takePendingSiteGoogle(): PendingSiteGoogle | null {
  try {
    const raw: string | null = window.sessionStorage.getItem(pendingSiteGoogleKey);
    window.sessionStorage.removeItem(pendingSiteGoogleKey);
    if (raw === null) {
      return null;
    }
    const parsed: { state?: unknown; rawNonce?: unknown } = JSON.parse(raw) as { state?: unknown; rawNonce?: unknown };
    if (typeof parsed.state === "string" && typeof parsed.rawNonce === "string") {
      return { state: parsed.state, rawNonce: parsed.rawNonce };
    }
    console.error("site_google_pending_corrupt", { keys: Object.keys(parsed) });
    return null;
  } catch (error: unknown) {
    console.error("site_google_pending_unreadable", { error: error instanceof Error ? error.message : String(error) });
    return null;
  }
}

/** Google düğmesi: yeni nonce ve `state` saklanır, sayfa Google'a yönlendirilir; dönüş `finishSiteGoogleReturn`'de. */
function setUpGoogleRedirect(text: ClientCopy, notice: HTMLElement, redirectUri: string): void {
  const button: HTMLButtonElement = element("google-redirect-button", HTMLButtonElement);
  button.addEventListener("click", (): void => {
    hideNotice(notice);
    button.disabled = true;
    void (async (): Promise<void> => {
      const nonce: Nonce = await newNonce();
      const pending: PendingSiteGoogle = { state: randomHex(16), rawNonce: nonce.raw };
      try {
        window.sessionStorage.setItem(pendingSiteGoogleKey, JSON.stringify(pending));
      } catch (error: unknown) {
        console.error("site_google_storage_failed", { error: error instanceof Error ? error.message : String(error) });
        showNotice(notice, text.errors.storageUnavailable);
        button.disabled = false;
        return;
      }
      window.location.assign(googleAuthorizeRedirect(googleAuthorizeUrl, siteConfig.googleClientId, redirectUri, pending.state, nonce.hashed));
    })();
  });
  button.disabled = false;
}

/**
 * Google'dan site girişi dönüşü: `#` parçası hemen silinir; `state` eşleşirse kimlik jetonu ham nonce'la sunucuya gider
 * ve hesap sayfasına geçilir. Vazgeçildiyse bildirim yok; başka hatada bildirim gösterilir ve giriş yeniden sunulur.
 */
async function finishSiteGoogleReturn(
  text: ClientCopy,
  notice: HTMLElement,
  result: Exclude<ProviderReturn, { readonly kind: "none" }>,
  pending: PendingSiteGoogle,
  accountPath: string,
  redirectUri: string,
): Promise<void> {
  window.history.replaceState(null, "", window.location.pathname);
  startSiteSignIn(text, notice, accountPath, redirectUri);
  if (result.kind === "error") {
    if (!isCancellation(result.error)) {
      console.warn("site_google_error", { error: result.error });
      showNotice(notice, text.errors.googleFailed);
    }
    return;
  }
  if (result.state !== pending.state) {
    console.error("site_google_state_mismatch", {});
    showNotice(notice, text.errors.googleFailed);
    return;
  }
  try {
    await signInOnSite("/v1/auth/google", result.idToken, pending.rawNonce, accountPath);
  } catch (error: unknown) {
    showNotice(notice, errorText(error, text));
  }
}

/** Sitenin kendi girişi: Apple (açılır pencere) ve Google (yönlendirme), jeton sunucuya. */
function startSiteSignIn(text: ClientCopy, notice: HTMLElement, accountPath: string, redirectUri: string): void {
  const appleNonces: SiteNonces = siteNonces();
  void setUpApple(text, notice, redirectUri, {
    nextHashedNonce: appleNonces.next,
    onIdentityToken: (identityToken: string): Promise<void> => signInOnSite("/v1/auth/apple", identityToken, appleNonces.raw(), accountPath),
  });
  setUpGoogleRedirect(text, notice, redirectUri);
}

/** Sağlayıcının yetkilendirme adresi: uygulamanın nonce özeti ve bu denemenin `state`'iyle. */
function providerAuthorizeUrl(pending: PendingAppSignIn, redirectUri: string): string {
  return pending.provider === "apple"
    ? appleAuthorizeRedirect(appleAuthorizeUrl, siteConfig.appleServiceId, redirectUri, pending.state, pending.hashedNonce)
    : googleAuthorizeRedirect(googleAuthorizeUrl, siteConfig.googleClientId, redirectUri, pending.state, pending.hashedNonce);
}

/**
 * Uygulama adına giriş: Apple ve Google düğmeleri sağlayıcıya yönlendirir (uygulamanın giriş penceresinde açılır
 * pencere güvenilir çalışmaz). Yönlendirmeden önce sağlayıcı, rastgele `state` ve nonce özeti `sessionStorage`'a yazılır;
 * yazılamazsa yönlendirilmez.
 */
function startAppSignIn(text: ClientCopy, notice: HTMLElement, redirectUri: string, hashedNonce: string): void {
  element("signin-intro", HTMLElement).classList.add("hidden");
  element("signin-app-intro", HTMLElement).classList.remove("hidden");
  const apple: HTMLButtonElement = element("apple-button", HTMLButtonElement);
  const google: HTMLButtonElement = element("google-redirect-button", HTMLButtonElement);
  const go = (provider: AppSignInProvider): void => {
    hideNotice(notice);
    const pending: PendingAppSignIn = { provider, state: randomHex(16), hashedNonce };
    try {
      window.sessionStorage.setItem(pendingAppSignInKey, serializePendingAppSignIn(pending));
    } catch (error: unknown) {
      console.error("app_sign_in_storage_failed", { error: error instanceof Error ? error.message : String(error) });
      showNotice(notice, text.errors.storageUnavailable);
      return;
    }
    apple.disabled = true;
    google.disabled = true;
    window.location.assign(providerAuthorizeUrl(pending, redirectUri));
  };
  apple.addEventListener("click", (): void => go("apple"));
  google.addEventListener("click", (): void => go("google"));
  apple.disabled = false;
  google.disabled = false;
}

/** Bekleyen denemeyi okur ve siler (tek kullanımlık); depolama okunamazsa ya da kayıt yoksa null. */
function takePendingAppSignIn(): PendingAppSignIn | null {
  try {
    const pending: PendingAppSignIn | null = parsePendingAppSignIn(window.sessionStorage.getItem(pendingAppSignInKey));
    window.sessionStorage.removeItem(pendingAppSignInKey);
    return pending;
  } catch (error: unknown) {
    console.error("app_sign_in_storage_failed", { error: error instanceof Error ? error.message : String(error) });
    return null;
  }
}

/**
 * Sağlayıcıdan `#` parçasıyla dönüşü işler: bekleyen deneme yoksa hata; `state` eşleşmezse ya da sağlayıcı hata
 * döndürdüyse aynı nonce özetiyle giriş yeniden gösterilir (kullanıcı vazgeçtiyse bildirim yok); jeton gelirse
 * uygulamaya iletilir. Jeton adreste ve tarayıcı geçmişinde kalmasın diye parça hemen silinir.
 */
function finishAppReturn(text: ClientCopy, notice: HTMLElement, result: Exclude<ProviderReturn, { readonly kind: "none" }>, signInPath: string, redirectUri: string): void {
  const pending: PendingAppSignIn | null = takePendingAppSignIn();
  window.history.replaceState(null, "", pending === null ? signInPath : appSignInPagePath(signInPath, pending.hashedNonce));
  if (pending === null) {
    element("signin-panel", HTMLElement).classList.add("hidden");
    showNotice(notice, text.errors.appRequestInvalid);
    console.error("app_return_without_pending", { kind: result.kind });
    return;
  }
  startAppSignIn(text, notice, redirectUri, pending.hashedNonce);
  if (result.kind === "error") {
    if (!isCancellation(result.error)) {
      console.warn("app_provider_error", { provider: pending.provider, error: result.error });
      showNotice(notice, pending.provider === "apple" ? text.errors.appleFailed : text.errors.googleFailed);
    }
    return;
  }
  if (result.state !== pending.state) {
    console.error("app_return_state_mismatch", { provider: pending.provider });
    showNotice(notice, text.errors.appReturnInvalid);
    return;
  }
  handOffToApp(appSignInUrl(pending.provider, result.idToken));
}

/** Sayfayı başlatır. */
function main(): void {
  const root: HTMLElement = element("signin", HTMLElement);
  const notice: HTMLElement = element("signin-error", HTMLElement);
  const text: ClientCopy = clientCopy;
  const returned: ProviderReturn = providerReturn(window.location.hash);
  if (returned.kind !== "none") {
    // Sitenin Google girişinden mi dönüldü (bu sekmede bekleyen site denemesi), yoksa uygulama adına girişten mi.
    const siteGoogle: PendingSiteGoogle | null = takePendingSiteGoogle();
    if (siteGoogle !== null) {
      void finishSiteGoogleReturn(text, notice, returned, siteGoogle, dataValue(root, "accountPath"), dataValue(root, "redirectUri"));
      return;
    }
    finishAppReturn(text, notice, returned, window.location.pathname, dataValue(root, "redirectUri"));
    return;
  }
  const mode: SignInMode = signInMode(window.location.search);
  if (mode.kind === "invalid-app") {
    element("signin-panel", HTMLElement).classList.add("hidden");
    showNotice(notice, text.errors.appRequestInvalid);
    console.error("app_sign_in_invalid", { search: window.location.search });
    return;
  }
  if (mode.kind === "app") {
    startAppSignIn(text, notice, dataValue(root, "redirectUri"), mode.hashedNonce);
    return;
  }
  startSiteSignIn(text, notice, dataValue(root, "accountPath"), dataValue(root, "redirectUri"));
}

main();
