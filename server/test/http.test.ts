import { describe, expect, it } from "vitest";
import { type Harness, blockingLimiter, defaultHarness, envWith, expectError, req, signIn } from "./helpers";

const siteOrigin: string = "http://localhost:8788";

describe("sağlık, hata biçimi, güvenlik başlıkları ve CORS", () => {
  it("GET /v1/health tamam döner ve güvenlik başlıklarını taşır", async () => {
    const harness: Harness = await defaultHarness();
    const response: Response = await harness.call(req("GET", "/v1/health", {}));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok" });
    expect(response.headers.get("strict-transport-security")).toContain("max-age=");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(response.headers.get("content-security-policy")).toContain("default-src 'none'");
    // Geçerli yapılandırılmış alan sözlüğü (`özellik=()`); yalın `()` tarayıcıda yok sayılırdı.
    expect(response.headers.get("permissions-policy")).toBe("camera=(), microphone=(), geolocation=(), payment=(), usb=()");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("access-control-allow-origin")).toBeNull();
  });

  it("bilinmeyen uç tek tip hata gövdesi döner", async () => {
    const harness: Harness = await defaultHarness();
    await expectError(await harness.call(req("GET", "/v1/yok", {})), 404, "not_found");
  });

  it("site kaynağı web uçlarında CORS alır, uygulama uçlarında almaz", async () => {
    const harness: Harness = await defaultHarness();
    const web: Response = await harness.call(req("GET", "/v1/health", { headers: { origin: siteOrigin } }));
    expect(web.headers.get("access-control-allow-origin")).toBe(siteOrigin);
    expect(web.headers.get("access-control-allow-credentials")).toBeNull();

    const app: Response = await harness.call(req("POST", "/v1/meetings/start", { headers: { origin: siteOrigin }, json: {} }));
    expect(app.headers.get("access-control-allow-origin")).toBeNull();

    const foreign: Response = await harness.call(req("GET", "/v1/health", { headers: { origin: "https://evil.example" } }));
    expect(foreign.headers.get("access-control-allow-origin")).toBeNull();
  });

  it("ön kontrol yalnızca site kaynağı ve web uçları için izin verir", async () => {
    const harness: Harness = await defaultHarness();
    const allowed: Response = await harness.call(req("OPTIONS", "/v1/billing/checkout", { headers: { origin: siteOrigin } }));
    expect(allowed.status).toBe(204);
    expect(allowed.headers.get("access-control-allow-headers")).toBe("authorization, content-type");
    await expectError(await harness.call(req("OPTIONS", "/v1/llm/messages", { headers: { origin: siteOrigin } })), 403, "forbidden");
    await expectError(await harness.call(req("OPTIONS", "/v1/me", { headers: { origin: "https://evil.example" } })), 403, "forbidden");
  });

  it("korumalı uçlar bearer jetonu ister ve sahte jetonu reddeder", async () => {
    const harness: Harness = await defaultHarness();
    await expectError(await harness.call(req("GET", "/v1/me", {})), 401, "unauthorized");
    await expectError(await harness.call(req("GET", "/v1/me", { token: "e30.e30.sahte" })), 401, "invalid_token");
  });

  it("JSON olmayan ve şemaya uymayan gövdeler reddedilir; boyut sınırı uygulanır", async () => {
    const harness: Harness = await defaultHarness();
    await expectError(
      await harness.call(req("POST", "/v1/auth/refresh", { body: "x", headers: { "content-type": "text/plain" } })),
      415,
      "unsupported_media_type",
    );
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: "kısa" } })), 400, "invalid_body");
    await expectError(
      await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: "a".repeat(40), fazla: true } })),
      400,
      "invalid_body",
    );
    await expectError(
      await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: "a".repeat(40), dolgu: "x".repeat(20_000) } })),
      413,
      "payload_too_large",
    );
  });

  it("IP hız sınırı aşılınca 429 döner", async () => {
    const harness: Harness = await defaultHarness();
    const limited = envWith({ API_IP_LIMITER: blockingLimiter });
    await expectError(await harness.call(req("GET", "/v1/me", { env: limited })), 429, "rate_limited");
  });

  it("kullanıcı hız sınırı toplantı başlatmayı durdurur", async () => {
    const harness: Harness = await defaultHarness();
    const session = await signIn(harness);
    const limited = envWith({ START_USER_LIMITER: blockingLimiter });
    await expectError(
      await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {}, env: limited })),
      429,
      "rate_limited",
    );
  });

  it("eksik yapılandırma ayrıntı sızdırmadan 500 döner", async () => {
    const harness: Harness = await defaultHarness();
    const broken = envWith({ ACCESS_TOKEN_SECRET: "kısa" });
    const body = await expectError(await harness.call(req("GET", "/v1/health", { env: broken })), 500, "internal_error");
    expect(body.error.message).not.toContain("ACCESS_TOKEN_SECRET");
  });
});
