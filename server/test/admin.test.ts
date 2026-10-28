import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
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
  readonly subscriptions: { active: number; grace: number; ending: number; canceledTotal: number; mrrUsd: number };
  readonly meetings: { last30Days: Array<{ day: string; trial: number; subscription: number }>; hoursThisMonth: number };
  readonly spend: { todayUsd: number; ceilingUsd: number; last30Days: Array<{ day: string; usd: number }> };
  readonly tokens: { thisMonth: number };
  readonly reports: { openFeedback: number; openCrash: number; openContact: number };
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
    await grantSubscription(ending, "active", nowMs + 10 * dayMs);
    await env.DB.prepare("UPDATE subscriptions SET cancel_at = ? WHERE user_id = ?").bind(nowMs + 10 * dayMs, ending).run();
    await grantSubscription(grace, "past_due", nowMs - dayMs);
    await grantSubscription(canceled, "canceled", nowMs - 5 * dayMs);

    // Toplantılar: bugün bir deneme ve bir abonelik toplantısı; dün denemesi biten kullanıcının üç 30 dakikalık toplantısı.
    expect((await startMeeting(harness, trialUser)).status).toBe(201);
    expect((await startMeeting(harness, admin)).status).toBe(201);
    for (let index: number = 0; index < 3; index += 1) {
      const startedAt: number = nowMs - dayMs + index * 3_600_000;
      await env.DB.prepare(
        `INSERT INTO meeting_sessions (id, user_id, kind, started_at, max_ends_at, ended_at, token_budget)
         VALUES (?, ?, 'trial', ?, ?, ?, 1)`,
      )
        .bind(randomId(), exhaustedUser.userId, startedAt, startedAt + 90 * 60_000, startedAt + 30 * 60_000)
        .run();
    }

    const month: string = dayOf(nowMs, 0).slice(0, 7);
    await env.DB.batch([
      env.DB.prepare("INSERT INTO downloads (day, count) VALUES (?, 3), (?, 1), (?, 10)").bind(dayOf(nowMs, 0), dayOf(nowMs, -2), dayOf(nowMs, -40)),
      env.DB.prepare("INSERT INTO daily_spend (day, micro_usd) VALUES (?, 1250000), (?, 500000)").bind(dayOf(nowMs, 0), dayOf(nowMs, -5)),
      env.DB.prepare("INSERT INTO monthly_usage (user_id, month, input_tokens, output_tokens) VALUES (?, ?, 1000, 500), (?, '2026-09', 999, 0)").bind(
        admin.userId,
        month,
        trialUser.userId,
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
    expect(stats.subscriptions).toEqual({ active: 2, grace: 1, ending: 1, canceledTotal: 1, mrrUsd: 5.99 });
    expect(stats.meetings.last30Days.slice(28)).toEqual([
      { day: days[28], trial: 3, subscription: 0 },
      { day: days[29], trial: 1, subscription: 1 },
    ]);
    expect(stats.meetings.hoursThisMonth).toBe(1.5);
    expect(stats.spend.todayUsd).toBe(1.25);
    expect(stats.spend.ceilingUsd).toBe(25);
    expect(stats.spend.last30Days[24]).toEqual({ day: days[24], usd: 0.5 });
    expect(stats.tokens).toEqual({ thisMonth: 1500 });
    expect(stats.reports).toEqual({ openFeedback: 2, openCrash: 1, openContact: 0 });
  });

  it("yönetici olmayan 403 alır; gövdede kendi kimliği vardır; liste boşsa kimse yönetici değildir", async () => {
    const harness: Harness = await defaultHarness();
    const subject: string = `google-${randomId()}`;
    const user: Session = await signInWithGoogle(harness, subject);
    const body: ErrorBody & { error: { identity?: string } } = await expectError(await adminGet(harness, user, "/v1/admin/stats"), 403, "forbidden");
    expect(body.error.identity).toBe(`google:${subject}`);

    const apple: Session = await signIn(harness);
    const appleBody: ErrorBody & { error: { identity?: string } } = await expectError(await adminGet(harness, apple, "/v1/admin/reports"), 403, "forbidden");
    expect(appleBody.error.identity).toMatch(/^apple:apple-/);

    // Birden çok kimlik virgülle döner.
    await env.DB.prepare("INSERT INTO auth_identities (provider, subject, user_id, created_at) VALUES ('apple', 'ikinci', ?, 0)").bind(user.userId).run();
    const both: ErrorBody & { error: { identity?: string } } = await expectError(await adminGet(harness, user, "/v1/admin/stats"), 403, "forbidden");
    expect(both.error.identity).toBe(`apple:ikinci,google:${subject}`);

    const admin: Session = await signInWithGoogle(harness, adminSubject);
    await expectError(await harness.call(req("GET", "/v1/admin/stats", { token: admin.accessToken })), 403, "forbidden");
    await expectError(await harness.call(req("GET", "/v1/admin/stats", {})), 401, "unauthorized");
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
});
