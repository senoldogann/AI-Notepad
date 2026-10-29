// Abonelik sunucusunun (server/src/app.ts) sitenin kullandığı uçları: giriş, oturum yenileme, hesap, ödeme, hesap
// silme ve iletişim formu. Yanıtlar elle doğrulanır (bağımlılık yok); beklenmeyen biçim `ApiResponseError` verir.
// Alan okuyucuları yönetim paneli istemcisi (admin-api.ts) de kullanır.
import { siteConfig } from "../site";

/** Sunucunun döndürdüğü oturum (`sessionBody`). */
export interface SessionTokens {
  readonly accessToken: string;
  readonly refreshToken: string;
  /** Erişim jetonunun ömrü (saniye). */
  readonly expiresIn: number;
  readonly userId: string;
}

/** Aboneliğin erişim durumu (server/src/entitlements.ts). */
export type SubscriptionAccess = "active" | "grace" | "none";

/**
 * `GET /v1/me` yanıtındaki abonelik: ek sürenin bitişi yalnızca `grace` durumunda vardır. `cancelAt` iptal edilmiş
 * aboneliğin biteceği andır; yenilenecekse null.
 */
export type SubscriptionInfo =
  | { readonly status: string; readonly currentPeriodEnd: string; readonly cancelAt: string | null; readonly access: "grace"; readonly graceEndsAt: string }
  | { readonly status: string; readonly currentPeriodEnd: string; readonly cancelAt: string | null; readonly access: "active" | "none"; readonly graceEndsAt: null };

/** `GET /v1/me` yanıtı. */
export interface Entitlements {
  readonly userId: string;
  readonly plan: "trial" | "subscription";
  readonly trialMeetingsTotal: number;
  readonly trialMeetingsLeft: number;
  readonly monthlyHoursUsed: number;
  readonly monthlyHoursCap: number;
  readonly subscription: SubscriptionInfo | null;
}

/** Sunucunun `{error: {code, message}}` gövdesiyle döndürdüğü hata. */
export class ApiRequestError extends Error {
  override readonly name: string = "ApiRequestError";
  readonly status: number;
  readonly code: string;
  readonly path: string;
  /** Yetkisiz yönetim isteğinde (403 `forbidden`) sunucunun bildirdiği giriş kimliği (`google:<sub>`); yoksa null. */
  readonly identity: string | null;

  constructor(path: string, status: number, code: string, message: string, identity: string | null) {
    super(`${path} isteği başarısız (durum ${status}, kod ${code}): ${message}`);
    this.status = status;
    this.code = code;
    this.path = path;
    this.identity = identity;
  }
}

/** Sunucuya ulaşılamadı (ağ hatası, CORS reddi). */
export class ApiNetworkError extends Error {
  override readonly name: string = "ApiNetworkError";
  readonly path: string;

  constructor(path: string, cause: string) {
    super(`${path} isteği sunucuya ulaşamadı: ${cause}`);
    this.path = path;
  }
}

/** Yanıt beklenen biçimde değil. */
export class ApiResponseError extends Error {
  override readonly name: string = "ApiResponseError";
  readonly path: string;
  readonly status: number;
  readonly body: string;

  constructor(path: string, status: number, problem: string, body: string) {
    super(`${path} yanıtı beklenen biçimde değil (durum ${status}): ${problem}; gövde: ${body.slice(0, 300)}`);
    this.path = path;
    this.status = status;
    this.body = body;
  }
}

/** JSON değeri (ayrıştırma sonrası; alanlar aşağıdaki okuyucularla doğrulanır). */
export type JsonValue = string | number | boolean | null | JsonValue[] | { readonly [key: string]: JsonValue };
/** JSON nesnesi. */
export type JsonObject = { readonly [key: string]: JsonValue };

/** HTTP yöntemleri. */
type Method = "GET" | "POST" | "DELETE";

/** Bir isteğin tanımı. */
export interface ApiCall {
  readonly method: Method;
  readonly path: string;
  /** JSON gövde; gövdesiz istekte null. */
  readonly body: JsonObject | null;
  /** Bearer erişim jetonu; kimliksiz istekte null. */
  readonly accessToken: string | null;
  /** Ağ hatası ve 502/503'te toplam deneme sayısı; yan etkili istekte 1. */
  readonly attempts: number;
}

/** Ham yanıt: durum ve gövde metni. */
export interface RawResponse {
  readonly status: number;
  readonly text: string;
}

/** Değer JSON nesnesi mi. Saf fonksiyondur. */
function isObject(value: JsonValue): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Nesnedeki metin alanı; yoksa `ApiResponseError`. */
export function stringField(object: JsonObject, key: string, response: RawResponse, path: string): string {
  const value: JsonValue | undefined = object[key];
  if (typeof value !== "string") {
    throw new ApiResponseError(path, response.status, `"${key}" metin değil`, response.text);
  }
  return value;
}

/** Nesnedeki sayı alanı; yoksa `ApiResponseError`. */
export function numberField(object: JsonObject, key: string, response: RawResponse, path: string): number {
  const value: JsonValue | undefined = object[key];
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new ApiResponseError(path, response.status, `"${key}" sayı değil`, response.text);
  }
  return value;
}

/** Nesnedeki metin ya da null alanı; ikisi de değilse (eksikse de) `ApiResponseError`. */
export function nullableStringField(object: JsonObject, key: string, response: RawResponse, path: string): string | null {
  return object[key] === null ? null : stringField(object, key, response, path);
}

/** Nesnedeki iç nesne; değilse `ApiResponseError`. */
export function objectField(object: JsonObject, key: string, response: RawResponse, path: string): JsonObject {
  const value: JsonValue | undefined = object[key];
  if (value === undefined || !isObject(value)) {
    throw new ApiResponseError(path, response.status, `"${key}" nesne değil`, response.text);
  }
  return value;
}

/** Nesnedeki nesne dizisi; dizi değilse ya da öğelerden biri nesne değilse `ApiResponseError`. */
export function objectArrayField(object: JsonObject, key: string, response: RawResponse, path: string): JsonObject[] {
  const value: JsonValue | undefined = object[key];
  if (!Array.isArray(value)) {
    throw new ApiResponseError(path, response.status, `"${key}" dizi değil`, response.text);
  }
  return value.map((item: JsonValue, index: number): JsonObject => {
    if (!isObject(item)) {
      throw new ApiResponseError(path, response.status, `"${key}[${index}]" nesne değil`, response.text);
    }
    return item;
  });
}

/** Gövdeyi JSON nesnesi olarak ayrıştırır; değilse `ApiResponseError`. */
export function parseObject(response: RawResponse, path: string): JsonObject {
  let parsed: JsonValue;
  try {
    parsed = JSON.parse(response.text) as JsonValue;
  } catch {
    throw new ApiResponseError(path, response.status, "JSON değil", response.text);
  }
  if (!isObject(parsed)) {
    throw new ApiResponseError(path, response.status, "JSON nesnesi değil", response.text);
  }
  return parsed;
}

/** Hata yanıtını `ApiRequestError`'a çevirir (gövde sunucunun hata biçiminde değilse kod `http_<durum>`). */
function requestError(response: RawResponse, path: string): ApiRequestError {
  try {
    const body: JsonObject = parseObject(response, path);
    const error: JsonValue | undefined = body["error"];
    if (error !== undefined && isObject(error)) {
      const identity: JsonValue | undefined = error["identity"];
      return new ApiRequestError(
        path,
        response.status,
        stringField(error, "code", response, path),
        stringField(error, "message", response, path),
        typeof identity === "string" ? identity : null,
      );
    }
  } catch (problem: unknown) {
    if (!(problem instanceof ApiResponseError)) {
      throw problem;
    }
  }
  return new ApiRequestError(path, response.status, `http_${response.status}`, response.text.slice(0, 300), null);
}

/** Yeniden denenebilir durum (Worker'ın üst servis ya da harcama hatası değil, geçici ağ geçidi hatası). */
function isRetryableStatus(status: number): boolean {
  return status === 502 || status === 503 || status === 504;
}

/** Bekler. */
function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve: () => void): void => {
    setTimeout(resolve, milliseconds);
  });
}

/** Tek bir HTTP isteği; ağ hatası `ApiNetworkError`. */
async function sendOnce(call: ApiCall): Promise<RawResponse> {
  const headers: Headers = new Headers();
  if (call.body !== null) {
    headers.set("content-type", "application/json");
  }
  if (call.accessToken !== null) {
    headers.set("authorization", `Bearer ${call.accessToken}`);
  }
  let response: Response;
  try {
    response = await fetch(`${siteConfig.apiBase}${call.path}`, {
      method: call.method,
      headers,
      body: call.body === null ? null : JSON.stringify(call.body),
      credentials: "omit",
      cache: "no-store",
    });
  } catch (error: unknown) {
    throw new ApiNetworkError(call.path, error instanceof Error ? error.message : String(error));
  }
  return { status: response.status, text: await response.text() };
}

/**
 * İsteği gönderir; ağ hatası ve 502/503/504'te `attempts` kez dener (her denemede uyarı loglanır), sonra son hatayı
 * fırlatır. 2xx dışı yanıt `ApiRequestError`.
 */
export async function send(call: ApiCall): Promise<RawResponse> {
  let lastError: Error = new ApiNetworkError(call.path, "hiç denenmedi");
  for (let attempt: number = 1; attempt <= call.attempts; attempt += 1) {
    try {
      const response: RawResponse = await sendOnce(call);
      if (response.status >= 200 && response.status < 300) {
        return response;
      }
      const error: ApiRequestError = requestError(response, call.path);
      if (!isRetryableStatus(response.status)) {
        throw error;
      }
      lastError = error;
    } catch (error: unknown) {
      if (!(error instanceof ApiNetworkError)) {
        throw error;
      }
      lastError = error;
    }
    if (attempt < call.attempts) {
      console.warn("api_retry", { path: call.path, attempt, error: lastError.message });
      await delay(400 * 2 ** (attempt - 1));
    }
  }
  throw lastError;
}

/** Oturum yanıtını okur. */
export function parseSession(response: RawResponse, path: string): SessionTokens {
  const body: JsonObject = parseObject(response, path);
  return {
    accessToken: stringField(body, "accessToken", response, path),
    refreshToken: stringField(body, "refreshToken", response, path),
    expiresIn: numberField(body, "expiresIn", response, path),
    userId: stringField(body, "userId", response, path),
  };
}

/** `{url}` yanıtını okur (Checkout ve Portal). */
export function parseRedirectUrl(response: RawResponse, path: string): string {
  const url: string = stringField(parseObject(response, path), "url", response, path);
  if (!url.startsWith("https://")) {
    throw new ApiResponseError(path, response.status, "adres https değil", response.text);
  }
  return url;
}

/** Abonelik alanını okur. */
function parseSubscription(value: JsonValue | undefined, response: RawResponse, path: string): SubscriptionInfo | null {
  if (value === null) {
    return null;
  }
  if (value === undefined || !isObject(value)) {
    throw new ApiResponseError(path, response.status, '"subscription" nesne ya da null değil', response.text);
  }
  const access: string = stringField(value, "access", response, path);
  if (access !== "active" && access !== "grace" && access !== "none") {
    throw new ApiResponseError(path, response.status, `bilinmeyen erişim "${access}"`, response.text);
  }
  const status: string = stringField(value, "status", response, path);
  const currentPeriodEnd: string = stringField(value, "currentPeriodEnd", response, path);
  const cancelAt: string | null = value["cancelAt"] === null ? null : stringField(value, "cancelAt", response, path);
  if (access === "grace") {
    return { status, currentPeriodEnd, cancelAt, access, graceEndsAt: stringField(value, "graceEndsAt", response, path) };
  }
  if (value["graceEndsAt"] !== null) {
    throw new ApiResponseError(path, response.status, '"graceEndsAt" ek süre dışında null değil', response.text);
  }
  return { status, currentPeriodEnd, cancelAt, access, graceEndsAt: null };
}

/** `GET /v1/me` yanıtını okur. */
export function parseEntitlements(response: RawResponse, path: string): Entitlements {
  const body: JsonObject = parseObject(response, path);
  const plan: string = stringField(body, "plan", response, path);
  if (plan !== "trial" && plan !== "subscription") {
    throw new ApiResponseError(path, response.status, `bilinmeyen plan "${plan}"`, response.text);
  }
  return {
    userId: stringField(body, "userId", response, path),
    plan,
    trialMeetingsTotal: numberField(body, "trialMeetingsTotal", response, path),
    trialMeetingsLeft: numberField(body, "trialMeetingsLeft", response, path),
    monthlyHoursUsed: numberField(body, "monthlyHoursUsed", response, path),
    monthlyHoursCap: numberField(body, "monthlyHoursCap", response, path),
    subscription: parseSubscription(body["subscription"], response, path),
  };
}
