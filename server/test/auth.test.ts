import { env } from "cloudflare:workers";
import { type JWK, SignJWT, exportJWK, generateKeyPair } from "jose";
import { describe, expect, it } from "vitest";
import { appleIssuer, appleJwksUrl } from "../src/auth/apple";
import { googleJwksUrl } from "../src/auth/google";
import { jwksCacheTtlMs } from "../src/auth/identityToken";
import { refreshRetryWindowMs } from "../src/auth/tokens";
import { randomId, randomToken, sha256Hex } from "../src/crypto";
import {
  type AppleTokenFields,
  type Harness,
  type Session,
  appleIdentityToken,
  blockingLimiter,
  defaultHarness,
  envWith,
  expectError,
  googleClientId,
  googleIdentityToken,
  req,
  signIn,
  signInWithGoogle,
} from "./helpers";

const clientId: string = "com.senoldogan.AINotepad.hosted";

/** Kimlik jetonu girişinin değiştirilebilir alanları. */
interface LoginOverrides {
  readonly audience: string;
  readonly issuer: string;
  readonly nonceClaimFor: string;
  readonly nonce: string;
  readonly expiresInSeconds: number;
}

async function appleLogin(harness: Harness, overrides: LoginOverrides): Promise<Response> {
  const identityToken: string = await appleIdentityToken({
    subject: `apple-${randomId()}`,
    nonceClaim: await sha256Hex(overrides.nonceClaimFor),
    audience: overrides.audience,
    issuer: overrides.issuer,
    expiresInSeconds: overrides.expiresInSeconds,
    nowMs: harness.clock.nowMs,
  });
  return harness.call(req("POST", "/v1/auth/apple", { json: { identityToken, nonce: overrides.nonce } }));
}

async function googleLogin(harness: Harness, subject: string, overrides: LoginOverrides): Promise<Response> {
  const fields: AppleTokenFields = {
    subject,
    nonceClaim: await sha256Hex(overrides.nonceClaimFor),
    audience: overrides.audience,
    issuer: overrides.issuer,
    expiresInSeconds: overrides.expiresInSeconds,
    nowMs: harness.clock.nowMs,
  };
  const identityToken: string = await googleIdentityToken(fields);
  return harness.call(req("POST", "/v1/auth/google", { json: { identityToken, nonce: overrides.nonce } }));
}

describe("Apple ile giriş", () => {
  it("geçerli jetonla kullanıcı ve oturum oluşturur; aynı Apple kimliği aynı kullanıcıdır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    expect(session.accessToken.split(".")).toHaveLength(3);
    const me: Response = await harness.call(req("GET", "/v1/me", { token: session.accessToken }));
    expect(me.status).toBe(200);
    expect((await me.json<{ userId: string }>()).userId).toBe(session.userId);
    // Jetondaki doğrulanmış e-posta saklanmaz.
    const identity = await env.DB.prepare("SELECT provider, email FROM auth_identities WHERE user_id = ?").bind(session.userId).first<{ provider: string; email: string | null }>();
    expect(identity).toEqual({ provider: "apple", email: null });
  });

  it("yanlış aud, yanlış iss, süresi dolmuş jeton ve yanlış nonce reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const nonce: string = randomToken(24);
    const base = { audience: clientId, issuer: appleIssuer, nonceClaimFor: nonce, nonce, expiresInSeconds: 600 };
    await expectError(await appleLogin(harness, { ...base, audience: "com.baskasi.app" }), 401, "invalid_token");
    await expectError(await appleLogin(harness, { ...base, issuer: "https://evil.example" }), 401, "invalid_token");
    await expectError(await appleLogin(harness, { ...base, expiresInSeconds: -60 }), 401, "invalid_token");
    await expectError(await appleLogin(harness, { ...base, nonce: randomToken(24) }), 401, "invalid_token");
  });

  it("aynı nonce ikinci kez kullanılamaz", async () => {
    const harness: Harness = await defaultHarness();
    const nonce: string = randomToken(24);
    const base = { audience: clientId, issuer: appleIssuer, nonceClaimFor: nonce, nonce, expiresInSeconds: 600 };
    expect((await appleLogin(harness, base)).status).toBe(200);
    await expectError(await appleLogin(harness, base), 401, "invalid_token");
  });

  it("Apple JWKS geçici hatası yeniden denenir", async () => {
    const harness: Harness = await defaultHarness();
    let calls: number = 0;
    const original = harness.outbound.length;
    harness.stub("https://appleid.apple.com/auth/keys", async (): Promise<Response> => {
      calls += 1;
      return new Response("geçici", { status: 503 });
    });
    const nonce: string = randomToken(24);
    const response: Response = await appleLogin(harness, { audience: clientId, issuer: appleIssuer, nonceClaimFor: nonce, nonce, expiresInSeconds: 600 });
    await expectError(response, 502, "upstream_unavailable");
    expect(calls).toBe(3);
    expect(harness.outbound.length - original).toBe(3);
  });

  it("Apple anahtarları önbellekte tutulur; bilinmeyen kid (anahtar dönüşü) ve süresi dolan önbellek yeniden alınır", async () => {
    const harness: Harness = await defaultHarness();
    const jwksCalls = (): number => harness.outbound.filter((request: Request): boolean => request.url === appleJwksUrl).length;
    await signIn(harness);
    await signIn(harness);
    expect(jwksCalls()).toBe(1);

    // Apple yeni bir anahtara geçti: jetonun kid'i önbellekte yok.
    const { privateKey, publicKey } = await generateKeyPair("RS256", { extractable: true });
    const rotated: JWK = { ...(await exportJWK(publicKey)), kid: "test-apple-key-2", alg: "RS256", use: "sig" };
    const original: JWK[] = harness.platform.jwksCache.get(appleJwksUrl)?.keys.keys ?? [];
    harness.stub(appleJwksUrl, async (): Promise<Response> => Response.json({ keys: [...original, rotated] }));
    const nonce: string = randomToken(24);
    const issuedAt: number = Math.floor(harness.clock.nowMs / 1000);
    const identityToken: string = await new SignJWT({ nonce: await sha256Hex(nonce) })
      .setProtectedHeader({ alg: "RS256", kid: "test-apple-key-2" })
      .setIssuer(appleIssuer)
      .setAudience(clientId)
      .setSubject(`apple-${randomId()}`)
      .setIssuedAt(issuedAt)
      .setExpirationTime(issuedAt + 600)
      .sign(privateKey);
    expect((await harness.call(req("POST", "/v1/auth/apple", { json: { identityToken, nonce } }))).status).toBe(200);
    expect(jwksCalls()).toBe(2);
    await signIn(harness);
    expect(jwksCalls()).toBe(2);

    harness.clock.nowMs += jwksCacheTtlMs;
    await signIn(harness);
    expect(jwksCalls()).toBe(3);
  });

  it("giriş uçları IP başına hız sınırlıdır", async () => {
    const harness: Harness = await defaultHarness();
    const limited = envWith({ AUTH_IP_LIMITER: blockingLimiter });
    await expectError(
      await harness.call(req("POST", "/v1/auth/apple", { json: { identityToken: "x".repeat(30), nonce: randomToken(24) }, env: limited })),
      429,
      "rate_limited",
    );
  });
});

describe("Google ile giriş", () => {
  it("geçerli jetonla kullanıcı ve oturum oluşturur; aynı Google kimliği aynı kullanıcıdır, e-posta saklanmaz", async () => {
    const harness: Harness = await defaultHarness();
    const subject: string = `google-${randomId()}`;
    const first: Session = await signInWithGoogle(harness, subject);
    const me: Response = await harness.call(req("GET", "/v1/me", { token: first.accessToken }));
    expect(me.status).toBe(200);
    // Kısa `iss` biçimi de geçerlidir; aynı `sub` aynı kullanıcıya düşer.
    const nonce: string = randomToken(24);
    const second: Response = await googleLogin(harness, subject, {
      audience: googleClientId,
      issuer: "accounts.google.com",
      nonceClaimFor: nonce,
      nonce,
      expiresInSeconds: 3600,
    });
    expect(second.status).toBe(200);
    expect((await second.json<Session>()).userId).toBe(first.userId);
    const identity = await env.DB.prepare("SELECT provider, subject, email FROM auth_identities WHERE user_id = ?")
      .bind(first.userId)
      .first<{ provider: string; subject: string; email: string | null }>();
    expect(identity).toEqual({ provider: "google", subject, email: null });
  });

  it("Apple ve Google'daki aynı `sub` ayrı kullanıcılardır (otomatik bağlama yok)", async () => {
    const harness: Harness = await defaultHarness();
    const subject: string = `ortak-${randomId()}`;
    const google: Session = await signInWithGoogle(harness, subject);
    const nonce: string = randomToken(24);
    const appleToken: string = await appleIdentityToken({
      subject,
      nonceClaim: await sha256Hex(nonce),
      audience: clientId,
      issuer: appleIssuer,
      expiresInSeconds: 600,
      nowMs: harness.clock.nowMs,
    });
    const apple: Response = await harness.call(req("POST", "/v1/auth/apple", { json: { identityToken: appleToken, nonce } }));
    expect(apple.status).toBe(200);
    expect((await apple.json<Session>()).userId).not.toBe(google.userId);
  });

  it("yanlış aud, yanlış iss, Apple iss'i, süresi dolmuş jeton ve yanlış nonce reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const nonce: string = randomToken(24);
    const base: LoginOverrides = { audience: googleClientId, issuer: "https://accounts.google.com", nonceClaimFor: nonce, nonce, expiresInSeconds: 3600 };
    const subject: string = `google-${randomId()}`;
    await expectError(await googleLogin(harness, subject, { ...base, audience: "baska.apps.googleusercontent.com" }), 401, "invalid_token");
    await expectError(await googleLogin(harness, subject, { ...base, audience: clientId }), 401, "invalid_token");
    await expectError(await googleLogin(harness, subject, { ...base, issuer: "https://evil.example" }), 401, "invalid_token");
    await expectError(await googleLogin(harness, subject, { ...base, issuer: appleIssuer }), 401, "invalid_token");
    await expectError(await googleLogin(harness, subject, { ...base, expiresInSeconds: -60 }), 401, "invalid_token");
    await expectError(await googleLogin(harness, subject, { ...base, nonce: randomToken(24) }), 401, "invalid_token");
    // Ham nonce'un kendisi (özeti değil) jetonda: reddedilir.
    const raw: string = randomToken(24);
    const fields: AppleTokenFields = { subject, nonceClaim: raw, audience: googleClientId, issuer: base.issuer, expiresInSeconds: 3600, nowMs: harness.clock.nowMs };
    const rawToken: string = await googleIdentityToken(fields);
    await expectError(await harness.call(req("POST", "/v1/auth/google", { json: { identityToken: rawToken, nonce: raw } })), 401, "invalid_token");
  });

  it("Apple anahtarıyla imzalanmış jeton Google ucunda reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const nonce: string = randomToken(24);
    const identityToken: string = await appleIdentityToken({
      subject: `google-${randomId()}`,
      nonceClaim: await sha256Hex(nonce),
      audience: googleClientId,
      issuer: "https://accounts.google.com",
      expiresInSeconds: 600,
      nowMs: harness.clock.nowMs,
    });
    await expectError(await harness.call(req("POST", "/v1/auth/google", { json: { identityToken, nonce } })), 401, "invalid_token");
  });

  it("aynı nonce ikinci kez kullanılamaz", async () => {
    const harness: Harness = await defaultHarness();
    const nonce: string = randomToken(24);
    const base: LoginOverrides = { audience: googleClientId, issuer: "https://accounts.google.com", nonceClaimFor: nonce, nonce, expiresInSeconds: 3600 };
    const subject: string = `google-${randomId()}`;
    expect((await googleLogin(harness, subject, base)).status).toBe(200);
    await expectError(await googleLogin(harness, subject, base), 401, "invalid_token");
  });

  it("Google JWKS geçici hatası yeniden denenir", async () => {
    const harness: Harness = await defaultHarness();
    let calls: number = 0;
    harness.stub(googleJwksUrl, async (): Promise<Response> => {
      calls += 1;
      return new Response("geçici", { status: 503 });
    });
    const nonce: string = randomToken(24);
    const response: Response = await googleLogin(harness, `google-${randomId()}`, {
      audience: googleClientId,
      issuer: "https://accounts.google.com",
      nonceClaimFor: nonce,
      nonce,
      expiresInSeconds: 3600,
    });
    await expectError(response, 502, "upstream_unavailable");
    expect(calls).toBe(3);
  });

  it("Google girişi de IP başına hız sınırlıdır; e-posta uçları kaldırıldı", async () => {
    const harness: Harness = await defaultHarness();
    const limited = envWith({ AUTH_IP_LIMITER: blockingLimiter });
    await expectError(
      await harness.call(req("POST", "/v1/auth/google", { json: { identityToken: "x".repeat(30), nonce: randomToken(24) }, env: limited })),
      429,
      "rate_limited",
    );
    await expectError(
      await harness.call(req("POST", "/v1/auth/email/start", { json: { email: "kisi@ornek.test", turnstileToken: "tt" } })),
      404,
      "not_found",
    );
  });
});

describe("yenileme jetonu ve çıkış", () => {
  it("yenileme jetonu döner; yerine geçen jeton kullanıldıktan sonra eski jeton gelirse tüm aile düşer", async () => {
    const harness: Harness = await defaultHarness();
    const first: Session = await signIn(harness);
    const rotated: Response = await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }));
    expect(rotated.status).toBe(200);
    const second: Session = await rotated.json<Session>();
    expect(second.refreshToken).not.toBe(first.refreshToken);
    const third: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: second.refreshToken } }))).json<Session>();
    expect((await harness.call(req("GET", "/v1/me", { token: third.accessToken }))).status).toBe(200);

    // Çalınmış eski jeton (halefi zaten kullanıldı, süre içinde bile olsa): yeniden kullanım tespit edilir.
    harness.clock.nowMs += 5_000;
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } })), 401, "invalid_token");
    // Meşru yeni jeton ve erişim jetonu da artık geçersiz.
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: third.refreshToken } })), 401, "invalid_token");
    await expectError(await harness.call(req("GET", "/v1/me", { token: third.accessToken })), 401, "invalid_token");
  });

  it("halefi kullanılmamış eski jeton yeniden deneme süresi (10 dk) geçince yeniden kullanımdır: aile düşer", async () => {
    const harness: Harness = await defaultHarness();
    const first: Session = await signIn(harness);
    const second: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }))).json<Session>();
    harness.clock.nowMs += refreshRetryWindowMs + 1_000;
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } })), 401, "invalid_token");
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: second.refreshToken } })), 401, "invalid_token");
  });

  it("yanıtı kaybolan yenileme (istemci zaman aşımı) dakikalar sonra aynı jetonla yeniden denenebilir; kaybolan jeton geçersizleşir, aile düşmez", async () => {
    const harness: Harness = await defaultHarness();
    const first: Session = await signIn(harness);
    const lost: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }))).json<Session>();
    // İstemcinin 30 sn'lik zaman aşımından ve sonraki isteğe dek geçen süreden uzun.
    harness.clock.nowMs += 4 * 60_000;
    const retried: Response = await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }));
    expect(retried.status).toBe(200);
    const second: Session = await retried.json<Session>();
    expect(second.refreshToken).not.toBe(lost.refreshToken);
    expect((await harness.call(req("GET", "/v1/me", { token: second.accessToken }))).status).toBe(200);
    // Kaybolan jeton artık yok (aile düşürülmez); yeni jeton dönmeye devam eder.
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: lost.refreshToken } })), 401, "invalid_token");
    const third: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: second.refreshToken } }))).json<Session>();
    expect((await harness.call(req("GET", "/v1/me", { token: third.accessToken }))).status).toBe(200);
    // Süre geçtikten sonra hemen önceki jeton yeniden kullanımdır: aile düşer.
    harness.clock.nowMs += refreshRetryWindowMs + 1_000;
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: second.refreshToken } })), 401, "invalid_token");
    await expectError(await harness.call(req("GET", "/v1/me", { token: third.accessToken })), 401, "invalid_token");
  });

  it("kullanılmış yazılıp halefi eklenmemiş jeton (yarıda kalmış dönüş) aileyi düşürmez, yeniden sunulunca yeni çift verir", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    // Eski sürümde jetonu kullanılmış yapan ifade işlendi, halefi ekleyen ifadeden önce istek düştü.
    await env.DB.prepare("UPDATE refresh_tokens SET used_at = ?, replaced_by = ? WHERE token_hash = ?")
      .bind(harness.clock.nowMs, await sha256Hex(randomToken(32)), await sha256Hex(session.refreshToken))
      .run();
    harness.clock.nowMs += 2 * 60_000;
    const retried: Response = await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } }));
    expect(retried.status).toBe(200);
    expect((await harness.call(req("GET", "/v1/me", { token: (await retried.json<Session>()).accessToken }))).status).toBe(200);
  });

  it("dönüşte ailede yalnızca son iki kullanılmış jeton kalır", async () => {
    const harness: Harness = await defaultHarness();
    let session: Session = await signIn(harness);
    for (let index: number = 0; index < 5; index += 1) {
      session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } }))).json<Session>();
    }
    const family = await env.DB.prepare("SELECT id FROM refresh_families WHERE user_id = ?").bind(session.userId).first<{ id: string }>();
    const rows = await env.DB.prepare("SELECT used_at IS NOT NULL AS used FROM refresh_tokens WHERE family_id = ? ORDER BY used")
      .bind(family?.id ?? "")
      .all<{ used: number }>();
    expect(rows.results).toEqual([{ used: 0 }, { used: 1 }, { used: 1 }]);
  });

  it("süresi dolmuş erişim jetonu reddedilir, yenileme yeni jeton verir", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    harness.clock.nowMs += 16 * 60_000;
    await expectError(await harness.call(req("GET", "/v1/me", { token: session.accessToken })), 401, "invalid_token");
    const refreshed: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } }))).json<Session>();
    expect((await harness.call(req("GET", "/v1/me", { token: refreshed.accessToken }))).status).toBe(200);
  });

  it("çıkış oturum ailesini düşürür", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const out: Response = await harness.call(req("POST", "/v1/auth/logout", { json: { refreshToken: session.refreshToken } }));
    expect(out.status).toBe(200);
    await expectError(await harness.call(req("GET", "/v1/me", { token: session.accessToken })), 401, "invalid_token");
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } })), 401, "invalid_token");
  });

  it("bilinmeyen yenileme jetonu reddedilir ve hiçbir jeton açık metin saklanmaz", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: randomToken(32) } })), 401, "invalid_token");
    const plain = await env.DB.prepare("SELECT COUNT(*) AS count FROM refresh_tokens WHERE token_hash = ?").bind(session.refreshToken).first<{ count: number }>();
    expect(plain?.count).toBe(0);
  });
});
