import { describe, expect, it } from "vitest";
import { type Harness, type Session, type StartedMeetingBody, defaultHarness, expectError, grantSubscription, refreshed, req, signIn } from "./helpers";

interface MeBody {
  readonly plan: string;
  readonly trialMeetingsLeft: number;
  readonly subscription: { status: string; currentPeriodEnd: string; access: string; graceEndsAt: string | null } | null;
}

function startFrom(harness: Harness, session: Session, clientIp: string): Promise<Response> {
  return harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {}, clientIp }));
}

async function me(harness: Harness, session: Session): Promise<MeBody> {
  return (await harness.call(req("GET", "/v1/me", { token: session.accessToken }))).json<MeBody>();
}

describe("IP başına günlük yeni deneme sınırı", () => {
  it("aynı IP'den günde 3 yeni hesap denemeye başlar; 4. hesap 429 alır, mevcut hesaplar etkilenmez", async () => {
    const harness: Harness = await defaultHarness();
    const ip: string = "203.0.113.7";
    const accounts: Session[] = [await signIn(harness), await signIn(harness), await signIn(harness)];
    for (const account of accounts) {
      expect((await startFrom(harness, account, ip)).status).toBe(201);
    }
    const fourth: Session = await signIn(harness);
    await expectError(await startFrom(harness, fourth, ip), 429, "trial_ip_limit");
    // Deneme hakkı harcanmadı.
    expect((await me(harness, fourth)).trialMeetingsLeft).toBe(3);

    // Denemeye zaten başlamış hesap aynı IP'den devam eder.
    const second: StartedMeetingBody = await (await startFrom(harness, accounts[0] as Session, ip)).json<StartedMeetingBody>();
    expect(second).toMatchObject({ kind: "trial", trialMeetingsLeft: 1 });

    // Başka IP'den ya da ertesi gün başlayabilir.
    expect((await startFrom(harness, fourth, "203.0.113.8")).status).toBe(201);
    harness.clock.nowMs += 86_400_000;
    const fifth: Session = await signIn(harness);
    expect((await startFrom(harness, fifth, ip)).status).toBe(201);
  });
});

describe("past_due ek süresi", () => {
  it("dönem sonundan sonra 7 gün erişim sürer ve /v1/me ek süreyi gösterir; sonra deneme planına düşer", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const periodEnd: number = harness.clock.nowMs - 2 * 86_400_000;
    await grantSubscription(session.userId, "past_due", periodEnd);

    const inGrace: MeBody = await me(harness, session);
    expect(inGrace.plan).toBe("subscription");
    expect(inGrace.subscription).toEqual({
      status: "past_due",
      currentPeriodEnd: new Date(periodEnd).toISOString(),
      access: "grace",
      graceEndsAt: new Date(periodEnd + 7 * 86_400_000).toISOString(),
    });
    const meeting: StartedMeetingBody = await (await startFrom(harness, session, "198.51.100.1")).json<StartedMeetingBody>();
    expect(meeting.kind).toBe("subscription");

    harness.clock.nowMs = periodEnd + 7 * 86_400_000 + 1;
    const later: Session = await refreshed(harness, session);
    const expired: MeBody = await me(harness, later);
    expect(expired.plan).toBe("trial");
    expect(expired.subscription?.access).toBe("none");
    expect(expired.subscription?.graceEndsAt).toBeNull();
    const trial: StartedMeetingBody = await (await startFrom(harness, later, "198.51.100.1")).json<StartedMeetingBody>();
    expect(trial.kind).toBe("trial");
  });

  it.each(["unpaid", "canceled", "incomplete_expired"])("%s durumunda dönem bitmemiş olsa da erişim yoktur", async (status: string) => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, status, harness.clock.nowMs + 10 * 86_400_000);
    const body: MeBody = await me(harness, session);
    expect(body.plan).toBe("trial");
    expect(body.subscription).toMatchObject({ status, access: "none", graceEndsAt: null });
  });

  it("aktif abonelik active erişim gösterir", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 10 * 86_400_000);
    expect((await me(harness, session)).subscription).toMatchObject({ access: "active", graceEndsAt: null });
  });
});
