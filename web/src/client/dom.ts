// Tarayıcı betiklerinin ortak yardımcıları: öğe bulma, hatayı kullanıcı metnine çevirme, bildirimler, dış betik yükleme
// ve sayfa teması.
import { ApiNetworkError, ApiRequestError } from "./api";
import { type ClientCopy, fill } from "./copy";

/** Sayfada beklenen öğe yok ya da türü farklı: sayfa ile betik uyuşmuyor. */
export class MissingElementError extends Error {
  override readonly name: string = "MissingElementError";
}

/** Dış betik yüklenemedi. */
export class ScriptLoadError extends Error {
  override readonly name: string = "ScriptLoadError";
}

/** Kimliği verilen öğeyi beklenen türde döndürür; yoksa `MissingElementError`. */
export function element<T extends HTMLElement>(id: string, type: new () => T): T {
  const found: HTMLElement | null = document.getElementById(id);
  if (!(found instanceof type)) {
    throw new MissingElementError(`#${id} bulunamadı ya da ${type.name} değil.`);
  }
  return found;
}

/** Hatayı kullanıcıya gösterilecek metne çevirir; ayrıntı konsola yazılır. */
export function errorText(error: unknown, text: ClientCopy): string {
  console.error("request_failed", { error: error instanceof Error ? error.message : String(error) });
  if (error instanceof ApiNetworkError) {
    return text.errors.network;
  }
  if (error instanceof ApiRequestError) {
    if (error.code === "rate_limited" || error.status === 429) {
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

/** Dış betiği yükler (CSP bu kaynaklara izin verir). */
export function loadScript(src: string): Promise<void> {
  return new Promise((resolve: () => void, reject: (error: Error) => void): void => {
    const script: HTMLScriptElement = document.createElement("script");
    script.src = src;
    script.async = true;
    script.addEventListener("load", (): void => resolve());
    script.addEventListener("error", (): void => reject(new ScriptLoadError(`${src} yüklenemedi.`)));
    document.head.append(script);
  });
}

/** Sayfa teması. */
export type Theme = "light" | "dark";

/** Sayfanın şu anki teması (`<html data-theme>`, public/theme.js yazar). */
export function currentTheme(): Theme {
  return document.documentElement.dataset["theme"] === "dark" ? "dark" : "light";
}

/** Tema her değiştiğinde çağrılır (public/theme.js `gistsmith:themechange` olayı). */
export function onThemeChange(listener: (theme: Theme) => void): void {
  document.addEventListener("gistsmith:themechange", (): void => {
    listener(currentTheme());
  });
}
