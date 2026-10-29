import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { cleanupExpiredRows } from "../src/cleanup";
import { subscriptionRenewalGraceMs } from "../src/entitlements";
import { type Harness, type Session, type StartedMeetingBody, defaultHarness, expectError, grantSubscription, refreshed, req, signIn } from "./helpers";

interface MeBody {
  readonly plan: string;
  readonly trialMeetingsLeft: number;
  readonly subscription: { status: string; currentPeriodEnd: string; cancelAt: string | null; access: string; graceEndsAt: string | null } | null;
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

describe("IPv6 istemcileri /64 önekiyle sayılır", () => {
  it("aynı /64 ağındaki farklı adresler aynı IP sınırına sayılır; başka /64 ve IPv4 eşlemeli adres ayrıdır", async () => {
    const harness: Harness = await defaultHarness();
    for (const ip of ["2001:db8:aa:1::1", "2001:db8:aa:1:ffff::2", "2001:0db8:00aa:0001:1234:5678:9abc:def0"]) {
      expect((await startFrom(harness, await signIn(harness), ip)).status).toBe(201);
    }
    await expectError(await startFrom(harness, await signIn(harness), "2001:db8:aa:1::abcd"), 429, "trial_ip_limit");
    expect((await startFrom(harness, await signIn(harness), "2001:db8:aa:2::1")).status).toBe(201);

    // IPv4 eşlemeli IPv6 adresi IPv4 adresiyle aynı anahtardır.
    for (let index: number = 0; index < 3; index += 1) {
      expect((await startFrom(harness, await signIn(harness), "192.0.2.77")).status).toBe(201);
    }
    await expectError(await startFrom(harness, await signIn(harness), "::ffff:192.0.2.77"), 429, "trial_ip_limit");
  });
});

describe("eski deneme kayıtları temizlendikten sonra", () => {
  it("denemeye başlamış hesap IP sınırına takılmaz ve yeniden sayılmaz", async () => {
    const harness: Harness = await defaultHarness();
    const ip: string = "203.0.113.90";
    const accounts: Session[] = [await signIn(harness), await signIn(harness), await signIn(harness)];
    for (const account of accounts) {
      expect((await startFrom(harness, account, ip)).status).toBe(201);
    }
    harness.clock.nowMs += 86_400_000;
    await cleanupExpiredRows(env.DB, new Date(harness.clock.nowMs), { batchSize: 100, maxBatchesPerTable: 10 });
    const remaining = await env.DB.prepare("SELECT COUNT(*) AS count FROM trial_starts WHERE day < ?")
      .bind(new Date(harness.clock.nowMs).toISOString().slice(0, 10))
      .first<{ count: number }>();
    expect(remaining?.count).toBe(0);

    const returning: Session = await refreshed(harness, accounts[0] as Session);
    const second: StartedMeetingBody = await (await startFrom(harness, returning, ip)).json<StartedMeetingBody>();
    expect(second).toMatchObject({ kind: "trial", trialMeetingsLeft: 1 });
    // Bugün bu IP'den yeni hesaplar için 3 hak hâlâ duruyor.
    for (let index: number = 0; index < 3; index += 1) {
      expect((await startFrom(harness, await signIn(harness), ip)).status).toBe(201);
    }
    await expectError(await startFrom(harness, await signIn(harness), ip), 429, "trial_ip_limit");
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
      cancelAt: null,
      access: "grace",
      graceEndsAt: new Date(periodEnd + 7 * 86_400_000).toISOString(),
      plan: "monthly",
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

  it("yenilenecek abonelik dönem sonunda yenileme webhook'u gelene dek (48 saat) erişimi korur; deneme yoluna ve DeviceCheck'e düşmez", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const periodEnd: number = harness.clock.nowMs + 60_000;
    await grantSubscription(session.userId, "active", periodEnd);

    // Dönem bitti, yenileme olayı henüz gelmedi.
    harness.clock.nowMs = periodEnd + 3 * 3_600_000;
    const renewing: Session = await refreshed(harness, session);
    expect(await me(harness, renewing)).toMatchObject({ plan: "subscription", subscription: { status: "active", access: "active" } });
    const meeting: StartedMeetingBody = await (await startFrom(harness, renewing, "198.51.100.7")).json<StartedMeetingBody>();
    expect(meeting.kind).toBe("subscription");

    // Yenileme hiç gelmezse ek süreden sonra erişim biter.
    harness.clock.nowMs = periodEnd + subscriptionRenewalGraceMs + 1;
    const lapsed: Session = await refreshed(harness, renewing);
    expect(await me(harness, lapsed)).toMatchObject({ plan: "trial", subscription: { access: "none" } });
  });

  it("dönem sonunda bitecek (iptal edilmiş) abonelik yenileme ek süresi almaz", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const periodEnd: number = harness.clock.nowMs + 60_000;
    await grantSubscription(session.userId, "active", periodEnd);
    await env.DB.prepare("UPDATE subscriptions SET cancel_at = ? WHERE user_id = ?").bind(periodEnd, session.userId).run();
    harness.clock.nowMs = periodEnd + 1;
    const later: Session = await refreshed(harness, session);
    expect(await me(harness, later)).toMatchObject({ plan: "trial", subscription: { access: "none" } });
  });
});
