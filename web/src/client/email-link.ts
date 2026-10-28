// E-posta bağlantısı sayfası: adresin `#token=` parçasındaki tek kullanımlık jetonu `/v1/auth/email/verify` ile
// oturuma çevirir. Jeton hemen adres çubuğundan ve geçmişten silinir (yeniden yüklemede ya da paylaşımda kalmasın).
import { ApiRequestError, type RawResponse, parseSession, send } from "./api";
import { dataValue, element, errorText, pageCopy } from "./dom";
import { saveSession } from "./session";
import type { ClientCopy } from "../i18n/client-copy";

/** Adresin `#` parçasındaki jeton; yoksa null. Saf fonksiyondur. */
export function tokenFromHash(hash: string): string | null {
  const token: string | null = new URLSearchParams(hash.replace(/^#/, "")).get("token");
  return token === null || token === "" ? null : token;
}

/** Hata panelini gösterir. */
function fail(message: string): void {
  element("link-working", HTMLElement).classList.add("hidden");
  element("link-failed-text", HTMLElement).textContent = message;
  const panel: HTMLElement = element("link-failed", HTMLElement);
  panel.classList.remove("hidden");
  panel.focus();
}

/** Sayfayı başlatır. */
async function main(): Promise<void> {
  const root: HTMLElement = element("email-link", HTMLElement);
  const text: ClientCopy = pageCopy();
  const token: string | null = tokenFromHash(window.location.hash);
  history.replaceState(null, "", window.location.pathname);
  if (token === null) {
    fail(text.errors.invalidLink);
    return;
  }
  const path: string = "/v1/auth/email/verify";
  try {
    const response: RawResponse = await send({ method: "POST", path, body: { token }, accessToken: null, attempts: 1 });
    saveSession(parseSession(response, path));
    window.location.replace(dataValue(root, "accountPath"));
  } catch (error: unknown) {
    const linkRejected: boolean = error instanceof ApiRequestError && (error.code === "invalid_token" || error.code === "invalid_body");
    fail(linkRejected ? text.errors.invalidLink : errorText(error, text));
  }
}

void main();
