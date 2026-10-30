import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { parseConfig } from "../src/config";
import { randomId, randomToken } from "../src/crypto";
import type { Env } from "../src/env";
import { type ReferralRewardReport, grantDueReferralRewards } from "../src/referralRewards";
import {
  type Harness,
  type Session,
  type StartedMeetingBody,
  defaultHarness,
  envWith,
  expectError,
  grantSubscription,
  refreshed,
  req,
  signIn,
  signInWithGoogle,
  startMeeting,
} from "./helpers";
import { sendSubscription } from "./stripeEvents";
import { type FakeStripe, type FakeSubscription, fakeSubscription, stubStripeApi } from "./stripeFake";

const dayMs: number = 86_400_000;
const adminSubject: string = "comp-admin-sub";
const adminEnv: Env = envWith({ ADMIN_IDENTITIES: `google:${adminSubject}` });

/** Yönetici ayrıntısındaki abonelik (denetlenen alanlar). */
interface DetailSubscriptionBody {
  readonly status: string;
  readonly access: string;
  readonly plan: string | null;
  readonly complimentary: boolean;
  readonly currentPeriodEnd: string;
  readonly cancelAt: string | null;
}

/** `POST /v1/admin/users/{id}/complimentary` yanıtı (kullanıcı ayrıntısı; denetlenen alanlar). */
interface DetailBody {
  readonly user: { readonly id: string; readonly plan: string; readonly subscription: DetailSubscriptionBody | null };
  readonly stripeCustomerId: string | null;
}

/** `/v1/me` yanıtı (karşılaştırma için tüm alanlar). */
interface MeBody {
  readonly userId: string;
  readonly plan: string;
  readonly subscription: { readonly status: string; readonly plan: string | null; readonly access: string; readonly currentPeriodEnd: string; readonly cancelAt: string | null; readonly complimentary: boolean } | null;
  readonly [key: string]: unknown;
}

/** Abonelik satırı (veritabanı). */
interface SubscriptionRow {
  readonly stripe_customer_id: string;
  readonly stripe_subscription_id: string;
  readonly status: string;
  readonly plan: string | null;
  readonly complimentary: number;
  readonly current_period_end: number;
  readonly cancel_at: number | null;
}

/** İstatistiklerin abonelik ve dönüşüm alanları. */
interface StatsBody {
  readonly subscriptions: { active: number; grace: number; ending: number; canceledTotal: number; monthly: number; yearly: number; mrrUsd: number; complimentary: number; freeInviteMonth: number };
  readonly conversion: { trialStarted: number; converted: number; subscribedWithoutTrial: number };
  readonly churn: { canceledLast30Days: number };
}

function setComplimentary(harness: Harness, session: Session, userId: string, json: object): Promise<Response> {
  return harness.call(req("POST", `/v1/admin/users/${userId}/complimentary`, { token: session.accessToken, json, env: adminEnv }));
}

async function me(harness: Harness, session: Session): Promise<MeBody> {
  const response: Response = await harness.call(req("GET", "/v1/me", { token: session.accessToken }));
  expect(response.status).toBe(200);
  return response.json<MeBody>();
}

async function stats(harness: Harness, admin: Session): Promise<StatsBody> {
  const response: Response = await harness.call(req("GET", "/v1/admin/stats", { token: admin.accessToken, env: adminEnv }));
  expect(response.status).toBe(200);
  return response.json<StatsBody>();
}

async function subscriptionRow(userId: string): Promise<SubscriptionRow | null> {
  return env.DB.prepare(
    "SELECT stripe_customer_id, stripe_subscription_id, status, plan, complimentary, current_period_end, cancel_at FROM subscriptions WHERE user_id = ?",
  )
    .bind(userId)
    .first<SubscriptionRow>();
}

function stripeRequests(harness: Harness): Request[] {
  return harness.outbound.filter((request: Request): boolean => request.url.startsWith("https://api.stripe.com/"));
}

/** Yönetici oturumu ve ücretsiz erişim verilmiş kullanıcı. */
async function complimentaryUser(harness: Harness): Promise<{ admin: Session; user: Session }> {
  const admin: Session = await signInWithGoogle(harness, adminSubject);
  const user: Session = await signIn(harness);
  expect((await setComplimentary(harness, admin, user.userId, { grant: true })).status).toBe(200);
  return { admin, user };
}

describe("ücretsiz tam erişim", () => {
  it("yönetici verir ve kaldırır: yapay Stripe kimlikleri, Stripe çağrısı yok, süre değiştirilebilir; geçersiz istekler reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const user: Session = await signIn(harness);

    const granted: Response = await setComplimentary(harness, admin, user.userId, { grant: true });
    expect(granted.status).toBe(200);
    const detail: DetailBody = await granted.json<DetailBody>();
    expect(detail.user).toMatchObject({ id: user.userId, plan: "subscription", subscription: { status: "active", access: "active", plan: "monthly", complimentary: true, cancelAt: null } });
    expect(detail.stripeCustomerId).toBeNull();
    const row: SubscriptionRow | null = await subscriptionRow(user.userId);
    expect(row?.stripe_customer_id).toMatch(/^comp_cus_[0-9a-f-]{36}$/);
    expect(row?.stripe_subscription_id).toMatch(/^comp_sub_[0-9a-f-]{36}$/);
    expect(row).toMatchObject({ status: "active", plan: "monthly", complimentary: 1, cancel_at: null });
    // Süresiz: dönem sonu 100 yıl sonra.
    expect(row?.current_period_end).toBeGreaterThan(harness.clock.nowMs + 99 * 365 * dayMs);
    const customers = await env.DB.prepare("SELECT COUNT(*) AS count FROM stripe_customers WHERE user_id = ?").bind(user.userId).first<{ count: number }>();
    expect(customers?.count).toBe(0);

    // Bitiş tarihi: dönem sonu ve `cancel_at` o tarih; yapay kimlikler korunur.
    const until: string = new Date(harness.clock.nowMs + 60 * dayMs).toISOString();
    const limited: DetailBody = await (await setComplimentary(harness, admin, user.userId, { grant: true, until })).json<DetailBody>();
    expect(limited.user.subscription).toMatchObject({ complimentary: true, currentPeriodEnd: until, cancelAt: until, access: "active" });
    expect((await subscriptionRow(user.userId))?.stripe_subscription_id).toBe(row?.stripe_subscription_id);
    // Yalnızca tarih (UTC gece yarısı) da kabul edilir.
    expect((await setComplimentary(harness, admin, user.userId, { grant: true, until: "2099-01-31" })).status).toBe(200);
    expect((await subscriptionRow(user.userId))?.cancel_at).toBe(Date.UTC(2099, 0, 31));

    await expectError(await setComplimentary(harness, admin, user.userId, { grant: true, until: new Date(harness.clock.nowMs - dayMs).toISOString() }), 400, "invalid_body");
    await expectError(await setComplimentary(harness, admin, user.userId, { grant: false, until }), 400, "invalid_body");
    await expectError(await setComplimentary(harness, admin, user.userId, { grant: true, until: "next week" }), 400, "invalid_body");
    await expectError(await setComplimentary(harness, admin, user.userId, { grant: "yes" }), 400, "invalid_body");
    await expectError(await setComplimentary(harness, admin, randomId(), { grant: true }), 404, "not_found");

    const revoked: Response = await setComplimentary(harness, admin, user.userId, { grant: false });
    expect(revoked.status).toBe(200);
    expect((await revoked.json<DetailBody>()).user).toMatchObject({ plan: "free", subscription: null });
    expect(await subscriptionRow(user.userId)).toBeNull();
    expect((await me(harness, user)).plan).toBe("trial");
    await expectError(await setComplimentary(harness, admin, user.userId, { grant: false }), 404, "not_found");
    expect(stripeRequests(harness)).toHaveLength(0);
  });

  it("yönetici olmayan veremez ve kaldıramaz (403); yönetici listesi boşsa kimse veremez", async () => {
    const harness: Harness = await defaultHarness();
    const outsider: Session = await signIn(harness);
    const target: Session = await signIn(harness);
    await expectError(await setComplimentary(harness, outsider, target.userId, { grant: true }), 403, "forbidden");
    await expectError(await setComplimentary(harness, outsider, target.userId, { grant: false }), 403, "forbidden");
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    await expectError(
      await harness.call(req("POST", `/v1/admin/users/${target.userId}/complimentary`, { token: admin.accessToken, json: { grant: true } })),
      403,
      "forbidden",
    );
    await expectError(await harness.call(req("POST", `/v1/admin/users/${target.userId}/complimentary`, { json: { grant: true }, env: adminEnv })), 401, "unauthorized");
    expect(await subscriptionRow(target.userId)).toBeNull();
  });

  it("haklar ödeyen aylık abonenin haklarıyla aynıdır; /v1/me aylık planı ve complimentary: true gönderir; toplantı abonelik toplantısıdır", async () => {
    const harness: Harness = await defaultHarness();
    const { user } = await complimentaryUser(harness);
    const paying: Session = await signIn(harness);
    await grantSubscription(paying.userId, "active", harness.clock.nowMs + 30 * dayMs);

    const free: MeBody = await me(harness, user);
    const paid: MeBody = await me(harness, paying);
    expect(free.plan).toBe("subscription");
    expect(free.subscription).toMatchObject({ status: "active", plan: "monthly", access: "active", cancelAt: null });
    expect(Object.keys(free).sort()).toEqual(Object.keys(paid).sort());
    expect(Object.keys(free.subscription ?? {}).sort()).toEqual(Object.keys(paid.subscription ?? {}).sort());
    // Tek fark ücretsiz erişim işareti: uygulama planı yine aylık okur, site "Free access" yazar.
    expect(free.subscription?.complimentary).toBe(true);
    expect(paid.subscription?.complimentary).toBe(false);
    // Dönem sonu, hesap kimliği ve işaret dışında her şey aynı.
    expect({ ...free, userId: "", subscription: { ...free.subscription, currentPeriodEnd: "", complimentary: false } }).toEqual({
      ...paid,
      userId: "",
      subscription: { ...paid.subscription, currentPeriodEnd: "" },
    });

    const started: Response = await startMeeting(harness, user);
    expect(started.status).toBe(201);
    expect((await started.json<StartedMeetingBody>()).kind).toBe("subscription");
    expect(stripeRequests(harness)).toHaveLength(0);
  });

  it("davet koduna uygundur", async () => {
    const harness: Harness = await defaultHarness();
    const { user } = await complimentaryUser(harness);
    const response: Response = await harness.call(req("GET", "/v1/referral", { token: user.accessToken }));
    expect(response.status).toBe(200);
    const body: { code: string | null; inviteUrl: string | null; complimentary: boolean } = await response.json<{ code: string | null; inviteUrl: string | null; complimentary: boolean }>();
    expect(body.code).toMatch(/^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{8}$/);
    // Ödül uygulanmaz (ödenecek fatura yok): istemciler bunu söyler.
    expect(body.complimentary).toBe(true);
    // Kod başka hesapta geçerlidir (sahibinin erişimi var).
    const friend: Session = await signIn(harness);
    const validated: Response = await harness.call(req("POST", "/v1/referral/validate", { token: friend.accessToken, json: { code: body.code } }));
    expect(validated.status).toBe(200);
    expect(stripeRequests(harness)).toHaveLength(0);
  });

  it("Portal Stripe'a gitmeden sitedeki hesap sayfasını döner; Checkout complimentary_subscription (409); süresi bitince Checkout açılır", async () => {
    const harness: Harness = await defaultHarness();
    const { admin, user } = await complimentaryUser(harness);
    const portal: Response = await harness.call(req("POST", "/v1/billing/portal", { token: user.accessToken }));
    expect(portal.status).toBe(200);
    expect((await portal.json<{ url: string }>()).url).toBe("http://localhost:8788/account");
    await expectError(await harness.call(req("POST", "/v1/billing/checkout", { token: user.accessToken, json: { plan: "monthly" } })), 409, "complimentary_subscription");
    expect(stripeRequests(harness)).toHaveLength(0);

    // Bitiş tarihi geçmiş ücretsiz erişim bitmiştir: Checkout açılır.
    expect((await setComplimentary(harness, admin, user.userId, { grant: true, until: new Date(harness.clock.nowMs + dayMs).toISOString() })).status).toBe(200);
    harness.clock.nowMs += 2 * dayMs;
    const stripe: FakeStripe = stubStripeApi(harness);
    const session: Session = await refreshed(harness, user);
    expect((await me(harness, session)).plan).toBe("trial");
    expect((await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken, json: { plan: "monthly" } }))).status).toBe(200);
    expect(stripe.checkoutForms).toHaveLength(1);
  });

  it("verilemez: bitmemiş Stripe aboneliği varsa 409 ve satır değişmez; bitmiş Stripe aboneliğinin yerini alır", async () => {
    const harness: Harness = await defaultHarness();
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const paying: Session = await signIn(harness);
    await grantSubscription(paying.userId, "active", harness.clock.nowMs + 30 * dayMs);
    const before: SubscriptionRow | null = await subscriptionRow(paying.userId);
    await expectError(await setComplimentary(harness, admin, paying.userId, { grant: true }), 409, "subscription_exists");
    expect(await subscriptionRow(paying.userId)).toEqual(before);
    // Ödemesi gecikmiş (ek süresi geçmiş olsa da) abonelik de Stripe'ta yaşar.
    const pastDue: Session = await signIn(harness);
    await grantSubscription(pastDue.userId, "past_due", harness.clock.nowMs - 30 * dayMs);
    await expectError(await setComplimentary(harness, admin, pastDue.userId, { grant: true }), 409, "subscription_exists");
    // Kaldırma Stripe aboneliğine dokunmaz.
    await expectError(await setComplimentary(harness, admin, paying.userId, { grant: false }), 404, "not_found");
    expect(await subscriptionRow(paying.userId)).toEqual(before);

    const canceled: Session = await signIn(harness);
    await grantSubscription(canceled.userId, "canceled", harness.clock.nowMs - dayMs);
    expect((await setComplimentary(harness, admin, canceled.userId, { grant: true })).status).toBe(200);
    expect(await subscriptionRow(canceled.userId)).toMatchObject({ status: "active", complimentary: 1 });
    expect(stripeRequests(harness)).toHaveLength(0);
  });

  it("MRR, abone sayıları, dönüşüm ve kayıp ücretsiz erişimi saymaz; ayrı sayılır", async () => {
    const harness: Harness = await defaultHarness();
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const before: StatsBody = await stats(harness, admin);
    const user: Session = await signIn(harness);
    // Denemeye başlamış hesap: ücretsiz erişim dönüşüm sayılmaz.
    await env.DB.prepare("UPDATE users SET trial_started_at = ? WHERE id = ?").bind(harness.clock.nowMs - dayMs, user.userId).run();
    expect((await setComplimentary(harness, admin, user.userId, { grant: true })).status).toBe(200);
    const limited: Session = await signIn(harness);
    expect((await setComplimentary(harness, admin, limited.userId, { grant: true, until: new Date(harness.clock.nowMs + 5 * dayMs).toISOString() })).status).toBe(200);

    const after: StatsBody = await stats(harness, admin);
    expect(after.subscriptions).toEqual({ ...before.subscriptions, complimentary: before.subscriptions.complimentary + 2 });
    expect(after.conversion).toMatchObject({ trialStarted: before.conversion.trialStarted + 1, converted: before.conversion.converted, subscribedWithoutTrial: before.conversion.subscribedWithoutTrial });
    expect(after.churn).toEqual(before.churn);

    // Kaldırılan ücretsiz erişim iptal sayılmaz.
    expect((await setComplimentary(harness, admin, limited.userId, { grant: false })).status).toBe(200);
    const revoked: StatsBody = await stats(harness, admin);
    expect(revoked.subscriptions).toEqual({ ...before.subscriptions, complimentary: before.subscriptions.complimentary + 1 });
    expect(revoked.churn).toEqual(before.churn);
  });

  it("davet ödülü ücretsiz erişimli davet edene Stripe'a gitmeden düşer (referrer_complimentary)", async () => {
    const harness: Harness = await defaultHarness();
    const { user } = await complimentaryUser(harness);
    const friend: Session = await signIn(harness);
    const nowMs: number = harness.clock.nowMs;
    const rewardId: string = randomId();
    await env.DB.prepare(
      `INSERT INTO referral_redemptions (id, referred_user_id, referred_identity_hash, referrer_user_id, code, status, created_at, updated_at,
         stripe_subscription_id, joined_at, qualifying_invoice_id, qualified_at, reward_due_at)
       VALUES (?1, ?2, ?3, ?4, 'K7M2QX9D', 'qualified', ?5, ?5, ?6, ?5, ?7, ?5, ?5)`,
    )
      .bind(rewardId, friend.userId, randomToken(16), user.userId, nowMs - 40 * dayMs, `sub_${randomToken(8)}`, `in_${randomToken(8)}`)
      .run();
    const report: ReferralRewardReport = await grantDueReferralRewards(env.DB, harness.platform, parseConfig(env), new Date(nowMs));
    expect(report).toEqual({ processed: 1, granted: 0, capped: 0, voided: 1, failed: 0 });
    const row = await env.DB.prepare("SELECT status, void_reason, stripe_balance_transaction_id FROM referral_redemptions WHERE id = ?")
      .bind(rewardId)
      .first<{ status: string; void_reason: string | null; stripe_balance_transaction_id: string | null }>();
    expect(row).toEqual({ status: "void", void_reason: "referrer_complimentary", stripe_balance_transaction_id: null });
    expect(stripeRequests(harness)).toHaveLength(0);
  });

  it("hesap silme Stripe'ı çağırmadan ücretsiz erişimli hesabı siler", async () => {
    const harness: Harness = await defaultHarness();
    const { user } = await complimentaryUser(harness);
    expect((await harness.call(req("DELETE", "/v1/me", { token: user.accessToken }))).status).toBe(204);
    expect(await subscriptionRow(user.userId)).toBeNull();
    const users = await env.DB.prepare("SELECT COUNT(*) AS count FROM users WHERE id = ?").bind(user.userId).first<{ count: number }>();
    expect(users?.count).toBe(0);
    expect(stripeRequests(harness)).toHaveLength(0);
  });

  it("webhook süren ücretsiz erişimi ezmez ve Stripe'ı çağırmaz; süresi bitmişse Stripe aboneliği yerini alır", async () => {
    const harness: Harness = await defaultHarness();
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const user: Session = await signIn(harness);
    // Daha önce ödeme sayfası açmış hesap: Stripe müşterisi var.
    const customer: string = `cus_${randomToken(8)}`;
    await env.DB.prepare("INSERT INTO stripe_customers (user_id, stripe_customer_id, created_at) VALUES (?, ?, 0)").bind(user.userId, customer).run();
    expect((await setComplimentary(harness, admin, user.userId, { grant: true, until: new Date(harness.clock.nowMs + 10 * dayMs).toISOString() })).status).toBe(200);
    const granted: SubscriptionRow | null = await subscriptionRow(user.userId);

    const stripe: FakeStripe = stubStripeApi(harness);
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    const subscriptionId: string = `sub_${randomToken(8)}`;
    const live: FakeSubscription = { ...fakeSubscription(subscriptionId, customer, "active", now, now + 30 * 86_400), metadata: { user_id: user.userId } };
    expect((await sendSubscription(harness, stripe, `evt_${randomToken(8)}`, "customer.subscription.created", now, live)).status).toBe(200);
    expect(await subscriptionRow(user.userId)).toEqual(granted);
    expect(stripeRequests(harness)).toHaveLength(0);

    // Ücretsiz erişim bitti: sonraki abonelik olayı Stripe aboneliğini yazar.
    harness.clock.nowMs += 11 * dayMs;
    const later: number = Math.floor(harness.clock.nowMs / 1000);
    const renewed: FakeSubscription = { ...fakeSubscription(subscriptionId, customer, "active", now, later + 30 * 86_400), metadata: { user_id: user.userId } };
    expect((await sendSubscription(harness, stripe, `evt_${randomToken(8)}`, "customer.subscription.updated", later, renewed)).status).toBe(200);
    expect(await subscriptionRow(user.userId)).toMatchObject({ stripe_subscription_id: subscriptionId, stripe_customer_id: customer, complimentary: 0, status: "active" });
  });
});
