// Giriş sayfası: Apple ile giriş (açılır pencere, nonce) ve Turnstile korumalı e-posta bağlantısı. Başarılı girişte
// oturum saklanır ve hesap sayfasına geçilir.
import { type RawResponse, parseSession, send } from "./api";
import { dataValue, element, errorText, hideNotice, pageCopy, showNotice } from "./dom";
import { saveSession } from "./session";
import { appleAuthScriptUrl, turnstileScriptUrl } from "../config";
import type { ClientCopy } from "../i18n/client-copy";
import { siteConfig } from "../site";

/** Dış betik yüklenemedi. */
class ScriptLoadError extends Error {
  override readonly name: string = "ScriptLoadError";
}

/** Apple yanıtındaki `state` gönderdiğimizle aynı değil. */
class AppleStateError extends Error {
  override readonly name: string = "AppleStateError";
}

/** Apple'a verilen tek kullanımlık değerler. */
interface AppleNonce {
  readonly raw: string;
  readonly state: string;
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

/** Dış betiği bir kez yükler (CSP bu kaynaklara izin verir). */
function loadScript(src: string): Promise<void> {
  return new Promise((resolve: () => void, reject: (error: Error) => void): void => {
    const script: HTMLScriptElement = document.createElement("script");
    script.src = src;
    script.async = true;
    script.addEventListener("load", (): void => resolve());
    script.addEventListener("error", (): void => reject(new ScriptLoadError(`${src} yüklenemedi.`)));
    document.head.append(script);
  });
}

/** Girişten dönen oturumu saklar ve hesap sayfasına geçer. */
function finishSignIn(response: RawResponse, path: string, accountPath: string): void {
  saveSession(parseSession(response, path));
  window.location.assign(accountPath);
}

/**
 * Apple'ı yeni bir nonce ve state ile hazırlar. Nonce tek kullanımlıktır (sunucu ikinci kez kabul etmez); her denemeden
 * sonra yenilenir. `init` tıklamadan önce yapılır: açılır pencere tıklamayla eş zamanlı açılmalı.
 */
async function prepareApple(apple: AppleIdGlobal, redirectUri: string): Promise<AppleNonce> {
  const nonce: AppleNonce = { raw: randomHex(32), state: randomHex(16) };
  apple.auth.init({
    clientId: siteConfig.appleServiceId,
    scope: "email",
    redirectURI: redirectUri,
    state: nonce.state,
    nonce: await sha256Hex(nonce.raw),
    usePopup: true,
  });
  return nonce;
}

/** Apple düğmesini bağlar. Betik yüklenemezse düğme kapanır ve e-posta yolu önerilir. */
async function setUpApple(text: ClientCopy, notice: HTMLElement, accountPath: string, redirectUri: string): Promise<void> {
  const button: HTMLButtonElement = element("apple-button", HTMLButtonElement);
  try {
    await loadScript(appleAuthScriptUrl);
  } catch (error: unknown) {
    button.disabled = true;
    showNotice(notice, text.errors.appleUnavailable);
    console.error("apple_script_failed", { error: error instanceof Error ? error.message : String(error) });
    return;
  }
  const apple: AppleIdGlobal | undefined = window.AppleID;
  if (apple === undefined) {
    button.disabled = true;
    showNotice(notice, text.errors.appleUnavailable);
    console.error("apple_script_failed", { error: "window.AppleID tanımsız" });
    return;
  }
  let nonce: AppleNonce = await prepareApple(apple, redirectUri);
  button.disabled = false;
  button.addEventListener("click", (): void => {
    hideNotice(notice);
    button.disabled = true;
    const attempt: AppleNonce = nonce;
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
          body: { identityToken: result.authorization.id_token, nonce: attempt.raw },
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
        nonce = await prepareApple(apple, redirectUri);
        button.disabled = false;
      });
  });
}

/** E-posta formunu ve Turnstile'ı bağlar. */
async function setUpEmail(text: ClientCopy, notice: HTMLElement, lang: string): Promise<void> {
  const form: HTMLFormElement = element("email-form", HTMLFormElement);
  const input: HTMLInputElement = element("email", HTMLInputElement);
  const submit: HTMLButtonElement = element("email-submit", HTMLButtonElement);
  const formPanel: HTMLElement = element("signin-panel", HTMLElement);
  const sentPanel: HTMLElement = element("signin-sent", HTMLElement);
  const again: HTMLButtonElement = element("signin-again", HTMLButtonElement);
  const container: HTMLElement = element("turnstile", HTMLElement);
  const submitLabel: string = submit.textContent;

  let turnstileToken: string | null = null;
  await loadScript(turnstileScriptUrl);
  const turnstile: TurnstileGlobal | undefined = window.turnstile;
  if (turnstile === undefined) {
    throw new ScriptLoadError("window.turnstile tanımsız.");
  }
  const widgetId: string = turnstile.render(container, {
    sitekey: siteConfig.turnstileSiteKey,
    action: "email-login",
    theme: "auto",
    language: lang,
    callback: (token: string): void => {
      turnstileToken = token;
      submit.disabled = false;
    },
    "expired-callback": (): void => {
      turnstileToken = null;
      submit.disabled = true;
    },
    "error-callback": (code: string): void => {
      turnstileToken = null;
      submit.disabled = true;
      showNotice(notice, text.errors.turnstile);
      console.error("turnstile_failed", { code });
    },
  });

  form.addEventListener("submit", (event: SubmitEvent): void => {
    event.preventDefault();
    if (turnstileToken === null || !form.reportValidity()) {
      return;
    }
    hideNotice(notice);
    submit.disabled = true;
    submit.textContent = text.working;
    const token: string = turnstileToken;
    turnstileToken = null;
    void send({ method: "POST", path: "/v1/auth/email/start", body: { email: input.value.trim(), turnstileToken: token }, accessToken: null, attempts: 1 })
      .then((): void => {
        formPanel.classList.add("hidden");
        sentPanel.classList.remove("hidden");
        sentPanel.focus();
      })
      .catch((error: unknown): void => {
        showNotice(notice, errorText(error, text));
      })
      .finally((): void => {
        // Turnstile yanıtı tek kullanımlıktır: her gönderimden sonra yenilenir.
        submit.textContent = submitLabel;
        turnstile.reset(widgetId);
      });
  });

  again.addEventListener("click", (): void => {
    sentPanel.classList.add("hidden");
    formPanel.classList.remove("hidden");
    input.focus();
  });
}

/** Sayfayı başlatır. */
function main(): void {
  const root: HTMLElement = element("signin", HTMLElement);
  const notice: HTMLElement = element("signin-error", HTMLElement);
  const text: ClientCopy = pageCopy();
  const accountPath: string = dataValue(root, "accountPath");
  const redirectUri: string = dataValue(root, "redirectUri");
  const lang: string = document.documentElement.lang;
  void setUpApple(text, notice, accountPath, redirectUri);
  setUpEmail(text, notice, lang).catch((error: unknown): void => {
    showNotice(notice, errorText(error, text));
  });
}

main();
