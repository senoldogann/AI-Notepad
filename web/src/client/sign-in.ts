// Giriş sayfası: Apple ile giriş (açılır pencere) ve Google ile giriş (Google Identity Services düğmesi). Her ikisinde
// tarayıcı rastgele bir ham nonce üretir, sağlayıcıya özetini verir, kimlik jetonunu ham nonce'la sunucuya yollar;
// başarılı girişte oturum saklanır ve hesap sayfasına geçilir. Mac uygulaması adına girişte (app-handoff.ts) yalnızca
// Google düğmesi görünür ve jeton uygulamaya iletilir.
import { type RawResponse, parseSession, send } from "./api";
import { appGoogleSignInUrl, type SignInMode, signInMode } from "./app-handoff";
import { type ClientCopy, clientCopy } from "./copy";
import { type Theme, currentTheme, dataValue, element, errorText, hideNotice, loadScript, onThemeChange, showNotice } from "./dom";
import { saveSession } from "./session";
import { appleAuthScriptUrl, googleScriptUrl } from "../config";
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

/** Apple'ı nonce ve state ile hazırlar. `init` tıklamadan önce yapılır: açılır pencere tıklamayla eş zamanlı açılmalı. */
function prepareApple(apple: AppleIdGlobal, redirectUri: string, nonce: Nonce, state: string): void {
  apple.auth.init({
    clientId: siteConfig.appleServiceId,
    scope: "email",
    redirectURI: redirectUri,
    state,
    nonce: nonce.hashed,
    usePopup: true,
  });
}

/** Apple düğmesini bağlar. Betik yüklenemezse düğme kapalı kalır ve Google önerilir. */
async function setUpApple(text: ClientCopy, notice: HTMLElement, accountPath: string, redirectUri: string): Promise<void> {
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
  let nonce: Nonce = await newNonce();
  let state: string = randomHex(16);
  prepareApple(apple, redirectUri, nonce, state);
  button.disabled = false;
  button.addEventListener("click", (): void => {
    hideNotice(notice);
    button.disabled = true;
    const attempt: { readonly nonce: Nonce; readonly state: string } = { nonce, state };
    void apple.auth
      .signIn()
      .then(async (result: AppleSignInResponse): Promise<void> => {
        if (result.authorization.state !== attempt.state) {
          throw new AppleStateError("Apple yanıtındaki state eşleşmiyor.");
        }
        const path: string = "/v1/auth/apple";
        const response: RawResponse = await send({
          method: "POST",
          path,
          body: { identityToken: result.authorization.id_token, nonce: attempt.nonce.raw },
          accessToken: null,
          attempts: 1,
        });
        finishSignIn(response, path, accountPath);
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
        nonce = await newNonce();
        state = randomHex(16);
        prepareApple(apple, redirectUri, nonce, state);
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
    logo_alignment: "left",
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

/** Sitenin kendi girişi: Apple ve Google, jeton sunucuya. */
function startSiteSignIn(text: ClientCopy, notice: HTMLElement, accountPath: string, redirectUri: string): void {
  void setUpApple(text, notice, accountPath, redirectUri);
  let pending: Nonce | null = null;
  void setUpGoogle(text, notice, {
    nextHashedNonce: async (): Promise<string> => {
      pending = await newNonce();
      return pending.hashed;
    },
    onCredential: async (credential: string): Promise<void> => {
      const nonce: Nonce | null = pending;
      if (nonce === null) {
        throw new Error("Google nonce hazırlanmadan jeton geldi.");
      }
      const path: string = "/v1/auth/google";
      const response: RawResponse = await send({ method: "POST", path, body: { identityToken: credential, nonce: nonce.raw }, accessToken: null, attempts: 1 });
      finishSignIn(response, path, accountPath);
    },
  });
}

/** Uygulama adına giriş: yalnızca Google, uygulamanın nonce özetiyle; jeton uygulamaya. */
function startAppSignIn(text: ClientCopy, notice: HTMLElement, hashedNonce: string): void {
  element("apple-block", HTMLElement).classList.add("hidden");
  element("signin-intro", HTMLElement).classList.add("hidden");
  element("signin-app-intro", HTMLElement).classList.remove("hidden");
  void setUpGoogle(text, notice, {
    nextHashedNonce: async (): Promise<string> => hashedNonce,
    onCredential: async (credential: string): Promise<void> => {
      handOffToApp(appGoogleSignInUrl(credential));
    },
  });
}

/** Sayfayı başlatır. */
function main(): void {
  const root: HTMLElement = element("signin", HTMLElement);
  const notice: HTMLElement = element("signin-error", HTMLElement);
  const text: ClientCopy = clientCopy;
  const mode: SignInMode = signInMode(window.location.search);
  if (mode.kind === "invalid-app") {
    element("signin-panel", HTMLElement).classList.add("hidden");
    showNotice(notice, text.errors.appRequestInvalid);
    console.error("app_sign_in_invalid", { search: window.location.search });
    return;
  }
  if (mode.kind === "app") {
    startAppSignIn(text, notice, mode.hashedNonce);
    return;
  }
  startSiteSignIn(text, notice, dataValue(root, "accountPath"), dataValue(root, "redirectUri"));
}

main();
