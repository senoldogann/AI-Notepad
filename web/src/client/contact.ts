// İletişim formu: e-posta, mesaj (en çok 5000 karakter) ve Turnstile; `POST /v1/reports` `{kind: "contact", …}` → 202.
// Turnstile parçacığı sayfa temasıyla çizilir; tema değişince (henüz çözülmemişse de) yeniden çizilir.
import { send } from "./api";
import { type ClientCopy, clientCopy, fill } from "./copy";
import { ScriptLoadError, type Theme, currentTheme, element, errorText, hideNotice, loadScript, onThemeChange, showNotice } from "./dom";
import { turnstileScriptUrl } from "../config";
import { siteConfig } from "../site";

/** Mesajın en uzun hâli (sunucunun sınırıyla aynı). */
const maxMessageLength: number = 5000;

/** Turnstile yanıtı ve parçacığı. */
interface TurnstileState {
  widgetId: string;
  token: string | null;
}

/** Sayfayı başlatır. */
async function main(): Promise<void> {
  const text: ClientCopy = clientCopy;
  const form: HTMLFormElement = element("contact-form", HTMLFormElement);
  const email: HTMLInputElement = element("contact-email", HTMLInputElement);
  const message: HTMLTextAreaElement = element("contact-message", HTMLTextAreaElement);
  const counter: HTMLElement = element("contact-counter", HTMLElement);
  const submit: HTMLButtonElement = element("contact-submit", HTMLButtonElement);
  const notice: HTMLElement = element("contact-error", HTMLElement);
  const sent: HTMLElement = element("contact-sent", HTMLElement);
  const again: HTMLButtonElement = element("contact-again", HTMLButtonElement);
  const container: HTMLElement = element("turnstile", HTMLElement);
  const submitLabel: string = submit.textContent;

  const updateCounter = (): void => {
    counter.textContent = fill(text.characters, { count: message.value.length.toLocaleString("en-GB"), max: maxMessageLength.toLocaleString("en-GB") });
  };
  message.addEventListener("input", updateCounter);
  updateCounter();

  await loadScript(turnstileScriptUrl);
  const turnstile: TurnstileGlobal | undefined = window.turnstile;
  if (turnstile === undefined) {
    throw new ScriptLoadError("window.turnstile tanımsız.");
  }
  const state: TurnstileState = { widgetId: "", token: null };
  const renderWidget = (theme: Theme): string =>
    turnstile.render(container, {
      sitekey: siteConfig.turnstileSiteKey,
      action: "contact",
      theme,
      language: "en",
      callback: (token: string): void => {
        state.token = token;
        submit.disabled = false;
      },
      "expired-callback": (): void => {
        state.token = null;
        submit.disabled = true;
      },
      "error-callback": (code: string): void => {
        state.token = null;
        submit.disabled = true;
        showNotice(notice, text.errors.turnstile);
        console.error("turnstile_failed", { code });
      },
    });
  state.widgetId = renderWidget(currentTheme());
  onThemeChange((theme: Theme): void => {
    turnstile.remove(state.widgetId);
    state.token = null;
    submit.disabled = true;
    state.widgetId = renderWidget(theme);
  });

  form.addEventListener("submit", (event: SubmitEvent): void => {
    event.preventDefault();
    if (state.token === null || !form.reportValidity()) {
      return;
    }
    if (message.value.length > maxMessageLength) {
      showNotice(notice, text.errors.messageTooLong);
      return;
    }
    hideNotice(notice);
    submit.disabled = true;
    submit.textContent = text.working;
    const turnstileToken: string = state.token;
    state.token = null;
    void send({
      method: "POST",
      path: "/v1/reports",
      body: { kind: "contact", email: email.value.trim(), message: message.value.trim(), turnstileToken },
      accessToken: null,
      attempts: 1,
    })
      .then((): void => {
        form.classList.add("hidden");
        sent.classList.remove("hidden");
        sent.focus();
        form.reset();
        updateCounter();
      })
      .catch((error: unknown): void => {
        showNotice(notice, errorText(error, text));
      })
      .finally((): void => {
        // Turnstile yanıtı tek kullanımlıktır: her gönderimden sonra yenilenir.
        submit.textContent = submitLabel;
        turnstile.reset(state.widgetId);
      });
  });

  again.addEventListener("click", (): void => {
    sent.classList.add("hidden");
    form.classList.remove("hidden");
    email.focus();
  });
}

main().catch((error: unknown): void => {
  showNotice(element("contact-error", HTMLElement), errorText(error, clientCopy));
});
