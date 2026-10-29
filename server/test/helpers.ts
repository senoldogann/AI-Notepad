import { env } from "cloudflare:workers";
import { type CryptoKey as JoseKey, type JWK, SignJWT, exportJWK, generateKeyPair } from "jose";
import { expect } from "vitest";
import { handleRequest } from "../src/app";
import { appleAppAttestationRootPem } from "../src/attest/appleRoot";
import { appleIssuer, appleJwksUrl } from "../src/auth/apple";
import { googleJwksUrl } from "../src/auth/google";
import { randomId, randomToken, sha256Hex } from "../src/crypto";
import type { Env } from "../src/env";
import type { Platform } from "../src/platform";

/** Dışarı giden istek işleyicisi (sahte üst servis). */
export type StubHandler = (request: Request) => Promise<Response>;

/** Test düzeneği: Worker'ın istek işleyicisini gerçek D1 ile çağırır; yalnızca dışarı giden fetch sahtedir. */
export interface Harness {
  readonly clock: { nowMs: number };
  readonly outbound: Request[];
  readonly platform: Platform;
  readonly stub: (urlPrefix: string, handler: StubHandler) => void;
  readonly call: (request: TestRequest) => Promise<Response>;
  /** `waitUntil` ile arka plana bırakılan işleri bekler (akış sonu muhasebesi). */
  readonly drain: () => Promise<void>;
}

/** Test isteği. */
export interface TestRequest {
  readonly method: string;
  readonly path: string;
  readonly token: string | null;
  readonly json: object | null;
  readonly headers: Readonly<Record<string, string>>;
  readonly body: BodyInit | null;
  readonly env: Env | null;
  readonly clientIp: string | null;
}

/** Varsayılan alanlarla test isteği. */
export function req(method: string, path: string, fields: Partial<TestRequest>): TestRequest {
  return { method, path, token: null, json: null, headers: {}, body: null, env: null, clientIp: null, ...fields };
}

/** Yeni düzenek; Apple JWKS uç noktası hazır bağlanır. */
export async function createHarness(rootPem: string): Promise<Harness> {
  const clock: { nowMs: number } = { nowMs: Date.UTC(2026, 9, 15, 12, 0, 0) };
  const outbound: Request[] = [];
  const routes: Array<{ prefix: string; handler: StubHandler }> = [];
  const pending: Array<Promise<void>> = [];
  const platform: Platform = {
    fetch: async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
      const request: Request = new Request(input, init);
      outbound.push(request.clone());
      const route = routes.find((candidate): boolean => request.url.startsWith(candidate.prefix));
      if (route === undefined) {
        throw new Error(`Beklenmeyen dış istek: ${request.method} ${request.url}`);
      }
      return route.handler(request);
    },
    now: (): Date => new Date(clock.nowMs),
    appAttestRootPem: rootPem,
    retryBaseDelayMs: 0,
    jwksCache: new Map(),
  };
  const harness: Harness = {
    clock,
    outbound,
    platform,
    stub: (prefix: string, handler: StubHandler): void => {
      routes.unshift({ prefix, handler });
    },
    call: async (test: TestRequest): Promise<Response> => {
      const headers: Headers = new Headers(test.headers);
      if (test.token !== null) {
        headers.set("authorization", `Bearer ${test.token}`);
      }
      let body: BodyInit | null = test.body;
      if (test.json !== null) {
        headers.set("content-type", "application/json");
        body = JSON.stringify(test.json);
      }
      const request: Request = new Request(`https://api.test${test.path}`, { method: test.method, headers, body });
      return handleRequest(request, test.env ?? env, {
        platform,
        waitUntil: (promise: Promise<void>): void => {
          pending.push(promise);
        },
        clientIp: test.clientIp ?? `198.51.100.${Math.floor(Math.random() * 250)}-${randomId()}`,
      });
    },
    drain: async (): Promise<void> => {
      await Promise.all(pending.splice(0));
    },
  };
  const apple: AppleKeys = await appleKeys();
  harness.stub(appleJwksUrl, async (): Promise<Response> => Response.json({ keys: [apple.publicJwk] }));
  const google: AppleKeys = await googleKeys();
  harness.stub(googleJwksUrl, async (): Promise<Response> => Response.json({ keys: [google.publicJwk] }));
  return harness;
}

/** Üretim köküyle düzenek (App Attest testleri dışındaki her şey). */
export async function defaultHarness(): Promise<Harness> {
  return createHarness(appleAppAttestationRootPem);
}

interface AppleKeys {
  readonly privateKey: JoseKey;
  readonly publicJwk: JWK;
}

let appleKeysPromise: Promise<AppleKeys> | null = null;

/** Sahte Apple imza anahtarı (dosya başına bir kez üretilir). */
async function appleKeys(): Promise<AppleKeys> {
  appleKeysPromise ??= (async (): Promise<AppleKeys> => {
    const { privateKey, publicKey } = await generateKeyPair("RS256", { extractable: true });
    const publicJwk: JWK = { ...(await exportJWK(publicKey)), kid: "test-apple-key", alg: "RS256", use: "sig" };
    return { privateKey, publicJwk };
  })();
  return appleKeysPromise;
}

/** Apple kimlik jetonu alanları. */
export interface AppleTokenFields {
  readonly subject: string;
  readonly nonceClaim: string;
  readonly audience: string;
  readonly issuer: string;
  readonly expiresInSeconds: number;
  readonly nowMs: number;
}

/** Sahte Apple anahtarıyla imzalı kimlik jetonu. */
export async function appleIdentityToken(fields: AppleTokenFields): Promise<string> {
  const { privateKey } = await appleKeys();
  const issuedAt: number = Math.floor(fields.nowMs / 1000);
  return new SignJWT({ nonce: fields.nonceClaim, email: `${fields.subject}@privaterelay.appleid.com`, email_verified: true })
    .setProtectedHeader({ alg: "RS256", kid: "test-apple-key" })
    .setIssuer(fields.issuer)
    .setAudience(fields.audience)
    .setSubject(fields.subject)
    .setIssuedAt(issuedAt)
    .setExpirationTime(issuedAt + fields.expiresInSeconds)
    .sign(privateKey);
}

let googleKeysPromise: Promise<AppleKeys> | null = null;

/** Sahte Google imza anahtarı (Apple'ınkinden ayrı; dosya başına bir kez üretilir). */
async function googleKeys(): Promise<AppleKeys> {
  googleKeysPromise ??= (async (): Promise<AppleKeys> => {
    const { privateKey, publicKey } = await generateKeyPair("RS256", { extractable: true });
    const publicJwk: JWK = { ...(await exportJWK(publicKey)), kid: "test-google-key", alg: "RS256", use: "sig" };
    return { privateKey, publicJwk };
  })();
  return googleKeysPromise;
}

/** Testlerdeki Google istemci kimliği (`wrangler.jsonc` → `GOOGLE_CLIENT_IDS`). */
export const googleClientId: string = "461373321454-ku1ot0ildt8b9toe7aerq1imidfgu1ah.apps.googleusercontent.com";

/** Sahte Google anahtarıyla imzalı kimlik jetonu (alanlar Apple'ınkiyle aynı). */
export async function googleIdentityToken(fields: AppleTokenFields): Promise<string> {
  const { privateKey } = await googleKeys();
  const issuedAt: number = Math.floor(fields.nowMs / 1000);
  return new SignJWT({ nonce: fields.nonceClaim, email: `${fields.subject}@gmail.com`, email_verified: true, azp: fields.audience })
    .setProtectedHeader({ alg: "RS256", kid: "test-google-key" })
    .setIssuer(fields.issuer)
    .setAudience(fields.audience)
    .setSubject(fields.subject)
    .setIssuedAt(issuedAt)
    .setExpirationTime(issuedAt + fields.expiresInSeconds)
    .sign(privateKey);
}

/** Google ile giriş akışının tamamı; `subject` verilen Google kimliğinin oturumu. */
export async function signInWithGoogle(harness: Harness, subject: string): Promise<Session> {
  const nonce: string = randomToken(24);
  const identityToken: string = await googleIdentityToken({
    subject,
    nonceClaim: await sha256Hex(nonce),
    audience: googleClientId,
    issuer: "https://accounts.google.com",
    expiresInSeconds: 3600,
    nowMs: harness.clock.nowMs,
  });
  const response: Response = await harness.call(req("POST", "/v1/auth/google", { json: { identityToken, nonce } }));
  expect(response.status).toBe(200);
  return response.json<Session>();
}

/** Oturum yanıtı. */
export interface Session {
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly userId: string;
}

/** Apple ile giriş akışının tamamı (gerçek doğrulama yolu); yeni kullanıcının oturumu. */
export async function signIn(harness: Harness): Promise<Session> {
  const nonce: string = randomToken(24);
  const identityToken: string = await appleIdentityToken({
    subject: `apple-${randomId()}`,
    nonceClaim: await sha256Hex(nonce),
    audience: "com.senoldogan.AINotepad.hosted",
    issuer: appleIssuer,
    expiresInSeconds: 600,
    nowMs: harness.clock.nowMs,
  });
  const response: Response = await harness.call(req("POST", "/v1/auth/apple", { json: { identityToken, nonce } }));
  expect(response.status).toBe(200);
  return response.json<Session>();
}

/** Saat ilerletildikten sonra (erişim jetonu 15 dakikada dolar) yenileme jetonuyla taze oturum. */
export async function refreshed(harness: Harness, session: Session): Promise<Session> {
  const response: Response = await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } }));
  expect(response.status).toBe(200);
  return response.json<Session>();
}

/** Hata gövdesi. */
export interface ErrorBody {
  readonly error: { readonly code: string; readonly message: string };
}

/** Yanıtın tek tip hata gövdesini ve durumunu doğrular. */
export async function expectError(response: Response, status: number, code: string): Promise<ErrorBody> {
  const body: ErrorBody = await response.json<ErrorBody>();
  expect({ status: response.status, code: body.error.code }).toEqual({ status, code });
  expect(typeof body.error.message).toBe("string");
  return body;
}

/** Toplantı başlatır (cihazsız). */
export async function startMeeting(harness: Harness, session: Session): Promise<Response> {
  return harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {} }));
}

/** Toplantı başlatma yanıtı. */
export interface StartedMeetingBody {
  readonly meetingId: string;
  readonly kind: "trial" | "subscription";
  readonly tokenBudget: number;
  readonly maxDurationMinutes: number;
  /** Toplantının en çok süresinin bittiği an (ISO 8601). */
  readonly expiresAt: string;
  readonly trialMeetingsLeft: number | null;
}

/** Ortamın bazı bağlamaları değiştirilmiş kopyası. */
export function envWith(overrides: Partial<Env>): Env {
  return { ...env, ...overrides };
}

/** Her isteği reddeden hız sınırlayıcı. */
export const blockingLimiter: RateLimit = {
  limit: async (): Promise<RateLimitOutcome> => ({ success: false }),
};

/** PCM WAV dosyası: 44 baytlık RIFF başlığı + `dataBytes` sıfır bayt. */
export function wavFile(sampleRate: number, channels: number, bits: number, dataBytes: number): Uint8Array {
  const file: Uint8Array = new Uint8Array(44 + dataBytes);
  const view: DataView = new DataView(file.buffer);
  const ascii = (offset: number, text: string): void => {
    file.set(Array.from(text, (char: string): number => char.charCodeAt(0)), offset);
  };
  ascii(0, "RIFF");
  view.setUint32(4, 36 + dataBytes, true);
  ascii(8, "WAVE");
  ascii(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, channels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, (sampleRate * channels * bits) / 8, true);
  view.setUint16(32, (channels * bits) / 8, true);
  view.setUint16(34, bits, true);
  ascii(36, "data");
  view.setUint32(40, dataBytes, true);
  return file;
}

/**
 * Abonelik satırı ekler (webhook testleri dışında kısayol). `past_due` durumunda `past_due_since` dönem sonu kabul
 * edilir (ödeme dönem sonunda başarısız oldu).
 */
export async function grantSubscription(userId: string, status: string, periodEndMs: number): Promise<void> {
  const customer: string = `cus_${randomToken(8)}`;
  await env.DB.batch([
    env.DB.prepare("INSERT INTO stripe_customers (user_id, stripe_customer_id, created_at) VALUES (?, ?, 0)").bind(userId, customer),
    env.DB.prepare(
      `INSERT INTO subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, current_period_end, past_due_since, last_event_created, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, 0, 0)`,
    ).bind(userId, customer, `sub_${randomToken(8)}`, status, periodEndMs, status === "past_due" ? periodEndMs : null),
  ]);
}
