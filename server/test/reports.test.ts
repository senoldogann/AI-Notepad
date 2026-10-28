import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { turnstileVerifyUrl } from "../src/auth/turnstile";
import { crashPayloadMaxChars, reportBodyMaxBytes } from "../src/reports";
import { type Harness, type Session, blockingLimiter, defaultHarness, envWith, expectError, req, signIn } from "./helpers";

const siteOrigin: string = "http://localhost:8788";

/** MetricKit `MXDiagnosticPayload.jsonRepresentation()` biçiminde küçük bir çökme raporu. */
const metricKitCrash: string = JSON.stringify({
  timeStampBegin: "2026-10-15 10:00:00",
  crashDiagnostics: [
    {
      callStackTree: { callStackPerThread: true, callStacks: [] },
      diagnosticMetaData: {
        appVersion: "1.2.0",
        osVersion: "macOS 26.1",
        exceptionType: 1,
        signal: 11,
        exceptionCode: 0,
        terminationReason: "Namespace SIGNAL, Code 11",
      },
    },
  ],
});

interface StoredReport {
  readonly kind: string;
  readonly status: string;
  readonly user_id: string | null;
  readonly email: string | null;
  readonly app_version: string | null;
  readonly os: string | null;
  readonly message: string | null;
  readonly payload: string | null;
  readonly summary: string;
}

async function lastReport(): Promise<StoredReport | null> {
  return env.DB.prepare("SELECT kind, status, user_id, email, app_version, os, message, payload, summary FROM reports ORDER BY rowid DESC LIMIT 1").first<StoredReport>();
}

async function reportCount(): Promise<number> {
  return (await env.DB.prepare("SELECT COUNT(*) AS count FROM reports").first<{ count: number }>())?.count ?? -1;
}

function postReport(harness: Harness, json: object, token: string | null): Promise<Response> {
  return harness.call(req("POST", "/v1/reports", { json, token }));
}

/** Turnstile sahtesi; gelen jetonları toplar. */
function stubTurnstile(harness: Harness, success: boolean): string[] {
  const tokens: string[] = [];
  harness.stub(turnstileVerifyUrl, async (request: Request): Promise<Response> => {
    const body = await request.json<{ secret: string; response: string }>();
    expect(body.secret).toBe(env.TURNSTILE_SECRET_KEY);
    tokens.push(body.response);
    return Response.json({ success, "error-codes": success ? [] : ["invalid-input-response"] });
  });
  return tokens;
}

describe("POST /v1/reports", () => {
  it("anonim geri bildirim 202 {} döner ve hesapsız saklanır; jetonla gelen hesaba bağlanır", async () => {
    const harness: Harness = await defaultHarness();
    const anonymous: Response = await postReport(harness, { kind: "feedback", message: "  Harika uygulama  ", appVersion: "1.2.0", os: "macOS 26.1" }, null);
    expect(anonymous.status).toBe(202);
    expect(await anonymous.json()).toEqual({});
    expect(await lastReport()).toEqual({
      kind: "feedback",
      status: "open",
      user_id: null,
      email: null,
      app_version: "1.2.0",
      os: "macOS 26.1",
      message: "Harika uygulama",
      payload: null,
      summary: "Harika uygulama",
    });

    const session: Session = await signIn(harness);
    const long: string = "ş".repeat(300);
    expect((await postReport(harness, { kind: "feedback", message: long, email: "kisi@ornek.test" }, session.accessToken)).status).toBe(202);
    const stored: StoredReport | null = await lastReport();
    expect(stored?.user_id).toBe(session.userId);
    expect(stored?.email).toBe("kisi@ornek.test");
    expect(stored?.summary).toBe("ş".repeat(200));
  });

  it("geçersiz ya da bozuk jeton anonim rapora dönmez: 401", async () => {
    const harness: Harness = await defaultHarness();
    const before: number = await reportCount();
    await expectError(await postReport(harness, { kind: "feedback", message: "x" }, "e30.e30.sahte"), 401, "invalid_token");
    await expectError(
      await harness.call(req("POST", "/v1/reports", { json: { kind: "feedback", message: "x" }, headers: { authorization: "Basic abc" } })),
      401,
      "unauthorized",
    );
    expect(await reportCount()).toBe(before);
  });

  it("çökme raporu: MetricKit imzası özete çıkar; JSON nesnesi olmayan yük ve yüksüz çökme reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    expect((await postReport(harness, { kind: "crash", payload: metricKitCrash, appVersion: "1.2.0" }, null)).status).toBe(202);
    const stored: StoredReport | null = await lastReport();
    expect(stored?.summary).toBe("EXC_BAD_ACCESS · SIGSEGV");
    expect(stored?.payload).toBe(metricKitCrash);

    expect((await postReport(harness, { kind: "crash", payload: JSON.stringify({ kendi: "biçimimiz" }) }, null)).status).toBe(202);
    expect((await lastReport())?.summary).toBe("crash report");
    expect((await postReport(harness, { kind: "crash", payload: "{}", message: "Kayıt bitince çöktü" }, null)).status).toBe(202);
    expect((await lastReport())?.summary).toBe("Kayıt bitince çöktü");

    await expectError(await postReport(harness, { kind: "crash", payload: "[1, 2]" }, null), 400, "invalid_body");
    await expectError(await postReport(harness, { kind: "crash", payload: "{bozuk" }, null), 400, "invalid_body");
    await expectError(await postReport(harness, { kind: "crash", message: "yük yok" }, null), 400, "invalid_body");
  });

  it("türe ait olmayan ya da eksik alanlar reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    await expectError(await postReport(harness, { kind: "feedback" }, null), 400, "invalid_body");
    await expectError(await postReport(harness, { kind: "feedback", message: "   " }, null), 400, "invalid_body");
    await expectError(await postReport(harness, { kind: "feedback", message: "x", payload: "{}" }, null), 400, "invalid_body");
    await expectError(await postReport(harness, { kind: "feedback", message: "x", email: "adres-değil" }, null), 400, "invalid_body");
    await expectError(await postReport(harness, { kind: "feedback", message: "x".repeat(5001) }, null), 400, "invalid_body");
    await expectError(await postReport(harness, { kind: "feedback", message: "x", appVersion: "1".repeat(41) }, null), 400, "invalid_body");
    await expectError(await postReport(harness, { kind: "bug", message: "x" }, null), 400, "invalid_body");
  });

  it("iletişim formu e-posta, mesaj ve Turnstile ister; Turnstile doğrulanmazsa saklanmaz", async () => {
    const harness: Harness = await defaultHarness();
    const contact = { kind: "contact", message: "Kurumsal fiyat?", email: "satin@ornek.test", turnstileToken: "tt-ok" };
    await expectError(await postReport(harness, { kind: "contact", message: "x", email: "satin@ornek.test" }, null), 400, "invalid_body");
    await expectError(await postReport(harness, { kind: "contact", message: "x", turnstileToken: "tt" }, null), 400, "invalid_body");
    expect(harness.outbound).toHaveLength(0);

    stubTurnstile(harness, false);
    const before: number = await reportCount();
    await expectError(await postReport(harness, contact, null), 403, "turnstile_failed");
    expect(await reportCount()).toBe(before);

    const tokens: string[] = stubTurnstile(harness, true);
    const accepted: Response = await harness.call(req("POST", "/v1/reports", { json: contact, headers: { origin: siteOrigin } }));
    expect(accepted.status).toBe(202);
    expect(accepted.headers.get("access-control-allow-origin")).toBe(siteOrigin);
    expect(tokens).toEqual(["tt-ok"]);
    expect(await lastReport()).toMatchObject({ kind: "contact", email: "satin@ornek.test", message: "Kurumsal fiyat?", payload: null });

    const preflight: Response = await harness.call(req("OPTIONS", "/v1/reports", { headers: { origin: siteOrigin } }));
    expect(preflight.status).toBe(204);
  });

  it("gövde boyutu ayrıştırmadan önce sınırlanır (413); 512 K karakteri aşan yük reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const huge: string = JSON.stringify({ kind: "crash", payload: "x".repeat(reportBodyMaxBytes) });
    await expectError(
      await harness.call(req("POST", "/v1/reports", { body: huge, headers: { "content-type": "application/json" } })),
      413,
      "payload_too_large",
    );
    const tooLong: string = JSON.stringify({ a: "x".repeat(crashPayloadMaxChars) });
    await expectError(await postReport(harness, { kind: "crash", payload: tooLong }, null), 400, "invalid_body");
    const largest: string = JSON.stringify({ a: "x".repeat(crashPayloadMaxChars - 10) });
    expect((await postReport(harness, { kind: "crash", payload: largest }, null)).status).toBe(202);
  });

  it("IP hız sınırı ve tüm kullanıcılar için günlük sınır 429 döner; sınır ertesi gün sıfırlanır", async () => {
    const harness: Harness = await defaultHarness();
    await expectError(
      await harness.call(req("POST", "/v1/reports", { json: { kind: "feedback", message: "x" }, env: envWith({ REPORT_IP_LIMITER: blockingLimiter }) })),
      429,
      "rate_limited",
    );
    // Günlük sınır bugünkü (UTC) tüm raporları sayar.
    harness.clock.nowMs += 10 * 86_400_000;
    const capped = envWith({ REPORTS_PER_DAY: "2" });
    const warnings = vi.spyOn(console, "warn");
    for (let index: number = 0; index < 2; index += 1) {
      expect((await harness.call(req("POST", "/v1/reports", { json: { kind: "feedback", message: `ileti ${index}` }, env: capped }))).status).toBe(202);
    }
    await expectError(await harness.call(req("POST", "/v1/reports", { json: { kind: "feedback", message: "gizli-ileti" }, env: capped })), 429, "daily_cap_reached");
    const lines: string[] = warnings.mock.calls.map((call: unknown[]): string => String(call[0]));
    warnings.mockRestore();
    expect(lines.some((line: string): boolean => line.includes('"event":"reports_daily_cap_reached"'))).toBe(true);
    expect(lines.some((line: string): boolean => line.includes("gizli-ileti"))).toBe(false);
    harness.clock.nowMs += 86_400_000;
    expect((await harness.call(req("POST", "/v1/reports", { json: { kind: "feedback", message: "yarın" }, env: capped }))).status).toBe(202);
  });

  it("loglar mesaj, e-posta ya da yük içermez", async () => {
    const harness: Harness = await defaultHarness();
    const lines: string[] = [];
    const spy = vi.spyOn(console, "log").mockImplementation((...args: unknown[]): void => {
      lines.push(args.map((arg: unknown): string => String(arg)).join(" "));
    });
    try {
      await postReport(harness, { kind: "crash", payload: metricKitCrash, message: "GİZLİ-NOT", email: "gizli@ornek.test" }, null);
    } finally {
      spy.mockRestore();
    }
    const line: string | undefined = lines.find((text: string): boolean => text.includes('"event":"report_received"'));
    expect(line).toBeDefined();
    expect(line).not.toContain("GİZLİ-NOT");
    expect(line).not.toContain("gizli@ornek.test");
    expect(line).not.toContain("terminationReason");
  });
});
