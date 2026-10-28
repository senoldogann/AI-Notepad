import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import {
  type Harness,
  type Session,
  type StartedMeetingBody,
  defaultHarness,
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

describe("haklar ve toplantı oturumları", () => {
  it("yeni kullanıcı 3 deneme toplantısı ve 10 saat sınırı görür", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    expect(await me(harness, session)).toEqual({
      userId: session.userId,
      plan: "trial",
      trialMeetingsTotal: 3,
      trialMeetingsLeft: 3,
      monthlyHoursUsed: 0,
      monthlyHoursCap: 10,
      subscription: null,
    });
  });

  it("deneme 3 toplantıda biter; her biri 90 dakikalık ve bütçelidir", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    for (let left: number = 2; left >= 0; left -= 1) {
      const response: Response = await startMeeting(harness, session);
      expect(response.status).toBe(201);
      const body: StartedMeetingBody = await response.json<StartedMeetingBody>();
      expect(body).toMatchObject({ kind: "trial", maxDurationMinutes: 90, tokenBudget: 600000, trialMeetingsLeft: left });
      harness.clock.nowMs += 60_000;
    }
    await expectError(await startMeeting(harness, session), 402, "trial_exhausted");
    expect((await me(harness, session)).trialMeetingsLeft).toBe(0);
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
          json: { max_tokens: 100, messages: [{ role: "user", content: "merhaba" }] },
        }),
      ),
      403,
      "meeting_not_active",
    );
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
    await grantSubscription(session.userId, harness.clock.nowMs + 20 * 86_400_000);
    expect((await me(harness, session)).plan).toBe("subscription");

    const first: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    expect(first).toMatchObject({ kind: "subscription", maxDurationMinutes: 240, tokenBudget: 1500000, trialMeetingsLeft: null });
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

  it("dönemi geçmiş ya da iptal edilmiş abonelik hak vermez", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, harness.clock.nowMs - 1000);
    expect((await me(harness, session)).plan).toBe("trial");
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    expect(meeting.kind).toBe("trial");
  });
});
