import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { parseConfig } from "../src/config";
import { deepgramGrantUrl, deepgramGrantWindowMs, deepgramGrantsPerWindow, deepgramTrialGrantsPerMeeting, deepgramUsage } from "../src/deepgram";
import type { Env } from "../src/env";
import {
  type Harness,
  type Session,
  type StartedMeetingBody,
  defaultHarness,
  envWith,
  expectError,
  refreshed,
  req,
  signIn,
  startMeeting,
} from "./helpers";

/** Her isteğe izin veren hız sınırlayıcı (jeton sınırı testinde kullanıcı hız sınırı araya girmesin). */
const allowingLimiter: RateLimit = {
  limit: async (): Promise<RateLimitOutcome> => ({ success: true }),
};

/** Deepgram açık; sahte anahtar. */
const deepgramOn: Env = envWith({ DEEPGRAM_POLICY: "on", DEEPGRAM_API_KEY: "test-deepgram-key-000000", DEEPGRAM_USER_LIMITER: allowingLimiter });

/** Deepgram açık, bütçe 0,01 $ (0,0092 $/dk → 65 akış saniyesi). */
const tinyBudget: Env = envWith({ ...deepgramOn, DEEPGRAM_BUDGET_USD: "0.01" });

/** `POST /v1/live/deepgram-token` yanıtı. */
interface GrantBody {
  readonly accessToken: string;
  readonly expiresIn: number;
  readonly model: string;
  readonly mipOptOut: boolean;
  readonly grantsLeft: number;
}

/** Deepgram jeton ucunu sahte JWT'yle bağlar; gelen istekleri döndürür. */
function stubGrant(harness: Harness): Request[] {
  const requests: Request[] = [];
  harness.stub(deepgramGrantUrl, async (request: Request): Promise<Response> => {
    requests.push(request.clone());
    return Response.json({ access_token: "eyJ.sahte.jwt", expires_in: 30 });
  });
  return requests;
}

function tokenRequest(harness: Harness, session: Session, meetingId: string, testEnv: Env): Promise<Response> {
  return harness.call(req("POST", "/v1/live/deepgram-token", { token: session.accessToken, headers: { "x-meeting-id": meetingId }, env: testEnv }));
}

async function liveEngineOf(harness: Harness, session: Session, testEnv: Env): Promise<string> {
  const response: Response = await harness.call(req("GET", "/v1/me", { token: session.accessToken, env: testEnv }));
  expect(response.status).toBe(200);
  return (await response.json<{ liveEngine: string }>()).liveEngine;
}

async function openMeeting(harness: Harness, session: Session): Promise<string> {
  const response: Response = await startMeeting(harness, session);
  expect(response.status).toBe(201);
  return (await response.json<StartedMeetingBody>()).meetingId;
}

async function chargedSecondsOf(meetingId: string): Promise<{ charged_seconds: number; grants: number; settled_at: number | null } | null> {
  return env.DB.prepare("SELECT charged_seconds, grants, settled_at FROM deepgram_live_meetings WHERE meeting_id = ?")
    .bind(meetingId)
    .first<{ charged_seconds: number; grants: number; settled_at: number | null }>();
}

describe("Deepgram canlı metin jetonu", () => {
  it("politika kapalıyken /v1/me Mac'i söyler ve jeton verilmez; Deepgram çağrılmaz", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meetingId: string = await openMeeting(harness, session);
    expect(await liveEngineOf(harness, session, env)).toBe("whisperkit");
    await expectError(await tokenRequest(harness, session, meetingId, env), 503, "deepgram_unavailable");
    expect(harness.outbound.some((request: Request): boolean => request.url.startsWith(deepgramGrantUrl))).toBe(false);
  });

  it("açık toplantıya jeton verir (anahtar yalnızca Deepgram'a gider); bitmiş, başkasının ya da kimliksiz toplantıya vermez", async () => {
    const harness: Harness = await defaultHarness();
    const requests: Request[] = stubGrant(harness);
    const session: Session = await signIn(harness);
    const other: Session = await signIn(harness);
    expect(await liveEngineOf(harness, session, deepgramOn)).toBe("deepgram");
    const meetingId: string = await openMeeting(harness, session);

    const response: Response = await tokenRequest(harness, session, meetingId, deepgramOn);
    expect(response.status).toBe(200);
    expect(await response.json<GrantBody>()).toEqual({
      accessToken: "eyJ.sahte.jwt",
      expiresIn: 30,
      model: "nova-3",
      mipOptOut: true,
      grantsLeft: deepgramTrialGrantsPerMeeting - 1,
    });
    expect(requests).toHaveLength(1);
    expect(requests[0]?.method).toBe("POST");
    expect(requests[0]?.headers.get("authorization")).toBe("Token test-deepgram-key-000000");
    expect(await requests[0]?.json()).toEqual({ ttl_seconds: 30 });
    // Peşin tahmin: deneme toplantısının 90 dakikası × 2 akış.
    expect(await chargedSecondsOf(meetingId)).toEqual({ charged_seconds: 90 * 60 * 2, grants: 1, settled_at: null });

    await expectError(await tokenRequest(harness, other, meetingId, deepgramOn), 403, "meeting_not_active");
    await expectError(
      await harness.call(req("POST", "/v1/live/deepgram-token", { token: session.accessToken, env: deepgramOn })),
      400,
      "bad_request",
    );

    // 10 dakika sonra bitirilen toplantının tahmini gerçek süreye (10 dk × 2 akış) iner; bitmiş toplantı (not için ek
    // süre içinde olsa da) jeton alamaz.
    harness.clock.nowMs += 10 * 60_000;
    const ended: Response = await harness.call(req("POST", `/v1/meetings/${meetingId}/end`, { token: session.accessToken, env: deepgramOn }));
    expect(ended.status).toBe(200);
    expect(await chargedSecondsOf(meetingId)).toEqual({ charged_seconds: 10 * 60 * 2, grants: 1, settled_at: harness.clock.nowMs });
    await expectError(await tokenRequest(harness, session, meetingId, deepgramOn), 403, "meeting_not_active");
    expect(requests).toHaveLength(1);
  });

  it("toplantı başına jeton sınırı (deneme): sınırdan sonra yeniden bağlanma reddedilir, Deepgram çağrılmaz", async () => {
    const harness: Harness = await defaultHarness();
    const requests: Request[] = stubGrant(harness);
    let session: Session = await signIn(harness);
    const meetingId: string = await openMeeting(harness, session);
    for (let index: number = 0; index < deepgramTrialGrantsPerMeeting; index += 1) {
      if (index > 0 && index % deepgramGrantsPerWindow === 0) {
        harness.clock.nowMs += deepgramGrantWindowMs;
        session = await refreshed(harness, session);
      }
      expect((await tokenRequest(harness, session, meetingId, deepgramOn)).status).toBe(200);
    }
    harness.clock.nowMs += deepgramGrantWindowMs;
    session = await refreshed(harness, session);
    await expectError(await tokenRequest(harness, session, meetingId, deepgramOn), 429, "deepgram_grant_limit");
    expect(requests).toHaveLength(deepgramTrialGrantsPerMeeting);
    expect((await chargedSecondsOf(meetingId))?.grants).toBe(deepgramTrialGrantsPerMeeting);
  });

  it("kısa pencerede çok sayıda jeton (aynı anda çok akış) reddedilir; pencere geçince yeniden bağlanma sürer", async () => {
    const harness: Harness = await defaultHarness();
    const requests: Request[] = stubGrant(harness);
    let session: Session = await signIn(harness);
    const meetingId: string = await openMeeting(harness, session);
    for (let index: number = 0; index < deepgramGrantsPerWindow; index += 1) {
      expect((await tokenRequest(harness, session, meetingId, deepgramOn)).status).toBe(200);
    }
    await expectError(await tokenRequest(harness, session, meetingId, deepgramOn), 429, "deepgram_grant_limit");
    expect(requests).toHaveLength(deepgramGrantsPerWindow);

    harness.clock.nowMs += deepgramGrantWindowMs;
    session = await refreshed(harness, session);
    expect((await tokenRequest(harness, session, meetingId, deepgramOn)).status).toBe(200);
    expect(requests).toHaveLength(deepgramGrantsPerWindow + 1);
  });

  it("jetonun ömrü toplantının en çok süresinin sonunu geçmez; en çok süre geçince jeton verilmez", async () => {
    const harness: Harness = await defaultHarness();
    const requests: Request[] = stubGrant(harness);
    let session: Session = await signIn(harness);
    const started: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    const maxEndsAt: number = Date.parse(started.expiresAt);

    harness.clock.nowMs = maxEndsAt - 10_000;
    session = await refreshed(harness, session);
    const response: Response = await tokenRequest(harness, session, started.meetingId, deepgramOn);
    expect(response.status).toBe(200);
    expect((await response.json<GrantBody>()).expiresIn).toBe(10);
    expect(await requests[0]?.json()).toEqual({ ttl_seconds: 10 });

    harness.clock.nowMs = maxEndsAt;
    await expectError(await tokenRequest(harness, session, started.meetingId, deepgramOn), 403, "meeting_not_active");
    expect(requests).toHaveLength(1);
  });

  it("Deepgram'ın geçici hatası uyarıyla yeniden denenir, sonra 502; kalıcı ret denenmez; hak ayrılmaz", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meetingId: string = await openMeeting(harness, session);
    let calls: number = 0;
    harness.stub(deepgramGrantUrl, async (): Promise<Response> => {
      calls += 1;
      return new Response("busy", { status: 503 });
    });
    const warnings = vi.spyOn(console, "warn");
    try {
      await expectError(await tokenRequest(harness, session, meetingId, deepgramOn), 502, "upstream_unavailable");
      expect(calls).toBe(3);
      const retries: string[] = warnings.mock.calls.map((call: unknown[]): string => String(call[0])).filter((line: string): boolean => line.includes('"event":"upstream_retry"'));
      expect(retries).toHaveLength(2);
      expect(retries[0]).toContain('"service":"deepgram"');
    } finally {
      warnings.mockRestore();
    }
    expect(await chargedSecondsOf(meetingId)).toBeNull();

    calls = 0;
    harness.stub(deepgramGrantUrl, async (): Promise<Response> => {
      calls += 1;
      return Response.json({ err_code: "INVALID_AUTH" }, { status: 401 });
    });
    await expectError(await tokenRequest(harness, session, meetingId, deepgramOn), 502, "upstream_unavailable");
    expect(calls).toBe(1);

    harness.stub(deepgramGrantUrl, async (): Promise<Response> => Response.json({ token: "beklenmeyen" }));
    await expectError(await tokenRequest(harness, session, meetingId, deepgramOn), 502, "upstream_unavailable");
    expect(await chargedSecondsOf(meetingId)).toBeNull();
  });

  it("bütçe dolunca /v1/me Mac'e geçer, yeni toplantıya jeton verilmez; jeton almış toplantı yeniden bağlanabilir; alarm yazılır", async () => {
    // Bu dosyanın önceki toplantıları ömür boyu bütçeye sayılır: bütçe bu test için sıfırdan başlar.
    await env.DB.prepare("DELETE FROM deepgram_live_meetings").run();
    const harness: Harness = await defaultHarness();
    stubGrant(harness);
    const first: Session = await signIn(harness);
    const second: Session = await signIn(harness);
    const firstMeeting: string = await openMeeting(harness, first);
    const secondMeeting: string = await openMeeting(harness, second);
    expect(await liveEngineOf(harness, second, tinyBudget)).toBe("deepgram");

    const alerts = vi.spyOn(console, "error");
    try {
      expect((await tokenRequest(harness, first, firstMeeting, tinyBudget)).status).toBe(200);
      const crossings: string[] = alerts.mock.calls
        .map((call: unknown[]): string => String(call[0]))
        .filter((line: string): boolean => line.includes('"event":"deepgram_budget_threshold"'));
      expect(crossings).toHaveLength(1);
      expect(JSON.parse(crossings[0] ?? "{}")).toMatchObject({ level: "alert", threshold: 0.95, budgetUsd: 0.01 });
    } finally {
      alerts.mockRestore();
    }

    expect(await liveEngineOf(harness, second, tinyBudget)).toBe("whisperkit");
    await expectError(await tokenRequest(harness, second, secondMeeting, tinyBudget), 503, "deepgram_unavailable");
    expect(await chargedSecondsOf(secondMeeting)).toBeNull();
    expect((await tokenRequest(harness, first, firstMeeting, tinyBudget)).status).toBe(200);

    const usage = await deepgramUsage(env.DB, parseConfig(tinyBudget));
    expect(usage).toEqual({
      policy: "on",
      budgetUsd: 0.01,
      estimatedUsd: 1.66,
      percent: 16560,
      streamMinutes: 180,
      meetings: 1,
      openMeetings: 1,
      usdPerMinute: 0.0092,
    });
  });

  it("bütçe toplamı tek satırdır: ekleme, gerçek süreye indirme ve silmede tablonun toplamıyla aynı kalır", async () => {
    const totals = async (): Promise<{ counter: unknown; table: unknown }> => ({
      counter: await env.DB.prepare("SELECT charged_seconds AS seconds, meetings, open_meetings AS open FROM deepgram_budget WHERE id = 1").first(),
      table: await env.DB.prepare(
        `SELECT COALESCE(SUM(charged_seconds), 0) AS seconds, COUNT(*) AS meetings,
           COALESCE(SUM(CASE WHEN settled_at IS NULL THEN 1 ELSE 0 END), 0) AS open FROM deepgram_live_meetings`,
      ).first(),
    });
    await env.DB.prepare("DELETE FROM deepgram_live_meetings").run();
    expect(await totals()).toEqual({ counter: { seconds: 0, meetings: 0, open: 0 }, table: { seconds: 0, meetings: 0, open: 0 } });
    await env.DB.prepare(
      `INSERT INTO deepgram_live_meetings (meeting_id, grants, first_grant_at, charged_seconds, settled_at) VALUES
         ('dg_a', 1, 0, 1000, NULL), ('dg_b', 1, 0, 400, NULL), ('dg_c', 1, 0, 50, 5)`,
    ).run();
    expect((await totals()).counter).toEqual({ seconds: 1450, meetings: 3, open: 2 });
    // Peşin tahmin gerçek süreye indirilir; jeton sayacı (`grants`) toplamı değiştirmez.
    await env.DB.prepare("UPDATE deepgram_live_meetings SET charged_seconds = 300, settled_at = 9 WHERE meeting_id = 'dg_a'").run();
    await env.DB.prepare("UPDATE deepgram_live_meetings SET grants = grants + 1 WHERE meeting_id = 'dg_b'").run();
    await env.DB.prepare("DELETE FROM deepgram_live_meetings WHERE meeting_id = 'dg_c'").run();
    const after = await totals();
    expect(after.counter).toEqual({ seconds: 700, meetings: 2, open: 1 });
    expect(after.counter).toEqual(after.table);
  });
});
