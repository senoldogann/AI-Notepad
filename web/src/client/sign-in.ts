// Giriş sayfası. Sitenin kendi girişi: Apple ile giriş (açılır pencere) ve Google ile giriş (Google Identity Services
// düğmesi); tarayıcı rastgele bir ham nonce üretir, sağlayıcıya özetini verir, kimlik jetonunu ham nonce'la sunucuya
// yollar; başarılı girişte oturum saklanır ve hesap sayfasına geçilir. Mac uygulaması adına giriş (app-handoff.ts):
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
import { type Theme, currentTheme, dataValue, element, errorText, hideNotice, loadScript, onThemeChange, showNotice } from "./dom";
import { saveSession } from "./session";
import { appleAuthScriptUrl, appleAuthorizeUrl, googleAuthorizeUrl, googleScriptUrl } from "../config";
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

/** Google düğmesinin en dar ve en geniş hâli (Google'ın kabul ettiği aralık, piksel). */
const googleButtonMinWidth: number = 200;
const googleButtonMaxWidth: number = 400;

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

/** Google düğmesini kabın genişliğine ve sayfa temasına göre çizer (tema değişince yeniden çizilir). */
function renderGoogleButton(google: GoogleGlobal, container: HTMLElement, theme: Theme): void {
  const width: number = Math.round(Math.min(googleButtonMaxWidth, Math.max(googleButtonMinWidth, container.clientWidth)));
  google.accounts.id.renderButton(container, {
    type: "standard",
    theme: theme === "dark" ? "filled_black" : "outline",
    size: "large",
    text: "continue_with",
    shape: "pill",
    // Logo metnin yanında (Apple düğmesi gibi), düğmenin sol kenarına yaslı değil.
    logo_alignment: "center",
    width,
    locale: "en",
  });
}

/** Google'a hangi nonce özetinin verileceği ve kimlik jetonunun ne yapılacağı. */
interface GoogleFlow {
  /** Google'a verilecek nonce özeti (her denemede yeni). */
  readonly nextHashedNonce: () => Promise<string>;
  /** Kimlik jetonu geldiğinde. Hata fırlatırsa bildirim gösterilir ve yeni nonce'la yeniden hazırlanır. */
  readonly onCredential: (credential: string) => Promise<void>;
}

/** Google Identity Services'i yükler, düğmeyi çizer ve verilen akışa bağlar. Betik yüklenemezse Apple önerilir. */
async function setUpGoogle(text: ClientCopy, notice: HTMLElement, flow: GoogleFlow): Promise<void> {
  const container: HTMLElement = element("google-button", HTMLElement);
  try {
    await loadScript(googleScriptUrl);
  } catch (error: unknown) {
    container.classList.add("hidden");
    showNotice(notice, text.errors.googleUnavailable);
    console.error("google_script_failed", { error: error instanceof Error ? error.message : String(error) });
    return;
  }
  const google: GoogleGlobal | undefined = window.google;
  if (google === undefined) {
    container.classList.add("hidden");
    showNotice(notice, text.errors.googleUnavailable);
    console.error("google_script_failed", { error: "window.google tanımsız" });
    return;
  }
  const initialize = async (): Promise<void> => {
    google.accounts.id.initialize({
      client_id: siteConfig.googleClientId,
      nonce: await flow.nextHashedNonce(),
      ux_mode: "popup",
      auto_select: false,
      context: "signin",
      itp_support: true,
      callback: (response: GoogleCredentialResponse): void => {
        hideNotice(notice);
        flow.onCredential(response.credential).catch(async (error: unknown): Promise<void> => {
          showNotice(notice, errorText(error, text));
          await initialize();
          renderGoogleButton(google, container, currentTheme());
        });
      },
    });
  };
  await initialize();
  renderGoogleButton(google, container, currentTheme());
  onThemeChange((theme: Theme): void => {
    renderGoogleButton(google, container, theme);
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

/** Sitenin kendi girişi: Apple ve Google, jeton sunucuya. */
function startSiteSignIn(text: ClientCopy, notice: HTMLElement, accountPath: string, redirectUri: string): void {
  const appleNonces: SiteNonces = siteNonces();
  void setUpApple(text, notice, redirectUri, {
    nextHashedNonce: appleNonces.next,
    onIdentityToken: (identityToken: string): Promise<void> => signInOnSite("/v1/auth/apple", identityToken, appleNonces.raw(), accountPath),
  });
  const googleNonces: SiteNonces = siteNonces();
  void setUpGoogle(text, notice, {
    nextHashedNonce: googleNonces.next,
    onCredential: (credential: string): Promise<void> => signInOnSite("/v1/auth/google", credential, googleNonces.raw(), accountPath),
  });
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
  element("google-button", HTMLElement).classList.add("hidden");
  const apple: HTMLButtonElement = element("apple-button", HTMLButtonElement);
  const google: HTMLButtonElement = element("google-redirect-button", HTMLButtonElement);
  google.classList.remove("hidden");
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
