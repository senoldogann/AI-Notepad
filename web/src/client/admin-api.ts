// Yönetim panelinin sunucu uçları (`/v1/admin/*`, Bearer oturum): özet istatistikler, bildirim kutusu listesi, tek
// bildirim ve durum değişikliği. Yanıtlar api.ts'teki okuyucularla katı biçimde doğrulanır.
// Zaman alanları (`generatedAt`, `createdAt`) Unix ms sayısı ya da ISO 8601 metni olabilir; ikisi de ms'ye çevrilir.
// Bildirim kimliği metin ya da tamsayı olabilir; metne çevrilir.
import {
  ApiResponseError,
  type JsonObject,
  type JsonValue,
  type RawResponse,
  nullableStringField,
  numberField,
  objectArrayField,
  objectField,
  parseObject,
  stringField,
} from "./api";
import { authorizedSend } from "./session";

/** Bir günün değeri (`YYYY-MM-DD`, UTC). */
export interface DayCount {
  readonly day: string;
  readonly count: number;
}

/** Bir günün toplantıları (deneme ve abonelik ayrı). */
export interface DayMeetings {
  readonly day: string;
  readonly trial: number;
  readonly subscription: number;
}

/** Bir günün yapay zekâ harcaması (USD). */
export interface DaySpend {
  readonly day: string;
  readonly usd: number;
}

/** `GET /v1/admin/stats` yanıtı. */
export interface AdminStats {
  /** Unix ms. */
  readonly generatedAt: number;
  readonly downloads: { readonly total: number; readonly last30Days: readonly DayCount[] };
  readonly users: {
    readonly total: number;
    readonly newLast30Days: readonly DayCount[];
    readonly byProvider: { readonly apple: number; readonly google: number };
  };
  readonly trials: { readonly activeTrialUsers: number; readonly exhaustedTrialUsers: number };
  readonly subscriptions: { readonly active: number; readonly grace: number; readonly ending: number; readonly canceledTotal: number; readonly mrrUsd: number };
  readonly meetings: { readonly last30Days: readonly DayMeetings[]; readonly hoursThisMonth: number };
  readonly spend: { readonly todayUsd: number; readonly ceilingUsd: number; readonly last30Days: readonly DaySpend[] };
  readonly tokens: { readonly thisMonth: number };
  readonly reports: { readonly openFeedback: number; readonly openCrash: number; readonly openContact: number };
  /** Stripe anahtarının modu (canlı ya da test). */
  readonly stripe: { readonly mode: StripeMode };
  /** ElevenLabs plan döngüsündeki yazıya çevirme saatleri ve planın sınırı. */
  readonly elevenLabs: { readonly usedHours: number; readonly capHours: number; readonly percent: number };
}

/** Stripe anahtarının modu. */
export type StripeMode = "live" | "test";

/** Bildirim türü. */
export type ReportKind = "feedback" | "crash" | "contact";

/** Bildirim durumu. */
export type ReportStatus = "open" | "done";

/** Listedeki bildirim. */
export interface ReportSummary {
  readonly id: string;
  readonly kind: ReportKind;
  readonly status: ReportStatus;
  /** Unix ms. */
  readonly createdAt: number;
  readonly userId: string | null;
  readonly email: string | null;
  readonly appVersion: string | null;
  readonly os: string | null;
  readonly summary: string | null;
}

/** Bildirim listesinin bir sayfası; `nextBefore` sonraki sayfanın `before` değeri (yoksa null). */
export interface ReportPage {
  readonly items: readonly ReportSummary[];
  readonly nextBefore: number | null;
}

/** Bildirimin tamamı: mesaj ve (çökme raporunda) JSON metni. */
export interface ReportDetail {
  readonly id: string;
  readonly kind: ReportKind;
  readonly status: ReportStatus;
  readonly createdAt: number;
  readonly userId: string | null;
  readonly email: string | null;
  readonly appVersion: string | null;
  readonly os: string | null;
  readonly message: string | null;
  readonly payload: string | null;
}

const dayPattern: RegExp = /^\d{4}-\d{2}-\d{2}$/;

/** `YYYY-MM-DD` gün alanı. */
function dayField(object: JsonObject, response: RawResponse, path: string): string {
  const day: string = stringField(object, "day", response, path);
  if (!dayPattern.test(day)) {
    throw new ApiResponseError(path, response.status, `"day" YYYY-MM-DD değil: ${day}`, response.text);
  }
  return day;
}

/** Zaman alanı: Unix ms sayısı ya da ISO 8601 metni; ms döner. */
function timestampField(object: JsonObject, key: string, response: RawResponse, path: string): number {
  const value: JsonValue | undefined = object[key];
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && !Number.isNaN(Date.parse(value))) {
    return Date.parse(value);
  }
  throw new ApiResponseError(path, response.status, `"${key}" zaman değil`, response.text);
}

/** Kimlik alanı: metin ya da tamsayı; metin döner. */
function idField(object: JsonObject, response: RawResponse, path: string): string {
  const value: JsonValue | undefined = object["id"];
  if (typeof value === "string" && value !== "") {
    return value;
  }
  if (typeof value === "number" && Number.isInteger(value)) {
    return String(value);
  }
  throw new ApiResponseError(path, response.status, '"id" metin ya da tamsayı değil', response.text);
}

/** Bildirim türü alanı. */
function kindField(object: JsonObject, response: RawResponse, path: string): ReportKind {
  const kind: string = stringField(object, "kind", response, path);
  if (kind !== "feedback" && kind !== "crash" && kind !== "contact") {
    throw new ApiResponseError(path, response.status, `bilinmeyen tür "${kind}"`, response.text);
  }
  return kind;
}

/** Bildirim durumu alanı. */
function statusField(object: JsonObject, response: RawResponse, path: string): ReportStatus {
  const status: string = stringField(object, "status", response, path);
  if (status !== "open" && status !== "done") {
    throw new ApiResponseError(path, response.status, `bilinmeyen durum "${status}"`, response.text);
  }
  return status;
}

/** `GET /v1/admin/stats` yanıtını okur. */
export function parseAdminStats(response: RawResponse, path: string): AdminStats {
  const body: JsonObject = parseObject(response, path);
  const downloads: JsonObject = objectField(body, "downloads", response, path);
  const users: JsonObject = objectField(body, "users", response, path);
  const byProvider: JsonObject = objectField(users, "byProvider", response, path);
  const trials: JsonObject = objectField(body, "trials", response, path);
  const subscriptions: JsonObject = objectField(body, "subscriptions", response, path);
  const meetings: JsonObject = objectField(body, "meetings", response, path);
  const spend: JsonObject = objectField(body, "spend", response, path);
  const tokens: JsonObject = objectField(body, "tokens", response, path);
  const reports: JsonObject = objectField(body, "reports", response, path);
  const stripe: JsonObject = objectField(body, "stripe", response, path);
  const elevenLabs: JsonObject = objectField(body, "elevenLabs", response, path);
  const dayCounts = (owner: JsonObject, key: string): DayCount[] =>
    objectArrayField(owner, key, response, path).map((item: JsonObject): DayCount => ({ day: dayField(item, response, path), count: numberField(item, "count", response, path) }));
  return {
    generatedAt: timestampField(body, "generatedAt", response, path),
    downloads: { total: numberField(downloads, "total", response, path), last30Days: dayCounts(downloads, "last30Days") },
    users: {
      total: numberField(users, "total", response, path),
      newLast30Days: dayCounts(users, "newLast30Days"),
      byProvider: { apple: numberField(byProvider, "apple", response, path), google: numberField(byProvider, "google", response, path) },
    },
    trials: {
      activeTrialUsers: numberField(trials, "activeTrialUsers", response, path),
      exhaustedTrialUsers: numberField(trials, "exhaustedTrialUsers", response, path),
    },
    subscriptions: {
      active: numberField(subscriptions, "active", response, path),
      grace: numberField(subscriptions, "grace", response, path),
      ending: numberField(subscriptions, "ending", response, path),
      canceledTotal: numberField(subscriptions, "canceledTotal", response, path),
      mrrUsd: numberField(subscriptions, "mrrUsd", response, path),
    },
    meetings: {
      last30Days: objectArrayField(meetings, "last30Days", response, path).map(
        (item: JsonObject): DayMeetings => ({
          day: dayField(item, response, path),
          trial: numberField(item, "trial", response, path),
          subscription: numberField(item, "subscription", response, path),
        }),
      ),
      hoursThisMonth: numberField(meetings, "hoursThisMonth", response, path),
    },
    spend: {
      todayUsd: numberField(spend, "todayUsd", response, path),
      ceilingUsd: numberField(spend, "ceilingUsd", response, path),
      last30Days: objectArrayField(spend, "last30Days", response, path).map(
        (item: JsonObject): DaySpend => ({ day: dayField(item, response, path), usd: numberField(item, "usd", response, path) }),
      ),
    },
    tokens: { thisMonth: numberField(tokens, "thisMonth", response, path) },
    reports: {
      openFeedback: numberField(reports, "openFeedback", response, path),
      openCrash: numberField(reports, "openCrash", response, path),
      openContact: numberField(reports, "openContact", response, path),
    },
    stripe: { mode: stripeModeField(stripe, response, path) },
    elevenLabs: {
      usedHours: numberField(elevenLabs, "usedHours", response, path),
      capHours: numberField(elevenLabs, "capHours", response, path),
      percent: numberField(elevenLabs, "percent", response, path),
    },
  };
}

/** Stripe modu alanı: "live" ya da "test". */
function stripeModeField(object: JsonObject, response: RawResponse, path: string): StripeMode {
  const mode: string = stringField(object, "mode", response, path);
  if (mode !== "live" && mode !== "test") {
    throw new ApiResponseError(path, response.status, `bilinmeyen Stripe modu "${mode}"`, response.text);
  }
  return mode;
}

/** Bildirim listesi öğesini okur. */
function parseReportSummary(item: JsonObject, response: RawResponse, path: string): ReportSummary {
  return {
    id: idField(item, response, path),
    kind: kindField(item, response, path),
    status: statusField(item, response, path),
    createdAt: timestampField(item, "createdAt", response, path),
    userId: nullableStringField(item, "userId", response, path),
    email: nullableStringField(item, "email", response, path),
    appVersion: nullableStringField(item, "appVersion", response, path),
    os: nullableStringField(item, "os", response, path),
    summary: nullableStringField(item, "summary", response, path),
  };
}

/** `GET /v1/admin/reports` yanıtını okur. */
export function parseReportPage(response: RawResponse, path: string): ReportPage {
  const body: JsonObject = parseObject(response, path);
  return {
    items: objectArrayField(body, "items", response, path).map((item: JsonObject): ReportSummary => parseReportSummary(item, response, path)),
    nextBefore: body["nextBefore"] === null ? null : numberField(body, "nextBefore", response, path),
  };
}

/** `GET /v1/admin/reports/{id}` yanıtını okur. */
export function parseReportDetail(response: RawResponse, path: string): ReportDetail {
  const body: JsonObject = parseObject(response, path);
  return {
    id: idField(body, response, path),
    kind: kindField(body, response, path),
    status: statusField(body, response, path),
    createdAt: timestampField(body, "createdAt", response, path),
    userId: nullableStringField(body, "userId", response, path),
    email: nullableStringField(body, "email", response, path),
    appVersion: nullableStringField(body, "appVersion", response, path),
    os: nullableStringField(body, "os", response, path),
    message: nullableStringField(body, "message", response, path),
    payload: nullableStringField(body, "payload", response, path),
  };
}

/** Özet istatistikler. */
export async function fetchStats(): Promise<AdminStats> {
  const path: string = "/v1/admin/stats";
  return parseAdminStats(await authorizedSend({ method: "GET", path, body: null, attempts: 3 }), path);
}

/** Bildirim listesinin bir sayfası (`before` yoksa en yeniler). */
export async function fetchReports(kind: ReportKind, status: ReportStatus, before: number | null): Promise<ReportPage> {
  const query: URLSearchParams = new URLSearchParams({ kind, status });
  if (before !== null) {
    query.set("before", String(before));
  }
  const path: string = `/v1/admin/reports?${query.toString()}`;
  return parseReportPage(await authorizedSend({ method: "GET", path, body: null, attempts: 3 }), path);
}

/** Tek bildirim. */
export async function fetchReport(id: string): Promise<ReportDetail> {
  const path: string = `/v1/admin/reports/${encodeURIComponent(id)}`;
  return parseReportDetail(await authorizedSend({ method: "GET", path, body: null, attempts: 3 }), path);
}

/** Bildirimin durumunu değiştirir (204). */
export async function setReportStatus(id: string, status: ReportStatus): Promise<void> {
  const path: string = `/v1/admin/reports/${encodeURIComponent(id)}`;
  await authorizedSend({ method: "POST", path, body: { status }, attempts: 1 });
}
