import { z } from "zod";
import { identityTokenSchema, refreshSchema } from "./auth/schemas";
import { verifyAppleIdentityToken } from "./auth/apple";
import { verifyGoogleIdentityToken } from "./auth/google";
import { deleteAccount } from "./account";
import { adminStats, requireAdmin } from "./admin";
import { requireCloudflareAccess } from "./auth/access";
import {
  type AuthedUser,
  type SessionTokens,
  authenticate,
  authenticateUnlessDeleted,
  logout,
  rotateRefreshToken,
  startSession,
} from "./auth/tokens";
import { verifyTurnstile } from "./auth/turnstile";
import { findOrCreateUser } from "./auth/users";
import { trialIdentityHash } from "./trialLedger";
import { createChallenge, deviceAssertionSchema, registerDevice, verifyDeviceAssertion } from "./attest/devices";
import { createCheckout, createPortal, handleStripeWebhook } from "./billing";
import { type Config, ConfigError, type StripeWebhookConfig, parseConfig, parseStripeWebhookConfig } from "./config";
import { Base64Error, base64Decode, base64Encode, hmacSha256Hex } from "./crypto";
import { issueDeepgramGrant } from "./deepgram";
import { countDownload, latestMacVersion } from "./downloads";
import { entitlements, requireAccountLLMAccess } from "./entitlements";
import type { Env } from "./env";
import { ApiError, UpstreamError } from "./errors";
import { bearerToken, errorResponse, jsonResponse, optionalBearerToken, readBodyBytes, readJsonBody } from "./http";
import { clientIpKey } from "./ip";
import { llmRequestSchema } from "./llm/request";
import { type LLMScope, proxyLLM } from "./llm/proxy";
import { errorName, log } from "./log";
import { type MeetingStartRequest, endMeeting, reprocessMeeting, requireUsableMeeting, startMeeting } from "./meetings";
import {
  type ReportInput,
  createReport,
  getReport,
  listReports,
  parseReportFilter,
  reportBodyMaxBytes,
  reportSchema,
  reportStatusUpdateSchema,
  setReportStatus,
} from "./reports";
import { requireSpendHeadroom, requireTrialSpendHeadroom } from "./usage";
import type { RequestContext } from "./platform";
import { cachedTranscriptionResponse, parseTranscribeParams, proxyTranscription } from "./transcribe";

/** Küçük JSON gövdeleri için üst sınır. */
const smallBodyBytes: number = 16 * 1024;
/** Stripe webhook gövdesi üst sınırı. */
const webhookBodyBytes: number = 512 * 1024;

/**
 * Site kaynağından (CORS) çağrılabilen uçlar; geri kalanı yalnızca uygulamadan (bearer, çerezsiz) çağrılır. Yönetici
 * uçları (`/v1/admin/…`) da yalnızca site kaynağına açıktır (`allowedCorsOrigin`).
 */
const webRoutes: ReadonlySet<string> = new Set([
  "/v1/health",
  "/v1/download/mac/version",
  "/v1/auth/apple",
  "/v1/auth/google",
  "/v1/auth/refresh",
  "/v1/auth/logout",
  "/v1/me",
  "/v1/billing/checkout",
  "/v1/billing/portal",
  "/v1/reports",
]);

/** Yönetici uçlarının ön eki. */
const adminPrefix: string = "/v1/admin/";

/** Her yanıta eklenen güvenlik başlıkları. */
const securityHeaders: Readonly<Record<string, string>> = {
  "strict-transport-security": "max-age=63072000; includeSubDomains; preload",
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY",
  "referrer-policy": "no-referrer",
  "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
  "cross-origin-resource-policy": "same-site",
  "permissions-policy": "()",
};

/** Yanıta güvenlik başlıklarını ve (izinli kaynaktan gelen web isteğinde) CORS başlıklarını ekler. */
function finalizeResponse(response: Response, corsOrigin: string | null): Response {
  const headers: Headers = new Headers(response.headers);
  for (const [name, value] of Object.entries(securityHeaders)) {
    headers.set(name, value);
  }
  if (!headers.has("cache-control")) {
    headers.set("cache-control", "no-store");
  }
  if (corsOrigin !== null) {
    headers.set("access-control-allow-origin", corsOrigin);
    headers.set("vary", "Origin");
  }
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

/** İstek web kaynağındansa ve uç web'e açıksa izinli kaynak; değilse null. Saf fonksiyondur. */
export function allowedCorsOrigin(origin: string | null, path: string, siteOrigin: string): string | null {
  return origin !== null && origin === siteOrigin && (webRoutes.has(path) || path.startsWith(adminPrefix)) ? origin : null;
}

/** CORS ön kontrol yanıtı; izinli değilse 403. Saf fonksiyondur. */
function preflight(request: Request, path: string, siteOrigin: string): Response {
  const origin: string | null = allowedCorsOrigin(request.headers.get("origin"), path, siteOrigin);
  if (origin === null) {
    return finalizeResponse(errorResponse(new ApiError("forbidden", "Bu kaynaktan erişime izin yok.")), null);
  }
  const response: Response = new Response(null, {
    status: 204,
    headers: {
      "access-control-allow-methods": "GET, POST, DELETE",
      "access-control-allow-headers": "authorization, content-type",
      "access-control-max-age": "600",
    },
  });
  return finalizeResponse(response, origin);
}

/** Hız sınırı: aşılırsa `rate_limited`. */
async function enforceLimit(limiter: RateLimit, key: string): Promise<void> {
  const outcome: RateLimitOutcome = await limiter.limit({ key });
  if (!outcome.success) {
    throw new ApiError("rate_limited", "Çok fazla istek; biraz bekleyip yeniden dene.");
  }
}

/** Toplantı kimliği başlığı (`x-meeting-id`, UUID). */
function meetingIdHeader(request: Request): string {
  const value: string | null = optionalMeetingIdHeader(request);
  if (value === null) {
    throw new ApiError("bad_request", "x-meeting-id başlığı (toplantı oturumu kimliği) gerekli.");
  }
  return value;
}

/** İsteğe bağlı toplantı kimliği başlığı; yoksa null, varsa UUID olmalı (değilse `bad_request`). */
function optionalMeetingIdHeader(request: Request): string | null {
  const value: string | null = request.headers.get("x-meeting-id");
  if (value === null) {
    return null;
  }
  if (!z.uuid().safeParse(value).success) {
    throw new ApiError("bad_request", "x-meeting-id başlığı geçerli bir toplantı oturumu kimliği olmalı.");
  }
  return value;
}

/**
 * İsteğe bağlı `x-device-key-id` başlığı (App Attest anahtar kimliği, base64): `/v1/me` etkin deneme sayısını cihazla
 * birlikte göstersin diye. Yalnızca gösterim içindir; hak toplantı başlatırken imzalı onayla denetlenir.
 * Biçim geçersizse `bad_request`.
 */
function deviceKeyIdHeader(request: Request): string | null {
  const value: string | null = request.headers.get("x-device-key-id");
  if (value === null) {
    return null;
  }
  try {
    return base64Encode(base64Decode(value));
  } catch (error: unknown) {
    if (error instanceof Base64Error) {
      throw new ApiError("bad_request", "x-device-key-id base64 olmalı.");
    }
    throw error;
  }
}

/** Oturum yanıtı gövdesi. Saf fonksiyondur. */
function sessionBody(tokens: SessionTokens): object {
  return {
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken,
    tokenType: "Bearer",
    expiresIn: tokens.expiresIn,
    userId: tokens.userId,
  };
}

const deviceChallengeSchema = z.strictObject({ purpose: z.enum(["attest", "assert"]) });
const deviceAttestSchema = z.strictObject({
  keyId: z.string().min(1).max(128),
  attestation: z.string().min(1).max(32_768),
  challenge: z.string().min(16).max(128),
});
/** `deviceCheckToken`: Apple DeviceCheck jetonu (base64, ~2–3 KB); deneme toplantısı için gerekir (bkz. `requireTrialDevice`). */
const meetingStartSchema = z.strictObject({
  device: deviceAssertionSchema.optional(),
  deviceCheckToken: z.base64().min(1).max(8192).optional(),
  /** İstemcinin kayıt kimliği: aynı kimlikle yinelenen başlatma aynı oturumu döndürür (bkz. `startMeeting`). */
  clientRef: z.string().regex(/^[A-Za-z0-9._-]{1,64}$/).optional(),
  /** Sonradan işlenen kayıt: açık toplantıyı kapatma (bkz. `MeetingStartRequest.deferred`). */
  deferred: z.boolean().optional(),
});
const meetingEndPath: RegExp = /^\/v1\/meetings\/([0-9a-f-]{36})\/end$/;
const meetingReprocessPath: RegExp = /^\/v1\/meetings\/([0-9a-f-]{36})\/reprocess$/;

/** İstek bağlamı ve yapılandırmayla yönlendirme. */
async function route(request: Request, env: Env, config: Config, context: RequestContext, path: string): Promise<Response> {
  const db: D1Database = env.DB;
  const now: Date = context.platform.now();
  const method: string = request.method;
  const authed = async (): Promise<AuthedUser> => authenticate(db, config, bearerToken(request), context.platform.now());

  if (path === "/v1/health" && method === "GET") {
    return jsonResponse(200, { status: "ok" });
  }
  // Hız sınırı ve IP özeti IPv6'da /64 önekine göredir (`clientIpKey`); Turnstile gerçek IP'yi alır.
  const ipKey: string = clientIpKey(context.clientIp);
  await enforceLimit(env.API_IP_LIMITER, `ip:${ipKey}`);

  if (path.startsWith("/v1/auth/") && method === "POST") {
    await enforceLimit(env.AUTH_IP_LIMITER, `ip:${ipKey}`);
    if (path === "/v1/auth/apple") {
      const body = await readJsonBody(request, identityTokenSchema, smallBodyBytes);
      const identity = await verifyAppleIdentityToken(db, context.platform, config, body.identityToken, body.nonce);
      const identityHash: string = await trialIdentityHash(config.secrets.trialHash, "apple", identity.subject);
      const userId: string = await findOrCreateUser(db, "apple", identity.subject, identityHash, now);
      log("info", "login", { provider: "apple", userId });
      return jsonResponse(200, sessionBody(await startSession(db, config, userId, now)));
    }
    if (path === "/v1/auth/google") {
      const body = await readJsonBody(request, identityTokenSchema, smallBodyBytes);
      const identity = await verifyGoogleIdentityToken(db, context.platform, config, body.identityToken, body.nonce);
      // Apple hesabıyla otomatik bağlama yoktur (ayrı kullanıcı).
      const identityHash: string = await trialIdentityHash(config.secrets.trialHash, "google", identity.subject);
      const userId: string = await findOrCreateUser(db, "google", identity.subject, identityHash, now);
      log("info", "login", { provider: "google", userId });
      return jsonResponse(200, sessionBody(await startSession(db, config, userId, now)));
    }
    if (path === "/v1/auth/refresh") {
      const body = await readJsonBody(request, refreshSchema, smallBodyBytes);
      return jsonResponse(200, sessionBody(await rotateRefreshToken(db, config, body.refreshToken, now)));
    }
    if (path === "/v1/auth/logout") {
      const body = await readJsonBody(request, refreshSchema, smallBodyBytes);
      await logout(db, body.refreshToken, now);
      return jsonResponse(200, { status: "logged_out" });
    }
  }

  if (path === "/v1/me" && method === "GET") {
    const user: AuthedUser = await authed();
    return jsonResponse(200, await entitlements(db, config, user.userId, deviceKeyIdHeader(request), now));
  }
  if (path === "/v1/me" && method === "DELETE") {
    const user: AuthedUser | null = await authenticateUnlessDeleted(db, config, bearerToken(request), now);
    if (user !== null) {
      await enforceLimit(env.START_USER_LIMITER, `user:${user.userId}`);
      await deleteAccount(db, context.platform, config, user.userId, now);
    }
    return new Response(null, { status: 204 });
  }

  if (path === "/v1/device/challenge" && method === "POST") {
    const user: AuthedUser = await authed();
    await enforceLimit(env.START_USER_LIMITER, `user:${user.userId}`);
    const body = await readJsonBody(request, deviceChallengeSchema, smallBodyBytes);
    const challenge: string = await createChallenge(db, user.userId, body.purpose, now);
    return jsonResponse(200, { challenge, expiresInSeconds: 300 });
  }
  if (path === "/v1/device/attest" && method === "POST") {
    const user: AuthedUser = await authed();
    await enforceLimit(env.START_USER_LIMITER, `user:${user.userId}`);
    const body = await readJsonBody(request, deviceAttestSchema, 64 * 1024);
    const deviceId: string = await registerDevice(db, context.platform, config, user.userId, body);
    return jsonResponse(201, { deviceId });
  }

  if (path === "/v1/meetings/start" && method === "POST") {
    const user: AuthedUser = await authed();
    await enforceLimit(env.START_USER_LIMITER, `user:${user.userId}`);
    const body = await readJsonBody(request, meetingStartSchema, smallBodyBytes);
    if (body.device === undefined && config.attest.policy === "required") {
      throw new ApiError("attestation_required", "Bu sürüm cihaz doğrulaması (App Attest) gerektiriyor.");
    }
    const deviceId: string | null =
      body.device === undefined ? null : await verifyDeviceAssertion(db, context.platform, config, user.userId, "meetings.start", body.device);
    const clientIpHash: string = await hmacSha256Hex(config.secrets.trialHash, `trial-ip:${ipKey}`);
    const startRequest: MeetingStartRequest = { deviceId, clientIpHash, deviceCheckToken: body.deviceCheckToken ?? null, clientRef: body.clientRef ?? null, deferred: body.deferred ?? false };
    return jsonResponse(201, await startMeeting(db, context.platform, config, user.userId, startRequest, now));
  }
  const endMatch: RegExpExecArray | null = meetingEndPath.exec(path);
  if (endMatch !== null && endMatch[1] !== undefined && method === "POST") {
    const user: AuthedUser = await authed();
    const row = await endMeeting(db, user.userId, endMatch[1], now);
    return jsonResponse(200, { meetingId: row.id, minutes: row.minutes, tokensUsed: row.tokens_used, audioSeconds: row.audio_seconds });
  }
  const reprocessMatch: RegExpExecArray | null = meetingReprocessPath.exec(path);
  if (reprocessMatch !== null && reprocessMatch[1] !== undefined && method === "POST") {
    const user: AuthedUser = await authed();
    await enforceLimit(env.START_USER_LIMITER, `user:${user.userId}`);
    return jsonResponse(200, await reprocessMeeting(db, config, user.userId, reprocessMatch[1], now));
  }

  if (path === "/v1/llm/messages" && method === "POST") {
    const user: AuthedUser = await authed();
    await enforceLimit(env.PROXY_USER_LIMITER, `user:${user.userId}`);
    // Toplantı kimliği varsa çağrı o toplantının bütçesinden düşer; yoksa hesap çağrısıdır (deneme ya da abonelik
    // hakkı gerekir, kullanıcının günlük ve aylık sınırı geçerlidir).
    const meetingId: string | null = optionalMeetingIdHeader(request);
    let scope: LLMScope;
    if (meetingId === null) {
      scope = { kind: "account", userId: user.userId, access: await requireAccountLLMAccess(db, config, user.userId, now) };
      if (scope.access === "trial") {
        await requireTrialSpendHeadroom(db, config, now);
      }
    } else {
      scope = { kind: "meeting", userId: user.userId, meeting: await requireUsableMeeting(db, config, user.userId, meetingId, now) };
    }
    await requireSpendHeadroom(db, config, now);
    const body = await readJsonBody(request, llmRequestSchema, config.llm.maxRequestBytes);
    return proxyLLM(db, context, config, scope, body);
  }
  if (path === "/v1/transcribe" && method === "POST") {
    const user: AuthedUser = await authed();
    await enforceLimit(env.PROXY_USER_LIMITER, `user:${user.userId}`);
    // Ödenmiş sonuç pencere ve harcama denetimlerinden önce döner (bkz. `cachedTranscriptionResponse`).
    const repeated: Response | null = await cachedTranscriptionResponse(db, request, user.userId, meetingIdHeader(request), now);
    if (repeated !== null) {
      return repeated;
    }
    const meeting = await requireUsableMeeting(db, config, user.userId, meetingIdHeader(request), now);
    await requireSpendHeadroom(db, config, now);
    const params = parseTranscribeParams(new URL(request.url), request.headers.get("x-keyterms"), config.transcribe.maxKeyterms);
    return proxyTranscription(db, context, config, meeting, request, params);
  }

  if (path === "/v1/live/deepgram-token" && method === "POST") {
    // Deepgram canlı metni için kısa ömürlü jeton: açık (bitmemiş) toplantı gerekir; her bağlantı ve yeniden bağlanma
    // yeni jeton ister (bkz. `deepgram.ts`). Gövde yoktur; toplantı `x-meeting-id` başlığındadır.
    const user: AuthedUser = await authed();
    await enforceLimit(env.DEEPGRAM_USER_LIMITER, `user:${user.userId}`);
    const meeting = await requireUsableMeeting(db, config, user.userId, meetingIdHeader(request), now);
    return jsonResponse(200, await issueDeepgramGrant(db, context.platform, config, meeting, now));
  }

  if (path === "/v1/billing/checkout" && method === "POST") {
    const user: AuthedUser = await authed();
    await enforceLimit(env.START_USER_LIMITER, `user:${user.userId}`);
    return jsonResponse(200, { url: await createCheckout(db, context.platform, config, user.userId) });
  }
  if (path === "/v1/billing/portal" && method === "POST") {
    const user: AuthedUser = await authed();
    await enforceLimit(env.START_USER_LIMITER, `user:${user.userId}`);
    return jsonResponse(200, { url: await createPortal(db, context.platform, config, user.userId) });
  }

  if (path === "/v1/reports" && method === "POST") {
    await enforceLimit(env.REPORT_IP_LIMITER, `ip:${ipKey}`);
    // Geri bildirim ve çökme raporu hesap ister (jetonsuz 401); sitedeki iletişim formunda jeton isteğe bağlıdır,
    // Turnstile zorunludur. Gönderilen jeton geçerli olmalı (geçersiz jeton anonim rapora dönmez, 401).
    const token: string | null = optionalBearerToken(request);
    const user: AuthedUser | null = token === null ? null : await authenticate(db, config, token, now);
    const body: ReportInput = await readJsonBody(request, reportSchema, reportBodyMaxBytes);
    if (body.kind === "contact") {
      await verifyTurnstile(context.platform, config.secrets.turnstile, body.turnstileToken, context.clientIp);
    } else if (user === null) {
      throw new ApiError("unauthorized", "Geri bildirim ve çökme raporu için giriş yapmış olmalısın.");
    }
    await createReport(db, config, body, user === null ? null : user.userId, now);
    return jsonResponse(202, {});
  }
  if (path === "/v1/download/mac/version" && method === "GET") {
    // İndirme sayfasındaki sürüm numarası; tarayıcı ve kenar önbelleği 5 dk tutar (GitHub her görüntülemede çağrılmaz).
    const version: string = await latestMacVersion(context.platform, config.appcastUrl);
    return new Response(JSON.stringify({ version }), {
      status: 200,
      headers: { "content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=300" },
    });
  }
  if (path === "/v1/download/mac" && method === "GET") {
    await countDownload(db, now);
    return new Response(null, { status: 302, headers: { location: config.dmgUrl } });
  }

  if (path.startsWith(adminPrefix)) {
    await requireCloudflareAccess(context.platform, config.access, request);
    return routeAdmin(request, db, config, path, await authed(), now);
  }

  throw new ApiError("not_found", "Böyle bir uç yok.");
}

const adminReportPath: RegExp = /^\/v1\/admin\/reports\/([0-9a-f-]{36})$/;

/**
 * Yönetici uçları: istek Cloudflare Access'ten geçmiş (`requireCloudflareAccess`) ve kimliği doğrulanmış çağıran
 * `ADMIN_IDENTITIES` listesinde olmalı (değilse 403 + kendi kimliği).
 */
async function routeAdmin(request: Request, db: D1Database, config: Config, path: string, user: AuthedUser, now: Date): Promise<Response> {
  await requireAdmin(db, config, user.userId);
  const method: string = request.method;
  if (path === "/v1/admin/stats" && method === "GET") {
    return jsonResponse(200, await adminStats(db, config, now));
  }
  if (path === "/v1/admin/reports" && method === "GET") {
    return jsonResponse(200, await listReports(db, parseReportFilter(new URL(request.url))));
  }
  const reportMatch: RegExpExecArray | null = adminReportPath.exec(path);
  if (reportMatch !== null && reportMatch[1] !== undefined && method === "GET") {
    return jsonResponse(200, await getReport(db, reportMatch[1]));
  }
  if (reportMatch !== null && reportMatch[1] !== undefined && method === "POST") {
    const body = await readJsonBody(request, reportStatusUpdateSchema, smallBodyBytes);
    await setReportStatus(db, reportMatch[1], body.status);
    return new Response(null, { status: 204 });
  }
  throw new ApiError("not_found", "Böyle bir uç yok.");
}

/**
 * Stripe webhook'u: yalnızca Stripe ayarlarıyla (`parseStripeWebhookConfig`) çalışır; ilgisiz bir ayarın hatası (ör.
 * DeviceCheck ya da Deepgram anahtarı) ödeme olaylarını durdurmaz.
 */
async function stripeWebhook(request: Request, env: Env, context: RequestContext): Promise<Response> {
  let config: StripeWebhookConfig;
  try {
    config = parseStripeWebhookConfig(env);
  } catch (error: unknown) {
    if (error instanceof ConfigError) {
      log("alert", "stripe_webhook_config_invalid", { fields: error.fields.join(",") });
      return finalizeResponse(errorResponse(new ApiError("internal_error", "Sunucu yapılandırması eksik.")), null);
    }
    throw error;
  }
  try {
    const signature: string | null = request.headers.get("stripe-signature");
    if (signature === null) {
      throw new ApiError("webhook_invalid", "Stripe-Signature başlığı gerekli.");
    }
    const payload: string = new TextDecoder().decode(await readBodyBytes(request, webhookBodyBytes));
    const result: { duplicate: boolean } = await handleStripeWebhook(env.DB, context.platform, config, payload, signature);
    return finalizeResponse(jsonResponse(200, { received: true, duplicate: result.duplicate }), null);
  } catch (error: unknown) {
    if (error instanceof ApiError) {
      return finalizeResponse(errorResponse(error), null);
    }
    log("error", "unhandled_error", { path: "/v1/billing/webhook", error: errorName(error) });
    return finalizeResponse(errorResponse(new ApiError("internal_error", "Beklenmeyen bir sunucu hatası oluştu.")), null);
  }
}

/** Worker'ın istek işleyicisi: yapılandırma, CORS, yönlendirme, tek tip hata ve güvenlik başlıkları. */
export async function handleRequest(request: Request, env: Env, context: RequestContext): Promise<Response> {
  const url: URL = new URL(request.url);
  const path: string = url.pathname;
  if (path === "/v1/billing/webhook" && request.method === "POST") {
    return stripeWebhook(request, env, context);
  }
  let config: Config;
  try {
    config = parseConfig(env);
  } catch (error: unknown) {
    if (error instanceof ConfigError) {
      log("error", "config_invalid", { error: error.name, fields: error.fields.join(",") });
      return finalizeResponse(errorResponse(new ApiError("internal_error", "Sunucu yapılandırması eksik.")), null);
    }
    throw error;
  }
  if (request.method === "OPTIONS") {
    return preflight(request, path, config.siteOrigin);
  }
  const corsOrigin: string | null = allowedCorsOrigin(request.headers.get("origin"), path, config.siteOrigin);
  try {
    return finalizeResponse(await route(request, env, config, context, path), corsOrigin);
  } catch (error: unknown) {
    if (error instanceof ApiError) {
      return finalizeResponse(errorResponse(error), corsOrigin);
    }
    if (error instanceof UpstreamError) {
      log("error", "upstream_failed", { path, service: error.service, status: error.status });
      return finalizeResponse(errorResponse(new ApiError("upstream_unavailable", "Bağlı bir servis şu an yanıt vermiyor; biraz sonra yeniden dene.")), corsOrigin);
    }
    log("error", "unhandled_error", { path, error: errorName(error) });
    return finalizeResponse(errorResponse(new ApiError("internal_error", "Beklenmeyen bir sunucu hatası oluştu.")), corsOrigin);
  }
}
