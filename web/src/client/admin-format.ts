// Yönetim panelinin ortak biçimlendiricileri ve küçük DOM yardımcıları (genel bakış, kullanıcılar, işletim, bildirimler).
// Biçimlendiriciler saftır; DOM yardımcıları yalnızca yeni öğe üretir (satır içi stil kullanılmaz: CSP).
import { type AdminClientCopy, clientCopy, fill } from "./copy";
import { siteLocale } from "../config";

const adminText: AdminClientCopy = clientCopy.admin;

/** Sayı (binlik ayraçlı, en çok bir ondalık). Saf fonksiyondur. */
export function formatCount(value: number): string {
  return new Intl.NumberFormat(siteLocale, { maximumFractionDigits: 1 }).format(value);
}

/** Büyük sayıyı kısa yazar ("6.5M"). Saf fonksiyondur. */
export function formatCompact(value: number): string {
  return new Intl.NumberFormat(siteLocale, { notation: "compact", maximumFractionDigits: 1 }).format(value);
}

/** Dolar tutarı. Saf fonksiyondur. */
export function formatUsd(value: number): string {
  return new Intl.NumberFormat(siteLocale, { style: "currency", currency: "USD", currencyDisplay: "narrowSymbol", maximumFractionDigits: 2 }).format(value);
}

/** Oran (0–1) yüzde olarak; payda 0 ise "—". Saf fonksiyondur. */
export function formatRate(part: number, whole: number): string {
  return whole === 0 ? adminText.none : new Intl.NumberFormat(siteLocale, { style: "percent", maximumFractionDigits: 1 }).format(part / whole);
}

/** `YYYY-MM-DD` günü kısa yazar ("29 Oct"). Saf fonksiyondur. */
export function formatDay(day: string): string {
  return new Intl.DateTimeFormat(siteLocale, { day: "numeric", month: "short", timeZone: "UTC" }).format(new Date(`${day}T00:00:00Z`));
}

/** Zamanı tarih ve saatle yazar. Saf fonksiyondur. */
export function formatTime(ms: number): string {
  return new Intl.DateTimeFormat(siteLocale, { dateStyle: "medium", timeStyle: "short" }).format(new Date(ms));
}

/** Zamanı yalnızca tarihle yazar. Saf fonksiyondur. */
export function formatDate(ms: number): string {
  return new Intl.DateTimeFormat(siteLocale, { dateStyle: "medium" }).format(new Date(ms));
}

/** Zamanı şimdiye göre yazar ("3 hours ago", "in 2 days"). Saf fonksiyondur. */
export function formatRelative(ms: number, nowMs: number): string {
  const seconds: number = Math.round((ms - nowMs) / 1000);
  const steps: readonly (readonly [Intl.RelativeTimeFormatUnit, number])[] = [
    ["day", 86_400],
    ["hour", 3_600],
    ["minute", 60],
  ];
  const format: Intl.RelativeTimeFormat = new Intl.RelativeTimeFormat(siteLocale, { numeric: "auto" });
  for (const [unit, size] of steps) {
    if (Math.abs(seconds) >= size) {
      return format.format(Math.trunc(seconds / size), unit);
    }
  }
  return format.format(0, "minute");
}

/** Zaman ya da yoksa "—". Saf fonksiyondur. */
export function formatOptionalTime(ms: number | null): string {
  return ms === null ? adminText.none : formatTime(ms);
}

/** Hesap kimliğinin kısa biçimi (ilk 8 karakter). Saf fonksiyondur. */
export function shortId(id: string): string {
  return id.slice(0, 8);
}

/** `{ad}` yer tutuculu metni sayılarla doldurur. Saf fonksiyondur. */
export function fillCounts(template: string, values: Readonly<Record<string, number>>): string {
  return fill(template, Object.fromEntries(Object.entries(values).map(([key, value]: [string, number]): [string, string] => [key, formatCount(value)])));
}

/** Sınıflı ve metinli yeni HTML öğesi. */
export function node<Tag extends keyof HTMLElementTagNameMap>(tag: Tag, className: string, text: string): HTMLElementTagNameMap[Tag] {
  const created: HTMLElementTagNameMap[Tag] = document.createElement(tag);
  if (className !== "") {
    created.className = className;
  }
  created.textContent = text;
  return created;
}

/** Rozet (`pill`); `tone` boşsa nötr. */
export function pill(text: string, tone: "" | "ok" | "warn"): HTMLSpanElement {
  return node("span", tone === "" ? "pill pill--compact" : `pill pill--compact pill--${tone}`, text);
}

/** Tablo satırı: hücreler metin ya da hazır öğe. */
export function tableRow(cells: readonly (string | HTMLElement)[]): HTMLTableRowElement {
  const row: HTMLTableRowElement = document.createElement("tr");
  for (const cell of cells) {
    const td: HTMLTableCellElement = document.createElement("td");
    if (typeof cell === "string") {
      td.textContent = cell;
    } else {
      td.append(cell);
    }
    row.append(td);
  }
  return row;
}
