// Tarayıcı betiklerinin ortak yardımcıları: öğe bulma, sayfa dili, hatayı kullanıcı metnine çevirme.
import { ApiNetworkError, ApiRequestError } from "./api";
import { type ClientCopy, clientCopy, fill } from "../i18n/client-copy";
import type { Lang } from "../i18n/routes";
import { isLang } from "./lang";

/** Sayfada beklenen öğe yok ya da türü farklı: sayfa ile betik uyuşmuyor. */
export class MissingElementError extends Error {
  override readonly name: string = "MissingElementError";
}

/** Kimliği verilen öğeyi beklenen türde döndürür; yoksa `MissingElementError`. */
export function element<T extends HTMLElement>(id: string, type: new () => T): T {
  const found: HTMLElement | null = document.getElementById(id);
  if (!(found instanceof type)) {
    throw new MissingElementError(`#${id} bulunamadı ya da ${type.name} değil.`);
  }
  return found;
}

/** Sayfanın dili (`<html lang>`); sitenin dili değilse `MissingElementError`. */
export function pageLang(): Lang {
  const lang: string = document.documentElement.lang;
  if (!isLang(lang)) {
    throw new MissingElementError(`<html lang="${lang}"> sitenin dili değil.`);
  }
  return lang;
}

/** Sayfa dilinin tarayıcı metinleri. */
export function pageCopy(): ClientCopy {
  return clientCopy[pageLang()];
}

/** Hatayı kullanıcıya gösterilecek metne çevirir; ayrıntı konsola yazılır. */
export function errorText(error: unknown, text: ClientCopy): string {
  console.error("request_failed", { error: error instanceof Error ? error.message : String(error) });
  if (error instanceof ApiNetworkError) {
    return text.errors.network;
  }
  if (error instanceof ApiRequestError) {
    if (error.code === "rate_limited") {
      return text.errors.rateLimited;
    }
    if (error.code === "turnstile_failed") {
      return text.errors.turnstile;
    }
    if (error.code === "upstream_unavailable" || error.code === "upstream_rejected") {
      return text.errors.upstream;
    }
    return fill(text.errors.generic, { code: error.code });
  }
  return fill(text.errors.generic, { code: error instanceof Error ? error.name : "unknown" });
}

/** Bildirim kutusunu metinle gösterir. */
export function showNotice(notice: HTMLElement, message: string): void {
  notice.textContent = message;
  notice.classList.remove("hidden");
}

/** Bildirim kutusunu gizler. */
export function hideNotice(notice: HTMLElement): void {
  notice.textContent = "";
  notice.classList.add("hidden");
}

/** Öğenin `data-*` değeri; yoksa `MissingElementError`. */
export function dataValue(owner: HTMLElement, key: string): string {
  const value: string | undefined = owner.dataset[key];
  if (value === undefined || value === "") {
    throw new MissingElementError(`#${owner.id} öğesinde data-${key} yok.`);
  }
  return value;
}
