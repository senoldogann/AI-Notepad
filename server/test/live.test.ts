import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { type Harness, type Session, type StartedMeetingBody, defaultHarness, envWith, req, signIn, startMeeting } from "./helpers";

/**
 * Gerçek servis testleri: yalnızca `AINOTEPAD_SERVER_LIVE_TESTS=1` ve test anahtarları verildiğinde çalışır
 * (bkz. vitest.config.ts). Apple JWKS yine sahtedir; Anthropic ve Stripe'a gerçek istek gider.
 *
 *   AINOTEPAD_SERVER_LIVE_TESTS=1 LIVE_ANTHROPIC_API_KEY=... LIVE_STRIPE_SECRET_KEY=sk_test_... \
 *   LIVE_STRIPE_PRICE_ID=price_... npx vitest run test/live.test.ts
 */
const live: boolean = env.LIVE_TESTS === "1";
const anthropicKey: string | undefined = env.LIVE_ANTHROPIC_API_KEY;
const stripeKey: string | undefined = env.LIVE_STRIPE_SECRET_KEY;
const stripePrice: string | undefined = env.LIVE_STRIPE_PRICE_ID;

function passThrough(harness: Harness, prefix: string): void {
  harness.stub(prefix, (request: Request): Promise<Response> => fetch(request));
}

describe.skipIf(!live || anthropicKey === undefined)("gerçek Anthropic Haiku 5.5 çağrısı", () => {
  it("akışlı JSON şemalı istek yanıt verir ve kullanım sayılır", async () => {
    const harness: Harness = await defaultHarness();
    passThrough(harness, "https://api.anthropic.com/");
    const liveEnv = envWith({ ANTHROPIC_API_KEY: anthropicKey ?? "" });
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    const response: Response = await harness.call(
      req("POST", "/v1/llm/messages", {
        token: session.accessToken,
        headers: { "x-meeting-id": meeting.meetingId },
        env: liveEnv,
        json: {
          system: "Kısa ve Türkçe yanıt ver.",
          max_tokens: 2048,
          stream: true,
          messages: [{ role: "user", content: "Toplantı: 'Cuma günü sürüm çıkacak, Ayşe testleri yazacak.' Görevleri çıkar." }],
          output_config: {
            format: {
              type: "json_schema",
              schema: {
                type: "object",
                properties: { tasks: { type: "array", items: { type: "string" } } },
                required: ["tasks"],
                additionalProperties: false,
              },
            },
          },
        },
      }),
    );
    expect(response.status).toBe(200);
    const text: string = await response.text();
    await harness.drain();
    expect(text).toContain("event: message_stop");
    const row = await env.DB.prepare("SELECT tokens_used FROM meeting_sessions WHERE id = ?").bind(meeting.meetingId).first<{ tokens_used: number }>();
    expect(row?.tokens_used ?? 0).toBeGreaterThan(0);
  });
});

describe.skipIf(!live || stripeKey === undefined || stripePrice === undefined)("gerçek Stripe test modu", () => {
  it("Checkout ve Portal oturumu açılır", async () => {
    expect(stripeKey?.startsWith("sk_test_")).toBe(true);
    const harness: Harness = await defaultHarness();
    passThrough(harness, "https://api.stripe.com/");
    const liveEnv = envWith({ STRIPE_SECRET_KEY: stripeKey ?? "", STRIPE_PRICE_ID: stripePrice ?? "" });
    const session: Session = await signIn(harness);
    const checkout: Response = await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken, env: liveEnv }));
    expect(checkout.status).toBe(200);
    expect((await checkout.json<{ url: string }>()).url).toMatch(/^https:\/\/checkout\.stripe\.com\//);
    const portal: Response = await harness.call(req("POST", "/v1/billing/portal", { token: session.accessToken, env: liveEnv }));
    expect(portal.status).toBe(200);
  });
});
