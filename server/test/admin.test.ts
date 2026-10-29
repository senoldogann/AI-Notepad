import { env } from "cloudflare:workers";
import { type JWK, SignJWT, exportJWK, generateKeyPair } from "jose";
import { describe, expect, it } from "vitest";
import { accessJwksUrl } from "../src/auth/access";
import { randomId } from "../src/crypto";
import type { Env } from "../src/env";
import {
  type ErrorBody,
  type Harness,
  type Session,
  defaultHarness,
  envWith,
  expectError,
  grantSubscription,
  req,
  signIn,
  signInWithGoogle,
  startMeeting,
} from "./helpers";

const dayMs: number = 86_400_000;
const siteOrigin: string = "http://localhost:8788";
const adminSubject: string = "admin-sub-42";
const adminEnv: Env = envWith({ ADMIN_IDENTITIES: `apple:baska-yonetici,google:${adminSubject}` });

function dayOf(nowMs: number, offsetDays: number): string {
  return new Date(nowMs + offsetDays * dayMs).toISOString().slice(0, 10);
}

async function insertUser(createdAt: number): Promise<string> {
  const userId: string = randomId();
  await env.DB.prepare("INSERT INTO users (id, created_at) VALUES (?, ?)").bind(userId, createdAt).run();
  return userId;
}

function adminGet(harness: Harness, session: Session, path: string): Promise<Response> {
  return harness.call(req("GET", path, { token: session.accessToken, env: adminEnv }));
}

/** İstatistik yanıtının denetlenen alanları. */
interface StatsBody {
  readonly generatedAt: string;
  readonly downloads: { total: number; last30Days: Array<{ day: string; count: number }> };
  readonly users: { total: number; newLast30Days: Array<{ day: string; count: number }>; byProvider: { apple: number; google: number } };
  readonly trials: { activeTrialUsers: number; exhaustedTrialUsers: number };
  readonly subscriptions: { active: number; grace: number; ending: number; canceledTotal: number; monthly: number; yearly: number; mrrUsd: number; complimentary: number };
  readonly referrals: { joined: number; pending: number; granted: number; voided: number };
  readonly meetings: { last30Days: Array<{ day: string; trial: number; subscription: number }>; hoursThisMonth: number };
  readonly spend: { todayUsd: number; ceilingUsd: number; trialTodayUsd: number; trialCeilingUsd: number; last30Days: Array<{ day: string; usd: number }> };
  readonly tokens: { thisMonth: number };
  readonly reports: { openFeedback: number; openCrash: number; openContact: number };
  readonly stripe: { mode: string };
  readonly elevenLabs: { cycleStart: string; usedHours: number; capHours: number; percent: number };
  readonly conversion: { trialStarted: number; converted: number; startedLast30Days: number; convertedLast30Days: number; subscribedWithoutTrial: number };
  readonly churn: { canceledLast30Days: number; pastDue: number; unpaid: number; duplicateSubscriptions: number };
  readonly billing: { refundsLast30Days: number; disputesLast30Days: number; paymentFailuresLast30Days: number };
  readonly usage: {
    meetingsThisMonth: number;
    deferredThisMonth: number;
    reprocessedThisMonth: number;
    openMeetings: number;
    audioHoursThisMonth: number;
    accountTokensThisMonth: number;
    monthlyTokenCapPerUser: number;
    monthlyAccountTokenCapPerUser: number;
    usersNearTokenCap: number;
  };
  readonly trialRefusals: {
    last30Days: { device_used: number; exhausted: number; expired: number; ip_daily_limit: number };
    today: { device_used: number; exhausted: number; expired: number; ip_daily_limit: number };
  };
}

interface ListBody {
  readonly items: Array<{
    id: string;
    kind: string;
    status: string;
    createdAt: string;
    userId: string | null;
    email: string | null;
    appVersion: string | null;
    os: string | null;
    summary: string;
  }>;
  readonly nextBefore: number | null;
}

/** Kullanıcı listesindeki öğe. */
interface UserItemBody {
  readonly id: string;
  readonly provider: string | null;
  readonly createdAt: string;
  readonly plan: string;
  readonly subscription: {
    status: string;
    access: string;
    currentPeriodEnd: string;
    cancelAt: string | null;
    pastDueSince: string | null;
    graceEndsAt: string | null;
    updatedAt: string;
  } | null;
  readonly trial: { used: number; left: number; startedAt: string | null; endsAt: string | null };
  readonly meetingsTotal: number;
  readonly hoursThisMonth: number;
  readonly lastActiveAt: string | null;
  readonly failedMeetings: number;
  readonly lastFailureCode: string | null;
}

interface UserPageBody {
  readonly items: UserItemBody[];
  readonly nextCursor: string | null;
}

interface MeetingItemBody {
  readonly id: string;
  readonly state: string;
  readonly durationMinutes: number;
  readonly deferred: boolean;
  readonly reprocessCount: number;
  readonly audioMinutes: number;
  readonly noteCompleted: boolean;
  readonly failureCount: number;
  readonly lastFailureCode: string | null;
  readonly lastFailureAt: string | null;
}

/** Ayrıntı sayısı. */
interface DetailCountBody {
  readonly detail: string;
  readonly count: number;
}

/** Sorun penceresi. */
interface ProblemWindowBody {
  readonly trialCapacityReached: number;
  readonly spendCeilingReached: number;
  readonly refusals: DetailCountBody[];
  readonly providerErrors: DetailCountBody[];
  readonly serverErrors: DetailCountBody[];
  readonly serverErrorsTotal: number;
}

/** `GET /v1/admin/insights` yanıtı. */
interface InsightsBody {
  readonly generatedAt: string;
  readonly problems: { last7Days: ProblemWindowBody; last30Days: ProblemWindowBody };
  readonly funnel: { days: number; steps: Array<{ step: string; count: number }> };
  readonly downloads: { total: number; bySource: DetailCountBody[]; byReferrerHost: DetailCountBody[] };
  readonly cancellations: {
    total: number;
    byFeedback: DetailCountBody[];
    byReason: DetailCountBody[];
    recent: Array<{ userId: string; at: string; reason: string | null; feedback: string | null; comment: string | null }>;
  };
}

interface UserDetailBody {
  readonly user: UserItemBody;
  readonly trialDeviceVerifiedAt: string | null;
  readonly stripeCustomerId: string | null;
  readonly cancellation: { at: string; reason: string | null; feedback: string | null; comment: string | null } | null;
  readonly usage: { usedHours: number; capHours: number; audioHours: number; tokens: number; tokenCap: number; accountTokens: number; accountTokenCap: number };
  readonly meetings: MeetingItemBody[];
  readonly reports: Array<{ id: string; kind: string; status: string; createdAt: string; summary: string }>;
  readonly timeline: Array<{ kind: string; at: string; detail: string | null }>;
}

interface OperationsBody {
  readonly generatedAt: string;
  readonly meetings: {
    open: number;
    openItems: Array<{ id: string; userId: string; kind: string; startedAt: string; maxEndsAt: string; deferred: boolean; deepgram: boolean }>;
    unendedLast7Days: number;
  };
  readonly reservations: { active: number; expired: number; oldestExpiredAt: string | null };
  readonly deepgram: { unsettled: number; stale: number };
  readonly stripe: { lastEventAt: string | null; eventsLast24Hours: number; last7DaysByType: Array<{ type: string; count: number }> };
  readonly reports: {
    last7Days: { feedback: number; crash: number; contact: number };
    recentCrashes: Array<{ id: string; status: string; createdAt: string; appVersion: string | null; os: string | null; summary: string }>;
  };
}

describe("yönetici API'si", () => {
  // Bu dosyanın ilk testi: sayılar yalnızca burada eklenen satırlardan gelir.
  it("GET /v1/admin/stats tanımlı biçimi, 30 günlük sıfır doldurulmuş serileri ve doğru sayıları döner", async () => {
    const harness: Harness = await defaultHarness();
    const nowMs: number = harness.clock.nowMs;
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const trialUser: Session = await signIn(harness);
    const exhaustedUser: Session = await signIn(harness);
    await insertUser(nowMs - dayMs);
    const ending: string = await insertUser(nowMs - 40 * dayMs);
    const grace: string = await insertUser(nowMs - 40 * dayMs);
    const canceled: string = await insertUser(nowMs - 40 * dayMs);

    // Abonelikler: yönetici etkin, biri iptal edilmiş (dönem sonunda biter), biri ek sürede, biri bitmiş.
    await grantSubscription(admin.userId, "active", nowMs + 20 * dayMs);
    // Yönetici yıllık planda: MRR'ye ayda 49 / 12 katar.
    await env.DB.prepare("UPDATE subscriptions SET plan = 'yearly' WHERE user_id = ?").bind(admin.userId).run();
    await grantSubscription(ending, "active", nowMs + 10 * dayMs);
    await env.DB.prepare("UPDATE subscriptions SET cancel_at = ? WHERE user_id = ?").bind(nowMs + 10 * dayMs, ending).run();
    await grantSubscription(grace, "past_due", nowMs - dayMs);
    await grantSubscription(canceled, "canceled", nowMs - 5 * dayMs);

    // Toplantılar: bugün bir deneme ve bir abonelik toplantısı; dün denemesi biten kullanıcının üç 30 dakikalık toplantısı.
    expect((await startMeeting(harness, trialUser)).status).toBe(201);
    expect((await startMeeting(harness, admin)).status).toBe(201);
    // İlki sonradan işlenmiş, ikincisi iki kez yeniden işlenmiş.
    for (let index: number = 0; index < 3; index += 1) {
      const startedAt: number = nowMs - dayMs + index * 3_600_000;
      await env.DB.prepare(
        `INSERT INTO meeting_sessions (id, user_id, kind, started_at, max_ends_at, ended_at, token_budget, deferred, reprocess_count)
         VALUES (?, ?, 'trial', ?, ?, ?, 1, ?, ?)`,
      )
        .bind(randomId(), exhaustedUser.userId, startedAt, startedAt + 90 * 60_000, startedAt + 30 * 60_000, index === 0 ? 1 : 0, index === 1 ? 2 : 0)
        .run();
    }
    // Dönüşüm: deneme kullanıcıları son 30 günde başladı; iptal eden (`ending`) 40 gün önce denemeden aboneliğe geçti.
    await env.DB.batch([
      env.DB.prepare("UPDATE users SET trial_started_at = ? WHERE id = ?").bind(nowMs - dayMs, exhaustedUser.userId),
      env.DB.prepare("UPDATE users SET trial_started_at = ? WHERE id = ?").bind(nowMs - 40 * dayMs, ending),
      env.DB.prepare("UPDATE subscriptions SET updated_at = ? WHERE user_id = ?").bind(nowMs - 2 * dayMs, canceled),
    ]);

    const month: string = dayOf(nowMs, 0).slice(0, 7);
    await env.DB.batch([
      env.DB.prepare("INSERT INTO downloads (day, count) VALUES (?, 3), (?, 1), (?, 10)").bind(dayOf(nowMs, 0), dayOf(nowMs, -2), dayOf(nowMs, -40)),
      // ElevenLabs dönemi ayın 11'inde başlar: 5 gün önceki (10 Ekim) ses önceki döneme aittir.
      env.DB.prepare("INSERT INTO daily_spend (day, micro_usd, trial_micro_usd, audio_seconds) VALUES (?, 1250000, 400000, 39600), (?, 500000, 0, 180000)").bind(
        dayOf(nowMs, 0),
        dayOf(nowMs, -5),
      ),
      // `grace` kullanıcısı aylık token sınırının %80'ini aştı.
      env.DB.prepare(
        `INSERT INTO monthly_usage (user_id, month, input_tokens, output_tokens, audio_seconds, account_tokens)
         VALUES (?1, ?2, 1000, 500, 7200, 300), (?3, '2026-09', 999, 0, 0, 0), (?4, ?2, 5200000, 0, 0, 0)`,
      ).bind(admin.userId, month, trialUser.userId, grace),
      // Ödeme olayları: 30 gün içinde bir iade ve bir başarısız ödeme; 40 gün önceki iade ve abonelik güncellemesi sayılmaz.
      env.DB.prepare(
        `INSERT INTO stripe_events (id, type, processed_at) VALUES
           ('evt_a', 'charge.refunded', ?1), ('evt_b', 'charge.refunded', ?2), ('evt_c', 'invoice.payment_failed', ?1),
           ('evt_d', 'customer.subscription.updated', ?1)`,
      ).bind(nowMs - dayMs, nowMs - 40 * dayMs),
      env.DB.prepare(
        "INSERT INTO duplicate_subscriptions (stripe_subscription_id, user_id, stripe_customer_id, created_at) VALUES ('sub_dup', ?, 'cus_dup', ?)",
      ).bind(admin.userId, nowMs),
      env.DB.prepare("INSERT INTO trial_refusals (day, reason, count) VALUES (?1, 'device_used', 2), (?2, 'ip_daily_limit', 1), (?3, 'exhausted', 5)").bind(
        dayOf(nowMs, 0),
        dayOf(nowMs, -3),
        dayOf(nowMs, -40),
      ),
      env.DB.prepare(
        `INSERT INTO reports (id, kind, status, created_at, summary) VALUES
           (?1, 'feedback', 'open', ?5, 'a'), (?2, 'feedback', 'open', ?5, 'b'), (?3, 'crash', 'open', ?5, 'c'), (?4, 'contact', 'done', ?5, 'd')`,
      ).bind(randomId(), randomId(), randomId(), randomId(), nowMs),
    ]);

    const response: Response = await harness.call(req("GET", "/v1/admin/stats", { token: admin.accessToken, env: adminEnv, headers: { origin: siteOrigin } }));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("access-control-allow-origin")).toBe(siteOrigin);
    const stats: StatsBody = await response.json<StatsBody>();

    const days: string[] = Array.from({ length: 30 }, (_: unknown, index: number): string => dayOf(nowMs, index - 29));
    for (const series of [stats.downloads.last30Days, stats.users.newLast30Days, stats.meetings.last30Days, stats.spend.last30Days]) {
      expect(series.map((entry: { day: string }): string => entry.day)).toEqual(days);
    }
    expect(stats.generatedAt).toBe(new Date(nowMs).toISOString());
    expect(stats.downloads.total).toBe(14);
    expect(stats.downloads.last30Days[29]).toEqual({ day: days[29], count: 3 });
    expect(stats.downloads.last30Days[27]).toEqual({ day: days[27], count: 1 });
    expect(stats.downloads.last30Days[0]).toEqual({ day: days[0], count: 0 });
    expect(stats.users).toMatchObject({ total: 7, byProvider: { apple: 2, google: 1 } });
    expect(stats.users.newLast30Days.slice(28)).toEqual([
      { day: days[28], count: 1 },
      { day: days[29], count: 3 },
    ]);
    expect(stats.trials).toEqual({ activeTrialUsers: 1, exhaustedTrialUsers: 1 });
    // Yenilenecek: yalnızca yöneticinin yıllık aboneliği (aylık olan iptal edilmiş) → 49 / 12 = 4,08 $.
    expect(stats.subscriptions).toEqual({ active: 2, grace: 1, ending: 1, canceledTotal: 1, monthly: 0, yearly: 1, mrrUsd: 4.08, complimentary: 0 });
    expect(stats.referrals).toEqual({ joined: 0, pending: 0, granted: 0, voided: 0 });
    expect(stats.meetings.last30Days.slice(28)).toEqual([
      { day: days[28], trial: 3, subscription: 0 },
      { day: days[29], trial: 1, subscription: 1 },
    ]);
    expect(stats.meetings.hoursThisMonth).toBe(1.5);
    expect(stats.spend.todayUsd).toBe(1.25);
    expect(stats.spend.ceilingUsd).toBe(25);
    expect(stats.spend.trialTodayUsd).toBe(0.4);
    expect(stats.spend.trialCeilingUsd).toBe(10);
    expect(stats.spend.last30Days[24]).toEqual({ day: days[24], usd: 0.5 });
    expect(stats.tokens).toEqual({ thisMonth: 5_201_500 });
    expect(stats.reports).toEqual({ openFeedback: 2, openCrash: 1, openContact: 0 });
    expect(stats.stripe).toEqual({ mode: "test" });
    expect(stats.elevenLabs).toEqual({ cycleStart: "2026-10-11", usedHours: 11, capHours: 110, percent: 10 });
    expect(stats.conversion).toEqual({ trialStarted: 3, converted: 1, startedLast30Days: 2, convertedLast30Days: 0, subscribedWithoutTrial: 3 });
    expect(stats.churn).toEqual({ canceledLast30Days: 1, pastDue: 1, unpaid: 0, duplicateSubscriptions: 1 });
    expect(stats.billing).toEqual({ refundsLast30Days: 1, disputesLast30Days: 0, paymentFailuresLast30Days: 1 });
    expect(stats.usage).toEqual({
      meetingsThisMonth: 5,
      deferredThisMonth: 1,
      reprocessedThisMonth: 1,
      openMeetings: 2,
      audioHoursThisMonth: 2,
      accountTokensThisMonth: 300,
      monthlyTokenCapPerUser: 6_500_000,
      monthlyAccountTokenCapPerUser: 1_500_000,
      usersNearTokenCap: 1,
    });
    expect(stats.trialRefusals).toEqual({
      last30Days: { device_used: 2, exhausted: 0, expired: 0, ip_daily_limit: 1 },
      today: { device_used: 2, exhausted: 0, expired: 0, ip_daily_limit: 0 },
    });
  });

  it("yönetici olmayan düz 403 alır (gövdede kimlik yok); liste boşsa kimse yönetici değildir", async () => {
    const harness: Harness = await defaultHarness();
    const subject: string = `google-${randomId()}`;
    const user: Session = await signInWithGoogle(harness, subject);
    const body: ErrorBody = await expectError(await adminGet(harness, user, "/v1/admin/stats"), 403, "forbidden");
    expect(Object.keys(body.error).sort()).toEqual(["code", "message"]);
    expect(JSON.stringify(body)).not.toContain(subject);

    const apple: Session = await signIn(harness);
    const appleBody: ErrorBody = await expectError(await adminGet(harness, apple, "/v1/admin/reports"), 403, "forbidden");
    expect(Object.keys(appleBody.error).sort()).toEqual(["code", "message"]);
    // Kullanıcı ve işletim uçları da aynı yönetici denetiminden geçer (kendi kaydına bile erişemez).
    for (const path of ["/v1/admin/users", `/v1/admin/users/${apple.userId}`, "/v1/admin/operations"]) {
      await expectError(await adminGet(harness, apple, path), 403, "forbidden");
      await expectError(await harness.call(req("GET", path, { env: adminEnv })), 401, "unauthorized");
    }

    const admin: Session = await signInWithGoogle(harness, adminSubject);
    await expectError(await harness.call(req("GET", "/v1/admin/stats", { token: admin.accessToken })), 403, "forbidden");
    await expectError(await harness.call(req("GET", "/v1/admin/stats", {})), 401, "unauthorized");
  });

  it("Cloudflare Access AUD ayarlıysa yönetici uçları geçerli Access jetonu ister; boşsa denetim kapalı", async () => {
    const harness: Harness = await defaultHarness();
    const teamDomain: string = "dry-heart-1ee2.cloudflareaccess.com";
    const audience: string = "a".repeat(64);
    const accessEnv: Env = envWith({ ADMIN_IDENTITIES: `google:${adminSubject}`, CF_ACCESS_TEAM_DOMAIN: teamDomain, CF_ACCESS_AUD: audience });
    const { privateKey, publicKey } = await generateKeyPair("RS256", { extractable: true });
    const publicJwk: JWK = { ...(await exportJWK(publicKey)), kid: "access-key", alg: "RS256" };
    harness.stub(accessJwksUrl(teamDomain), async (): Promise<Response> => Response.json({ keys: [publicJwk], public_cert: {}, public_certs: [] }));
    const accessToken = (aud: string, issuer: string): Promise<string> =>
      new SignJWT({ email: "yonetici@ornek.test", type: "app" })
        .setProtectedHeader({ alg: "RS256", kid: "access-key" })
        .setIssuer(issuer)
        .setAudience([aud])
        .setSubject("access-sub")
        .setIssuedAt(Math.floor(harness.clock.nowMs / 1000))
        .setExpirationTime(Math.floor(harness.clock.nowMs / 1000) + 600)
        .sign(privateKey);
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const stats = (headers: Record<string, string>): Promise<Response> =>
      harness.call(req("GET", "/v1/admin/stats", { token: admin.accessToken, env: accessEnv, headers }));

    await expectError(await stats({}), 403, "forbidden");
    await expectError(await stats({ "cf-access-jwt-assertion": await accessToken("b".repeat(64), `https://${teamDomain}`) }), 403, "forbidden");
    await expectError(await stats({ "cf-access-jwt-assertion": await accessToken(audience, "https://baska.cloudflareaccess.com") }), 403, "forbidden");
    expect((await stats({ "cf-access-jwt-assertion": await accessToken(audience, `https://${teamDomain}`) })).status).toBe(200);
    // Access'ten geçse de yönetici olmayan reddedilir.
    const user: Session = await signInWithGoogle(harness, `google-${randomId()}`);
    const userStats: Response = await harness.call(
      req("GET", "/v1/admin/stats", { token: user.accessToken, env: accessEnv, headers: { "cf-access-jwt-assertion": await accessToken(audience, `https://${teamDomain}`) } }),
    );
    await expectError(userStats, 403, "forbidden");
    // AUD boşsa (varsayılan) jetonsuz istek yalnızca yönetici listesiyle denetlenir.
    expect((await harness.call(req("GET", "/v1/admin/stats", { token: admin.accessToken, env: adminEnv }))).status).toBe(200);
  });

  it("CORS yalnızca site kaynağına açıktır", async () => {
    const harness: Harness = await defaultHarness();
    const preflight: Response = await harness.call(req("OPTIONS", "/v1/admin/reports/00000000-0000-0000-0000-000000000000", { headers: { origin: siteOrigin } }));
    expect(preflight.status).toBe(204);
    await expectError(await harness.call(req("OPTIONS", "/v1/admin/stats", { headers: { origin: "https://evil.example" } })), 403, "forbidden");
  });

  it("rapor listesi, süzgeçler, sayfalama (aynı milisaniye bölünmez), ayrıntı ve durum değiştirme", async () => {
    const harness: Harness = await defaultHarness();
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    await env.DB.prepare("DELETE FROM reports").run();
    const base: number = harness.clock.nowMs;
    // 55 rapor: en yeni 49'u farklı anlarda, 50. ve 51. aynı milisaniyede (sayfa sınırı).
    const statements: D1PreparedStatement[] = [];
    for (let index: number = 0; index < 55; index += 1) {
      const createdAt: number = index === 50 ? base - 49_000 : base - index * 1000;
      const kind: string = index % 5 === 0 ? "crash" : "feedback";
      statements.push(
        env.DB.prepare(
          `INSERT INTO reports (id, kind, status, created_at, user_id, email, app_version, os, message, payload, summary)
           VALUES (?, ?, 'open', ?, NULL, ?, '1.2.0', 'macOS 26.1', ?, ?, ?)`,
        ).bind(randomId(), kind, createdAt, index === 0 ? "kisi@ornek.test" : null, `ileti ${index}`, kind === "crash" ? "{}" : null, `özet ${index}`),
      );
    }
    await env.DB.batch(statements);

    const first: ListBody = await (await adminGet(harness, admin, "/v1/admin/reports")).json<ListBody>();
    expect(first.items).toHaveLength(49);
    expect(first.nextBefore).toBe(base - 49_000 + 1);
    expect(first.items[0]).toEqual({
      id: first.items[0]?.id,
      kind: "crash",
      status: "open",
      createdAt: new Date(base).toISOString(),
      userId: null,
      email: "kisi@ornek.test",
      appVersion: "1.2.0",
      os: "macOS 26.1",
      summary: "özet 0",
    });
    const second: ListBody = await (await adminGet(harness, admin, `/v1/admin/reports?kind=&status=&before=${first.nextBefore}`)).json<ListBody>();
    expect(second.items).toHaveLength(6);
    expect(second.nextBefore).toBeNull();
    const all: Set<string> = new Set([...first.items, ...second.items].map((item: { id: string }): string => item.id));
    expect(all.size).toBe(55);

    const crashes: ListBody = await (await adminGet(harness, admin, "/v1/admin/reports?kind=crash")).json<ListBody>();
    expect(crashes.items).toHaveLength(11);
    expect(crashes.items.every((item: { kind: string }): boolean => item.kind === "crash")).toBe(true);

    const target: string = crashes.items[0]?.id ?? "";
    const detail: Response = await adminGet(harness, admin, `/v1/admin/reports/${target}`);
    expect(await detail.json()).toEqual({
      id: target,
      kind: "crash",
      status: "open",
      createdAt: new Date(base).toISOString(),
      userId: null,
      email: "kisi@ornek.test",
      appVersion: "1.2.0",
      os: "macOS 26.1",
      message: "ileti 0",
      payload: "{}",
    });

    const update = (status: string): Promise<Response> =>
      harness.call(req("POST", `/v1/admin/reports/${target}`, { token: admin.accessToken, env: adminEnv, json: { status } }));
    const done: Response = await update("done");
    expect(done.status).toBe(204);
    expect((await update("done")).status).toBe(204);
    await expectError(await update("kapalı"), 400, "invalid_body");
    const doneList: ListBody = await (await adminGet(harness, admin, "/v1/admin/reports?status=done")).json<ListBody>();
    expect(doneList.items.map((item: { id: string }): string => item.id)).toEqual([target]);

    const missing: string = randomId();
    await expectError(await adminGet(harness, admin, `/v1/admin/reports/${missing}`), 404, "not_found");
    await expectError(
      await harness.call(req("POST", `/v1/admin/reports/${missing}`, { token: admin.accessToken, env: adminEnv, json: { status: "done" } })),
      404,
      "not_found",
    );
    await expectError(await adminGet(harness, admin, "/v1/admin/reports?kind=bug"), 400, "invalid_body");
    await expectError(await adminGet(harness, admin, "/v1/admin/reports?sayfa=2"), 400, "invalid_body");
    await expectError(await adminGet(harness, admin, "/v1/admin/reports?before=-5"), 400, "invalid_body");
    await expectError(await adminGet(harness, admin, "/v1/admin/yok"), 404, "not_found");
  });

  it("kullanıcı listesi: biçim, süzgeçler ve imleçli sayfalama; sağlayıcı kimliği dönmez", async () => {
    const harness: Harness = await defaultHarness();
    const nowMs: number = harness.clock.nowMs;
    const iso = (ms: number): string => new Date(ms).toISOString();
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const subject: string = `google-${randomId()}`;
    const subscriber: Session = await signInWithGoogle(harness, subject);
    await grantSubscription(subscriber.userId, "active", nowMs + 20 * dayMs);
    expect((await startMeeting(harness, subscriber)).status).toBe(201);
    const trialUser: Session = await signIn(harness);
    expect((await startMeeting(harness, trialUser)).status).toBe(201);
    // 60 boş hesap; üçer üçer aynı milisaniyede: imleç (`created_at`, `id`) sayfa sınırında bölmez.
    await env.DB.batch(
      Array.from({ length: 60 }, (_: unknown, index: number): D1PreparedStatement =>
        env.DB.prepare("INSERT INTO users (id, created_at) VALUES (?, ?)").bind(randomId(), nowMs - 10 * dayMs - Math.floor(index / 3)),
      ),
    );

    const total: number = (await env.DB.prepare("SELECT COUNT(*) AS count FROM users").first<{ count: number }>())?.count ?? 0;
    const seen: string[] = [];
    let cursor: string | null = "";
    let pages: number = 0;
    while (cursor !== null) {
      const page: UserPageBody = await (await adminGet(harness, admin, `/v1/admin/users?cursor=${encodeURIComponent(cursor)}`)).json<UserPageBody>();
      expect(page.items.length).toBeLessThanOrEqual(50);
      seen.push(...page.items.map((item: UserItemBody): string => item.id));
      cursor = page.nextCursor;
      pages += 1;
    }
    expect(seen).toHaveLength(total);
    expect(new Set(seen).size).toBe(total);
    expect(pages).toBe(Math.ceil(total / 50));

    // Kimlik öneki büyük harfle de aranır; öğenin tüm alanları.
    const prefix: string = subscriber.userId.slice(0, 8);
    const found: UserPageBody = await (await adminGet(harness, admin, `/v1/admin/users?q=${prefix.toUpperCase()}`)).json<UserPageBody>();
    expect(found.items.every((item: UserItemBody): boolean => item.id.startsWith(prefix))).toBe(true);
    expect(found.items.find((item: UserItemBody): boolean => item.id === subscriber.userId)).toEqual({
      id: subscriber.userId,
      provider: "google",
      createdAt: iso(nowMs),
      plan: "subscription",
      subscription: {
        status: "active",
        access: "active",
        currentPeriodEnd: iso(nowMs + 20 * dayMs),
        cancelAt: null,
        pastDueSince: null,
        graceEndsAt: null,
        plan: "monthly",
        complimentary: false,
        updatedAt: iso(0),
      },
      trial: { used: 0, left: 3, startedAt: null, endsAt: null },
      meetingsTotal: 1,
      hoursThisMonth: 0,
      lastActiveAt: iso(nowMs),
      failedMeetings: 0,
      lastFailureCode: null,
    });
    expect(JSON.stringify(found)).not.toContain(subject);

    const segment = async (query: string): Promise<UserItemBody[]> => (await (await adminGet(harness, admin, `/v1/admin/users?${query}`)).json<UserPageBody>()).items;
    const subscribed: UserItemBody[] = await segment("segment=subscribed");
    expect(subscribed.map((item: UserItemBody): string => item.id)).toContain(subscriber.userId);
    expect(subscribed.every((item: UserItemBody): boolean => item.plan === "subscription")).toBe(true);
    const trials: UserItemBody[] = await segment("segment=trial");
    expect(trials.find((item: UserItemBody): boolean => item.id === trialUser.userId)).toMatchObject({
      provider: "apple",
      plan: "trial",
      subscription: null,
      trial: { used: 1, left: 2, startedAt: iso(nowMs), endsAt: iso(nowMs + 7 * dayMs) },
    });
    expect(trials.every((item: UserItemBody): boolean => item.plan === "trial")).toBe(true);
    const free: UserItemBody[] = await segment("segment=free");
    expect(free.length).toBeGreaterThan(0);
    expect(free.every((item: UserItemBody): boolean => item.plan === "free" && item.subscription === null && item.trial.used === 0)).toBe(true);
    const google: UserItemBody[] = await segment("provider=google");
    expect(google.every((item: UserItemBody): boolean => item.provider === "google")).toBe(true);
    expect(google.map((item: UserItemBody): string => item.id)).not.toContain(trialUser.userId);

    for (const query of ["segment=vip", "q=abc%21", "cursor=abc", "provider=email", "sayfa=2"]) {
      await expectError(await adminGet(harness, admin, `/v1/admin/users?${query}`), 400, "invalid_body");
    }
  });

  it("kullanıcı ayrıntısı: toplantılar, bu ayın kullanımı, raporlar ve zaman çizelgesi; bilinmeyen kullanıcı 404", async () => {
    const harness: Harness = await defaultHarness();
    const nowMs: number = harness.clock.nowMs;
    const iso = (ms: number): string => new Date(ms).toISOString();
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const subject: string = `google-${randomId()}`;
    const user: Session = await signInWithGoogle(harness, subject);
    await grantSubscription(user.userId, "active", nowMs + 20 * dayMs);
    expect((await startMeeting(harness, user)).status).toBe(201);
    const ended: string = randomId();
    const expired: string = randomId();
    const reportId: string = randomId();
    await env.DB.batch([
      env.DB.prepare("UPDATE subscriptions SET cancel_at = ?, updated_at = ? WHERE user_id = ?").bind(nowMs + 19 * dayMs, nowMs - dayMs, user.userId),
      // Dün: 45 dakika, sonradan işlenmiş, bir kez yeniden işlenmiş. Önceki gün: bitirilmeden 90 dakikası dolmuş.
      env.DB.prepare(
        `INSERT INTO meeting_sessions (id, user_id, kind, started_at, max_ends_at, ended_at, end_reason, token_budget, tokens_used,
           audio_seconds, deferred, reprocess_count)
         VALUES (?1, ?3, 'subscription', ?4, ?5, ?6, 'ended', 1000, 400, 2700, 1, 1),
                (?2, ?3, 'subscription', ?7, ?8, NULL, NULL, 1000, 0, 0, 0, 0)`,
      ).bind(
        ended,
        expired,
        user.userId,
        nowMs - dayMs,
        nowMs - dayMs + 240 * 60_000,
        nowMs - dayMs + 45 * 60_000,
        nowMs - 2 * dayMs,
        nowMs - 2 * dayMs + 90 * 60_000,
      ),
      env.DB.prepare(
        "INSERT INTO monthly_usage (user_id, month, audio_seconds, input_tokens, output_tokens, account_tokens) VALUES (?, ?, 2700, 4000, 1000, 700)",
      ).bind(user.userId, dayOf(nowMs, 0).slice(0, 7)),
      env.DB.prepare("INSERT INTO reports (id, kind, status, created_at, user_id, message, summary) VALUES (?, 'feedback', 'open', ?, ?, 'ileti', 'özet')").bind(
        reportId,
        nowMs - 3_600_000,
        user.userId,
      ),
    ]);
    const customer = await env.DB.prepare("SELECT stripe_customer_id FROM stripe_customers WHERE user_id = ?").bind(user.userId).first<{ stripe_customer_id: string }>();

    const response: Response = await adminGet(harness, admin, `/v1/admin/users/${user.userId}`);
    expect(response.status).toBe(200);
    const detail: UserDetailBody = await response.json<UserDetailBody>();
    expect(detail.user).toMatchObject({ id: user.userId, plan: "subscription", meetingsTotal: 3, hoursThisMonth: 2.25, lastActiveAt: iso(nowMs) });
    expect(detail.user.subscription).toMatchObject({ status: "active", access: "active", cancelAt: iso(nowMs + 19 * dayMs), updatedAt: iso(nowMs - dayMs) });
    expect(detail.trialDeviceVerifiedAt).toBeNull();
    expect(detail.stripeCustomerId).toBe(customer?.stripe_customer_id);
    expect(detail.usage).toEqual({ usedHours: 2.25, capHours: 10, audioHours: 0.75, tokens: 5000, tokenCap: 6_500_000, accountTokens: 700, accountTokenCap: 1_500_000 });
    expect(
      detail.meetings.map((meeting: MeetingItemBody): Array<string | number | boolean> => [
        meeting.state,
        meeting.durationMinutes,
        meeting.deferred,
        meeting.reprocessCount,
        meeting.audioMinutes,
      ]),
    ).toEqual([
      ["open", 0, false, 0, 0],
      ["ended", 45, true, 1, 45],
      ["expired", 90, false, 0, 0],
    ]);
    expect(detail.meetings.slice(1).map((meeting: MeetingItemBody): string => meeting.id)).toEqual([ended, expired]);
    expect(detail.reports).toEqual([{ id: reportId, kind: "feedback", status: "open", createdAt: iso(nowMs - 3_600_000), summary: "özet" }]);
    expect(detail.timeline).toEqual([
      { kind: "subscription_period_end", at: iso(nowMs + 20 * dayMs), detail: "active" },
      { kind: "subscription_cancel_at", at: iso(nowMs + 19 * dayMs), detail: null },
      { kind: "account_created", at: iso(nowMs), detail: null },
      { kind: "subscription_updated", at: iso(nowMs - dayMs), detail: "active" },
    ]);
    // Sağlayıcı kimliği ve rapor içeriği ayrıntıda yoktur.
    const text: string = JSON.stringify(detail);
    expect(text).not.toContain(subject);
    expect(text).not.toContain("ileti");

    await expectError(await adminGet(harness, admin, `/v1/admin/users/${randomId()}`), 404, "not_found");
    await expectError(await adminGet(harness, admin, "/v1/admin/users/kisa"), 404, "not_found");
  });

  it("içgörüler: sorunlar, huni, indirme kaynakları ve iptal nedenleri; bırakma kesimleri ve toplantı hataları", async () => {
    const harness: Harness = await defaultHarness();
    // Önceki testlerin hesapları ve sayaçları pencerelerin dışında kalsın.
    harness.clock.nowMs += 500 * dayMs;
    const nowMs: number = harness.clock.nowMs;
    const iso = (ms: number): string => new Date(ms).toISOString();
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    // Kohort (son 30 gün): toplantısız, notlu ama hatalı tek toplantılı ve 3 toplantılı iptal etmiş abone. Kohort dışı:
    // denemesi bitmiş (süre doldu), abone olmamış hesap.
    const idle: string = await insertUser(nowMs - dayMs);
    const noted: string = await insertUser(nowMs - 2 * dayMs);
    const subscriber: string = await insertUser(nowMs - 25 * dayMs);
    const trialEnded: string = await insertUser(nowMs - 60 * dayMs);
    const notedMeeting: string = randomId();
    await env.DB.batch([
      env.DB.prepare("UPDATE users SET trial_started_at = ? WHERE id = ?").bind(nowMs - 60 * dayMs, trialEnded),
      env.DB.prepare("UPDATE users SET trial_started_at = ? WHERE id = ?").bind(nowMs - 2 * dayMs, noted),
      env.DB.prepare(
        `INSERT INTO meeting_sessions (id, user_id, kind, started_at, max_ends_at, ended_at, end_reason, token_budget, first_note_at,
           failure_count, last_failure_code, last_failure_at)
         VALUES (?1, ?2, 'trial', ?3, ?4, ?4, 'ended', 1, ?4, 2, 'upstream_rejected:elevenlabs', ?4)`,
      ).bind(notedMeeting, noted, nowMs - 2 * dayMs, nowMs - 2 * dayMs + 30 * 60_000),
      env.DB.prepare(
        `INSERT INTO meeting_sessions (id, user_id, kind, started_at, max_ends_at, ended_at, end_reason, token_budget) VALUES
           (?1, ?4, 'subscription', ?5, ?5, ?5, 'ended', 1), (?2, ?4, 'subscription', ?6, ?6, ?6, 'ended', 1),
           (?3, ?4, 'subscription', ?7, ?7, ?7, 'ended', 1), (?8, ?9, 'trial', ?10, ?10, ?10, 'ended', 1)`,
      ).bind(randomId(), randomId(), randomId(), subscriber, nowMs - 24 * dayMs, nowMs - 23 * dayMs, nowMs - 22 * dayMs, randomId(), trialEnded, nowMs - 60 * dayMs),
      env.DB.prepare(
        `INSERT INTO subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, current_period_end, cancel_at, last_event_created, updated_at)
         VALUES (?, 'cus_insight', 'sub_insight', 'canceled', ?, NULL, 1, ?)`,
      ).bind(subscriber, nowMs - dayMs, nowMs - dayMs),
      env.DB.prepare(
        `INSERT INTO subscription_cancellations (stripe_subscription_id, user_id, created_at, event_created, reason, feedback, comment)
         VALUES ('sub_insight', ?, ?, 1, 'cancellation_requested', 'too_expensive', 'Pahalı')`,
      ).bind(subscriber, nowMs - dayMs),
      env.DB.prepare(
        `INSERT INTO ops_events (day, kind, detail, count) VALUES
           (?1, 'refusal', 'trial_capacity_reached', 4), (?1, 'provider_error', 'elevenlabs', 2), (?1, 'server_error', 'internal_error', 1),
           (?2, 'refusal', 'spend_ceiling_reached', 3), (?2, 'refusal', 'trial_capacity_reached', 1), (?2, 'server_error', 'spend_ceiling_reached', 3)`,
      ).bind(dayOf(nowMs, 0), dayOf(nowMs, -10)),
    ]);

    // İndirmeler: aynı ağdan ikinci indirme sayılmaz; kaynak izin listesinden, Referer'dan yalnızca alan adı.
    const download = async (query: string, ip: string, referer: string | null): Promise<void> => {
      const headers: Record<string, string> = referer === null ? {} : { referer };
      const response: Response = await harness.call(req("GET", `/v1/download/mac${query}`, { clientIp: ip, headers }));
      expect(response.status).toBe(302);
    };
    await download("?src=home-hero", "203.0.113.7", "https://www.producthunt.com/posts/gistsmith?ref=abc");
    await download("?src=home-hero", "203.0.113.7", "https://www.producthunt.com/posts/gistsmith?ref=abc");
    await download("?src=../../etc", "203.0.113.8", null);
    await download("", "2001:db8::1", "javascript:alert(1)");
    const visitors = await env.DB.prepare("SELECT visitor_hash FROM download_visitors WHERE day = ?").bind(dayOf(nowMs, 0)).all<{ visitor_hash: string }>();
    expect(visitors.results).toHaveLength(3);
    expect(JSON.stringify(visitors.results)).not.toContain("203.0.113");

    const response: Response = await adminGet(harness, admin, "/v1/admin/insights");
    expect(response.status).toBe(200);
    const insights = await response.json<InsightsBody>();
    expect(insights.generatedAt).toBe(iso(nowMs));
    expect(insights.problems.last7Days).toEqual({
      trialCapacityReached: 4,
      spendCeilingReached: 0,
      refusals: [{ detail: "trial_capacity_reached", count: 4 }],
      providerErrors: [{ detail: "elevenlabs", count: 2 }],
      serverErrors: [{ detail: "internal_error", count: 1 }],
      serverErrorsTotal: 1,
    });
    expect(insights.problems.last30Days).toMatchObject({ trialCapacityReached: 5, spendCeilingReached: 3, serverErrorsTotal: 4 });
    expect(insights.funnel).toEqual({
      days: 30,
      steps: [
        { step: "downloads", count: 3 },
        { step: "accounts", count: 3 },
        { step: "first_meeting", count: 2 },
        { step: "first_note", count: 1 },
        { step: "three_meetings", count: 1 },
        { step: "subscribed", count: 1 },
        { step: "canceled", count: 1 },
      ],
    });
    expect(insights.downloads).toEqual({
      total: 3,
      bySource: [
        { detail: "direct", count: 1 },
        { detail: "home-hero", count: 1 },
        { detail: "other", count: 1 },
      ],
      byReferrerHost: [
        { detail: "", count: 1 },
        { detail: "other", count: 1 },
        { detail: "producthunt.com", count: 1 },
      ],
    });
    expect(insights.cancellations).toEqual({
      total: 1,
      byFeedback: [{ detail: "too_expensive", count: 1 }],
      byReason: [{ detail: "cancellation_requested", count: 1 }],
      recent: [{ userId: subscriber, at: iso(nowMs - dayMs), reason: "cancellation_requested", feedback: "too_expensive", comment: "Pahalı" }],
    });

    // Bırakma kesimleri.
    const segment = async (name: string): Promise<string[]> =>
      (await (await adminGet(harness, admin, `/v1/admin/users?segment=${name}`)).json<UserPageBody>()).items.map((item: UserItemBody): string => item.id);
    expect(await segment("no_meeting")).toContain(idle);
    expect(await segment("no_meeting")).not.toContain(noted);
    expect(await segment("trial_ended")).toContain(trialEnded);
    expect(await segment("trial_ended")).not.toContain(noted);
    expect(await segment("trial_ended")).not.toContain(subscriber);
    const inactive: string[] = await segment("inactive");
    expect(inactive).toEqual(expect.arrayContaining([subscriber, trialEnded]));
    expect(inactive).not.toContain(noted);
    expect(inactive).not.toContain(idle);
    expect(await segment("failed")).toEqual([noted]);

    // Kullanıcı başına "ne ters gitti": listede hatalı toplantı sayısı ve son kod, ayrıntıda toplantının hatası ve not durumu.
    const failedUser: UserItemBody | undefined = (await (await adminGet(harness, admin, "/v1/admin/users?segment=failed")).json<UserPageBody>()).items[0];
    expect(failedUser).toMatchObject({ failedMeetings: 1, lastFailureCode: "upstream_rejected:elevenlabs" });
    const detail = await (await adminGet(harness, admin, `/v1/admin/users/${noted}`)).json<UserDetailBody>();
    expect(detail.meetings[0]).toMatchObject({
      id: notedMeeting,
      noteCompleted: true,
      failureCount: 2,
      lastFailureCode: "upstream_rejected:elevenlabs",
      lastFailureAt: iso(nowMs - 2 * dayMs + 30 * 60_000),
    });
    expect(detail.cancellation).toBeNull();
    const canceled = await (await adminGet(harness, admin, `/v1/admin/users/${subscriber}`)).json<UserDetailBody>();
    expect(canceled.cancellation).toEqual({ at: iso(nowMs - dayMs), reason: "cancellation_requested", feedback: "too_expensive", comment: "Pahalı" });
  });

  it("işletim görünümü: açık ve bitirilmemiş toplantılar, takılı ayırmalar, Deepgram tahminleri, Stripe olayları ve son çökmeler", async () => {
    const harness: Harness = await defaultHarness();
    const nowMs: number = harness.clock.nowMs;
    const iso = (ms: number): string => new Date(ms).toISOString();
    const hourMs: number = 3_600_000;
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    // Önceki testlerin satırları sayıları etkilemesin.
    await env.DB.batch([
      env.DB.prepare("DELETE FROM meeting_sessions"),
      env.DB.prepare("DELETE FROM usage_reservations"),
      env.DB.prepare("DELETE FROM deepgram_live_meetings"),
      env.DB.prepare("DELETE FROM stripe_events"),
      env.DB.prepare("DELETE FROM reports"),
    ]);
    const userId: string = await insertUser(nowMs - dayMs);
    const open: string = randomId();
    const crash: string = randomId();
    const month: string = dayOf(nowMs, 0).slice(0, 7);
    await env.DB.batch([
      // Açık (10 dk önce), bitirilmeden süresi dolmuş (2 gün önce), pencere dışında kalan (10 gün önce) ve bitmiş toplantı.
      env.DB.prepare(
        `INSERT INTO meeting_sessions (id, user_id, kind, started_at, max_ends_at, ended_at, token_budget) VALUES
           (?1, ?2, 'subscription', ?3, ?4, NULL, 1),
           (?5, ?2, 'trial', ?6, ?7, NULL, 1),
           (?8, ?2, 'trial', ?9, ?10, NULL, 1),
           (?11, ?2, 'trial', ?6, ?7, ?7, 1)`,
      ).bind(
        open,
        userId,
        nowMs - 10 * 60_000,
        nowMs + 80 * 60_000,
        randomId(),
        nowMs - 2 * dayMs,
        nowMs - 2 * dayMs + 90 * 60_000,
        randomId(),
        nowMs - 10 * dayMs,
        nowMs - 10 * dayMs + 90 * 60_000,
        randomId(),
      ),
      env.DB.prepare(
        `INSERT INTO deepgram_live_meetings (meeting_id, grants, first_grant_at, charged_seconds, settled_at)
         VALUES (?1, 1, ?2, 600, NULL), (?3, 1, ?4, 600, NULL), (?5, 1, ?4, 60, ?2)`,
      ).bind(open, nowMs - 10 * 60_000, randomId(), nowMs - 2 * dayMs, randomId()),
      env.DB.prepare(
        `INSERT INTO usage_reservations (id, user_id, meeting_id, kind, month, day, tokens, trial_account_tokens, account_tokens, audio_seconds,
           estimated_micro_usd, trial_spend, created_at, expires_at)
         VALUES (?1, ?4, NULL, 'llm', ?5, ?6, 10, 0, 0, 0, 1, 0, ?7, ?8), (?2, ?4, NULL, 'llm', ?5, ?6, 10, 0, 0, 0, 1, 0, ?7, ?9),
                (?3, ?4, NULL, 'llm', ?5, ?6, 10, 0, 0, 0, 1, 0, ?7, ?10)`,
      ).bind(randomId(), randomId(), randomId(), userId, month, dayOf(nowMs, 0), nowMs - 3 * dayMs, nowMs + 10 * 60_000, nowMs - 2 * hourMs, nowMs - 2 * dayMs),
      env.DB.prepare(
        `INSERT INTO stripe_events (id, type, processed_at) VALUES
           ('evt_1', 'invoice.paid', ?1), ('evt_2', 'invoice.paid', ?2), ('evt_3', 'customer.subscription.updated', ?3), ('evt_4', 'charge.refunded', ?4)`,
      ).bind(nowMs - hourMs, nowMs - 3 * dayMs, nowMs - 2 * dayMs, nowMs - 10 * dayMs),
      env.DB.prepare(
        `INSERT INTO reports (id, kind, status, created_at, app_version, os, summary) VALUES
           (?1, 'crash', 'open', ?3, '0.1.4', 'macOS 26.1', 'EXC_BAD_ACCESS · SIGSEGV'), (?2, 'crash', 'done', ?4, NULL, NULL, 'eski'),
           (?5, 'feedback', 'open', ?6, NULL, NULL, 'f'), (?7, 'contact', 'open', ?8, NULL, NULL, 'c')`,
      ).bind(crash, randomId(), nowMs - hourMs, nowMs - 9 * dayMs, randomId(), nowMs - dayMs, randomId(), nowMs - 2 * dayMs),
    ]);

    const response: Response = await adminGet(harness, admin, "/v1/admin/operations");
    expect(response.status).toBe(200);
    const ops: OperationsBody = await response.json<OperationsBody>();
    expect(ops.generatedAt).toBe(iso(nowMs));
    expect(ops.meetings).toEqual({
      open: 1,
      openItems: [{ id: open, userId, kind: "subscription", startedAt: iso(nowMs - 10 * 60_000), maxEndsAt: iso(nowMs + 80 * 60_000), deferred: false, deepgram: true }],
      unendedLast7Days: 1,
    });
    expect(ops.reservations).toEqual({ active: 1, expired: 2, oldestExpiredAt: iso(nowMs - 2 * dayMs) });
    expect(ops.deepgram).toEqual({ unsettled: 2, stale: 1 });
    expect(ops.stripe).toEqual({
      lastEventAt: iso(nowMs - hourMs),
      eventsLast24Hours: 1,
      last7DaysByType: [
        { type: "invoice.paid", count: 2 },
        { type: "customer.subscription.updated", count: 1 },
      ],
    });
    expect(ops.reports.last7Days).toEqual({ feedback: 1, crash: 1, contact: 1 });
    expect(ops.reports.recentCrashes).toHaveLength(2);
    expect(ops.reports.recentCrashes[0]).toEqual({
      id: crash,
      status: "open",
      createdAt: iso(nowMs - hourMs),
      appVersion: "0.1.4",
      os: "macOS 26.1",
      summary: "EXC_BAD_ACCESS · SIGSEGV",
    });
  });
});
