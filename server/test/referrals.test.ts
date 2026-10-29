import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { monthlyRecurringRevenueUsd } from "../src/admin";
import { type Config, parseConfig } from "../src/config";
import type { Env } from "../src/env";
import { randomId, randomToken } from "../src/crypto";
import { ReferralRewardFailedError, type ReferralRewardReport, grantDueReferralRewards } from "../src/referralRewards";
import { normalizeReferralCode, referralCodeAlphabet, referralCodeFromBytes } from "../src/referrals";
import { type Harness, type Session, defaultHarness, envWith, expectError, grantSubscription, refreshed, req, signIn, signInWithGoogle } from "./helpers";
import { eventOf, invoicePaidEvent, postEvent, sendSubscription } from "./stripeEvents";
import { type FakeStripe, type FakeSubscription, fakeSubscription, fakeYearlySubscription, stubStripeApi } from "./stripeFake";

const siteOrigin: string = "http://localhost:8788";
const daySeconds: number = 86_400;
const dayMs: number = 86_400_000;

/** Teste özgü Stripe kimlikleri (dosyanın D1'i testler arasında paylaşılır). */
function uniqueIds(): (name: string) => string {
  const tag: string = randomToken(6);
  return (name: string): string => `${name}_${tag}`;
}

async function customerOf(userId: string): Promise<string> {
  const row = await env.DB.prepare("SELECT stripe_customer_id FROM stripe_customers WHERE user_id = ?").bind(userId).first<{ stripe_customer_id: string }>();
  if (row === null) {
    throw new Error("müşteri yok");
  }
  return row.stripe_customer_id;
}

/** `GET /v1/referral` yanıtı. */
interface ReferralBody {
  readonly enabled: boolean;
  readonly code: string | null;
  readonly inviteUrl: string | null;
  readonly joined: number;
  readonly rewarded: number;
  readonly pending: number;
  readonly rewardsLeftThisYear: number;
  readonly rewardsPerYear: number;
  readonly rewardUsd: number;
  readonly holdDays: number;
}

async function referral(harness: Harness, session: Session): Promise<ReferralBody> {
  const response: Response = await harness.call(req("GET", "/v1/referral", { token: session.accessToken }));
  expect(response.status).toBe(200);
  return response.json<ReferralBody>();
}

async function checkout(harness: Harness, session: Session, json: object): Promise<Response> {
  return harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken, json }));
}

async function validate(harness: Harness, session: Session, code: string): Promise<Response> {
  return harness.call(req("POST", "/v1/referral/validate", { token: session.accessToken, json: { code } }));
}

/** Abone: Checkout ile müşteri, etkin (aylık) abonelik olayı; dönem sonu 90 gün sonra. */
async function subscriber(harness: Harness, stripe: FakeStripe, id: (name: string) => string, name: string): Promise<{ session: Session; customer: string }> {
  const session: Session = await signIn(harness);
  expect((await checkout(harness, session, { plan: "monthly" })).status).toBe(200);
  const customer: string = await customerOf(session.userId);
  const now: number = Math.floor(harness.clock.nowMs / 1000);
  const subscription: FakeSubscription = { ...fakeSubscription(id(`sub_${name}`), customer, "active", now, now + 90 * daySeconds), metadata: { user_id: session.userId } };
  expect((await sendSubscription(harness, stripe, id(`evt_${name}`), "customer.subscription.created", now, subscription)).status).toBe(200);
  return { session, customer };
}

/** Davetle abone olan arkadaş: kodlu Checkout, kodu taşıyan abonelik olayı. */
async function referredFriend(
  harness: Harness,
  stripe: FakeStripe,
  id: (name: string) => string,
  name: string,
  session: Session,
  code: string,
  yearly: boolean,
): Promise<{ customer: string; subscriptionId: string }> {
  expect((await checkout(harness, session, { plan: yearly ? "yearly" : "monthly", referralCode: code })).status).toBe(200);
  const customer: string = await customerOf(session.userId);
  const now: number = Math.floor(harness.clock.nowMs / 1000);
  const base: FakeSubscription = yearly
    ? fakeYearlySubscription(id(`sub_${name}`), customer, "active", now, now + 365 * daySeconds)
    : fakeSubscription(id(`sub_${name}`), customer, "active", now, now + 30 * daySeconds);
  const subscription: FakeSubscription = { ...base, metadata: { user_id: session.userId, referral_code: code } };
  expect((await sendSubscription(harness, stripe, id(`evt_${name}`), "customer.subscription.created", now, subscription)).status).toBe(200);
  return { customer, subscriptionId: subscription.id };
}

/** Faturayı sahte Stripe'a (ödeme niyetiyle) yazar ve `invoice.paid` gönderir. */
async function payInvoice(
  harness: Harness,
  stripe: FakeStripe,
  friend: { customer: string; subscriptionId: string },
  invoiceId: string,
  amountPaid: number,
  code: string,
): Promise<void> {
  const created: number = Math.floor(harness.clock.nowMs / 1000);
  stripe.invoices.set(invoiceId, { subscription: friend.subscriptionId, paid: true, created });
  stripe.invoicePayments.set(invoiceId, [`pi_${invoiceId}`]);
  const payload: string = invoicePaidEvent({
    eventId: `evt_${invoiceId}`,
    invoiceId,
    customer: friend.customer,
    subscriptionId: friend.subscriptionId,
    amountPaid,
    referralCode: code,
    created,
  });
  expect((await postEvent(harness, payload)).status).toBe(200);
}

async function grant(harness: Harness): Promise<ReferralRewardReport> {
  return grantDueReferralRewards(env.DB, harness.platform, parseConfig(env), new Date(harness.clock.nowMs));
}

async function redemptionStatus(referredUserId: string): Promise<{ status: string; void_reason: string | null } | null> {
  return env.DB.prepare("SELECT status, void_reason FROM referral_redemptions WHERE referred_user_id = ?")
    .bind(referredUserId)
    .first<{ status: string; void_reason: string | null }>();
}

describe("Checkout planı", () => {
  it("plan doğrulanır: yıllık ve aylık fiyat; eski istemciler (gövdesiz ya da {}) aylık; bilinmeyen plan, fazladan alan ve plansız kod 400", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const session: Session = await signIn(harness);
    expect((await checkout(harness, session, { plan: "yearly" })).status).toBe(200);
    expect((await checkout(harness, session, { plan: "monthly" })).status).toBe(200);
    // Uygulama 0.1.5 ve öncesi: gövdesiz, content-type'sız POST.
    expect((await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken }))).status).toBe(200);
    // Bu sürümden önceki site: `{}`.
    expect((await checkout(harness, session, {})).status).toBe(200);
    expect(stripe.checkoutForms.map((form: URLSearchParams): string | null => form.get("line_items[0][price]"))).toEqual([
      env.STRIPE_YEARLY_PRICE_ID,
      env.STRIPE_PRICE_ID,
      env.STRIPE_PRICE_ID,
      env.STRIPE_PRICE_ID,
    ]);
    expect(stripe.checkoutForms.every((form: URLSearchParams): boolean => form.get("discounts[0][coupon]") === null)).toBe(true);
    await expectError(await checkout(harness, session, { plan: "weekly" }), 400, "invalid_body");
    await expectError(await checkout(harness, session, { plan: "yearly", coupon: "X" }), 400, "invalid_body");
    await expectError(await checkout(harness, session, { referralCode: "ABCDEFGH" }), 400, "invalid_body");
    await expectError(await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken, body: "plan=yearly" })), 415, "unsupported_media_type");
    expect(stripe.checkoutForms).toHaveLength(4);
  });

  it("yıllık abonelik /v1/me'de yearly görünür, haklar aylıkla aynıdır; Portal'da plan değişince güncellenir", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const id = uniqueIds();
    const session: Session = await signIn(harness);
    expect((await checkout(harness, session, { plan: "yearly" })).status).toBe(200);
    const customer: string = await customerOf(session.userId);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    await sendSubscription(harness, stripe, id("evt_1"), "customer.subscription.created", now, fakeYearlySubscription(id("sub"), customer, "active", now, now + 365 * daySeconds));
    const me = async (): Promise<{ plan: string; monthlyHoursCap: number; meetingMaxMinutes: number; subscription: { plan: string | null } | null }> =>
      (await harness.call(req("GET", "/v1/me", { token: session.accessToken }))).json();
    expect(await me()).toMatchObject({ plan: "subscription", monthlyHoursCap: 10, meetingMaxMinutes: 240, subscription: { plan: "yearly" } });
    await sendSubscription(harness, stripe, id("evt_2"), "customer.subscription.updated", now + 1, fakeSubscription(id("sub"), customer, "active", now, now + 30 * daySeconds));
    expect(await me()).toMatchObject({ plan: "subscription", monthlyHoursCap: 10, meetingMaxMinutes: 240, subscription: { plan: "monthly" } });
  });
});

describe("iki fiyat da bizim", () => {
  it("yıllık aboneliğin son faturasının tam iadesi aboneliği bitirir; itiraz yıllık aboneliği iptal eder", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const id = uniqueIds();
    const now: number = Math.floor(harness.clock.nowMs / 1000);

    const refunded: Session = await signIn(harness);
    expect((await checkout(harness, refunded, { plan: "yearly" })).status).toBe(200);
    const refundedCustomer: string = await customerOf(refunded.userId);
    const yearly: FakeSubscription = { ...fakeYearlySubscription(id("sub_r"), refundedCustomer, "active", now, now + 365 * daySeconds), latest_invoice: id("in_r") };
    await sendSubscription(harness, stripe, id("evt_r"), "customer.subscription.created", now, yearly);
    stripe.invoices.set(id("in_r"), { subscription: id("sub_r"), paid: true, created: now });
    stripe.invoicePayments.set(id("in_r"), [id("pi_r")]);
    const refund: string = eventOf(id("evt_refund"), "charge.refunded", now + 1, {
      id: id("ch_r"),
      object: "charge",
      customer: refundedCustomer,
      payment_intent: id("pi_r"),
      amount_refunded: 4900,
      currency: "usd",
      refunded: true,
    });
    expect((await postEvent(harness, refund)).status).toBe(200);
    expect(stripe.canceled).toEqual([id("sub_r")]);

    const disputed: Session = await signIn(harness);
    expect((await checkout(harness, disputed, { plan: "yearly" })).status).toBe(200);
    const disputedCustomer: string = await customerOf(disputed.userId);
    await sendSubscription(harness, stripe, id("evt_d"), "customer.subscription.created", now, fakeYearlySubscription(id("sub_d"), disputedCustomer, "active", now, now + 365 * daySeconds));
    stripe.charges.set(id("ch_d"), disputedCustomer);
    const dispute: string = eventOf(id("evt_dispute"), "charge.dispute.created", now + 2, {
      id: id("dp"),
      object: "dispute",
      charge: id("ch_d"),
      amount: 4900,
      currency: "usd",
      reason: "fraudulent",
    });
    expect((await postEvent(harness, dispute)).status).toBe(200);
    expect(stripe.canceled).toEqual([id("sub_r"), id("sub_d")]);
  });
});

describe("davet kodu", () => {
  it("kod biçimi: rastgele baytlardan düzgün dağılımlı, karışan karakter yok; girilen kod normalize edilir", () => {
    expect(referralCodeAlphabet).not.toMatch(/[01ILO]/);
    // 248 ve üstü baytlar atlanır (31'in katı olmayan kuyruk), diğerleri alfabeye mod 31 eşlenir.
    expect(referralCodeFromBytes(new Uint8Array([255, 248, 0, 1, 2, 30, 31, 247, 100, 200]))).toBe("234Z2Z9G");
    expect(referralCodeFromBytes(new Uint8Array([250, 251, 252]))).toBeNull();
    expect(normalizeReferralCode(" k7m2-qx9d ")).toBe("K7M2QX9D");
  });

  it("aboneye rastgele kalıcı kod verilir; abone olmayana verilmez; program kapalıyken kod yok ve kod kabul edilmez", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const id = uniqueIds();
    const trial: Session = await signIn(harness);
    expect(await referral(harness, trial)).toEqual({
      enabled: true,
      code: null,
      inviteUrl: null,
      joined: 0,
      rewarded: 0,
      pending: 0,
      rewardsLeftThisYear: 12,
      rewardsPerYear: 12,
      rewardUsd: 5.99,
      holdDays: 30,
    });
    const first = await subscriber(harness, stripe, id, "a");
    const second = await subscriber(harness, stripe, id, "b");
    const firstCode: ReferralBody = await referral(harness, first.session);
    expect(firstCode.code).toMatch(/^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{8}$/);
    expect(firstCode.inviteUrl).toBe(`${siteOrigin}/invite?code=${firstCode.code ?? ""}`);
    expect((await referral(harness, first.session)).code).toBe(firstCode.code);
    expect((await referral(harness, second.session)).code).not.toBe(firstCode.code);
    // Site kaynağından çağrılabilir (CORS).
    const cors: Response = await harness.call(req("GET", "/v1/referral", { token: first.session.accessToken, headers: { origin: siteOrigin } }));
    expect(cors.headers.get("access-control-allow-origin")).toBe(siteOrigin);

    const off = envWith({ REFERRAL_POLICY: "off" });
    const closed: ReferralBody = await (await harness.call(req("GET", "/v1/referral", { token: first.session.accessToken, env: off }))).json<ReferralBody>();
    expect(closed).toMatchObject({ enabled: false, code: null });
    await expectError(
      await harness.call(req("POST", "/v1/referral/validate", { token: trial.accessToken, json: { code: firstCode.code }, env: off })),
      503,
      "referral_unavailable",
    );
  });

  it("doğrulama: geçerli kod normalize edilir; bilinmeyen, biçimi bozuk ve abonesi bitmiş sahibin kodu, kendi kodu, aynı Mac ve daha önce abone olmuş hesap reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const id = uniqueIds();
    const owner = await subscriber(harness, stripe, id, "owner");
    const code: string = (await referral(harness, owner.session)).code ?? "";
    const friend: Session = await signIn(harness);
    const typed: string = `${code.slice(0, 4).toLowerCase()}-${code.slice(4).toLowerCase()}`;
    expect(await (await validate(harness, friend, typed)).json()).toEqual({ code });
    await expectError(await validate(harness, friend, "ZZZZZZZZ"), 404, "referral_invalid");
    await expectError(await validate(harness, friend, "abc"), 404, "referral_invalid");
    await expectError(await validate(harness, owner.session, code), 403, "referral_self");

    // Aynı Mac: sahibin doğrulattığı cihaz arkadaşın toplantısında görünüyor.
    const sameMac: Session = await signIn(harness);
    const device: string = `dev_${randomId()}`;
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO devices (id, public_key_spki, sign_count, environment, validation_category, bundle_version, receipt,
           attested_by_user_id, created_at, last_used_at) VALUES (?, 's', 0, 'development', 3, '1', 'r', ?, 0, 0)`,
      ).bind(device, owner.session.userId),
      env.DB.prepare("INSERT INTO meeting_sessions (id, user_id, device_id, kind, started_at, max_ends_at, token_budget) VALUES (?, ?, ?, 'trial', 0, 0, 1)").bind(
        randomId(),
        sameMac.userId,
        device,
      ),
    ]);
    await expectError(await validate(harness, sameMac, code), 403, "referral_self");

    // Daha önce abone olmuş (satırı iptal edilmiş olsa da) hesap yeni değildir.
    const returning: Session = await signIn(harness);
    await grantSubscription(returning.userId, "canceled", harness.clock.nowMs - dayMs);
    await expectError(await validate(harness, returning, code), 409, "referral_not_eligible");

    // Sahibin aboneliği bitince kodu geçersizdir.
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    await sendSubscription(harness, stripe, id("evt_owner_end"), "customer.subscription.deleted", now + 10, {
      ...fakeSubscription(id("sub_owner"), owner.customer, "canceled", now, now + 90 * daySeconds),
      metadata: { user_id: owner.session.userId },
    });
    await expectError(await validate(harness, friend, code), 404, "referral_invalid");
    // Reddedilen kod Stripe'a gitmez: Checkout oturumu açılmaz.
    const before: number = stripe.checkoutForms.length;
    await expectError(await checkout(harness, friend, { plan: "monthly", referralCode: code }), 404, "referral_invalid");
    expect(stripe.checkoutForms).toHaveLength(before);
  });

  it("kodlu Checkout: aylıkta ilk ay ücretsiz (%100, bir kez), yıllıkta 5,99 $ indirim; kuponlar bir kez oluşturulur, kod aboneliğe yazılır", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const id = uniqueIds();
    const owner = await subscriber(harness, stripe, id, "owner");
    const code: string = (await referral(harness, owner.session)).code ?? "";
    const monthly: Session = await signIn(harness);
    const yearly: Session = await signIn(harness);
    const another: Session = await signIn(harness);
    expect((await checkout(harness, monthly, { plan: "monthly", referralCode: code })).status).toBe(200);
    expect((await checkout(harness, yearly, { plan: "yearly", referralCode: code.toLowerCase() })).status).toBe(200);
    expect((await checkout(harness, another, { plan: "monthly", referralCode: code })).status).toBe(200);
    const forms: URLSearchParams[] = stripe.checkoutForms.slice(-3);
    expect(forms.map((form: URLSearchParams): string | null => form.get("discounts[0][coupon]"))).toEqual([
      "gistsmith_invite_first_month",
      "gistsmith_invite_yearly_599",
      "gistsmith_invite_first_month",
    ]);
    expect(forms.map((form: URLSearchParams): string | null => form.get("subscription_data[metadata][referral_code]"))).toEqual([code, code, code]);
    expect(forms[1]?.get("line_items[0][price]")).toBe(env.STRIPE_YEARLY_PRICE_ID);
    expect(stripe.couponForms.map((form: URLSearchParams): Record<string, string | null> => ({
      id: form.get("id"),
      duration: form.get("duration"),
      percent: form.get("percent_off"),
      amount: form.get("amount_off"),
      currency: form.get("currency"),
    }))).toEqual([
      { id: "gistsmith_invite_first_month", duration: "once", percent: "100", amount: null, currency: null },
      { id: "gistsmith_invite_yearly_599", duration: "once", percent: null, amount: "599", currency: "usd" },
    ]);
    // Panodan değiştirilmiş kupon kullanılmaz.
    stripe.coupons.set("gistsmith_invite_first_month", { ...(stripe.coupons.get("gistsmith_invite_first_month") ?? { id: "", object: "coupon", valid: true, duration: "once", percent_off: 100, amount_off: null, currency: null }), percent_off: 50 });
    await expectError(await checkout(harness, await signIn(harness), { plan: "monthly", referralCode: code }), 503, "referral_unavailable");
    // Kodsuz yeni Checkout bekleyen davet satırını siler.
    expect((await redemptionStatus(another.userId))?.status).toBe("checkout");
    expect((await checkout(harness, another, { plan: "monthly" })).status).toBe(200);
    expect(await redemptionStatus(another.userId)).toBeNull();
  });
});

describe("davet ödülü", () => {
  it("aylık arkadaş: ücretsiz ilk fatura katılım, ikinci ayın ödemesi 30 gün iadesiz kalınca davet edene 5,99 $ bakiye; çift ödül yok", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const id = uniqueIds();
    const owner = await subscriber(harness, stripe, id, "owner");
    const code: string = (await referral(harness, owner.session)).code ?? "";
    const friendSession: Session = await signIn(harness);
    const friend = await referredFriend(harness, stripe, id, "friend", friendSession, code, false);

    await payInvoice(harness, stripe, friend, id("in_free"), 0, code);
    expect(await referral(harness, owner.session)).toMatchObject({ joined: 1, pending: 1, rewarded: 0 });
    expect((await redemptionStatus(friendSession.userId))?.status).toBe("joined");
    expect((await grant(harness)).processed).toBe(0);

    harness.clock.nowMs += 30 * dayMs;
    // Erişim jetonu 15 dakikada, yenileme jetonu 60 günde dolar: saat ilerleyince oturum yenilenir.
    const ownerLater: Session = await refreshed(harness, owner.session);
    await payInvoice(harness, stripe, friend, id("in_second"), 599, code);
    expect((await redemptionStatus(friendSession.userId))?.status).toBe("qualified");
    harness.clock.nowMs += 29 * dayMs;
    expect((await grant(harness)).processed).toBe(0);
    harness.clock.nowMs += 2 * dayMs;
    expect(await grant(harness)).toEqual({ processed: 1, granted: 1, capped: 0, voided: 0, failed: 0 });
    expect(stripe.balanceTransactions).toHaveLength(1);
    expect(stripe.balanceTransactions[0]).toMatchObject({ customer: owner.customer, amount: -599, currency: "usd", metadata: { purpose: "referral_reward" } });
    expect(await referral(harness, await refreshed(harness, ownerLater))).toMatchObject({ joined: 1, pending: 0, rewarded: 1, rewardsLeftThisYear: 11 });

    // Yeniden çalıştırma, aynı olayın tekrarı ve sonraki aylar ödül vermez.
    expect((await grant(harness)).processed).toBe(0);
    await payInvoice(harness, stripe, friend, id("in_third"), 599, code);
    expect((await grant(harness)).processed).toBe(0);
    expect(stripe.balanceTransactions).toHaveLength(1);
  });

  it("iade, itiraz ve sonradan ortaya çıkan aynı Mac ödülü düşürür; yıllık arkadaşın ilk ödemesi hemen sayılır", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const id = uniqueIds();
    const owner = await subscriber(harness, stripe, id, "owner");
    const code: string = (await referral(harness, owner.session)).code ?? "";

    // Yıllık: ilk fatura (43,01 $) hemen `qualified`; kısmi iade webhook'u ödülü düşürür.
    const refundedSession: Session = await signIn(harness);
    const refunded = await referredFriend(harness, stripe, id, "refunded", refundedSession, code, true);
    await payInvoice(harness, stripe, refunded, id("in_refunded"), 4301, code);
    expect((await redemptionStatus(refundedSession.userId))?.status).toBe("qualified");
    const refund: string = eventOf(id("evt_refund"), "charge.refunded", Math.floor(harness.clock.nowMs / 1000), {
      id: id("ch_refunded"),
      object: "charge",
      customer: refunded.customer,
      payment_intent: `pi_${id("in_refunded")}`,
      amount_refunded: 1000,
      currency: "usd",
      refunded: false,
    });
    expect((await postEvent(harness, refund)).status).toBe(200);
    expect(await redemptionStatus(refundedSession.userId)).toEqual({ status: "void", void_reason: "refunded" });

    // İtiraz webhook'u.
    const disputedSession: Session = await signIn(harness);
    const disputed = await referredFriend(harness, stripe, id, "disputed", disputedSession, code, true);
    await payInvoice(harness, stripe, disputed, id("in_disputed"), 4301, code);
    stripe.charges.set(id("ch_disputed"), disputed.customer);
    const dispute: string = eventOf(id("evt_dispute"), "charge.dispute.created", Math.floor(harness.clock.nowMs / 1000), {
      id: id("dp"),
      object: "dispute",
      charge: id("ch_disputed"),
      amount: 4301,
      currency: "usd",
      reason: "fraudulent",
    });
    expect((await postEvent(harness, dispute)).status).toBe(200);
    expect(await redemptionStatus(disputedSession.userId)).toEqual({ status: "void", void_reason: "disputed" });

    // Webhook'u kaçmış itiraz: ödül anında Stripe'ta görülür.
    const lateSession: Session = await signIn(harness);
    const late = await referredFriend(harness, stripe, id, "late", lateSession, code, true);
    await payInvoice(harness, stripe, late, id("in_late"), 4301, code);
    stripe.disputedIntents.add(`pi_${id("in_late")}`);

    // Sonradan aynı Mac'te görülen hesap.
    const sameMacSession: Session = await signIn(harness);
    const sameMac = await referredFriend(harness, stripe, id, "same", sameMacSession, code, true);
    await payInvoice(harness, stripe, sameMac, id("in_same"), 4301, code);
    const device: string = `dev_${randomId()}`;
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO devices (id, public_key_spki, sign_count, environment, validation_category, bundle_version, receipt,
           attested_by_user_id, created_at, last_used_at) VALUES (?, 's', 0, 'development', 3, '1', 'r', ?, 0, 0)`,
      ).bind(device, sameMacSession.userId),
      env.DB.prepare("INSERT INTO meeting_sessions (id, user_id, device_id, kind, started_at, max_ends_at, token_budget) VALUES (?, ?, ?, 'subscription', 0, 0, 1)").bind(
        randomId(),
        owner.session.userId,
        device,
      ),
    ]);

    harness.clock.nowMs += 31 * dayMs;
    expect(await grant(harness)).toEqual({ processed: 2, granted: 0, capped: 0, voided: 2, failed: 0 });
    expect(await redemptionStatus(lateSession.userId)).toEqual({ status: "void", void_reason: "refunded" });
    expect(await redemptionStatus(sameMacSession.userId)).toEqual({ status: "void", void_reason: "self_referral" });
    expect(stripe.balanceTransactions).toHaveLength(0);
    expect(await referral(harness, await refreshed(harness, owner.session))).toMatchObject({ joined: 4, pending: 0, rewarded: 0 });
  });

  it("yıllık sınır: son 365 günde 12 ödül alan davet edenin sonraki ödülü verilmez (capped)", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const id = uniqueIds();
    const owner = await subscriber(harness, stripe, id, "owner");
    const code: string = (await referral(harness, owner.session)).code ?? "";
    const nowMs: number = harness.clock.nowMs;
    for (let index: number = 0; index < 12; index += 1) {
      await env.DB.prepare(
        `INSERT INTO referral_redemptions (id, referred_user_id, referred_identity_hash, referrer_user_id, code, status, created_at, updated_at,
           joined_at, rewarded_at) VALUES (?, NULL, ?, ?, ?, 'granted', 0, ?, 0, ?)`,
      )
        .bind(randomId(), `hash_${randomId()}`, owner.session.userId, code, nowMs, nowMs - (index + 1) * 20 * dayMs)
        .run();
    }
    expect((await referral(harness, owner.session)).rewardsLeftThisYear).toBe(0);
    const friendSession: Session = await signIn(harness);
    const friend = await referredFriend(harness, stripe, id, "friend", friendSession, code, true);
    await payInvoice(harness, stripe, friend, id("in_friend"), 4301, code);
    harness.clock.nowMs += 31 * dayMs;
    expect(await grant(harness)).toEqual({ processed: 1, granted: 0, capped: 1, voided: 0, failed: 0 });
    expect((await redemptionStatus(friendSession.userId))?.status).toBe("capped");
    expect(stripe.balanceTransactions).toHaveLength(0);
  });

  it("bakiye yazıldı ama yanıt kayboldu: satır bekler, idempotency süresi dolduktan sonraki çalışma aynı ödülü yeniden yazmaz", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const id = uniqueIds();
    const owner = await subscriber(harness, stripe, id, "owner");
    const code: string = (await referral(harness, owner.session)).code ?? "";
    const friendSession: Session = await signIn(harness);
    const friend = await referredFriend(harness, stripe, id, "friend", friendSession, code, true);
    await payInvoice(harness, stripe, friend, id("in_friend"), 4301, code);
    harness.clock.nowMs += 31 * dayMs;
    stripe.loseBalanceResponses = true;
    await expect(grant(harness)).rejects.toBeInstanceOf(ReferralRewardFailedError);
    expect((await redemptionStatus(friendSession.userId))?.status).toBe("qualified");
    expect(stripe.balanceTransactions).toHaveLength(1);
    stripe.loseBalanceResponses = false;
    stripe.balanceKeys.clear();
    harness.clock.nowMs += dayMs;
    expect(await grant(harness)).toMatchObject({ processed: 1, granted: 1 });
    expect(stripe.balanceTransactions).toHaveLength(1);
    const stored = await env.DB.prepare("SELECT stripe_balance_transaction_id AS id FROM referral_redemptions WHERE referred_user_id = ?")
      .bind(friendSession.userId)
      .first<{ id: string }>();
    expect(stored?.id).toBe(stripe.balanceTransactions[0]?.id);
  });

  it("hesap silme: aynı kimlik yeniden açılınca ikinci davet indirimi yok; davet eden silinince bekleyen ödül düşer ve kodu gider", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const id = uniqueIds();
    const owner = await subscriber(harness, stripe, id, "owner");
    const code: string = (await referral(harness, owner.session)).code ?? "";
    const subject: string = `google-${randomId()}`;
    const friendSession: Session = await signInWithGoogle(harness, subject);
    const friend = await referredFriend(harness, stripe, id, "friend", friendSession, code, false);
    await payInvoice(harness, stripe, friend, id("in_free"), 0, code);
    expect((await harness.call(req("DELETE", "/v1/me", { token: friendSession.accessToken }))).status).toBe(204);
    const anonymous = await env.DB.prepare("SELECT referred_user_id, status FROM referral_redemptions WHERE referrer_user_id = ?")
      .bind(owner.session.userId)
      .first<{ referred_user_id: string | null; status: string }>();
    expect(anonymous).toEqual({ referred_user_id: null, status: "joined" });
    const again: Session = await signInWithGoogle(harness, subject);
    await expectError(await validate(harness, again, code), 409, "referral_not_eligible");

    // Davet eden silinir: bekleyen ödül düşer, kod artık geçersiz.
    const pendingSession: Session = await signIn(harness);
    const pending = await referredFriend(harness, stripe, id, "pending", pendingSession, code, true);
    await payInvoice(harness, stripe, pending, id("in_pending"), 4301, code);
    expect((await harness.call(req("DELETE", "/v1/me", { token: owner.session.accessToken }))).status).toBe(204);
    expect(await redemptionStatus(pendingSession.userId)).toEqual({ status: "void", void_reason: "referrer_deleted" });
    await expectError(await validate(harness, await signIn(harness), code), 404, "referral_invalid");
    harness.clock.nowMs += 31 * dayMs;
    expect((await grant(harness)).processed).toBe(0);
  });
});

/** Yönetici istatistiğindeki abonelik sayıları (denetlenen alanlar). */
interface StatsSubscriptions {
  readonly monthly: number;
  readonly mrrUsd: number;
  readonly freeInviteMonth: number;
}

const adminSubject: string = "davet-yonetici";
const adminEnv: Env = envWith({ ADMIN_IDENTITIES: `google:${adminSubject}` });

async function subscriptionStats(harness: Harness, admin: Session): Promise<StatsSubscriptions> {
  const response: Response = await harness.call(req("GET", "/v1/admin/stats", { token: admin.accessToken, env: adminEnv }));
  expect(response.status).toBe(200);
  return (await response.json<{ subscriptions: StatsSubscriptions }>()).subscriptions;
}

describe("yönetici MRR ve davet sayaçları", () => {
  it("davetle gelen aylık abonenin ücretsiz ilk ayı MRR'a girmez, ayrı sayılır; ilk ücretli faturadan sonra MRR'a girer", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const id = uniqueIds();
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const before: StatsSubscriptions = await subscriptionStats(harness, admin);
    const owner = await subscriber(harness, stripe, id, "owner");
    const code: string = (await referral(harness, owner.session)).code ?? "";
    const friendSession: Session = await signIn(harness);
    const friend = await referredFriend(harness, stripe, id, "friend", friendSession, code, false);
    await payInvoice(harness, stripe, friend, id("in_free"), 0, code);

    // Paylaşılan veritabanında başka testlerin satırları da var: fark denetlenir.
    const inFreeMonth: StatsSubscriptions = await subscriptionStats(harness, admin);
    expect(inFreeMonth.monthly - before.monthly).toBe(1);
    expect(inFreeMonth.freeInviteMonth - before.freeInviteMonth).toBe(1);
    expect(Math.round((inFreeMonth.mrrUsd - before.mrrUsd) * 100)).toBe(599);

    harness.clock.nowMs += 30 * dayMs;
    await payInvoice(harness, stripe, friend, id("in_second"), 599, code);
    // Erişim jetonu 15 dakikada dolar: oturum bir kez yenilenir (eski yenileme jetonu yeniden kullanılmaz).
    const paid: StatsSubscriptions = await subscriptionStats(harness, await refreshed(harness, admin));
    expect(paid.monthly - before.monthly).toBe(2);
    expect(paid.freeInviteMonth - before.freeInviteMonth).toBe(0);
    expect(Math.round((paid.mrrUsd - before.mrrUsd) * 100)).toBe(1198);
  });

  it("MRR yıllığı ayda 1/12 sayar; davet sayaçları istatistikte görünür", async () => {
    // 3 aylık × 5,99 + 2 yıllık × 49 / 12 = 17,97 + 8,1667 = 26,14.
    expect(monthlyRecurringRevenueUsd(3, 2, 5.99, 49)).toBe(26.14);
    expect(monthlyRecurringRevenueUsd(0, 1, 5.99, 49)).toBe(4.08);
    expect(monthlyRecurringRevenueUsd(0, 0, 5.99, 49)).toBe(0);
    const config: Config = parseConfig(env);
    expect(config.priceUsdYearly).toBe(49);
  });
});
