import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import type { Env } from "../src/env";
import { turnstileVerifyUrl } from "../src/auth/turnstile";
import { crashPayloadMaxBytes, reportBodyMaxBytes, reportsPerUserPerDay } from "../src/reports";
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
  it("hesapsız sürümlerin (geliştirici, iPhone) jetonsuz raporu kabul edilir ama tür bütçesinin dörtte birini aşamaz", async () => {
    const harness: Harness = await defaultHarness();
    const small: Env = envWith({ REPORT_BYTES_PER_DAY: "4000" });
    const anonymous = (message: string): Promise<Response> =>
      harness.call(req("POST", "/v1/reports", { json: { kind: "feedback", message }, env: small }));
    // Özetle birlikte ~600 bayt: dörtte bir (1000) bütçeye bir tane sığar, ikincisi 429.
    expect((await anonymous("a".repeat(400))).status).toBe(202);
    expect((await lastReport())?.user_id).toBeNull();
    await expectError(await anonymous("b".repeat(400)), 429, "daily_cap_reached");
    // Hesaplı kullanıcı bütçenin kalanını kullanabilir.
    const session: Session = await signIn(harness);
    expect((await harness.call(req("POST", "/v1/reports", { token: session.accessToken, json: { kind: "feedback", message: "c".repeat(400) }, env: small }))).status).toBe(202);
  });

  it("jetonla gelen geri bildirim 202 {} döner ve hesaba bağlanır", async () => {
    const harness: Harness = await defaultHarness();

    const session: Session = await signIn(harness);
    const accepted: Response = await postReport(harness, { kind: "feedback", message: "  Harika uygulama  ", appVersion: "1.2.0", os: "macOS 26.1" }, session.accessToken);
    expect(accepted.status).toBe(202);
    expect(await accepted.json()).toEqual({});
    expect(await lastReport()).toEqual({
      kind: "feedback",
      status: "open",
      user_id: session.userId,
      email: null,
      app_version: "1.2.0",
      os: "macOS 26.1",
      message: "Harika uygulama",
      payload: null,
      summary: "Harika uygulama",
    });

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
    const token: string = (await signIn(harness)).accessToken;
    expect((await postReport(harness, { kind: "crash", payload: metricKitCrash, appVersion: "1.2.0" }, token)).status).toBe(202);
    const stored: StoredReport | null = await lastReport();
    expect(stored?.summary).toBe("EXC_BAD_ACCESS · SIGSEGV");
    expect(stored?.payload).toBe(metricKitCrash);

    expect((await postReport(harness, { kind: "crash", payload: JSON.stringify({ kendi: "biçimimiz" }) }, token)).status).toBe(202);
    expect((await lastReport())?.summary).toBe("crash report");
    expect((await postReport(harness, { kind: "crash", payload: "{}", message: "Kayıt bitince çöktü" }, token)).status).toBe(202);
    expect((await lastReport())?.summary).toBe("Kayıt bitince çöktü");

    await expectError(await postReport(harness, { kind: "crash", payload: "[1, 2]" }, token), 400, "invalid_body");
    await expectError(await postReport(harness, { kind: "crash", payload: "{bozuk" }, token), 400, "invalid_body");
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

  it("gövde boyutu ayrıştırmadan önce sınırlanır (413); 64 KB'ı aşan çökme yükü reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const token: string = (await signIn(harness)).accessToken;
    const huge: string = JSON.stringify({ kind: "crash", payload: "x".repeat(reportBodyMaxBytes) });
    await expectError(
      await harness.call(req("POST", "/v1/reports", { body: huge, token, headers: { "content-type": "application/json" } })),
      413,
      "payload_too_large",
    );
    // Sınır UTF-8 baytıdır: 64 K karakterden az ama 64 KB'tan büyük yük de reddedilir.
    const multiByte: string = JSON.stringify({ a: "ş".repeat(crashPayloadMaxBytes / 2) });
    await expectError(await postReport(harness, { kind: "crash", payload: multiByte }, token), 413, "payload_too_large");
    const tooLong: string = JSON.stringify({ a: "x".repeat(crashPayloadMaxBytes) });
    await expectError(await postReport(harness, { kind: "crash", payload: tooLong }, token), 400, "invalid_body");
    const largest: string = JSON.stringify({ a: "x".repeat(crashPayloadMaxBytes - 10) });
    expect((await postReport(harness, { kind: "crash", payload: largest }, token)).status).toBe(202);
  });

  it("IP hız sınırı ve tür başına günlük bayt bütçesi 429 döner; bir tür diğerini aç bırakmaz; sınır ertesi gün sıfırlanır", async () => {
    const harness: Harness = await defaultHarness();
    await expectError(
      await harness.call(req("POST", "/v1/reports", { json: { kind: "feedback", message: "x" }, env: envWith({ REPORT_IP_LIMITER: blockingLimiter }) })),
      429,
      "rate_limited",
    );
    // Bütçe bugünkü (UTC) türün raporlarının baytını sayar (mesaj + özet: 10 karakterlik ileti = 20 bayt).
    harness.clock.nowMs += 10 * 86_400_000;
    const capped = envWith({ REPORT_BYTES_PER_DAY: "40" });
    const send = async (json: object, token: string): Promise<Response> => harness.call(req("POST", "/v1/reports", { json, token, env: capped }));
    const tokens: string[] = [(await signIn(harness)).accessToken, (await signIn(harness)).accessToken];
    const warnings = vi.spyOn(console, "warn");
    expect((await send({ kind: "feedback", message: "ileti-0000" }, tokens[0] ?? "")).status).toBe(202);
    expect((await send({ kind: "feedback", message: "ileti-1111" }, tokens[1] ?? "")).status).toBe(202);
    await expectError(await send({ kind: "feedback", message: "gizli-ileti" }, tokens[0] ?? ""), 429, "daily_cap_reached");
    const lines: string[] = warnings.mock.calls.map((call: unknown[]): string => String(call[0]));
    warnings.mockRestore();
    expect(lines.some((line: string): boolean => line.includes('"event":"reports_daily_cap_reached"'))).toBe(true);
    expect(lines.some((line: string): boolean => line.includes("gizli-ileti"))).toBe(false);
    // Geri bildirim bütçesi dolsa da çökme raporu kendi bütçesinden kabul edilir.
    expect((await send({ kind: "crash", payload: "{}" }, tokens[0] ?? "")).status).toBe(202);
    harness.clock.nowMs += 86_400_000;
    const tomorrow: string = (await signIn(harness)).accessToken;
    expect((await send({ kind: "feedback", message: "yarın" }, tomorrow)).status).toBe(202);
  });

  it(`bir hesap günde en çok ${reportsPerUserPerDay} rapor gönderebilir; başka hesap etkilenmez`, async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs += 20 * 86_400_000;
    const busy: Session = await signIn(harness);
    for (let index: number = 0; index < reportsPerUserPerDay; index += 1) {
      expect((await postReport(harness, { kind: "feedback", message: `ileti ${index}` }, busy.accessToken)).status).toBe(202);
    }
    const refused = await expectError(await postReport(harness, { kind: "crash", payload: "{}" }, busy.accessToken), 429, "daily_cap_reached");
    expect(refused.error.message).toContain(String(reportsPerUserPerDay));
    expect((await postReport(harness, { kind: "feedback", message: "başka" }, (await signIn(harness)).accessToken)).status).toBe(202);
  });

  it("loglar mesaj, e-posta ya da yük içermez", async () => {
    const harness: Harness = await defaultHarness();
    const lines: string[] = [];
    const spy = vi.spyOn(console, "log").mockImplementation((...args: unknown[]): void => {
      lines.push(args.map((arg: unknown): string => String(arg)).join(" "));
    });
    try {
      await postReport(harness, { kind: "crash", payload: metricKitCrash, message: "GİZLİ-NOT", email: "gizli@ornek.test" }, (await signIn(harness)).accessToken);
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
