import { env } from "cloudflare:workers";
import Stripe from "stripe";
import { describe, expect, it, vi } from "vitest";
import { randomToken } from "../src/crypto";
import { type Harness, type Session, defaultHarness, envWith, expectError, grantSubscription, req, signIn } from "./helpers";
import { type FakeStripe, type FakeSubscription, fakeSubscription, fakeSubscriptionWithPrice, stubStripeApi } from "./stripeFake";

const siteOrigin: string = "http://localhost:8788";
const dayMs: number = 86_400_000;

async function customerOf(userId: string): Promise<string> {
  const row = await env.DB.prepare("SELECT stripe_customer_id FROM stripe_customers WHERE user_id = ?").bind(userId).first<{ stripe_customer_id: string }>();
  if (row === null) {
    throw new Error("müşteri yok");
  }
  return row.stripe_customer_id;
}

/** Stripe olayı gövdesi. */
function eventOf(id: string, type: string, created: number, object: object): string {
  return JSON.stringify({
    id,
    object: "event",
    type,
    created,
    api_version: "2026-09-30.endive",
    livemode: false,
    pending_webhooks: 1,
    request: { id: null, idempotency_key: null },
    data: { object },
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

/** Teste özgü Stripe kimlikleri: dosyanın D1'i testler arasında paylaşılır, abonelik ve olay kimlikleri benzersizdir. */
function uniqueIds(): (name: string) => string {
  const tag: string = randomToken(6);
  return (name: string): string => `${name}_${tag}`;
}

/** Webhook gönderici: aboneliğin güncel durumunu sahte Stripe'a yazar (Stripe olayı durum değiştikten sonra gönderir), sonra olayı yollar. */
interface Sender {
  /** Durumu Stripe'a yazıp olayı gönderir ve 200 bekler. */
  readonly change: (eventId: string, type: string, created: number, subscription: FakeSubscription) => Promise<Response>;
  /** Stripe'ın güncel durumuna dokunmadan (eski ya da geç gelen) olayı gönderir. */
  readonly replay: (eventId: string, type: string, created: number, subscription: FakeSubscription) => Promise<Response>;
}

function sender(harness: Harness, stripe: FakeStripe): Sender {
  const send = async (eventId: string, type: string, created: number, subscription: FakeSubscription): Promise<Response> =>
    postWebhook(harness, eventOf(eventId, type, created, subscription), env.STRIPE_WEBHOOK_SECRET);
  return {
    change: async (eventId: string, type: string, created: number, subscription: FakeSubscription): Promise<Response> => {
      const existing: FakeSubscription | undefined = stripe.subscriptions.get(subscription.id);
      stripe.subscriptions.set(subscription.id, existing === undefined ? subscription : { ...subscription, created: existing.created });
      return send(eventId, type, created, subscription);
    },
    replay: send,
  };
}

interface MeBody {
  readonly plan: string;
  readonly subscription: { status: string; cancelAt: string | null; access: string; graceEndsAt: string | null } | null;
}

async function plan(harness: Harness, session: Session): Promise<MeBody> {
  return (await harness.call(req("GET", "/v1/me", { token: session.accessToken }))).json<MeBody>();
}

/** Kullanıcının geçerli abonelik satırı. */
async function storedSubscription(userId: string): Promise<{ stripe_subscription_id: string; status: string } | null> {
  return env.DB.prepare("SELECT stripe_subscription_id, status FROM subscriptions WHERE user_id = ?")
    .bind(userId)
    .first<{ stripe_subscription_id: string; status: string }>();
}

/** Abone olmuş kullanıcı: Checkout ile müşteri oluşturulmuş oturum. */
async function customerSession(harness: Harness): Promise<{ session: Session; customer: string }> {
  const session: Session = await signIn(harness);
  expect((await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken }))).status).toBe(200);
  return { session, customer: await customerOf(session.userId) };
}

describe("Stripe Checkout ve Portal", () => {
  it("Checkout aylık fiyat, Managed Payments ve kullanıcı referansıyla açılır; müşteri yeniden kullanılır", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const session: Session = await signIn(harness);
    const first: Response = await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken, headers: { origin: siteOrigin } }));
    expect(first.status).toBe(200);
    expect(first.headers.get("access-control-allow-origin")).toBe(siteOrigin);
    expect(await first.json()).toEqual({ url: "https://checkout.stripe.com/c/pay/cs_test_1" });
    await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken }));
    expect(stripe.customers).toBe(1);
    // İkinci Checkout ilk (hâlâ açık) ödeme sayfasını kapatır: iki sekmede iki abonelik ödenemez.
    expect(stripe.expiredSessions).toEqual(["cs_test_1"]);
    expect([...stripe.openSessions.keys()]).toEqual(["cs_test_2"]);

    const form: URLSearchParams | undefined = stripe.checkoutForms[0];
    expect(form?.get("mode")).toBe("subscription");
    expect(form?.get("customer")).toBe(await customerOf(session.userId));
    expect(form?.get("client_reference_id")).toBe(session.userId);
    expect(form?.get("line_items[0][price]")).toBe(env.STRIPE_PRICE_ID);
    expect(form?.get("managed_payments[enabled]")).toBe("true");
    expect(form?.get("automatic_tax[enabled]")).toBeNull();
    expect(stripe.checkoutForms[1]?.get("customer")).toBe(form?.get("customer"));
  });

  it("Portal yalnızca müşterisi olan kullanıcıya açılır", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const session: Session = await signIn(harness);
    await expectError(await harness.call(req("POST", "/v1/billing/portal", { token: session.accessToken })), 402, "subscription_required");
    await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken }));
    const portal: Response = await harness.call(req("POST", "/v1/billing/portal", { token: session.accessToken }));
    expect(await portal.json()).toEqual({ url: "https://billing.stripe.com/p/session/bps_1" });
    expect(stripe.portalForms[0]?.get("customer")).toBe(await customerOf(session.userId));
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

  it("webhook'u gelmemiş ama Stripe'ta yaşayan abonelik varsa Checkout açılmaz (409)", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const id = uniqueIds();
    const { session, customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    stripe.subscriptions.set(id("sub"), fakeSubscription(id("sub"), customer, "active", now, now + 30 * 86_400));
    await expectError(await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken })), 409, "subscription_exists");
    expect(stripe.checkoutForms).toHaveLength(1);
  });
});

describe("Stripe webhook", () => {
  it("imzasız ya da yanlış imzalı olay reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const payload: string = eventOf("evt_bad", "invoice.paid", 1, { id: "in_1", object: "invoice" });
    await expectError(await harness.call(req("POST", "/v1/billing/webhook", { body: payload })), 400, "webhook_invalid");
    await expectError(await postWebhook(harness, payload, "whsec_baska_gizli_deger_000"), 400, "webhook_invalid");
  });

  it("5 dakikadan eski imzalı olay (yeniden oynatma) reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const payload: string = eventOf("evt_old", "invoice.paid", 1, { id: "in_1", object: "invoice" });
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

  it("olayın modu anahtarın moduyla uyuşmazsa alarm yazılır, 500 döner ve olay kaydedilmez (Stripe yeniden dener)", async () => {
    const harness: Harness = await defaultHarness();
    const live: string = JSON.stringify({ ...JSON.parse(eventOf("evt_livemode", "invoice.paid", 1, { id: "in_1", object: "invoice" })), livemode: true });
    const alerts = vi.spyOn(console, "error");
    await expectError(await postWebhook(harness, live, env.STRIPE_WEBHOOK_SECRET), 500, "internal_error");
    expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"stripe_mode_mismatch"'))).toBe(true);
    alerts.mockRestore();
    const recorded = await env.DB.prepare("SELECT COUNT(*) AS count FROM stripe_events WHERE id = 'evt_livemode'").first<{ count: number }>();
    expect(recorded?.count).toBe(0);
    // Canlı anahtarla aynı olay işlenir.
    stubStripeApi(harness);
    const liveKey = envWith({ STRIPE_SECRET_KEY: "sk_live_fake_0000000000000" });
    const signature: string = await Stripe.webhooks.generateTestHeaderStringAsync({
      payload: live,
      secret: env.STRIPE_WEBHOOK_SECRET,
      timestamp: Math.floor(harness.clock.nowMs / 1000),
      cryptoProvider: Stripe.createSubtleCryptoProvider(),
    });
    const accepted: Response = await harness.call(
      req("POST", "/v1/billing/webhook", { body: live, env: liveKey, headers: { "stripe-signature": signature, "content-type": "application/json" } }),
    );
    expect(accepted.status).toBe(200);
  });

  it("ilgisiz ayar hatası webhook'u durdurmaz (yalnızca Stripe ayarları gerekir); üretimde test anahtarı açık uyarı yazar", async () => {
    const harness: Harness = await defaultHarness();
    // DeviceCheck zorunlu ama anahtar yok, Deepgram açık ama anahtar yok: diğer uçlar 500 döner.
    const broken = envWith({ ENVIRONMENT: "production", DEVICECHECK_POLICY: "required", DEVICECHECK_PRIVATE_KEY: "", DEEPGRAM_POLICY: "on", DEEPGRAM_API_KEY: "" });
    await expectError(await harness.call(req("GET", "/v1/health", { env: broken })), 500, "internal_error");
    const id = uniqueIds();
    const payload: string = eventOf(id("evt_cfg"), "invoice.paid", 1, { id: "in_1", object: "invoice" });
    const signature: string = await Stripe.webhooks.generateTestHeaderStringAsync({
      payload,
      secret: env.STRIPE_WEBHOOK_SECRET,
      timestamp: Math.floor(harness.clock.nowMs / 1000),
      cryptoProvider: Stripe.createSubtleCryptoProvider(),
    });
    const warnings = vi.spyOn(console, "warn");
    const accepted: Response = await harness.call(
      req("POST", "/v1/billing/webhook", { body: payload, env: broken, headers: { "stripe-signature": signature, "content-type": "application/json" } }),
    );
    expect(accepted.status).toBe(200);
    expect(warnings.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"stripe_test_mode_in_production"'))).toBe(true);
    warnings.mockRestore();
    // Stripe sırrı eksikse webhook da açıkça durur (alan adıyla alarm).
    const alerts = vi.spyOn(console, "error");
    const noSecret = envWith({ STRIPE_WEBHOOK_SECRET: "" });
    await expectError(
      await harness.call(req("POST", "/v1/billing/webhook", { body: payload, env: noSecret, headers: { "stripe-signature": signature } })),
      500,
      "internal_error",
    );
    expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"fields":"STRIPE_WEBHOOK_SECRET"'))).toBe(true);
    alerts.mockRestore();
  });

  it("abonelik durumunu Stripe'taki güncel halinden yazar, aynı olayı bir kez işler, geç gelen eski olay yeni durumu ezmez", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const { session, customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    const periodEnd: number = now + 30 * 86_400;

    const active: FakeSubscription = fakeSubscription(id("sub"), customer, "active", now - 10, periodEnd);
    const first: Response = await send.change(id("evt_1"), "customer.subscription.created", now - 10, active);
    expect(await first.json()).toEqual({ received: true, duplicate: false });
    expect((await plan(harness, session)).plan).toBe("subscription");

    const before: number = stripe.subscriptionLists.length;
    const again: Response = await send.replay(id("evt_1"), "customer.subscription.created", now - 10, active);
    expect(await again.json()).toEqual({ received: true, duplicate: true });
    // İşlenmiş olay Stripe'a sorulmaz.
    expect(stripe.subscriptionLists.length).toBe(before);

    expect((await send.change(id("evt_2"), "customer.subscription.deleted", now, { ...active, status: "canceled" })).status).toBe(200);
    expect(await plan(harness, session)).toMatchObject({ plan: "trial", subscription: { status: "canceled" } });

    // Gecikmeli gelen eski "active" olayı iptali geri almaz: Stripe'ın güncel durumu iptaldir.
    expect((await send.replay(id("evt_3"), "customer.subscription.updated", now - 5, active)).status).toBe(200);
    expect((await plan(harness, session)).plan).toBe("trial");

    const count = await env.DB.prepare("SELECT COUNT(*) AS count FROM stripe_events WHERE id IN (?, ?, ?)").bind(id("evt_1"), id("evt_2"), id("evt_3")).first<{ count: number }>();
    expect(count?.count).toBe(3);
  });

  it("aynı saniyedeki olaylar ters sırayla gelse de son durum yazılır", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const { session, customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    const periodEnd: number = now + 30 * 86_400;
    const incomplete: FakeSubscription = fakeSubscription(id("sub"), customer, "incomplete", now - 1, periodEnd);
    // Stripe aynı saniyede incomplete → active geçti; "active" olayı önce, "incomplete" olayı sonra geldi.
    stripe.subscriptions.set(incomplete.id, { ...incomplete, status: "active" });
    expect((await send.replay(id("evt_b"), "customer.subscription.updated", now, { ...incomplete, status: "active" })).status).toBe(200);
    expect((await send.replay(id("evt_a"), "customer.subscription.created", now, incomplete)).status).toBe(200);
    expect(await storedSubscription(session.userId)).toEqual({ stripe_subscription_id: id("sub"), status: "active" });
    expect((await plan(harness, session)).plan).toBe("subscription");
  });

  it("iptal edilen abonelik dönem sonuna dek sürer ve biteceği an bildirilir; iptalden vazgeçilince silinir", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const { session, customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    const periodEnd: number = now + 30 * 86_400;
    const active: FakeSubscription = fakeSubscription(id("sub"), customer, "active", now - 10, periodEnd);
    await send.change(id("evt_c1"), "customer.subscription.created", now - 10, active);
    expect((await plan(harness, session)).subscription?.cancelAt).toBeNull();

    await send.change(id("evt_c2"), "customer.subscription.updated", now - 5, { ...active, cancel_at: periodEnd });
    expect(await plan(harness, session)).toMatchObject({ plan: "subscription", subscription: { cancelAt: new Date(periodEnd * 1000).toISOString() } });

    await send.change(id("evt_c3"), "customer.subscription.updated", now - 3, active);
    expect((await plan(harness, session)).subscription?.cancelAt).toBeNull();

    await send.change(id("evt_c4"), "customer.subscription.updated", now - 1, { ...active, cancel_at_period_end: true });
    expect((await plan(harness, session)).subscription?.cancelAt).toBe(new Date(periodEnd * 1000).toISOString());
  });

  it("iptal nedeni (cancellation_details) hesaba bağlı saklanır; iptalden vazgeçilince silinir, eski olay yeniyi ezmez, hesap silinince gider", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const { session, customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    const periodEnd: number = now + 30 * 86_400;
    const active: FakeSubscription = fakeSubscription(id("sub"), customer, "active", now - 20, periodEnd);
    const stored = async (): Promise<{ user_id: string; reason: string | null; feedback: string | null; comment: string | null } | null> =>
      env.DB.prepare("SELECT user_id, reason, feedback, comment FROM subscription_cancellations WHERE stripe_subscription_id = ?")
        .bind(active.id)
        .first<{ user_id: string; reason: string | null; feedback: string | null; comment: string | null }>();
    const details = (feedback: string, comment: string): object => ({ cancellation_details: { reason: "cancellation_requested", feedback, comment, feedback_option: null } });
    await send.change(id("evt_n1"), "customer.subscription.created", now - 20, active);
    // Nedeni olmayan yenilenen abonelik yazılmaz.
    expect(await stored()).toBeNull();

    const longComment: string = `  ${"ç".repeat(1200)}  `;
    await send.change(id("evt_n2"), "customer.subscription.updated", now - 10, { ...active, cancel_at_period_end: true, ...details("too_expensive", longComment) });
    const first = await stored();
    expect(first).toMatchObject({ user_id: session.userId, reason: "cancellation_requested", feedback: "too_expensive" });
    expect(first?.comment).toHaveLength(1000);

    // Geç gelen eski olay (iptalden önceki durum) satırı silmez.
    await send.replay(id("evt_n0"), "customer.subscription.updated", now - 15, active);
    expect(await stored()).not.toBeNull();

    // İptalden vazgeçilince satır silinir; yeniden iptal yeni nedenle yazılır.
    await send.change(id("evt_n3"), "customer.subscription.updated", now - 8, active);
    expect(await stored()).toBeNull();
    await send.change(id("evt_n4"), "customer.subscription.deleted", now - 5, { ...active, status: "canceled", ...details("missing_features", "Takvim yok") });
    expect(await stored()).toMatchObject({ feedback: "missing_features", comment: "Takvim yok" });

    expect((await harness.call(req("DELETE", "/v1/me", { token: session.accessToken }))).status).toBe(204);
    expect(await stored()).toBeNull();
  });

  it("past_due ek süresi dönem sonundan değil past_due'ya geçişten sayılır; past_due sürdükçe başlangıç korunur", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const { session, customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    // Yenileme başarısız: Stripe dönem sonunu bir ay ilerletti, durum past_due.
    const pastDue: FakeSubscription = fakeSubscription(id("sub"), customer, "past_due", now - 100, now + 30 * 86_400);
    const failedAt: number = harness.clock.nowMs;
    await send.change(id("evt_p1"), "customer.subscription.updated", now, pastDue);
    expect((await plan(harness, session)).subscription).toMatchObject({ access: "grace", graceEndsAt: new Date(failedAt + 7 * dayMs).toISOString() });

    harness.clock.nowMs += 3 * dayMs;
    const later: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } }))).json<Session>();
    await send.change(id("evt_p2"), "customer.subscription.updated", now + 3 * 86_400, pastDue);
    expect((await plan(harness, later)).subscription?.graceEndsAt).toBe(new Date(failedAt + 7 * dayMs).toISOString());

    harness.clock.nowMs = failedAt + 7 * dayMs + 1;
    const expired: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: later.refreshToken } }))).json<Session>();
    expect(await plan(harness, expired)).toMatchObject({ plan: "trial", subscription: { status: "past_due", access: "none", graceEndsAt: null } });

    // Ödeme alındı: past_due_since silinir.
    await send.change(id("evt_p3"), "customer.subscription.updated", now + 8 * 86_400, { ...pastDue, status: "active" });
    const row = await env.DB.prepare("SELECT past_due_since FROM subscriptions WHERE user_id = ?").bind(session.userId).first<{ past_due_since: number | null }>();
    expect(row?.past_due_since).toBeNull();
    expect((await plan(harness, expired)).plan).toBe("subscription");
  });

  it("tanınmayan müşterinin yaşayan aboneliği Stripe'ta iptal edilir ve alarm yazılır; bitmişi yalnızca kaydedilir", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const other: string = eventOf(id("evt_other"), "invoice.paid", 1, { id: "in_1", object: "invoice" });
    expect(await (await postWebhook(harness, other, env.STRIPE_WEBHOOK_SECRET)).json()).toEqual({ received: true, duplicate: false });

    const alerts = vi.spyOn(console, "error");
    const orphanActive: FakeSubscription = fakeSubscription(id("sub_orphan"), "cus_bilinmeyen", "active", 1, 2);
    expect((await send.change(id("evt_unknown"), "customer.subscription.created", 1, orphanActive)).status).toBe(200);
    expect(stripe.canceled).toEqual([id("sub_orphan")]);
    expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"stripe_unknown_customer_subscription_canceled"'))).toBe(true);
    alerts.mockRestore();
    const recorded = await env.DB.prepare("SELECT COUNT(*) AS count FROM stripe_events WHERE id = ?").bind(id("evt_unknown")).first<{ count: number }>();
    expect(recorded?.count).toBe(1);

    // Bilinmeyen müşterinin (ör. silinmiş hesap) iptali hak vermez: kaydedilir, Stripe'ta bir şey iptal edilmez.
    const orphanCanceled: FakeSubscription = fakeSubscription(id("sub_silinmis"), "cus_silinmis", "canceled", 1, 2);
    expect(await (await send.change(id("evt_orphan"), "customer.subscription.deleted", 1, orphanCanceled)).json()).toEqual({ received: true, duplicate: false });
    expect(stripe.canceled).toEqual([id("sub_orphan")]);
    const orphanRows = await env.DB.prepare("SELECT COUNT(*) AS count FROM subscriptions WHERE stripe_customer_id IN ('cus_bilinmeyen', 'cus_silinmis')").first<{ count: number }>();
    expect(orphanRows?.count).toBe(0);
  });

  it("başka ürünün aboneliğine dokunulmaz: tanınmayan müşteride iptal, tanınan müşteride kopya iadesi ve itirazda iptal yok", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();

    // Tanınmayan müşterinin başka fiyatlı, metadata'sız aboneliği: yalnızca loglanır (200), iptal edilmez.
    const foreign: FakeSubscription = fakeSubscriptionWithPrice(id("sub_foreign"), id("cus_other"), "active", 1, 2, "price_baska_urun");
    expect(await (await send.change(id("evt_foreign"), "customer.subscription.created", 1, foreign)).json()).toEqual({ received: true, duplicate: false });
    expect(stripe.canceled).toEqual([]);
    // `metadata.user_id` taşıyan abonelik (fiyatı değişmiş olsa da) bizimdir: tanınmayan müşteride iptal edilir.
    const ownOldPrice: FakeSubscription = { ...fakeSubscriptionWithPrice(id("sub_old_price"), id("cus_gone"), "active", 1, 2, "price_eski"), metadata: { user_id: "silinmis" } };
    expect((await send.change(id("evt_old_price"), "customer.subscription.created", 1, ownOldPrice)).status).toBe(200);
    expect(stripe.canceled).toEqual([id("sub_old_price")]);

    // Tanınan müşterinin başka ürün aboneliği kopya sayılmaz; itirazda yalnızca bizim aboneliğimiz iptal edilir.
    const { session, customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    stripe.subscriptions.set(id("sub_side"), fakeSubscriptionWithPrice(id("sub_side"), customer, "active", now - 500, now + 30 * 86_400, "price_baska_urun"));
    await send.change(id("evt_1"), "customer.subscription.created", now, fakeSubscription(id("sub"), customer, "active", now, now + 30 * 86_400));
    expect(stripe.canceled).toEqual([id("sub_old_price")]);
    expect(stripe.refundForms).toHaveLength(0);
    expect(await storedSubscription(session.userId)).toEqual({ stripe_subscription_id: id("sub"), status: "active" });
    stripe.charges.set(id("ch"), customer);
    const dispute: string = eventOf(id("evt_dis"), "charge.dispute.created", now + 1, {
      id: id("dp"),
      object: "dispute",
      charge: id("ch"),
      amount: 599,
      currency: "usd",
      reason: "fraudulent",
    });
    expect((await postWebhook(harness, dispute, env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    expect(stripe.canceled).toEqual([id("sub_old_price"), id("sub")]);
  });

  it("customer.deleted müşteri eşlemesini ve abonelik satırını siler", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const { session, customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    await send.change(id("evt_1"), "customer.subscription.created", now, fakeSubscription(id("sub"), customer, "active", now, now + 30 * 86_400));
    expect((await plan(harness, session)).plan).toBe("subscription");
    const deleted: string = eventOf(id("evt_del"), "customer.deleted", now + 1, { id: customer, object: "customer", deleted: true });
    expect((await postWebhook(harness, deleted, env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    expect(await plan(harness, session)).toMatchObject({ plan: "trial", subscription: null });
    const mapping = await env.DB.prepare("SELECT COUNT(*) AS count FROM stripe_customers WHERE user_id = ?").bind(session.userId).first<{ count: number }>();
    expect(mapping?.count).toBe(0);
  });

  it("tam iade yalnızca ödemenin aboneliğini ve yalnızca son faturası iade edilince bitirir; eski ay, başka ürün, kısmi ve eşleşmeyen iade yalnızca alarm", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const { session, customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    // Ocakta eski abonelik (iptal edilmiş), martta yeni abonelik.
    stripe.subscriptions.set(id("sub_old"), fakeSubscription(id("sub_old"), customer, "canceled", now - 90 * 86_400, now - 60 * 86_400));
    await send.change(id("evt_1"), "customer.subscription.created", now, { ...fakeSubscription(id("sub_new"), customer, "active", now, now + 30 * 86_400), latest_invoice: id("in_new") });
    stripe.invoices.set(id("in_old"), { subscription: id("sub_old"), paid: true, created: now - 90 * 86_400 });
    stripe.invoicePayments.set(id("in_old"), [id("pi_old")]);
    // Aynı aboneliğin geçen ayı (son fatura değil): iadesi ödenmiş güncel ayı kesmez.
    stripe.invoices.set(id("in_prev"), { subscription: id("sub_new"), paid: true, created: now - 30 * 86_400 });
    stripe.invoicePayments.set(id("in_prev"), [id("pi_prev")]);
    stripe.invoices.set(id("in_new"), { subscription: id("sub_new"), paid: true, created: now });
    stripe.invoicePayments.set(id("in_new"), [id("pi_new")]);
    // Aynı Stripe hesabındaki başka ürünün aboneliği: son faturasının iadesi de ona dokunmaz.
    stripe.subscriptions.set(id("sub_side"), { ...fakeSubscriptionWithPrice(id("sub_side"), customer, "active", now - 500, now + 30 * 86_400, "price_baska_urun"), latest_invoice: id("in_side") });
    stripe.invoices.set(id("in_side"), { subscription: id("sub_side"), paid: true, created: now - 500 });
    stripe.invoicePayments.set(id("in_side"), [id("pi_side")]);
    const refundEvent = (eventId: string, chargeId: string, intent: string | null, refunded: boolean, created: number): string =>
      eventOf(eventId, "charge.refunded", created, {
        id: chargeId,
        object: "charge",
        customer,
        payment_intent: intent,
        amount_refunded: refunded ? 599 : 100,
        currency: "usd",
        refunded,
      });

    // Kısmi iade, eski aboneliğin tam iadesi ve aboneliği bulunamayan ödeme yeni aboneliğe dokunmaz.
    for (const [eventId, chargeId, intent, refunded] of [
      [id("evt_part"), id("ch_part"), id("pi_new"), false],
      [id("evt_old"), id("ch_old"), id("pi_old"), true],
      [id("evt_prev"), id("ch_prev"), id("pi_prev"), true],
      [id("evt_side"), id("ch_side"), id("pi_side"), true],
      [id("evt_free"), id("ch_free"), null, true],
    ] as const) {
      expect((await postWebhook(harness, refundEvent(eventId, chargeId, intent, refunded, now + 1), env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    }
    expect(stripe.canceled).toEqual([]);
    expect((await plan(harness, session)).plan).toBe("subscription");

    // Yeni aboneliğin ödemesinin tam iadesi onu hemen bitirir.
    expect((await postWebhook(harness, refundEvent(id("evt_full"), id("ch_new"), id("pi_new"), true, now + 2), env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    expect(stripe.canceled).toEqual([id("sub_new")]);
    expect(await storedSubscription(session.userId)).toEqual({ stripe_subscription_id: id("sub_new"), status: "canceled" });
    expect((await plan(harness, session)).plan).toBe("trial");
    // Geç gelen eski etkin olay iptali ezmez.
    await send.replay(id("evt_old_update"), "customer.subscription.updated", now + 1, fakeSubscription(id("sub_new"), customer, "active", now, now + 30 * 86_400));
    expect((await plan(harness, session)).plan).toBe("trial");
  });

  it("customer.deleted sonrası Checkout yeni Stripe müşterisi açar (eski idempotency anahtarı silinmiş müşteriyi döndürmez)", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const id = uniqueIds();
    const { session, customer } = await customerSession(harness);
    const deleted: string = eventOf(id("evt_del"), "customer.deleted", Math.floor(harness.clock.nowMs / 1000), { id: customer, object: "customer", deleted: true });
    expect((await postWebhook(harness, deleted, env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    expect((await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken }))).status).toBe(200);
    const fresh: string = await customerOf(session.userId);
    expect(fresh).not.toBe(customer);
    expect(stripe.customers).toBe(2);
    expect(stripe.checkoutForms.at(-1)?.get("customer")).toBe(fresh);
  });

  it("charge.refunded alarm yazar; charge.dispute.created müşterinin aboneliğini hemen iptal eder ve alarm yazar", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const { session, customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    await send.change(id("evt_1"), "customer.subscription.created", now, fakeSubscription(id("sub"), customer, "active", now, now + 30 * 86_400));
    const alerts = vi.spyOn(console, "error");
    const refunded: string = eventOf(id("evt_ref"), "charge.refunded", now + 1, {
      id: id("ch"),
      object: "charge",
      customer,
      payment_intent: null,
      amount_refunded: 100,
      currency: "usd",
      refunded: false,
    });
    expect((await postWebhook(harness, refunded, env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    expect(stripe.canceled).toEqual([]);

    stripe.charges.set(id("ch"), customer);
    const dispute: string = eventOf(id("evt_dis"), "charge.dispute.created", now + 2, {
      id: id("dp"),
      object: "dispute",
      charge: id("ch"),
      amount: 599,
      currency: "usd",
      reason: "fraudulent",
    });
    expect((await postWebhook(harness, dispute, env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    expect(stripe.canceled).toEqual([id("sub")]);
    const lines: string[] = alerts.mock.calls.map((call: unknown[]): string => String(call[0]));
    alerts.mockRestore();
    expect(lines.some((line: string): boolean => line.includes('"event":"stripe_charge_refunded"') && line.includes(session.userId))).toBe(true);
    expect(lines.some((line: string): boolean => line.includes('"event":"stripe_dispute_created"') && line.includes('"canceledSubscriptions":1'))).toBe(true);
    // İptal olayı gelince abonelik satırı güncellenir.
    await send.change(id("evt_2"), "customer.subscription.deleted", now + 3, { ...fakeSubscription(id("sub"), customer, "canceled", now, now + 30 * 86_400) });
    expect((await plan(harness, session)).plan).toBe("trial");
  });

  it("abonelik yaşam döngüsü Stripe'ın olay sırasıyla: her olaydan sonra haklar ve toplantı türü doğrudur", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const { session, customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    const periodEnd: number = now + 30 * 86_400;
    const startKind = async (clientRef: string): Promise<string> =>
      (await (await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: { clientRef } }))).json<{ kind: string }>()).kind;
    const invoiceEvent = (eventId: string, type: string, created: number): string =>
      eventOf(eventId, type, created, {
        id: id("in_1"),
        object: "invoice",
        customer,
        status: type === "invoice.paid" ? "paid" : "open",
        parent: { type: "subscription_details", subscription_details: { subscription: id("sub"), metadata: null } },
      });
    const before: number = stripe.operations.length;

    // Checkout bitti ama ödeme henüz alınmadı: abonelik `incomplete`, erişim yok.
    const incomplete: FakeSubscription = fakeSubscription(id("sub"), customer, "incomplete", now, periodEnd);
    await send.change(id("evt_l1"), "customer.subscription.created", now, incomplete);
    expect(await plan(harness, session)).toMatchObject({ plan: "trial", subscription: { status: "incomplete", access: "none" } });
    // checkout.session.completed ve invoice.paid yalnızca kaydedilir (kopya olmayan faturada iade yok).
    const completed: string = eventOf(id("evt_l2"), "checkout.session.completed", now + 1, {
      id: id("cs"),
      object: "checkout.session",
      customer,
      mode: "subscription",
      subscription: id("sub"),
      client_reference_id: session.userId,
    });
    expect(await (await postWebhook(harness, completed, env.STRIPE_WEBHOOK_SECRET)).json()).toEqual({ received: true, duplicate: false });
    expect((await postWebhook(harness, invoiceEvent(id("evt_l3"), "invoice.paid", now + 2), env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    expect(stripe.operations.length).toBe(before);

    // Ödeme alındı: active → abonelik toplantısı.
    const active: FakeSubscription = { ...incomplete, status: "active" };
    await send.change(id("evt_l4"), "customer.subscription.updated", now + 3, active);
    expect(await plan(harness, session)).toMatchObject({ plan: "subscription", subscription: { status: "active", access: "active", cancelAt: null } });
    expect(await startKind("yasam-1")).toBe("subscription");

    // Yenileme ödemesi başarısız: invoice.payment_failed tek başına durumu değiştirmez; past_due gelince ek süre başlar.
    expect((await postWebhook(harness, invoiceEvent(id("evt_l5"), "invoice.payment_failed", now + 4), env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    expect((await plan(harness, session)).subscription?.access).toBe("active");
    await send.change(id("evt_l6"), "customer.subscription.updated", now + 5, { ...active, status: "past_due" });
    expect(await plan(harness, session)).toMatchObject({ plan: "subscription", subscription: { status: "past_due", access: "grace" } });
    expect(await startKind("yasam-2")).toBe("subscription");

    // Ödeme sonradan alındı, sonra kullanıcı Portal'dan iptal etti: dönem sonuna dek sürer.
    await send.change(id("evt_l7"), "customer.subscription.updated", now + 6, active);
    expect((await plan(harness, session)).subscription).toMatchObject({ access: "active", graceEndsAt: null });
    await send.change(id("evt_l8"), "customer.subscription.updated", now + 7, { ...active, cancel_at_period_end: true });
    expect(await plan(harness, session)).toMatchObject({ plan: "subscription", subscription: { cancelAt: new Date(periodEnd * 1000).toISOString() } });

    // Abonelik bitti: deneme planına döner, yeni Checkout açılabilir; Stripe'ta hiçbir şey iptal ya da iade edilmedi.
    await send.change(id("evt_l9"), "customer.subscription.deleted", now + 8, { ...active, status: "canceled", cancel_at_period_end: true });
    expect(await plan(harness, session)).toMatchObject({ plan: "trial", subscription: { status: "canceled", access: "none" } });
    expect(await startKind("yasam-3")).toBe("trial");
    expect((await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken }))).status).toBe(200);
    expect(stripe.canceled).toEqual([]);
    expect(stripe.refundForms).toEqual([]);
  });
});

describe("Stripe webhook: aynı kullanıcının birden çok aboneliği", () => {
  it("ek süresi geçmiş past_due aboneliğin yerini yeni, ödenmiş abonelik alır; eskisi Stripe'ta iptal edilir", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const { session, customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);

    // A: ödemesi gecikmiş, ek süresi (7 gün) dolmuş.
    const subA: FakeSubscription = fakeSubscription(id("sub_A"), customer, "active", now - 400, now - 10 * 86_400);
    harness.clock.nowMs -= 10 * dayMs;
    await send.change(id("evt_a1"), "customer.subscription.created", now - 400, subA);
    await send.change(id("evt_a2"), "customer.subscription.updated", now - 300, { ...subA, status: "past_due" });
    harness.clock.nowMs += 10 * dayMs;
    const fresh: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } }))).json<Session>();
    expect((await plan(harness, fresh)).plan).toBe("trial");
    // Yeni Checkout reddedilir (Portal'dan ödenmeli).
    await expectError(await harness.call(req("POST", "/v1/billing/checkout", { token: fresh.accessToken })), 409, "subscription_exists");

    // B yine de oluştu (ör. düzeltmeden önce açılmış ikinci bir Checkout sekmesi) ve ödendi: A'nın yerini alır, A iptal edilir.
    const alerts = vi.spyOn(console, "error");
    await send.change(id("evt_b1"), "customer.subscription.created", now - 200, fakeSubscription(id("sub_B"), customer, "active", now - 200, now + 30 * 86_400));
    expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"stripe_duplicate_subscription_canceled"'))).toBe(true);
    alerts.mockRestore();
    expect(stripe.canceled).toEqual([id("sub_A")]);
    expect(await storedSubscription(session.userId)).toEqual({ stripe_subscription_id: id("sub_B"), status: "active" });

    // A'nın iptal olayı B'yi ezmez.
    await send.replay(id("evt_a3"), "customer.subscription.deleted", now - 100, { ...subA, status: "canceled" });
    expect(await storedSubscription(session.userId)).toEqual({ stripe_subscription_id: id("sub_B"), status: "active" });
    expect(await plan(harness, fresh)).toMatchObject({ plan: "subscription", subscription: { status: "active" } });
  });

  it("iptal edilmiş aboneliğin yerini yeni abonelik alır (incomplete → active)", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const { session, customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    const periodEnd: number = now + 30 * 86_400;
    const subA: FakeSubscription = fakeSubscription(id("sub_A"), customer, "active", now - 400, periodEnd);
    await send.change(id("evt_1"), "customer.subscription.created", now - 400, subA);
    await send.change(id("evt_2"), "customer.subscription.deleted", now - 300, { ...subA, status: "canceled" });
    // Bitmiş abonelikte yeni Checkout açılır.
    expect((await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken }))).status).toBe(200);
    const subB: FakeSubscription = fakeSubscription(id("sub_B"), customer, "incomplete", now - 200, periodEnd);
    await send.change(id("evt_3"), "customer.subscription.created", now - 200, subB);
    expect(await storedSubscription(session.userId)).toEqual({ stripe_subscription_id: id("sub_B"), status: "incomplete" });
    await send.change(id("evt_4"), "customer.subscription.updated", now - 100, { ...subB, status: "active" });
    expect(await storedSubscription(session.userId)).toEqual({ stripe_subscription_id: id("sub_B"), status: "active" });
    expect((await plan(harness, session)).plan).toBe("subscription");
    expect(stripe.canceled).toEqual([]);
  });

  it("aynı müşteride yaşayan ikinci abonelik önce iade, sonra iptal edilir; iade hatasında yeniden denenir; geç ödemesi de iade edilir", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const { session, customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    const periodEnd: number = now + 30 * 86_400;
    await send.change(id("evt_1"), "customer.subscription.created", now - 400, fakeSubscription(id("sub_A"), customer, "active", now - 400, periodEnd));
    stripe.invoices.set(id("in_B"), { subscription: id("sub_B"), paid: true, created: now - 300 });
    stripe.invoicePayments.set(id("in_B"), [id("pi_B")]);
    const duplicate: FakeSubscription = fakeSubscription(id("sub_B"), customer, "active", now - 300, periodEnd);

    // İade geçici olarak başarısız: abonelik iptal edilmez, olay 502 ile reddedilir (Stripe yeniden gönderir).
    stripe.failRefunds = true;
    expect((await send.change(id("evt_2"), "customer.subscription.created", now - 300, duplicate)).status).toBe(502);
    expect(stripe.canceled).toEqual([]);
    const marked = await env.DB.prepare("SELECT user_id FROM duplicate_subscriptions WHERE stripe_subscription_id = ?").bind(id("sub_B")).first<{ user_id: string }>();
    expect(marked?.user_id).toBe(session.userId);

    // Yeniden gönderim: önce iade, sonra iptal.
    stripe.failRefunds = false;
    expect((await send.replay(id("evt_2"), "customer.subscription.created", now - 300, duplicate)).status).toBe(200);
    expect(stripe.operations).toEqual([`refund:${id("pi_B")}`, `cancel:${id("sub_B")}`]);
    expect(stripe.refundForms[0]?.get("reason")).toBe("duplicate");
    expect(stripe.refundForms[0]?.get("metadata[purpose]")).toBe("duplicate_subscription");
    expect(stripe.refundKeys).toEqual([`refund-duplicate-${id("sub_B")}-${id("pi_B")}`]);
    expect(await storedSubscription(session.userId)).toEqual({ stripe_subscription_id: id("sub_A"), status: "active" });

    // İptalden sonra geç ödenen kopya faturası `invoice.paid` ile iade edilir; diğer faturalar dokunulmaz.
    stripe.invoices.set(id("in_B2"), { subscription: id("sub_B"), paid: true, created: now - 100 });
    stripe.invoicePayments.set(id("in_B2"), [id("pi_B2")]);
    const latePaid = (eventId: string, invoice: string, subscription: string): string =>
      eventOf(eventId, "invoice.paid", now - 100, {
        id: invoice,
        object: "invoice",
        customer,
        status: "paid",
        created: now - 100,
        parent: { type: "subscription_details", subscription_details: { subscription, metadata: null } },
      });
    expect((await postWebhook(harness, latePaid(id("evt_late"), id("in_B2"), id("sub_B")), env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    expect(stripe.operations.at(-1)).toBe(`refund:${id("pi_B2")}`);
    stripe.invoices.set(id("in_A2"), { subscription: id("sub_A"), paid: true, created: now - 100 });
    stripe.invoicePayments.set(id("in_A2"), [id("pi_A2")]);
    expect((await postWebhook(harness, latePaid(id("evt_keep"), id("in_A2"), id("sub_A")), env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    expect(stripe.operations.at(-1)).toBe(`refund:${id("pi_B2")}`);

    // Kopyanın tam iadesi geçerli aboneliği bitirmez.
    const duplicateRefund: string = eventOf(id("evt_ref"), "charge.refunded", now - 50, {
      id: id("ch_B"),
      object: "charge",
      customer,
      payment_intent: id("pi_B"),
      amount_refunded: 599,
      currency: "usd",
      refunded: true,
    });
    expect((await postWebhook(harness, duplicateRefund, env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    expect(stripe.canceled).toEqual([id("sub_B")]);
    expect((await plan(harness, session)).plan).toBe("subscription");
  });
});

describe("Stripe webhook: kopya iadesinin sınırları", () => {
  it("iade yapıldı ama iptal başarısız: 24 saat sonra yeniden gönderilen olay zaten iade edilmiş ödemeyi atlar, iptali tamamlar", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const { customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    const periodEnd: number = now + 30 * 86_400;
    await send.change(id("evt_1"), "customer.subscription.created", now - 400, fakeSubscription(id("sub_A"), customer, "active", now - 400, periodEnd));
    stripe.invoices.set(id("in_B"), { subscription: id("sub_B"), paid: true, created: now - 300 });
    stripe.invoicePayments.set(id("in_B"), [id("pi_B")]);
    const duplicate: FakeSubscription = fakeSubscription(id("sub_B"), customer, "active", now - 300, periodEnd);

    stripe.failCancels = true;
    expect((await send.change(id("evt_2"), "customer.subscription.created", now - 300, duplicate)).status).toBe(502);
    expect(stripe.operations).toEqual([`refund:${id("pi_B")}`]);

    // Stripe idempotency anahtarını 24 saat saklar; sonra aynı ödemenin iadesi `charge_already_refunded` ile reddedilir.
    stripe.failCancels = false;
    harness.clock.nowMs += 25 * 3_600_000;
    expect((await send.replay(id("evt_2"), "customer.subscription.created", now - 300, duplicate)).status).toBe(200);
    expect(stripe.operations).toEqual([`refund:${id("pi_B")}`, `cancel:${id("sub_B")}`]);
  });

  it("kopya daha eski abonelikse yalnızca yenisinden sonra kesilen faturası iade edilir; eski meşru ayları ve geç ödenen eski faturası iade edilmez", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const send: Sender = sender(harness, stripe);
    const id = uniqueIds();
    const { customer } = await customerSession(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    // A: aylardır ödenen abonelik; son ödemesi başarısız (past_due).
    const subA: FakeSubscription = fakeSubscription(id("sub_A"), customer, "past_due", now - 90 * 86_400, now + 86_400);
    await send.change(id("evt_a"), "customer.subscription.updated", now - 1_000, subA);
    for (const [invoice, intent, created] of [
      [id("in_A1"), id("pi_A1"), now - 90 * 86_400],
      [id("in_A2"), id("pi_A2"), now - 60 * 86_400],
      [id("in_A3"), id("pi_A3"), now - 30 * 86_400],
      // B açıldıktan sonra A'nın yeniden denenen ödemesi de alındı: aynı dönem iki kez ücretlendi.
      [id("in_A4"), id("pi_A4"), now - 100],
    ] as const) {
      stripe.invoices.set(invoice, { subscription: id("sub_A"), paid: true, created });
      stripe.invoicePayments.set(invoice, [intent]);
    }

    // B: yeni, ödenmiş abonelik A'nın yerini alır; A kopyadır.
    await send.change(id("evt_b"), "customer.subscription.created", now - 200, fakeSubscription(id("sub_B"), customer, "active", now - 200, now + 30 * 86_400));
    expect(stripe.operations).toEqual([`refund:${id("pi_A4")}`, `cancel:${id("sub_A")}`]);

    // A'nın B'den önceki döneme ait faturası iptalden sonra geç ödenirse iade edilmez.
    stripe.invoices.set(id("in_A5"), { subscription: id("sub_A"), paid: true, created: now - 20 * 86_400 });
    stripe.invoicePayments.set(id("in_A5"), [id("pi_A5")]);
    const latePaid: string = eventOf(id("evt_late"), "invoice.paid", now - 50, {
      id: id("in_A5"),
      object: "invoice",
      customer,
      status: "paid",
      created: now - 20 * 86_400,
      parent: { type: "subscription_details", subscription_details: { subscription: id("sub_A"), metadata: null } },
    });
    expect((await postWebhook(harness, latePaid, env.STRIPE_WEBHOOK_SECRET)).status).toBe(200);
    expect(stripe.operations).toEqual([`refund:${id("pi_A4")}`, `cancel:${id("sub_A")}`]);
  });
});

describe("Checkout bitmemiş abonelikte reddedilir", () => {
  it.each([
    ["active", 10 * dayMs],
    ["trialing", 10 * dayMs],
    ["past_due", -2 * dayMs],
    ["past_due", -30 * dayMs],
    ["unpaid", 10 * dayMs],
    ["incomplete", 10 * dayMs],
    ["paused", 10 * dayMs],
  ])("%s (dönem sonu şimdiden %d ms) → 409 subscription_exists, Stripe çağrılmaz", async (status: string, periodOffsetMs: number) => {
    const harness: Harness = await defaultHarness();
    stubStripeApi(harness);
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, status, harness.clock.nowMs + periodOffsetMs);
    const body = await expectError(await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken })), 409, "subscription_exists");
    expect(body.error.message).toContain("Portal");
    expect(harness.outbound.filter((request: Request): boolean => request.url.startsWith("https://api.stripe.com/"))).toHaveLength(0);
  });

  it.each([
    ["canceled", 10 * dayMs],
    ["incomplete_expired", 10 * dayMs],
    ["unpaid", -dayMs],
  ])("bitmiş %s aboneliğinde (dönem sonu şimdiden %d ms) yeni Checkout açılır", async (status: string, periodOffsetMs: number) => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, status, harness.clock.nowMs + periodOffsetMs);
    expect((await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken }))).status).toBe(200);
    expect(stripe.checkoutForms).toHaveLength(1);
  });
});
