import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { Env } from "../src/env";
import { mayReprocess, reprocessAudioCap, reprocessTokenBudget } from "../src/meetings";
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
  startMeeting,
} from "./helpers";

interface MeBody {
  readonly plan: string;
  readonly trialMeetingsTotal: number;
  readonly trialMeetingsLeft: number;
  readonly monthlyHoursUsed: number;
  readonly monthlyHoursCap: number;
  readonly subscription: { status: string; currentPeriodEnd: string } | null;
}

async function me(harness: Harness, session: Session): Promise<MeBody> {
  const response: Response = await harness.call(req("GET", "/v1/me", { token: session.accessToken }));
  expect(response.status).toBe(200);
  return response.json<MeBody>();
}

function stubHaiku(harness: Harness): void {
  harness.stub("https://api.anthropic.com/v1/messages", async (): Promise<Response> =>
    Response.json({
      id: "msg_1",
      type: "message",
      role: "assistant",
      model: "claude-haiku-5-5",
      content: [{ type: "text", text: "ok" }],
      stop_reason: "end_turn",
      stop_sequence: null,
      usage: { input_tokens: 10, output_tokens: 5, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
    }),
  );
}

function llm(harness: Harness, session: Session, meetingId: string): Promise<Response> {
  return harness.call(
    req("POST", "/v1/llm/messages", {
      token: session.accessToken,
      headers: { "x-meeting-id": meetingId },
      json: { effort: "low", max_tokens: 100, messages: [{ role: "user", content: "x" }] },
    }),
  );
}

async function openState(meetingId: string): Promise<{ ended_at: number | null; end_reason: string | null } | null> {
  return env.DB.prepare("SELECT ended_at, end_reason FROM meeting_sessions WHERE id = ?")
    .bind(meetingId)
    .first<{ ended_at: number | null; end_reason: string | null }>();
}

async function meetingsStartedToday(harness: Harness, userId: string): Promise<number> {
  const row = await env.DB.prepare("SELECT meetings_started FROM daily_usage WHERE user_id = ? AND day = ?")
    .bind(userId, new Date(harness.clock.nowMs).toISOString().slice(0, 10))
    .first<{ meetings_started: number }>();
  return row?.meetings_started ?? 0;
}

describe("haklar ve toplantı oturumları", () => {
  it("yeni kullanıcı 3 deneme toplantısı ve 10 saat sınırı görür", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    expect(await me(harness, session)).toEqual({
      userId: session.userId,
      plan: "trial",
      trialMeetingsTotal: 3,
      trialDays: 7,
      trialMeetingsLeft: 3,
      accountTrialMeetingsLeft: 3,
      deviceTrialMeetingsLeft: null,
      trialEndsAt: null,
      monthlyHoursUsed: 0,
      monthlyHoursCap: 10,
      liveEngine: "whisperkit",
      accountTokensUsed: 0,
      accountTokensCap: 300_000,
      accountTokensPeriod: "day",
      accountTokensResetsAt: "2026-10-16T00:00:00.000Z",
      monthlyResetsAt: "2026-11-01T00:00:00.000Z",
      meetingMaxMinutes: 90,
      subscription: null,
    });
  });

  it("abone toplantı dışı yapay zekâ hakkının aylık kullanımını, sınırını ve sıfırlanma anını görür", async () => {
    const harness: Harness = await defaultHarness();
    stubHaiku(harness);
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    const response: Response = await harness.call(
      req("POST", "/v1/llm/messages", { token: session.accessToken, json: { effort: "low", max_tokens: 100, messages: [{ role: "user", content: "x" }] } }),
    );
    expect(response.status).toBe(200);
    await response.text();
    await harness.drain();
    // Sahte Haiku yanıtı 10 girdi + 5 çıktı token kullanır.
    expect(await me(harness, session)).toMatchObject({
      plan: "subscription",
      accountTokensUsed: 15,
      accountTokensCap: 1_500_000,
      accountTokensPeriod: "month",
      accountTokensResetsAt: "2026-11-01T00:00:00.000Z",
      monthlyResetsAt: "2026-11-01T00:00:00.000Z",
      meetingMaxMinutes: 240,
    });
  });

  it("deneme 3 toplantıda biter; her biri 90 dakikalık ve bütçelidir", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    for (let left: number = 2; left >= 0; left -= 1) {
      const response: Response = await startMeeting(harness, session);
      expect(response.status).toBe(201);
      const body: StartedMeetingBody = await response.json<StartedMeetingBody>();
      expect(body).toMatchObject({ kind: "trial", maxDurationMinutes: 90, tokenBudget: 1000000, trialMeetingsLeft: left });
      harness.clock.nowMs += 60_000;
    }
    await expectError(await startMeeting(harness, session), 402, "trial_exhausted");
    expect((await me(harness, session)).trialMeetingsLeft).toBe(0);
  });

  it("aynı clientRef ile yinelenen başlatma aynı oturumu döndürür; deneme ve günlük başlatma bir kez düşer", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const start = async (clientRef: string): Promise<Response> =>
      harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: { clientRef } }));
    const first: Response = await start("kayit-2026-11-01");
    expect(first.status).toBe(201);
    const firstBody: StartedMeetingBody = await first.json<StartedMeetingBody>();
    expect(firstBody).toMatchObject({ kind: "trial", trialMeetingsLeft: 2 });
    // Bitmiş oturum da aynı kimlikle yeniden açılmaz (çevrimdışı kayıt işlenirken yanıt kaybolduysa).
    await harness.call(req("POST", `/v1/meetings/${firstBody.meetingId}/end`, { token: session.accessToken }));
    harness.clock.nowMs += 5 * 60_000;
    const repeated: StartedMeetingBody = await (await start("kayit-2026-11-01")).json<StartedMeetingBody>();
    expect(repeated).toMatchObject({ meetingId: firstBody.meetingId, kind: "trial", maxDurationMinutes: 90, trialMeetingsLeft: 2 });
    expect((await me(harness, session)).trialMeetingsLeft).toBe(2);
    const started = await env.DB.prepare("SELECT meetings_started FROM daily_usage WHERE user_id = ?").bind(session.userId).first<{ meetings_started: number }>();
    expect(started?.meetings_started).toBe(1);
    // Başka kimlik yeni oturumdur; geçersiz kimlik reddedilir.
    const other: StartedMeetingBody = await (await start("kayit-2026-11-02")).json<StartedMeetingBody>();
    expect(other.meetingId).not.toBe(firstBody.meetingId);
    expect(other.trialMeetingsLeft).toBe(1);
    await expectError(await start("../geçersiz"), 400, "invalid_body");
  });

  it("yeni toplantı açık olanı kapatır; bitirme dakikayı yazar ve tekrarlanabilir", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const first: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    harness.clock.nowMs += 10 * 60_000 + 1;
    const second: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    const closed = await env.DB.prepare("SELECT minutes FROM meeting_sessions WHERE id = ?").bind(first.meetingId).first<{ minutes: number }>();
    expect(closed?.minutes).toBe(11);

    harness.clock.nowMs += 30 * 60_000;
    const later: Session = await refreshed(harness, session);
    const end: Response = await harness.call(req("POST", `/v1/meetings/${second.meetingId}/end`, { token: later.accessToken }));
    expect(end.status).toBe(200);
    expect(await end.json()).toEqual({ meetingId: second.meetingId, minutes: 30, tokensUsed: 0, audioSeconds: 0 });
    harness.clock.nowMs += 60_000;
    expect((await (await harness.call(req("POST", `/v1/meetings/${second.meetingId}/end`, { token: later.accessToken }))).json<{ minutes: number }>()).minutes).toBe(30);
  });

  it("başkasının toplantısı bitirilemez ve vekil çağrısında kullanılamaz", async () => {
    const harness: Harness = await defaultHarness();
    const owner: Session = await signIn(harness);
    const other: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, owner)).json<StartedMeetingBody>();
    await expectError(await harness.call(req("POST", `/v1/meetings/${meeting.meetingId}/end`, { token: other.accessToken })), 404, "not_found");
    await expectError(
      await harness.call(
        req("POST", "/v1/llm/messages", {
          token: other.accessToken,
          headers: { "x-meeting-id": meeting.meetingId },
          json: { effort: "low", max_tokens: 100, messages: [{ role: "user", content: "merhaba" }] },
        }),
      ),
      403,
      "meeting_not_active",
    );
  });

  it("ek süresi geçmiş toplantı sınırlı sayıda yeniden işlenmek için açılır; deneme ve başlatma düşmez", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    await harness.call(req("POST", `/v1/meetings/${meeting.meetingId}/end`, { token: session.accessToken }));
    let current: Session = session;
    const call = (): Promise<Response> =>
      harness.call(
        req("POST", "/v1/llm/messages", {
          token: current.accessToken,
          headers: { "x-meeting-id": meeting.meetingId },
          json: { max_tokens: 100, messages: [{ role: "user", content: "x" }], tools: [] },
        }),
      );
    const reprocess = (): Promise<Response> =>
      harness.call(req("POST", `/v1/meetings/${meeting.meetingId}/reprocess`, { token: current.accessToken }));
    // Ek süre içinde açılış hak harcamaz.
    expect(await (await reprocess()).json()).toMatchObject({ meetingId: meeting.meetingId, reprocessesLeft: 2 });
    harness.clock.nowMs += 31 * 60_000;
    current = await refreshed(harness, current);
    await expectError(await call(), 403, "meeting_not_active");
    expect(await (await reprocess()).json()).toMatchObject({ reprocessesLeft: 1 });
    // Açıldı: vekil çağrısı gövde doğrulamasına kadar ilerler.
    await expectError(await call(), 400, "invalid_body");
    harness.clock.nowMs += 31 * 60_000;
    current = await refreshed(harness, current);
    await expectError(await call(), 403, "meeting_not_active");
    expect(await (await reprocess()).json()).toMatchObject({ reprocessesLeft: 0 });
    harness.clock.nowMs += 31 * 60_000;
    current = await refreshed(harness, current);
    await expectError(await reprocess(), 409, "reprocess_limit_reached");
    // Yeniden işleme yeni deneme ya da başlatma saymaz.
    expect((await me(harness, current)).trialMeetingsLeft).toBe(2);
    expect(await meetingsStartedToday(harness, session.userId)).toBe(1);
    // Başkasının toplantısı yeniden açılamaz.
    const other: Session = await signIn(harness);
    await expectError(await harness.call(req("POST", `/v1/meetings/${meeting.meetingId}/reprocess`, { token: other.accessToken })), 404, "not_found");
  });

  it("yeniden işleme sesi kaydın gerçek süresiyle, yapay zekâyı sınırlı bütçeyle açar; erişimsiz hesap yalnızca 7 gün içinde", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const dayMs: number = 86_400_000;
    // Deneme ilk toplantıyla başlar (7 gün).
    const first: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    await harness.call(req("POST", `/v1/meetings/${first.meetingId}/end`, { token: session.accessToken }));
    harness.clock.nowMs += 6 * dayMs;
    let current: Session = await refreshed(harness, session);
    const late: StartedMeetingBody = await (await startMeeting(harness, current)).json<StartedMeetingBody>();
    harness.clock.nowMs += 2 * 60_000;
    await harness.call(req("POST", `/v1/meetings/${late.meetingId}/end`, { token: current.accessToken }));
    // İlk geçiş 2 dakikalık sesi yazdı.
    await env.DB.prepare("UPDATE meeting_sessions SET audio_seconds = 120, tokens_used = 5000 WHERE id = ?").bind(late.meetingId).run();

    // Deneme süresi doldu (erişim yok): bir haftadan eski toplantı reddedilir, yenisi açılır.
    harness.clock.nowMs += 2 * dayMs;
    current = await refreshed(harness, current);
    const reprocess = (meetingId: string): Promise<Response> =>
      harness.call(req("POST", `/v1/meetings/${meetingId}/reprocess`, { token: current.accessToken }));
    await expectError(await reprocess(first.meetingId), 402, "subscription_required");
    expect((await reprocess(late.meetingId)).status).toBe(200);
    const row = await env.DB.prepare("SELECT reprocess_audio_cap, token_budget FROM meeting_sessions WHERE id = ?")
      .bind(late.meetingId)
      .first<{ reprocess_audio_cap: number; token_budget: number }>();
    // Yazılmış 120 sn + kaydın 120 sn'si; bütçe kullanılan + yeniden işleme payı.
    expect(row).toEqual({ reprocess_audio_cap: 240, token_budget: 5000 + reprocessTokenBudget });

    // Erişimsiz hesap için pencere bitişten sonraki 7 gün.
    harness.clock.nowMs += 8 * dayMs;
    current = await refreshed(harness, current);
    await expectError(await reprocess(late.meetingId), 402, "subscription_required");
    expect(mayReprocess(true, 0, 365 * dayMs, 7 * dayMs)).toBe(true);
    expect(reprocessAudioCap(0, 600, 0)).toBeNull();
    expect(reprocessAudioCap(6000, 6000, 0)).toBe(6000 + 6000 + 120);
    // İkinci yeniden işlemede bir geçiş, yazılan sesin yarısıdır (sınır kaydın iki katına çıkmaz).
    expect(reprocessAudioCap(1200, 0, 1)).toBe(1200 + 600);
  });

  it("bütçesini neredeyse bitirmiş toplantı yeniden işlemede tam pay alır; harcama tavanı doluysa hak harcanmaz", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    await harness.call(req("POST", `/v1/meetings/${meeting.meetingId}/end`, { token: session.accessToken }));
    const nearlySpent: number = meeting.tokenBudget - 10_000;
    await env.DB.prepare("UPDATE meeting_sessions SET tokens_used = ? WHERE id = ?").bind(nearlySpent, meeting.meetingId).run();
    harness.clock.nowMs += 31 * 60_000;
    const current: Session = await refreshed(harness, session);
    const reprocess = (testEnv: Env): Promise<Response> =>
      harness.call(req("POST", `/v1/meetings/${meeting.meetingId}/reprocess`, { token: current.accessToken, env: testEnv }));
    const budgetRow = (): Promise<{ token_budget: number; reprocess_count: number } | null> =>
      env.DB.prepare("SELECT token_budget, reprocess_count FROM meeting_sessions WHERE id = ?")
        .bind(meeting.meetingId)
        .first<{ token_budget: number; reprocess_count: number }>();

    // Günlük harcama tavanı dolu: yapay zekâ çağrıları reddedileceği için yeniden işleme hakkı harcanmaz.
    await env.DB.prepare("INSERT INTO daily_spend (day, micro_usd) VALUES (?, 10) ON CONFLICT(day) DO UPDATE SET micro_usd = micro_usd + 10")
      .bind(new Date(harness.clock.nowMs).toISOString().slice(0, 10))
      .run();
    await expectError(await reprocess(envWith({ DAILY_SPEND_CEILING_USD: "0.000001" })), 503, "spend_ceiling_reached");
    expect(await budgetRow()).toEqual({ token_budget: meeting.tokenBudget, reprocess_count: 0 });

    expect(await (await reprocess(env)).json()).toMatchObject({ reprocessesLeft: 1 });
    expect(await budgetRow()).toEqual({ token_budget: nearlySpent + reprocessTokenBudget, reprocess_count: 1 });
  });

  it("sonradan işlenen kayıt (deferred) açık toplantıyı kapatmaz", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    const live: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    const deferred: Response = await harness.call(
      req("POST", "/v1/meetings/start", { token: session.accessToken, json: { clientRef: "bekleyen-1", deferred: true } }),
    );
    expect(deferred.status).toBe(201);
    expect((await openState(live.meetingId))?.ended_at).toBeNull();
    // Bekleyen kayıt bitmiş olarak açılır: canlı kullanılamaz (Deepgram jetonu yok), açık toplantı sayılmaz.
    const pending: StartedMeetingBody = await deferred.json<StartedMeetingBody>();
    expect((await openState(pending.meetingId))?.end_reason).toBe("ended");
    // Normal başlatma ise açık toplantıyı kapatır.
    await startMeeting(harness, session);
    expect((await openState(live.meetingId))?.end_reason).toBe("superseded");
    // Ek süresi içinde en çok 3 bekleyen: dördüncüsü rate_limited, süre geçince yenisi açılır.
    const startDeferred = (ref: string, token: string): Promise<Response> =>
      harness.call(req("POST", "/v1/meetings/start", { token, json: { clientRef: ref, deferred: true } }));
    expect((await startDeferred("bekleyen-2", session.accessToken)).status).toBe(201);
    expect((await startDeferred("bekleyen-3", session.accessToken)).status).toBe(201);
    await expectError(await startDeferred("bekleyen-4", session.accessToken), 429, "rate_limited");
    harness.clock.nowMs += 31 * 60_000;
    const later: Session = await refreshed(harness, session);
    expect((await startDeferred("bekleyen-4", later.accessToken)).status).toBe(201);
  });

  it("toplantı bittikten sonra 30 dakika not için açık kalır, sonra kapanır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    await harness.call(req("POST", `/v1/meetings/${meeting.meetingId}/end`, { token: session.accessToken }));
    let current: Session = session;
    const llm = (): Promise<Response> =>
      harness.call(
        req("POST", "/v1/llm/messages", {
          token: current.accessToken,
          headers: { "x-meeting-id": meeting.meetingId },
          json: { max_tokens: 100, messages: [{ role: "user", content: "x" }], tools: [] },
        }),
      );
    // Ek süre içinde oturum geçerli: gövde doğrulamasına kadar ilerler.
    await expectError(await llm(), 400, "invalid_body");
    harness.clock.nowMs += 29 * 60_000;
    current = await refreshed(harness, session);
    await expectError(await llm(), 400, "invalid_body");
    harness.clock.nowMs += 2 * 60_000;
    await expectError(await llm(), 403, "meeting_not_active");
  });

  it("abone aylık sınırın altında toplantı açar; sınır dolunca reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    expect((await me(harness, session)).plan).toBe("subscription");

    const first: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    expect(first).toMatchObject({ kind: "subscription", maxDurationMinutes: 240, tokenBudget: 2600000, trialMeetingsLeft: null });
    expect((await me(harness, session)).trialMeetingsLeft).toBe(3);

    // 9,5 saatlik ses kullanılmış: kalan 30 dakika, toplantı süresi buna kısalır.
    await env.DB.prepare("INSERT INTO monthly_usage (user_id, month, audio_seconds) VALUES (?, ?, ?)")
      .bind(session.userId, new Date(harness.clock.nowMs).toISOString().slice(0, 7), 9.5 * 3600)
      .run();
    const short: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    expect(short.maxDurationMinutes).toBe(30);
    expect((await me(harness, session)).monthlyHoursUsed).toBe(9.5);

    await env.DB.prepare("UPDATE monthly_usage SET audio_seconds = ? WHERE user_id = ?").bind(10 * 3600, session.userId).run();
    await expectError(await startMeeting(harness, session), 403, "monthly_cap_reached");
  });

  it("reddedilen deneme başlatması açık toplantıyı kapatmaz ve günlük başlatma hakkı harcamaz", async () => {
    const harness: Harness = await defaultHarness();
    stubHaiku(harness);
    const session: Session = await signIn(harness);
    let last: StartedMeetingBody | null = null;
    for (let index: number = 0; index < 3; index += 1) {
      last = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    }
    const open: StartedMeetingBody = last as StartedMeetingBody;
    await expectError(await startMeeting(harness, session), 402, "trial_exhausted");
    expect(await openState(open.meetingId)).toEqual({ ended_at: null, end_reason: null });
    expect(await meetingsStartedToday(harness, session.userId)).toBe(3);
    expect((await llm(harness, session, open.meetingId)).status).toBe(200);
  });

  it("aylık sınırda reddedilen abone başlatması açık toplantıyı kapatmaz ve günlük başlatma hakkı harcamaz", async () => {
    const harness: Harness = await defaultHarness();
    stubHaiku(harness);
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    const open: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    await env.DB.prepare("INSERT INTO monthly_usage (user_id, month, audio_seconds) VALUES (?, ?, ?)")
      .bind(session.userId, new Date(harness.clock.nowMs).toISOString().slice(0, 7), 10 * 3600)
      .run();
    await expectError(await startMeeting(harness, session), 403, "monthly_cap_reached");
    expect(await openState(open.meetingId)).toEqual({ ended_at: null, end_reason: null });
    expect(await meetingsStartedToday(harness, session.userId)).toBe(1);
    expect((await llm(harness, session, open.meetingId)).status).toBe(200);
  });

  it("başarılı başlatma eskisini ek süresiz kapatır ve sayılır; günlük sınırda reddedilen açık toplantıya dokunmaz", async () => {
    const harness: Harness = await defaultHarness();
    stubHaiku(harness);
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    const limited: Env = envWith({ MAX_MEETING_STARTS_PER_DAY: "2" });
    const start = (): Promise<Response> => harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {}, env: limited }));
    const first: StartedMeetingBody = await (await start()).json<StartedMeetingBody>();
    harness.clock.nowMs += 5 * 60_000;
    const second: StartedMeetingBody = await (await start()).json<StartedMeetingBody>();
    expect(await openState(first.meetingId)).toEqual({ ended_at: harness.clock.nowMs, end_reason: "superseded" });
    await expectError(await llm(harness, session, first.meetingId), 403, "meeting_not_active");
    expect(await meetingsStartedToday(harness, session.userId)).toBe(2);

    await expectError(await start(), 429, "daily_cap_reached");
    expect(await openState(second.meetingId)).toEqual({ ended_at: null, end_reason: null });
    expect(await meetingsStartedToday(harness, session.userId)).toBe(2);
    expect((await llm(harness, session, second.meetingId)).status).toBe(200);
  });

  it("dönemi geçmiş ya da iptal edilmiş abonelik hak vermez", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "canceled", harness.clock.nowMs + 20 * 86_400_000);
    expect((await me(harness, session)).plan).toBe("trial");
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    expect(meeting.kind).toBe("trial");
  });
});
