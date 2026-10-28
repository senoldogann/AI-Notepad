import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { randomId, randomToken } from "../src/crypto";
import {
  type Harness,
  type Session,
  type StartedMeetingBody,
  defaultHarness,
  expectError,
  grantSubscription,
  req,
  signIn,
} from "./helpers";

/** Stripe abonelik uçlarının sahtesi: listeyi döndürür, iptalleri toplar. */
interface StripeSubscriptionCalls {
  readonly lists: URL[];
  readonly canceled: string[];
}

function stubStripeSubscriptions(harness: Harness, subscriptions: ReadonlyArray<{ id: string; status: string }>): StripeSubscriptionCalls {
  const calls: StripeSubscriptionCalls = { lists: [], canceled: [] };
  harness.stub("https://api.stripe.com/v1/subscriptions", async (request: Request): Promise<Response> => {
    const url: URL = new URL(request.url);
    if (request.method === "GET") {
      calls.lists.push(url);
      return Response.json({
        object: "list",
        url: "/v1/subscriptions",
        has_more: false,
        data: subscriptions.map((subscription) => ({ ...subscription, object: "subscription" })),
      });
    }
    expect(request.method).toBe("DELETE");
    const id: string = url.pathname.split("/").at(-1) ?? "";
    calls.canceled.push(id);
    return Response.json({ id, object: "subscription", status: "canceled" });
  });
  return calls;
}

function deleteMe(harness: Harness, session: Session): Promise<Response> {
  return harness.call(req("DELETE", "/v1/me", { token: session.accessToken }));
}

/** Kullanıcıya bağlı satır sayıları (tablo → sayı). */
async function userRowCounts(userId: string): Promise<Record<string, number>> {
  const queries: ReadonlyArray<readonly [string, string]> = [
    ["users", "SELECT COUNT(*) AS count FROM users WHERE id = ?1"],
    ["auth_identities", "SELECT COUNT(*) AS count FROM auth_identities WHERE user_id = ?1"],
    ["refresh_families", "SELECT COUNT(*) AS count FROM refresh_families WHERE user_id = ?1"],
    ["device_challenges", "SELECT COUNT(*) AS count FROM device_challenges WHERE user_id = ?1"],
    ["devices", "SELECT COUNT(*) AS count FROM devices WHERE attested_by_user_id = ?1"],
    ["meeting_sessions", "SELECT COUNT(*) AS count FROM meeting_sessions WHERE user_id = ?1"],
    ["monthly_usage", "SELECT COUNT(*) AS count FROM monthly_usage WHERE user_id = ?1"],
    ["daily_usage", "SELECT COUNT(*) AS count FROM daily_usage WHERE user_id = ?1"],
    ["subscriptions", "SELECT COUNT(*) AS count FROM subscriptions WHERE user_id = ?1"],
    ["stripe_customers", "SELECT COUNT(*) AS count FROM stripe_customers WHERE user_id = ?1"],
    ["trial_starts", "SELECT COUNT(*) AS count FROM trial_starts WHERE user_id = ?1"],
  ];
  const counts: Record<string, number> = {};
  for (const [table, sql] of queries) {
    const row = await env.DB.prepare(sql).bind(userId).first<{ count: number }>();
    counts[table] = row?.count ?? -1;
  }
  return counts;
}

function startFrom(harness: Harness, session: Session, clientIp: string): Promise<Response> {
  return harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {}, clientIp }));
}

describe("DELETE /v1/me (hesap silme)", () => {
  it("Stripe aboneliğini hemen iptal eder, hesabın tüm satırlarını siler, oturumları düşürür; tekrarı 204'tür", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const userId: string = session.userId;
    const ip: string = `203.0.113.${Math.floor(Math.random() * 250)}`;

    // Deneme toplantısı (toplantı, günlük kullanım, deneme başlangıcı), aylık kullanım, meydan okuma, cihaz.
    expect((await startFrom(harness, session, ip)).status).toBe(201);
    const month: string = new Date(harness.clock.nowMs).toISOString().slice(0, 7);
    await env.DB.prepare("INSERT INTO monthly_usage (user_id, month, audio_seconds) VALUES (?, ?, 60)").bind(userId, month).run();
    expect((await harness.call(req("POST", "/v1/device/challenge", { token: session.accessToken, json: { purpose: "assert" } }))).status).toBe(200);
    const deviceId: string = randomToken(16);
    await env.DB.prepare(
      `INSERT INTO devices (id, public_key_spki, sign_count, environment, validation_category, bundle_version, receipt,
         attested_by_user_id, created_at, last_used_at) VALUES (?, 'spki', 0, 'development', 3, '1', 'receipt', ?, 0, 0)`,
    )
      .bind(deviceId, userId)
      .run();
    // Başka bir hesabın toplantısı aynı cihazı göstermiş: o hesap kalır, cihaz bağı kalkar.
    const other: Session = await signIn(harness);
    const otherMeeting: string = randomId();
    await env.DB.prepare(
      `INSERT INTO meeting_sessions (id, user_id, device_id, kind, started_at, max_ends_at, token_budget)
       VALUES (?, ?, ?, 'trial', 0, 1, 1)`,
    )
      .bind(otherMeeting, other.userId, deviceId)
      .run();
    // E-posta kimliği ve giriş bağlantıları; başka adresin bağlantısı kalır.
    const email: string = `kisi-${randomId()}@ornek.test`;
    const otherEmail: string = `baska-${randomId()}@ornek.test`;
    await env.DB.batch([
      env.DB.prepare("INSERT INTO auth_identities (provider, subject, user_id, email, created_at) VALUES ('email', ?, ?, ?, 0)").bind(email, userId, email),
      env.DB.prepare("INSERT INTO email_login_tokens (token_hash, email, created_at, expires_at) VALUES (?, ?, 0, 1)").bind(randomToken(16), email),
      env.DB.prepare("INSERT INTO email_login_tokens (token_hash, email, created_at, expires_at) VALUES (?, ?, 0, 1)").bind(randomToken(16), otherEmail),
    ]);
    await grantSubscription(userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    const stored = await env.DB.prepare("SELECT stripe_subscription_id, stripe_customer_id FROM subscriptions WHERE user_id = ?")
      .bind(userId)
      .first<{ stripe_subscription_id: string; stripe_customer_id: string }>();
    const stripe: StripeSubscriptionCalls = stubStripeSubscriptions(harness, [
      { id: stored?.stripe_subscription_id ?? "", status: "active" },
      { id: "sub_eski_iptal", status: "canceled" },
    ]);

    const families = await env.DB.prepare("SELECT id FROM refresh_families WHERE user_id = ?").bind(userId).all<{ id: string }>();
    const familyId: string = families.results[0]?.id ?? "";

    const deleted: Response = await deleteMe(harness, session);
    expect(deleted.status).toBe(204);
    expect(await deleted.text()).toBe("");
    const tokens = await env.DB.prepare("SELECT COUNT(*) AS count FROM refresh_tokens WHERE family_id = ?").bind(familyId).first<{ count: number }>();
    expect(tokens?.count).toBe(0);

    expect(stripe.lists[0]?.searchParams.get("customer")).toBe(stored?.stripe_customer_id);
    expect(stripe.lists[0]?.searchParams.get("status")).toBe("all");
    expect(stripe.canceled).toEqual([stored?.stripe_subscription_id]);
    expect(Object.values(await userRowCounts(userId)).every((count: number): boolean => count === 0)).toBe(true);
    const emailTokens = await env.DB.prepare("SELECT email FROM email_login_tokens WHERE email IN (?, ?)").bind(email, otherEmail).all<{ email: string }>();
    expect(emailTokens.results).toEqual([{ email: otherEmail }]);
    const otherRow = await env.DB.prepare("SELECT device_id FROM meeting_sessions WHERE id = ?").bind(otherMeeting).first<{ device_id: string | null }>();
    expect(otherRow).toEqual({ device_id: null });
    const anonymous = await env.DB.prepare("SELECT COUNT(*) AS count, SUM(accounts) AS accounts FROM deleted_trial_starts").first<{ count: number; accounts: number }>();
    expect(anonymous).toEqual({ count: 1, accounts: 1 });

    // Oturumlar düştü: erişim ve yenileme jetonu geçersiz.
    await expectError(await harness.call(req("GET", "/v1/me", { token: session.accessToken })), 401, "invalid_token");
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } })), 401, "invalid_token");

    // Yanıtı kaybolan istemci aynı jetonla yeniden dener: 204, Stripe yeniden çağrılmaz.
    expect((await deleteMe(harness, session)).status).toBe(204);
    expect(stripe.lists).toHaveLength(1);
    expect(stripe.canceled).toHaveLength(1);
  });

  it("Stripe müşterisi olmayan hesap Stripe çağrılmadan silinir; web sitesinden çağrılabilir", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const siteOrigin: string = "http://localhost:8788";
    const preflight: Response = await harness.call(
      req("OPTIONS", "/v1/me", { headers: { origin: siteOrigin, "access-control-request-method": "DELETE" } }),
    );
    expect(preflight.headers.get("access-control-allow-methods")).toContain("DELETE");
    const deleted: Response = await harness.call(req("DELETE", "/v1/me", { token: session.accessToken, headers: { origin: siteOrigin } }));
    expect(deleted.status).toBe(204);
    expect(deleted.headers.get("access-control-allow-origin")).toBe(siteOrigin);
    expect(harness.outbound.filter((request: Request): boolean => request.url.startsWith("https://api.stripe.com/"))).toHaveLength(0);
    expect((await userRowCounts(session.userId))["users"]).toBe(0);
  });

  it("Stripe iptali başarısızsa hiçbir satır silinmez ve 502 döner", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    let attempts: number = 0;
    harness.stub("https://api.stripe.com/", async (): Promise<Response> => {
      attempts += 1;
      return Response.json({ error: { type: "api_error", message: "geçici" } }, { status: 500 });
    });
    await expectError(await deleteMe(harness, session), 502, "upstream_unavailable");
    expect(attempts).toBe(3);
    expect((await harness.call(req("GET", "/v1/me", { token: session.accessToken }))).status).toBe(200);
    expect(await userRowCounts(session.userId)).toMatchObject({ users: 1, subscriptions: 1, stripe_customers: 1 });
  });

  it("çıkış yapılmış oturumun erişim jetonu hesabı silemez", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    expect((await harness.call(req("POST", "/v1/auth/logout", { json: { refreshToken: session.refreshToken } }))).status).toBe(200);
    await expectError(await deleteMe(harness, session), 401, "invalid_token");
    expect((await userRowCounts(session.userId))["users"]).toBe(1);
  });

  it("silinen hesabın deneme başlangıcı IP başına günlük sayaçta kalır", async () => {
    const harness: Harness = await defaultHarness();
    const ip: string = "198.18.0.77";
    const first: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startFrom(harness, first, ip)).json<StartedMeetingBody>();
    expect(meeting.kind).toBe("trial");
    expect((await deleteMe(harness, first)).status).toBe(204);
    // Sınır günde 3 yeni hesap: silinen hesap da sayılır.
    for (let index: number = 0; index < 2; index += 1) {
      expect((await startFrom(harness, await signIn(harness), ip)).status).toBe(201);
    }
    await expectError(await startFrom(harness, await signIn(harness), ip), 429, "trial_ip_limit");
  });
});
