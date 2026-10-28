import { env } from "cloudflare:workers";
import Stripe from "stripe";
import { describe, expect, it } from "vitest";
import { randomToken } from "../src/crypto";
import { type Harness, type Session, defaultHarness, expectError, req, signIn } from "./helpers";

const siteOrigin: string = "http://localhost:8788";

interface StripeCalls {
  customers: number;
  checkoutForms: URLSearchParams[];
  portalForms: URLSearchParams[];
}

function stubStripe(harness: Harness): StripeCalls {
  const calls: StripeCalls = { customers: 0, checkoutForms: [], portalForms: [] };
  harness.stub("https://api.stripe.com/v1/customers", async (request: Request): Promise<Response> => {
    expect(request.headers.get("authorization")).toBe(`Bearer ${env.STRIPE_SECRET_KEY}`);
    calls.customers += 1;
    return Response.json({ id: `cus_${randomToken(6)}`, object: "customer" });
  });
  harness.stub("https://api.stripe.com/v1/checkout/sessions", async (request: Request): Promise<Response> => {
    calls.checkoutForms.push(new URLSearchParams(new TextDecoder().decode(await request.arrayBuffer())));
    return Response.json({ id: "cs_test_1", object: "checkout.session", url: "https://checkout.stripe.com/c/pay/cs_test_1" });
  });
  harness.stub("https://api.stripe.com/v1/billing_portal/sessions", async (request: Request): Promise<Response> => {
    calls.portalForms.push(new URLSearchParams(new TextDecoder().decode(await request.arrayBuffer())));
    return Response.json({ id: "bps_1", object: "billing_portal.session", url: "https://billing.stripe.com/p/session/bps_1" });
  });
  return calls;
}

async function customerOf(userId: string): Promise<string> {
  const row = await env.DB.prepare("SELECT stripe_customer_id FROM stripe_customers WHERE user_id = ?").bind(userId).first<{ stripe_customer_id: string }>();
  if (row === null) {
    throw new Error("müşteri yok");
  }
  return row.stripe_customer_id;
}

function subscriptionEvent(id: string, type: string, customer: string, status: string, created: number, periodEnd: number): string {
  return JSON.stringify({
    id,
    object: "event",
    type,
    created,
    api_version: "2026-09-30.endive",
    livemode: false,
    pending_webhooks: 1,
    request: { id: null, idempotency_key: null },
    data: {
      object: {
        id: "sub_test_1",
        object: "subscription",
        customer,
        status,
        items: { object: "list", data: [{ id: "si_1", object: "subscription_item", current_period_end: periodEnd }] },
      },
    },
  });
}

async function postWebhook(harness: Harness, payload: string, secret: string): Promise<Response> {
  const signature: string = await Stripe.webhooks.generateTestHeaderStringAsync({
    payload,
    secret,
    timestamp: Math.floor(harness.clock.nowMs / 1000),
    cryptoProvider: Stripe.createSubtleCryptoProvider(),
  });
  return harness.call(req("POST", "/v1/billing/webhook", { body: payload, headers: { "stripe-signature": signature, "content-type": "application/json" } }));
}

async function plan(harness: Harness, session: Session): Promise<{ plan: string; subscription: { status: string } | null }> {
  return (await harness.call(req("GET", "/v1/me", { token: session.accessToken }))).json();
}

describe("Stripe Checkout ve Portal", () => {
  it("Checkout aylık fiyat, otomatik vergi ve kullanıcı referansıyla açılır; müşteri yeniden kullanılır", async () => {
    const harness: Harness = await defaultHarness();
    const calls: StripeCalls = stubStripe(harness);
    const session: Session = await signIn(harness);
    const first: Response = await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken, headers: { origin: siteOrigin } }));
    expect(first.status).toBe(200);
    expect(first.headers.get("access-control-allow-origin")).toBe(siteOrigin);
    expect(await first.json()).toEqual({ url: "https://checkout.stripe.com/c/pay/cs_test_1" });
    await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken }));
    expect(calls.customers).toBe(1);

    const form: URLSearchParams | undefined = calls.checkoutForms[0];
    expect(form?.get("mode")).toBe("subscription");
    expect(form?.get("customer")).toBe(await customerOf(session.userId));
    expect(form?.get("client_reference_id")).toBe(session.userId);
    expect(form?.get("line_items[0][price]")).toBe(env.STRIPE_PRICE_ID);
    expect(form?.get("automatic_tax[enabled]")).toBe("true");
    expect(calls.checkoutForms[1]?.get("customer")).toBe(form?.get("customer"));
  });

  it("Portal yalnızca müşterisi olan kullanıcıya açılır", async () => {
    const harness: Harness = await defaultHarness();
    const calls: StripeCalls = stubStripe(harness);
    const session: Session = await signIn(harness);
    await expectError(await harness.call(req("POST", "/v1/billing/portal", { token: session.accessToken })), 402, "subscription_required");
    await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken }));
    const portal: Response = await harness.call(req("POST", "/v1/billing/portal", { token: session.accessToken }));
    expect(await portal.json()).toEqual({ url: "https://billing.stripe.com/p/session/bps_1" });
    expect(calls.portalForms[0]?.get("customer")).toBe(await customerOf(session.userId));
  });

  it("Stripe hatası 502 olur ve gizli bilgi taşımaz", async () => {
    const harness: Harness = await defaultHarness();
    harness.stub("https://api.stripe.com/", async (): Promise<Response> =>
      Response.json({ error: { type: "invalid_request_error", message: "No such price: price_x; key sk_test_fake" } }, { status: 400 }),
    );
    const session: Session = await signIn(harness);
    const body = await expectError(await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken })), 502, "upstream_unavailable");
    expect(body.error.message).not.toContain("sk_test");
  });
});

describe("Stripe webhook", () => {
  it("imzasız ya da yanlış imzalı olay reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const payload: string = subscriptionEvent("evt_bad", "customer.subscription.updated", "cus_x", "active", 1, 2);
    await expectError(await harness.call(req("POST", "/v1/billing/webhook", { body: payload })), 400, "webhook_invalid");
    await expectError(await postWebhook(harness, payload, "whsec_baska_gizli_deger_000"), 400, "webhook_invalid");
  });

  it("5 dakikadan eski imzalı olay (yeniden oynatma) reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const payload: string = subscriptionEvent("evt_old", "customer.subscription.updated", "cus_x", "active", 1, 2);
    const signature: string = await Stripe.webhooks.generateTestHeaderStringAsync({
      payload,
      secret: env.STRIPE_WEBHOOK_SECRET,
      timestamp: Math.floor(harness.clock.nowMs / 1000) - 301,
      cryptoProvider: Stripe.createSubtleCryptoProvider(),
    });
    await expectError(
      await harness.call(req("POST", "/v1/billing/webhook", { body: payload, headers: { "stripe-signature": signature } })),
      400,
      "webhook_invalid",
    );
  });

  it("abonelik durumunu yazar, aynı olayı bir kez işler, eski olay yeni durumu ezmez", async () => {
    const harness: Harness = await defaultHarness();
    stubStripe(harness);
    const session: Session = await signIn(harness);
    await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken }));
    const customer: string = await customerOf(session.userId);
    const nowSeconds: number = Math.floor(harness.clock.nowMs / 1000);
    const periodEnd: number = nowSeconds + 30 * 86_400;

    const created: string = subscriptionEvent("evt_1", "customer.subscription.created", customer, "active", nowSeconds - 10, periodEnd);
    const first: Response = await postWebhook(harness, created, env.STRIPE_WEBHOOK_SECRET);
    expect(await first.json()).toEqual({ received: true, duplicate: false });
    expect((await plan(harness, session)).plan).toBe("subscription");

    const again: Response = await postWebhook(harness, created, env.STRIPE_WEBHOOK_SECRET);
    expect(await again.json()).toEqual({ received: true, duplicate: true });

    const canceled: string = subscriptionEvent("evt_2", "customer.subscription.deleted", customer, "canceled", nowSeconds, periodEnd);
    expect((await postWebhook(harness, canceled, env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    expect(await plan(harness, session)).toMatchObject({ plan: "trial", subscription: { status: "canceled" } });

    // Gecikmeli gelen eski "active" olayı iptali geri almaz.
    const stale: string = subscriptionEvent("evt_3", "customer.subscription.updated", customer, "active", nowSeconds - 5, periodEnd);
    expect((await postWebhook(harness, stale, env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    expect((await plan(harness, session)).plan).toBe("trial");

    const count = await env.DB.prepare("SELECT COUNT(*) AS count FROM stripe_events").first<{ count: number }>();
    expect(count?.count).toBe(3);
  });

  it("abonelik dışı olay kaydedilir ama durumu değiştirmez; bilinmeyen müşteri reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const other: string = JSON.stringify({
      id: "evt_other",
      object: "event",
      type: "invoice.paid",
      created: 1,
      data: { object: { id: "in_1", object: "invoice" } },
    });
    expect(await (await postWebhook(harness, other, env.STRIPE_WEBHOOK_SECRET)).json()).toEqual({ received: true, duplicate: false });
    const unknown: string = subscriptionEvent("evt_unknown", "customer.subscription.updated", "cus_bilinmeyen", "active", 1, 2);
    await expectError(await postWebhook(harness, unknown, env.STRIPE_WEBHOOK_SECRET), 404, "not_found");
    const recorded = await env.DB.prepare("SELECT COUNT(*) AS count FROM stripe_events WHERE id = 'evt_unknown'").first<{ count: number }>();
    expect(recorded?.count).toBe(0);
  });
});
