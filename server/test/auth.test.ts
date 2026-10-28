import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { appleIssuer } from "../src/auth/apple";
import { resendUrl } from "../src/auth/email";
import { turnstileVerifyUrl } from "../src/auth/turnstile";
import { randomId, randomToken, sha256Hex } from "../src/crypto";
import {
  type Harness,
  type Session,
  appleIdentityToken,
  blockingLimiter,
  defaultHarness,
  envWith,
  expectError,
  req,
  signIn,
} from "./helpers";

const clientId: string = "com.senoldogan.AINotepad.hosted";

async function appleLogin(harness: Harness, overrides: { audience: string; issuer: string; nonceClaimFor: string; nonce: string; expiresInSeconds: number }): Promise<Response> {
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

/** Turnstile ve Resend sahteleri; gönderilen bağlantıları toplar. */
function stubEmail(harness: Harness, turnstileSuccess: boolean): string[] {
  const links: string[] = [];
  harness.stub(turnstileVerifyUrl, async (request: Request): Promise<Response> => {
    const body = await request.json<{ secret: string; response: string }>();
    expect(body.secret).toBe(env.TURNSTILE_SECRET_KEY);
    return Response.json({ success: turnstileSuccess, "error-codes": turnstileSuccess ? [] : ["invalid-input-response"] });
  });
  harness.stub(resendUrl, async (request: Request): Promise<Response> => {
    expect(request.headers.get("authorization")).toBe(`Bearer ${env.RESEND_API_KEY}`);
    const body = await request.json<{ to: string[]; text: string }>();
    const match: RegExpMatchArray | null = /#token=([A-Za-z0-9_-]+)/.exec(body.text);
    if (match?.[1] !== undefined) {
      links.push(match[1]);
    }
    return Response.json({ id: "email_1" });
  });
  return links;
}

const resendEnv = envWith({ EMAIL_SENDER: "resend" });

describe("Apple ile giriş", () => {
  it("geçerli jetonla kullanıcı ve oturum oluşturur; aynı Apple kimliği aynı kullanıcıdır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    expect(session.accessToken.split(".")).toHaveLength(3);
    const me: Response = await harness.call(req("GET", "/v1/me", { token: session.accessToken }));
    expect(me.status).toBe(200);
    expect((await me.json<{ userId: string }>()).userId).toBe(session.userId);
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

describe("e-posta bağlantısıyla giriş", () => {
  it("Turnstile doğrulanınca bağlantı gönderilir; jeton tek kullanımlıktır", async () => {
    const harness: Harness = await defaultHarness();
    const links: string[] = stubEmail(harness, true);
    const email: string = `Kisi.${randomId()}@Example.com`;
    const start: Response = await harness.call(req("POST", "/v1/auth/email/start", { json: { email, turnstileToken: "tt" }, env: resendEnv }));
    expect(start.status).toBe(202);
    expect(links).toHaveLength(1);
    const token: string = links[0] ?? "";
    const stored = await env.DB.prepare("SELECT email FROM email_login_tokens WHERE token_hash = ?").bind(await sha256Hex(token)).first<{ email: string }>();
    expect(stored?.email).toBe(email.toLowerCase());

    const verify: Response = await harness.call(req("POST", "/v1/auth/email/verify", { json: { token } }));
    expect(verify.status).toBe(200);
    const session: Session = await verify.json<Session>();
    await expectError(await harness.call(req("POST", "/v1/auth/email/verify", { json: { token } })), 401, "invalid_token");

    // Aynı adresle ikinci giriş aynı kullanıcıya düşer.
    await harness.call(req("POST", "/v1/auth/email/start", { json: { email: email.toUpperCase(), turnstileToken: "tt" }, env: resendEnv }));
    const second: Response = await harness.call(req("POST", "/v1/auth/email/verify", { json: { token: links[1] ?? "" } }));
    expect((await second.json<Session>()).userId).toBe(session.userId);
  });

  it("süresi dolmuş bağlantı reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const links: string[] = stubEmail(harness, true);
    await harness.call(req("POST", "/v1/auth/email/start", { json: { email: `${randomId()}@example.com`, turnstileToken: "tt" }, env: resendEnv }));
    harness.clock.nowMs += 16 * 60_000;
    await expectError(await harness.call(req("POST", "/v1/auth/email/verify", { json: { token: links[0] ?? "" } })), 401, "invalid_token");
  });

  it("Turnstile başarısızsa e-posta gönderilmez", async () => {
    const harness: Harness = await defaultHarness();
    const links: string[] = stubEmail(harness, false);
    await expectError(
      await harness.call(req("POST", "/v1/auth/email/start", { json: { email: `${randomId()}@example.com`, turnstileToken: "kötü" }, env: resendEnv })),
      403,
      "turnstile_failed",
    );
    expect(links).toHaveLength(0);
  });

  it("geliştirme göndericisi dışarı istek atmaz", async () => {
    const harness: Harness = await defaultHarness();
    stubEmail(harness, true);
    const response: Response = await harness.call(req("POST", "/v1/auth/email/start", { json: { email: `${randomId()}@example.com`, turnstileToken: "tt" } }));
    expect(response.status).toBe(202);
    expect(harness.outbound.map((request: Request): string => request.url)).toEqual([turnstileVerifyUrl]);
  });
});

describe("yenileme jetonu ve çıkış", () => {
  it("yenileme jetonu döner; eski jeton yeniden kullanılırsa tüm aile düşer", async () => {
    const harness: Harness = await defaultHarness();
    const first: Session = await signIn(harness);
    const rotated: Response = await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }));
    expect(rotated.status).toBe(200);
    const second: Session = await rotated.json<Session>();
    expect(second.refreshToken).not.toBe(first.refreshToken);
    expect((await harness.call(req("GET", "/v1/me", { token: second.accessToken }))).status).toBe(200);

    // Çalınmış eski jeton: yeniden kullanım tespit edilir.
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } })), 401, "invalid_token");
    // Meşru yeni jeton ve erişim jetonu da artık geçersiz.
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: second.refreshToken } })), 401, "invalid_token");
    await expectError(await harness.call(req("GET", "/v1/me", { token: second.accessToken })), 401, "invalid_token");
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
