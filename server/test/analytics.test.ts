import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { AdminTrends, CurrencyRevenue, TrendDay } from "../src/adminTrends";
import { parseConfig } from "../src/config";
import { type DailyMetrics, recordDailyMetrics } from "../src/dailyMetrics";
import type { Env } from "../src/env";
import type { SiteAnalytics } from "../src/siteAnalytics";
import { cloudflareGraphqlUrl } from "../src/siteAnalytics";
import { elevenLabsSpeechToTextUrl } from "../src/transcribe";
import {
  type Harness,
  type Session,
  type StartedMeetingBody,
  defaultHarness,
  envWith,
  expectError,
  req,
  signIn,
  signInWithGoogle,
  startMeeting,
  wavFile,
} from "./helpers";
import { eventOf, invoicePaidEvent, postEvent, sendSubscription } from "./stripeEvents";
import { type FakeStripe, fakeSubscription, stubStripeApi } from "./stripeFake";

// Yeni sunucu kayıtları (göç 0041–0043): gerçek gelir, günlük anlık görüntü, token kovaları, konuşma tanıma dilleri,
// hesap silme ve yeniden deneme sayaçları, indirme kampanyaları ve site istatistikleri. Testler aynı D1'i paylaşır:
// her test kendi kimliklerine ve sayaçlarına bakar.

const dayMs: number = 86_400_000;
const adminSubject: string = "admin-trends-sub";
const adminEnv: Env = envWith({ ADMIN_IDENTITIES: `google:${adminSubject}` });
const anthropicUrl: string = "https://api.anthropic.com/v1/messages";

/** Yöneticinin oturumu (Google kimliği `ADMIN_IDENTITIES`'te). */
async function adminSession(harness: Harness): Promise<Session> {
  return signInWithGoogle(harness, adminSubject);
}

async function trends(harness: Harness, admin: Session): Promise<AdminTrends> {
  const response: Response = await harness.call(req("GET", "/v1/admin/trends", { token: admin.accessToken, env: adminEnv }));
  expect(response.status).toBe(200);
  return response.json<AdminTrends>();
}

function today(harness: Harness): string {
  return new Date(harness.clock.nowMs).toISOString().slice(0, 10);
}

async function opsCount(kind: string, detail: string, day: string): Promise<number> {
  const row = await env.DB.prepare("SELECT count FROM ops_events WHERE day = ? AND kind = ? AND detail = ?").bind(day, kind, detail).first<{ count: number }>();
  return row?.count ?? 0;
}

interface RevenueRow {
  readonly user_id: string | null;
  readonly subscription_id: string;
  readonly day: string;
  readonly currency: string;
  readonly amount_paid: number;
  readonly total_excluding_tax: number;
  readonly discount: number;
  readonly tax: number;
  readonly billing_reason: string | null;
}

describe("gerçek gelir: Stripe webhook'u", () => {
  it("invoice.paid fatura satırı ve ilk ödeme anı yazar (tekrarı yazmaz); iadeler birikimli; panel MRR, ARPU, LTV ve iadeleri gösterir", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const session: Session = await signIn(harness);
    const customer: string = "cus_revenue_1";
    await env.DB.prepare("INSERT INTO stripe_customers (user_id, stripe_customer_id, created_at) VALUES (?, ?, 0)").bind(session.userId, customer).run();
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    const paid = (eventId: string): string =>
      invoicePaidEvent({ eventId, invoiceId: "in_rev_1", customer, subscriptionId: "sub_rev_1", amountPaid: 599, referralCode: null, created: now });

    // Fatura abonelik olayından önce gelir: satır yazılır, abonelik satırı henüz yok.
    expect((await postEvent(harness, paid("evt_rev_paid"))).status).toBe(200);
    // Aynı faturanın ikinci olayı (farklı olay kimliği) satırı değiştirmez.
    expect((await postEvent(harness, paid("evt_rev_paid_again"))).status).toBe(200);
    const rows = await env.DB.prepare("SELECT * FROM revenue_invoices WHERE invoice_id = 'in_rev_1'").all<RevenueRow>();
    expect(rows.results).toEqual([
      expect.objectContaining({
        user_id: session.userId,
        subscription_id: "sub_rev_1",
        day: today(harness),
        currency: "usd",
        amount_paid: 599,
        total_excluding_tax: 483,
        discount: 0,
        tax: 116,
        billing_reason: "subscription_cycle",
      }),
    ]);

    // Abonelik olayı ilk ödeme anını kayıtlı faturadan doldurur.
    await sendSubscription(harness, stripe, "evt_rev_sub", "customer.subscription.created", now, fakeSubscription("sub_rev_1", customer, "active", now, now + 30 * 86_400));
    const firstPaid = await env.DB.prepare("SELECT first_paid_at FROM subscriptions WHERE user_id = ?").bind(session.userId).first<{ first_paid_at: number }>();
    expect(firstPaid?.first_paid_at).toBe(now * 1000);

    // Kısmi iade, sonra tam iade: birikimli tutar büyür; eski (küçük tutarlı) olay geri almaz.
    stripe.invoices.set("in_rev_1", { subscription: "sub_rev_1", paid: true, created: now });
    stripe.invoicePayments.set("in_rev_1", ["pi_rev_1"]);
    const refund = (eventId: string, amount: number, full: boolean): string =>
      eventOf(eventId, "charge.refunded", now + 10, {
        id: "ch_rev_1",
        object: "charge",
        customer,
        payment_intent: "pi_rev_1",
        amount: 599,
        amount_refunded: amount,
        currency: "usd",
        refunded: full,
      });
    expect((await postEvent(harness, refund("evt_rev_ref_1", 200, false))).status).toBe(200);
    expect((await postEvent(harness, refund("evt_rev_ref_2", 599, true))).status).toBe(200);
    expect((await postEvent(harness, refund("evt_rev_ref_old", 200, false))).status).toBe(200);
    const refunds = await env.DB.prepare("SELECT invoice_id, currency, amount_refunded FROM revenue_refunds WHERE charge_id = 'ch_rev_1'").all();
    expect(refunds.results).toEqual([{ invoice_id: "in_rev_1", currency: "usd", amount_refunded: 599 }]);

    // Kayıtlı olmayan faturanın iadesi gelire yazılmaz.
    stripe.invoices.set("in_foreign", { subscription: "sub_foreign", paid: true, created: now });
    stripe.invoicePayments.set("in_foreign", ["pi_foreign"]);
    const foreign: string = eventOf("evt_rev_foreign", "charge.refunded", now, {
      id: "ch_foreign",
      object: "charge",
      customer: "cus_unknown",
      payment_intent: "pi_foreign",
      amount: 100,
      amount_refunded: 50,
      currency: "usd",
      refunded: false,
    });
    expect((await postEvent(harness, foreign)).status).toBe(200);
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM revenue_refunds WHERE charge_id = 'ch_foreign'").first<{ n: number }>())?.n).toBe(0);

    const admin: Session = await adminSession(harness);
    const body: AdminTrends = await trends(harness, admin);
    const usd: CurrencyRevenue | undefined = body.revenue.currencies.find((item: CurrencyRevenue): boolean => item.currency === "usd");
    expect(usd).toMatchObject({
      mrrCents: 483,
      payingSubscriptions: 1,
      arpuCents: 483,
      paidLast30DaysCents: 599,
      taxLast30DaysCents: 116,
      discountLast30DaysCents: 0,
      refundedLast30DaysCents: 599,
      netLast30DaysCents: -116,
      paidAllTimeCents: 599,
      netAllTimeCents: -116,
      paidSubscriptionsAllTime: 1,
      ltvCents: -116,
    });
    expect(usd?.daily.length).toBe(90);
    expect(usd?.daily.at(-1)).toEqual({ day: today(harness), paidCents: 599, refundedCents: 599 });
    expect(body.revenue.firstPaymentsLast30Days).toBe(1);
    expect(body.revenue.medianDaysToFirstPayment).toBe(0);

    // Hesap silme: gelir satırı kalır, hesap bağı kalkar; silme abone kesimiyle sayılır.
    stripe.subscriptions.set("sub_rev_1", fakeSubscription("sub_rev_1", customer, "active", now, now + 30 * 86_400));
    const before: number = await opsCount("account_deleted", "subscriber", today(harness));
    expect((await harness.call(req("DELETE", "/v1/me", { token: session.accessToken }))).status).toBe(204);
    expect(await opsCount("account_deleted", "subscriber", today(harness))).toBe(before + 1);
    const unlinked = await env.DB.prepare("SELECT user_id FROM revenue_invoices WHERE invoice_id = 'in_rev_1'").first<{ user_id: string | null }>();
    expect(unlinked).toEqual({ user_id: null });
    const deletions: AdminTrends = await trends(harness, admin);
    expect(deletions.accountDeletions).toContainEqual({ detail: "subscriber", count: before + 1 });
  });

  it("denemesiz hesabın silinmesi `signup`, denemedekininki `trial` sayılır", async () => {
    const harness: Harness = await defaultHarness();
    stubStripeApi(harness);
    const signup: Session = await signIn(harness);
    const trial: Session = await signIn(harness);
    expect((await startMeeting(harness, trial)).status).toBe(201);
    const day: string = today(harness);
    const signupBefore: number = await opsCount("account_deleted", "signup", day);
    const trialBefore: number = await opsCount("account_deleted", "trial", day);
    expect((await harness.call(req("DELETE", "/v1/me", { token: signup.accessToken }))).status).toBe(204);
    expect((await harness.call(req("DELETE", "/v1/me", { token: trial.accessToken }))).status).toBe(204);
    expect(await opsCount("account_deleted", "signup", day)).toBe(signupBefore + 1);
    expect(await opsCount("account_deleted", "trial", day)).toBe(trialBefore + 1);
  });
});

interface BucketRow {
  readonly bucket: string;
  readonly calls: number;
  readonly streamed_calls: number;
  readonly input_tokens: number;
  readonly output_tokens: number;
}

function llmMessage(inputTokens: number, outputTokens: number): object {
  return {
    id: "msg_test",
    type: "message",
    role: "assistant",
    model: "claude-haiku-5-5",
    content: [{ type: "text", text: "Tamam" }],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: { input_tokens: inputTokens, output_tokens: outputTokens, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
  };
}

function sse(events: ReadonlyArray<readonly [string, object]>): string {
  return events.map(([type, data]): string => `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`).join("");
}

describe("token kovaları ve yeniden deneme sayacı", () => {
  it("her kesinleşen çağrı isteğin biçimine göre günlük kovasına yazılır; Anthropic'in yeniden denemesi sayılır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    const day: string = today(harness);
    const retriesBefore: number = await opsCount("retry", "anthropic", day);
    let calls: number = 0;
    harness.stub(anthropicUrl, async (request: Request): Promise<Response> => {
      calls += 1;
      const body: { stream?: boolean } = await request.json<{ stream?: boolean }>();
      // İlk çağrı geçici hata (529): yeniden denenir ve sayılır.
      if (calls === 1) {
        return Response.json({ type: "error", error: { type: "overloaded_error", message: "x" } }, { status: 529 });
      }
      if (body.stream === true) {
        return new Response(
          sse([
            ["message_start", { type: "message_start", message: { ...llmMessage(30, 1), content: [], stop_reason: null } }],
            ["message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 7 } }],
            ["message_stop", { type: "message_stop" }],
          ]),
          { status: 200, headers: { "content-type": "text/event-stream" } },
        );
      }
      return Response.json(llmMessage(10, 5));
    });
    const call = (json: object, meetingId: string | null): Promise<Response> =>
      harness.call(
        req("POST", "/v1/llm/messages", { token: session.accessToken, headers: meetingId === null ? {} : { "x-meeting-id": meetingId }, json }),
      );
    const messages = [{ role: "user", content: "Özetle." }];
    const schema = { format: { type: "json_schema", schema: { type: "object", properties: { text: { type: "string" } } } } };
    expect((await call({ effort: "low", max_tokens: 1024, messages }, meeting.meetingId)).status).toBe(200);
    expect((await call({ effort: "low", max_tokens: 1024, messages, output_config: schema }, meeting.meetingId)).status).toBe(200);
    expect((await call({ effort: "medium", max_tokens: 1024, messages }, meeting.meetingId)).status).toBe(200);
    expect((await call({ effort: "low", max_tokens: 1024, messages }, null)).status).toBe(200);
    const streamed: Response = await call({ effort: "medium", max_tokens: 1024, messages, stream: true }, null);
    expect(streamed.status).toBe(200);
    await streamed.text();
    await harness.drain();

    expect(await opsCount("retry", "anthropic", day)).toBe(retriesBefore + 1);
    const rows = await env.DB.prepare("SELECT bucket, calls, streamed_calls, input_tokens, output_tokens FROM llm_usage_daily WHERE day = ? ORDER BY bucket").bind(day).all<BucketRow>();
    expect(rows.results).toEqual([
      { bucket: "account_note", calls: 1, streamed_calls: 1, input_tokens: 30, output_tokens: 7 },
      { bucket: "account_quick", calls: 1, streamed_calls: 0, input_tokens: 10, output_tokens: 5 },
      { bucket: "meeting_live_structured", calls: 1, streamed_calls: 0, input_tokens: 10, output_tokens: 5 },
      { bucket: "meeting_live_text", calls: 1, streamed_calls: 0, input_tokens: 10, output_tokens: 5 },
      { bucket: "meeting_note", calls: 1, streamed_calls: 0, input_tokens: 10, output_tokens: 5 },
    ]);

    const admin: Session = await adminSession(harness);
    const body: AdminTrends = await trends(harness, admin);
    expect(body.tokenBuckets.map((bucket): string => bucket.bucket)).toEqual([
      "meeting_note",
      "meeting_live_structured",
      "meeting_live_text",
      "account_note",
      "account_quick",
    ]);
    expect(body.tokenBuckets[0]).toEqual({ bucket: "meeting_note", calls: 1, streamedCalls: 0, inputTokens: 10, outputTokens: 5 });
    expect(body.retries).toContainEqual({ detail: "anthropic", count: retriesBefore + 1 });
  });
});

describe("konuşma tanıma dilleri", () => {
  it("istenen ve algılanan dil başına istek ve ses süresi sayılır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
      // Ses akışı okunmadan yanıt dönülürse gönderim beklemede kalır.
      await request.arrayBuffer();
      return Response.json({ language_code: "TUR", language_probability: 0.9, text: "Merhaba", words: [], audio_duration_secs: 1 });
    });
    const upload = (query: string): Promise<Response> => {
      const audio: Uint8Array = wavFile(16_000, 1, 16, 32_000);
      return harness.call(
        req("POST", `/v1/transcribe${query}`, {
          token: session.accessToken,
          headers: { "x-meeting-id": meeting.meetingId, "content-type": "audio/wav", "content-length": String(audio.byteLength) },
          body: audio,
        }),
      );
    };
    expect((await upload("?language_code=tr")).status).toBe(200);
    expect((await upload("")).status).toBe(200);
    expect((await upload("?language_code=tr")).status).toBe(200);
    const rows = await env.DB.prepare(
      "SELECT requested, detected, requests, audio_seconds FROM transcription_languages_daily WHERE day = ? ORDER BY requested",
    )
      .bind(today(harness))
      .all();
    expect(rows.results).toEqual([
      { requested: "auto", detected: "tur", requests: 1, audio_seconds: 1 },
      { requested: "tr", detected: "tur", requests: 2, audio_seconds: 2 },
    ]);
    const admin: Session = await adminSession(harness);
    const body: AdminTrends = await trends(harness, admin);
    expect(body.languages).toContainEqual({ requested: "tr", detected: "tur", requests: 2, audioHours: 0 });
  });
});

describe("indirme kampanyaları", () => {
  it("izinli utm_source ve biçimi geçerli utm_campaign sayılır; tanınmayan `other`, kampanyasız indirme yazılmaz", async () => {
    const harness: Harness = await defaultHarness();
    const download = (query: string, ip: string): Promise<Response> => harness.call(req("GET", `/v1/download/mac${query}`, { clientIp: ip }));
    expect((await download("?src=home-hero&utm_source=Reddit&utm_campaign=Launch_1", "203.0.113.1")).status).toBe(302);
    // Aynı ağın tekrarı sayılmaz.
    expect((await download("?utm_source=reddit&utm_campaign=launch_1", "203.0.113.1")).status).toBe(302);
    expect((await download("?utm_source=spamsite", "203.0.113.2")).status).toBe(302);
    expect((await download("?utm_source=x&utm_campaign=bad%20name!", "203.0.113.3")).status).toBe(302);
    expect((await download("", "203.0.113.4")).status).toBe(302);
    const rows = await env.DB.prepare("SELECT utm_source, utm_campaign, count FROM download_campaigns WHERE day = ? ORDER BY utm_source").bind(today(harness)).all();
    expect(rows.results).toEqual([
      { utm_source: "other", utm_campaign: "", count: 1 },
      { utm_source: "reddit", utm_campaign: "launch_1", count: 1 },
      { utm_source: "x", utm_campaign: "other", count: 1 },
    ]);
    const admin: Session = await adminSession(harness);
    const body: AdminTrends = await trends(harness, admin);
    expect(body.campaigns).toContainEqual({ source: "reddit", campaign: "launch_1", count: 1 });
  });
});

describe("günlük anlık görüntü", () => {
  it("biten günün toplamlarını ve gün sonundaki durumu yazar; yeniden çalışınca günceller; panel seride gösterir", async () => {
    const harness: Harness = await defaultHarness();
    const nowMs: number = harness.clock.nowMs;
    const dayStart: number = Date.UTC(2026, 9, 14);
    const day: string = "2026-10-14";
    const userA: Session = await signIn(harness);
    await env.DB.batch([
      env.DB.prepare("UPDATE users SET created_at = ?, trial_started_at = ? WHERE id = ?").bind(dayStart + 1000, dayStart + 2000, userA.userId),
      env.DB.prepare(
        `INSERT INTO meeting_sessions (id, user_id, kind, started_at, max_ends_at, token_budget) VALUES
           ('dm_m1', ?1, 'trial', ?2, ?2, 1), ('dm_m2', ?1, 'trial', ?3, ?3, 1)`,
      ).bind(userA.userId, dayStart + 3000, dayStart - 5 * dayMs),
      env.DB.prepare(
        "INSERT INTO daily_spend (day, micro_usd, trial_micro_usd, audio_seconds, llm_micro_usd) VALUES (?, 900, 300, 120, 400) ON CONFLICT(day) DO UPDATE SET micro_usd = 900, trial_micro_usd = 300, audio_seconds = 120, llm_micro_usd = 400",
      ).bind(day),
      env.DB.prepare("INSERT INTO deepgram_live_meetings (meeting_id, grants, first_grant_at, charged_seconds, settled_at) VALUES ('dm_m1', 1, ?, 600, ?)").bind(
        dayStart + 4000,
        dayStart + 5000,
      ),
    ]);
    const config = parseConfig(env);
    const metrics: DailyMetrics = await recordDailyMetrics(env.DB, config, new Date(nowMs));
    expect(metrics).toMatchObject({
      day,
      usersNew: 1,
      activeUsersDay: 1,
      activeUsers7d: 1,
      meetingsTrial: 1,
      meetingsSubscription: 0,
      trialsStarted: 1,
      spendAnthropicMicroUsd: 400,
      spendElevenLabsMicroUsd: 500,
      spendTrialMicroUsd: 300,
      elevenLabsAudioSeconds: 120,
      deepgramStreamSeconds: 600,
      spendDeepgramMicroUsd: 92_000,
    });
    // Yeniden çalışma aynı günün satırını günceller.
    await env.DB.prepare("UPDATE daily_spend SET llm_micro_usd = 500 WHERE day = ?").bind(day).run();
    await recordDailyMetrics(env.DB, config, new Date(nowMs));
    const rows = await env.DB.prepare("SELECT day, spend_anthropic_micro_usd FROM daily_metrics WHERE day = ?").bind(day).all();
    expect(rows.results).toEqual([{ day, spend_anthropic_micro_usd: 500 }]);

    const admin: Session = await adminSession(harness);
    const body: AdminTrends = await trends(harness, admin);
    expect(body.daily.length).toBe(90);
    const yesterday: TrendDay | undefined = body.daily.find((item: TrendDay): boolean => item.day === day);
    expect(yesterday?.snapshot).toMatchObject({ usersNew: 1, meetingsTrial: 1, spendAnthropicUsd: 0.0005, spendElevenLabsUsd: 0.0004, spendDeepgramUsd: 0.092 });
    expect(body.daily.at(-1)).toEqual({ day: today(harness), snapshot: null });
  });
});

/** Cloudflare'e giden GraphQL gövdesi. */
interface GraphqlBody {
  readonly query: string;
  readonly variables: { readonly accountTag: string; readonly filter: { readonly siteTag: string; readonly datetime_geq: string; readonly datetime_leq: string } };
}

describe("site istatistikleri", () => {
  const configured: Env = envWith({
    ADMIN_IDENTITIES: `google:${adminSubject}`,
    CF_ANALYTICS_ACCOUNT_ID: "0123456789abcdef0123456789abcdef",
    CF_ANALYTICS_SITE_TAG: "fedcba9876543210fedcba9876543210",
    CF_ANALYTICS_TOKEN: "test-cloudflare-analytics-token-000",
  });

  it("jeton ya da kimlikler yoksa 503 analytics_unavailable; panelin diğer uçları çalışır", async () => {
    const harness: Harness = await defaultHarness();
    const admin: Session = await adminSession(harness);
    const before: number = harness.outbound.length;
    const missing = await expectError(await harness.call(req("GET", "/v1/admin/site-analytics", { token: admin.accessToken, env: adminEnv })), 503, "analytics_unavailable");
    expect(missing.error.message).toContain("CF_ANALYTICS_TOKEN");
    expect(harness.outbound.length).toBe(before);
    const tokenOnly: Env = envWith({ ADMIN_IDENTITIES: `google:${adminSubject}`, CF_ANALYTICS_TOKEN: "test-cloudflare-analytics-token-000" });
    await expectError(await harness.call(req("GET", "/v1/admin/site-analytics", { token: admin.accessToken, env: tokenOnly })), 503, "analytics_unavailable");
    expect((await harness.call(req("GET", "/v1/admin/trends", { token: admin.accessToken, env: adminEnv }))).status).toBe(200);
  });

  it("yapılandırılınca Cloudflare GraphQL'den 30 günün toplamları, günleri, sayfaları ve yönlendirenleri döner", async () => {
    const harness: Harness = await defaultHarness();
    const admin: Session = await adminSession(harness);
    const captured: { body: GraphqlBody | null; authorization: string | null } = { body: null, authorization: null };
    harness.stub(cloudflareGraphqlUrl, async (request: Request): Promise<Response> => {
      captured.authorization = request.headers.get("authorization");
      captured.body = await request.json<GraphqlBody>();
      return Response.json({
        data: {
          viewer: {
            accounts: [
              {
                total: [{ count: 120, sum: { visits: 80 } }],
                daily: [{ count: 20, sum: { visits: 15 }, dimensions: { date: today(harness) } }],
                topPaths: [{ count: 70, sum: { visits: 50 }, dimensions: { requestPath: "/" } }],
                topReferrers: [
                  { count: 60, sum: { visits: 40 }, dimensions: { refererHost: "" } },
                  { count: 30, sum: { visits: 20 }, dimensions: { refererHost: "news.ycombinator.com" } },
                ],
              },
            ],
          },
        },
        errors: null,
      });
    });
    const response: Response = await harness.call(req("GET", "/v1/admin/site-analytics", { token: admin.accessToken, env: configured }));
    expect(response.status).toBe(200);
    const body: SiteAnalytics = await response.json<SiteAnalytics>();
    expect(body).toMatchObject({ days: 30, pageViews: 120, visits: 80 });
    expect(body.daily.length).toBe(30);
    expect(body.daily.at(-1)).toEqual({ day: today(harness), pageViews: 20, visits: 15 });
    expect(body.daily[0]).toEqual({ day: new Date(harness.clock.nowMs - 29 * dayMs).toISOString().slice(0, 10), pageViews: 0, visits: 0 });
    expect(body.topPaths).toEqual([{ key: "/", pageViews: 70, visits: 50 }]);
    expect(body.topReferrers).toEqual([
      { key: "", pageViews: 60, visits: 40 },
      { key: "news.ycombinator.com", pageViews: 30, visits: 20 },
    ]);
    expect(captured.authorization).toBe("Bearer test-cloudflare-analytics-token-000");
    expect(captured.body).toMatchObject({
      variables: { accountTag: "0123456789abcdef0123456789abcdef", filter: { siteTag: "fedcba9876543210fedcba9876543210", datetime_leq: new Date(harness.clock.nowMs).toISOString() } },
    });
    expect(captured.body?.query).toContain("rumPageloadEventsAdaptiveGroups");
  });

  it("Cloudflare GraphQL hatası (ör. yetkisiz jeton) 502 upstream_unavailable olur ve servis hatası sayılır", async () => {
    const harness: Harness = await defaultHarness();
    const admin: Session = await adminSession(harness);
    harness.stub(cloudflareGraphqlUrl, async (): Promise<Response> => Response.json({ data: null, errors: [{ message: "not authorized for that account" }] }));
    const day: string = today(harness);
    const before: number = await opsCount("provider_error", "cloudflare_analytics", day);
    await expectError(await harness.call(req("GET", "/v1/admin/site-analytics", { token: admin.accessToken, env: configured })), 502, "upstream_unavailable");
    expect(await opsCount("provider_error", "cloudflare_analytics", day)).toBe(before + 1);
  });
});
