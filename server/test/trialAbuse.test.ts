import { env } from "cloudflare:workers";
import { type CryptoKey as JoseKey, decodeProtectedHeader, exportPKCS8, generateKeyPair, jwtVerify } from "jose";
import { describe, expect, it, vi } from "vitest";
import { deviceCheckUrl } from "../src/deviceCheck";
import type { Env } from "../src/env";
import { trialIdentityHash } from "../src/trialLedger";
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
  signInWithGoogle,
} from "./helpers";

const dayMs: number = 86_400_000;

const teamId: string = "79DZ4AA4DW";
const keyId: string = "TESTKEY123";

/** Sahte Apple DeviceCheck: jeton → bitler; her çağrıda JWT ve gövde doğrulanır. */
interface FakeDeviceCheck {
  readonly env: Env;
  readonly bits: Map<string, { bit0: boolean; bit1: boolean }>;
  readonly calls: Array<{ endpoint: string; token: string }>;
  /** Sıradaki çağrılara dönecek hata durumları (boşalınca normal yanıt). */
  readonly failures: number[];
}

interface DeviceCheckBody {
  readonly device_token: string;
  readonly transaction_id: string;
  readonly timestamp: number;
  readonly bit0?: boolean;
  readonly bit1?: boolean;
}

let keysPromise: Promise<{ privateKeyPem: string; publicKey: JoseKey }> | null = null;

/** Sahte DeviceCheck anahtarı (dosya başına bir kez). */
async function deviceCheckKeys(): Promise<{ privateKeyPem: string; publicKey: JoseKey }> {
  keysPromise ??= (async (): Promise<{ privateKeyPem: string; publicKey: JoseKey }> => {
    const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
    return { privateKeyPem: await exportPKCS8(privateKey), publicKey };
  })();
  return keysPromise;
}

/** DeviceCheck `required` ortamı ve geliştirme adresine bağlı sahte Apple servisi. */
async function fakeDeviceCheck(harness: Harness): Promise<FakeDeviceCheck> {
  const { privateKeyPem, publicKey } = await deviceCheckKeys();
  const fake: FakeDeviceCheck = {
    env: envWith({ DEVICECHECK_POLICY: "required", DEVICECHECK_KEY_ID: keyId, DEVICECHECK_TEAM_ID: teamId, DEVICECHECK_PRIVATE_KEY: privateKeyPem }),
    bits: new Map(),
    calls: [],
    failures: [],
  };
  harness.stub(deviceCheckUrl("development", "query_two_bits").replace("query_two_bits", ""), async (request: Request): Promise<Response> => {
    const jwt: string = (request.headers.get("authorization") ?? "").replace(/^Bearer /, "");
    expect(decodeProtectedHeader(jwt)).toEqual({ alg: "ES256", kid: keyId });
    const verified = await jwtVerify(jwt, publicKey, { issuer: teamId });
    expect(typeof verified.payload.iat).toBe("number");
    const body: DeviceCheckBody = await request.json<DeviceCheckBody>();
    expect(body.transaction_id.length).toBeGreaterThan(0);
    expect(body.timestamp).toBe(harness.clock.nowMs);
    const endpoint: string = new URL(request.url).pathname.split("/").at(-1) ?? "";
    fake.calls.push({ endpoint, token: body.device_token });
    const failure: number | undefined = fake.failures.shift();
    if (failure !== undefined) {
      return new Response(failure === 400 ? "Missing or incorrectly formatted device token payload" : "Internal Server Error", { status: failure });
    }
    if (endpoint === "query_two_bits") {
      const stored = fake.bits.get(body.device_token);
      return stored === undefined ? new Response("Failed to find bit state") : Response.json({ ...stored, last_update_time: "2026-10" });
    }
    expect(endpoint).toBe("update_two_bits");
    fake.bits.set(body.device_token, { bit0: body.bit0 ?? false, bit1: body.bit1 ?? false });
    return new Response("");
  });
  return fake;
}

/** Toplantı başlatır; `deviceCheckToken` null ise gövdede alan yoktur. */
function start(harness: Harness, session: Session, environment: Env | null, deviceCheckToken: string | null): Promise<Response> {
  const json: object = deviceCheckToken === null ? {} : { deviceCheckToken };
  return harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json, env: environment }));
}

function deleteMe(harness: Harness, session: Session, environment: Env | null): Promise<Response> {
  return harness.call(req("DELETE", "/v1/me", { token: session.accessToken, env: environment }));
}

async function trialMeetingsLeft(harness: Harness, session: Session): Promise<number> {
  const response: Response = await harness.call(req("GET", "/v1/me", { token: session.accessToken }));
  expect(response.status).toBe(200);
  return (await response.json<{ trialMeetingsLeft: number }>()).trialMeetingsLeft;
}

/** Google kimliğinin defter satırı (yoksa null). */
async function ledgerRow(subject: string): Promise<{ trial_meetings_used: number; device_verified: number } | null> {
  const identityHash: string = await trialIdentityHash(env.TRIAL_HASH_SECRET, "google", subject);
  return env.DB.prepare("SELECT trial_meetings_used, device_verified FROM trial_identity_ledger WHERE identity_hash = ?")
    .bind(identityHash)
    .first<{ trial_meetings_used: number; device_verified: number }>();
}

/** Mac'in DeviceCheck jetonu (base64; gerçeği ~2,2 KB). */
function macToken(name: string): string {
  return btoa(`devicecheck-${name}-${"x".repeat(64)}`);
}

describe("kimlik deneme defteri (hesap silinince deneme sıfırlanmaz)", () => {
  it("silinip aynı kimlikle yeniden açılan hesap kalan denemeyle sürer; IP sayacına yeni hesap olarak girmez", async () => {
    const harness: Harness = await defaultHarness();
    const subject: string = `google-${crypto.randomUUID()}`;
    const first: Session = await signInWithGoogle(harness, subject);
    expect((await start(harness, first, null, null)).status).toBe(201);
    expect((await start(harness, first, null, null)).status).toBe(201);
    expect((await deleteMe(harness, first, null)).status).toBe(204);

    // Kimlik açık saklanmaz: anahtar sunucu sırrıyla HMAC özetidir.
    expect(await ledgerRow(subject)).toEqual({ trial_meetings_used: 2, device_verified: 0 });
    const raw = await env.DB.prepare("SELECT COUNT(*) AS count FROM trial_identity_ledger WHERE identity_hash LIKE ?")
      .bind(`%${subject}%`)
      .first<{ count: number }>();
    expect(raw?.count).toBe(0);

    const again: Session = await signInWithGoogle(harness, subject);
    expect(again.userId).not.toBe(first.userId);
    expect(await trialMeetingsLeft(harness, again)).toBe(1);
    const last: StartedMeetingBody = await (await start(harness, again, null, null)).json<StartedMeetingBody>();
    expect(last).toMatchObject({ kind: "trial", trialMeetingsLeft: 0 });
    const ipRows = await env.DB.prepare("SELECT COUNT(*) AS count FROM trial_starts WHERE user_id = ?").bind(again.userId).first<{ count: number }>();
    expect(ipRows?.count).toBe(0);
    await expectError(await start(harness, again, null, null), 402, "trial_exhausted");

    // Yeniden silme defteri küçültmez; denemesi biten hesap toplantı dışı yapay zekâ da alamaz.
    const account: Response = await harness.call(
      req("POST", "/v1/llm/messages", { token: again.accessToken, json: { effort: "low", max_tokens: 10, messages: [{ role: "user", content: "x" }] } }),
    );
    await expectError(account, 402, "subscription_required");
    expect((await deleteMe(harness, again, null)).status).toBe(204);
    const third: Session = await signInWithGoogle(harness, subject);
    expect(await trialMeetingsLeft(harness, third)).toBe(0);
  });

  it("aynı ay içinde silinip yeniden açılan hesap bu ayın kullanımını devralır; sonraki ay sıfırdan başlar", async () => {
    const harness: Harness = await defaultHarness();
    const subject: string = `google-${crypto.randomUUID()}`;
    const identityHash: string = await trialIdentityHash(env.TRIAL_HASH_SECRET, "google", subject);
    const monthlyHours = async (session: Session): Promise<number> => {
      const response: Response = await harness.call(req("GET", "/v1/me", { token: session.accessToken }));
      expect(response.status).toBe(200);
      return (await response.json<{ monthlyHoursUsed: number }>()).monthlyHoursUsed;
    };
    const meetingOf = async (session: Session, minutes: number): Promise<Session> => {
      const meeting: StartedMeetingBody = await (await start(harness, session, null, null)).json<StartedMeetingBody>();
      harness.clock.nowMs += minutes * 60_000;
      const fresh: Session = await refreshed(harness, session);
      expect((await harness.call(req("POST", `/v1/meetings/${meeting.meetingId}/end`, { token: fresh.accessToken }))).status).toBe(200);
      return fresh;
    };

    // 1 saatlik toplantı ve bu ayın token kullanımı (kesinleşmiş kullanım gibi yazılır).
    let first: Session = await signInWithGoogle(harness, subject);
    first = await meetingOf(first, 60);
    const month: string = new Date(harness.clock.nowMs).toISOString().slice(0, 7);
    await env.DB.prepare("INSERT INTO monthly_usage (user_id, month, input_tokens, output_tokens, account_tokens) VALUES (?, ?, 1000, 500, 700)")
      .bind(first.userId, month)
      .run();
    expect(await monthlyHours(first)).toBe(1);
    expect((await deleteMe(harness, first, null)).status).toBe(204);
    const ledger = await env.DB.prepare(
      "SELECT usage_month, usage_seconds, usage_tokens, usage_account_tokens FROM trial_identity_ledger WHERE identity_hash = ?",
    )
      .bind(identityHash)
      .first();
    expect(ledger).toEqual({ usage_month: month, usage_seconds: 3600, usage_tokens: 1500, usage_account_tokens: 700 });

    // Aynı ay: süre ve token'lar devralınır; yeni kullanım üstüne eklenir ve yeniden silmede büyüğü kalır.
    let again: Session = await signInWithGoogle(harness, subject);
    expect(await monthlyHours(again)).toBe(1);
    const seeded = await env.DB.prepare("SELECT carried_seconds, input_tokens, output_tokens, account_tokens FROM monthly_usage WHERE user_id = ?")
      .bind(again.userId)
      .first();
    expect(seeded).toEqual({ carried_seconds: 3600, input_tokens: 1500, output_tokens: 0, account_tokens: 700 });
    again = await meetingOf(again, 30);
    expect(await monthlyHours(again)).toBe(1.5);
    expect((await deleteMe(harness, again, null)).status).toBe(204);
    const grown = await env.DB.prepare("SELECT usage_month, usage_seconds FROM trial_identity_ledger WHERE identity_hash = ?").bind(identityHash).first();
    expect(grown).toEqual({ usage_month: month, usage_seconds: 5400 });

    // Sonraki ay: defterdeki eski ay yok sayılır, kullanım sıfırdan başlar (deneme sayısı yine devralınır).
    harness.clock.nowMs = Date.UTC(2026, 10, 2, 12);
    const nextMonth: Session = await signInWithGoogle(harness, subject);
    expect(await monthlyHours(nextMonth)).toBe(0);
    const fresh = await env.DB.prepare("SELECT COUNT(*) AS count FROM monthly_usage WHERE user_id = ?").bind(nextMonth.userId).first<{ count: number }>();
    expect(fresh?.count).toBe(0);
    expect(await ledgerRow(subject)).toEqual({ trial_meetings_used: 2, device_verified: 0 });
  });

  it("aynı gün silinip yeniden açılan hesap günlük sayaçları (toplantı dışı deneme token'ı dahil) devralır; ertesi gün sıfırdan", async () => {
    const harness: Harness = await defaultHarness();
    const subject: string = `google-${crypto.randomUUID()}`;
    const first: Session = await signInWithGoogle(harness, subject);
    expect((await start(harness, first, null, null)).status).toBe(201);
    const day: string = new Date(harness.clock.nowMs).toISOString().slice(0, 10);
    await env.DB.prepare(
      `INSERT INTO daily_usage (user_id, day, tokens_used, trial_account_tokens_used, meetings_started) VALUES (?, ?, 900, 400, 1)
       ON CONFLICT(user_id, day) DO UPDATE SET tokens_used = 900, trial_account_tokens_used = 400, meetings_started = 1`,
    )
      .bind(first.userId, day)
      .run();
    expect((await deleteMe(harness, first, null)).status).toBe(204);

    const again: Session = await signInWithGoogle(harness, subject);
    const seeded = await env.DB.prepare("SELECT day, tokens_used, trial_account_tokens_used, meetings_started FROM daily_usage WHERE user_id = ?")
      .bind(again.userId)
      .first();
    expect(seeded).toEqual({ day, tokens_used: 900, trial_account_tokens_used: 400, meetings_started: 1 });
    // Toplantı dışı deneme payı (abone olmayan) devralınan kullanımı gösterir.
    const me = await (await harness.call(req("GET", "/v1/me", { token: again.accessToken }))).json<{ accountTokensUsed: number }>();
    expect(me.accountTokensUsed).toBe(400);
    expect((await deleteMe(harness, again, null)).status).toBe(204);

    harness.clock.nowMs += 86_400_000;
    const tomorrow: Session = await signInWithGoogle(harness, subject);
    const fresh = await env.DB.prepare("SELECT COUNT(*) AS count FROM daily_usage WHERE user_id = ?").bind(tomorrow.userId).first<{ count: number }>();
    expect(fresh?.count).toBe(0);
  });

  it("deneme harcamamış ve bu ay kullanımı olmayan hesap silinince defterde satır kalmaz", async () => {
    const harness: Harness = await defaultHarness();
    const subject: string = `google-${crypto.randomUUID()}`;
    const session: Session = await signInWithGoogle(harness, subject);
    expect((await deleteMe(harness, session, null)).status).toBe(204);
    expect(await ledgerRow(subject)).toBeNull();
  });
});

describe("Apple DeviceCheck ile Mac başına deneme", () => {
  it("ilk hesap Mac'i işaretler ve sonraki denemeleri jetonsuz başlatır; aynı Mac'teki ikinci hesap reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeDeviceCheck = await fakeDeviceCheck(harness);
    const mac: string = macToken("a");
    fake.bits.set(mac, { bit0: false, bit1: true });
    const owner: Session = await signInWithGoogle(harness, `google-${crypto.randomUUID()}`);

    expect((await start(harness, owner, fake.env, mac)).status).toBe(201);
    expect(fake.calls).toEqual([
      { endpoint: "query_two_bits", token: mac },
      { endpoint: "update_two_bits", token: mac },
    ]);
    // bit1 okunduğu gibi korunur.
    expect(fake.bits.get(mac)).toEqual({ bit0: true, bit1: true });
    expect((await start(harness, owner, fake.env, null)).status).toBe(201);
    expect((await start(harness, owner, fake.env, mac)).status).toBe(201);
    expect(fake.calls).toHaveLength(2);

    const other: Session = await signInWithGoogle(harness, `google-${crypto.randomUUID()}`);
    const refusals = async (): Promise<number> =>
      (await env.DB.prepare("SELECT COALESCE(SUM(count), 0) AS count FROM trial_refusals WHERE reason = 'device_used'").first<{ count: number }>())?.count ?? 0;
    const refusedBefore: number = await refusals();
    await expectError(await start(harness, other, fake.env, mac), 403, "trial_device_used");
    // Ret yönetim paneli için neden sayacına yazılır (kullanıcı ya da IP tutulmaz).
    expect(await refusals()).toBe(refusedBefore + 1);
    const meetings = await env.DB.prepare("SELECT COUNT(*) AS count FROM meeting_sessions WHERE user_id = ?").bind(other.userId).first<{ count: number }>();
    expect(meetings?.count).toBe(0);
    // Başka bir Mac'te ikinci hesap denemeye başlar.
    expect((await start(harness, other, fake.env, macToken("b"))).status).toBe(201);
  });

  it("jetonsuz deneme `device_check_required`; Apple'ın 400'ü `device_check_invalid`; 5xx yeniden denenir", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeDeviceCheck = await fakeDeviceCheck(harness);
    const session: Session = await signInWithGoogle(harness, `google-${crypto.randomUUID()}`);
    await expectError(await start(harness, session, fake.env, null), 400, "device_check_required");
    expect(fake.calls).toHaveLength(0);

    fake.failures.push(400);
    await expectError(await start(harness, session, fake.env, macToken("bozuk")), 400, "device_check_invalid");
    expect(fake.calls).toHaveLength(1);

    fake.calls.length = 0;
    fake.failures.push(500, 503);
    expect((await start(harness, session, fake.env, macToken("c"))).status).toBe(201);
    expect(fake.calls.map((call): string => call.endpoint)).toEqual(["query_two_bits", "query_two_bits", "query_two_bits", "update_two_bits"]);

    // Apple sürekli yanıt vermezse üç denemeden sonra 502; Mac işaretlenmez.
    const other: Session = await signInWithGoogle(harness, `google-${crypto.randomUUID()}`);
    fake.calls.length = 0;
    fake.failures.push(500, 500, 500);
    await expectError(await start(harness, other, fake.env, macToken("d")), 502, "upstream_unavailable");
    expect(fake.calls).toHaveLength(3);
    expect(fake.bits.has(macToken("d"))).toBe(false);
  });

  it("base64 olmayan jeton Apple'a gitmeden reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeDeviceCheck = await fakeDeviceCheck(harness);
    const session: Session = await signInWithGoogle(harness, `google-${crypto.randomUUID()}`);
    await expectError(await start(harness, session, fake.env, "jeton değil!"), 400, "invalid_body");
    expect(fake.calls).toHaveLength(0);
  });

  it("abonelik toplantısı DeviceCheck istemez", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeDeviceCheck = await fakeDeviceCheck(harness);
    const session: Session = await signInWithGoogle(harness, `google-${crypto.randomUUID()}`);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    const started: StartedMeetingBody = await (await start(harness, session, fake.env, null)).json<StartedMeetingBody>();
    expect(started.kind).toBe("subscription");
    expect(fake.calls).toHaveLength(0);
  });

  it("silinip aynı kimlikle yeniden açılan hesap Mac doğrulamasını da devralır", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeDeviceCheck = await fakeDeviceCheck(harness);
    const subject: string = `google-${crypto.randomUUID()}`;
    const first: Session = await signInWithGoogle(harness, subject);
    expect((await start(harness, first, fake.env, macToken("e"))).status).toBe(201);
    expect((await deleteMe(harness, first, fake.env)).status).toBe(204);
    expect(await ledgerRow(subject)).toEqual({ trial_meetings_used: 1, device_verified: 1 });

    const again: Session = await signInWithGoogle(harness, subject);
    fake.calls.length = 0;
    const started: StartedMeetingBody = await (await start(harness, again, fake.env, null)).json<StartedMeetingBody>();
    expect(started).toMatchObject({ kind: "trial", trialMeetingsLeft: 1 });
    expect(fake.calls).toHaveLength(0);
  });

  it("denemesi bitmiş hesap Mac'i işaretlemeden `trial_exhausted` alır", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeDeviceCheck = await fakeDeviceCheck(harness);
    const session: Session = await signInWithGoogle(harness, `google-${crypto.randomUUID()}`);
    await env.DB.prepare("UPDATE users SET carried_trial_meetings = 3 WHERE id = ?").bind(session.userId).run();
    await expectError(await start(harness, session, fake.env, null), 402, "trial_exhausted");
    expect(fake.calls).toHaveLength(0);
  });

  it("süresi dolmuş deneme Mac'i sorgulamadan `trial_exhausted` alır", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeDeviceCheck = await fakeDeviceCheck(harness);
    const session: Session = await signInWithGoogle(harness, `google-${crypto.randomUUID()}`);
    await env.DB.prepare("UPDATE users SET trial_started_at = ? WHERE id = ?").bind(harness.clock.nowMs - 8 * dayMs, session.userId).run();
    await expectError(await start(harness, session, fake.env, macToken("f")), 402, "trial_exhausted");
    expect(fake.calls).toHaveLength(0);
  });
});

/** `GET /v1/me` alanlarının deneme kısmı. */
interface TrialMe {
  readonly plan: string;
  readonly trialMeetingsLeft: number;
  readonly accountTrialMeetingsLeft: number;
  readonly trialEndsAt: string | null;
}

async function trialMe(harness: Harness, session: Session): Promise<TrialMe> {
  const response: Response = await harness.call(req("GET", "/v1/me", { token: session.accessToken }));
  expect(response.status).toBe(200);
  return response.json<TrialMe>();
}

async function trialStartedAt(userId: string): Promise<number | null> {
  const row = await env.DB.prepare("SELECT trial_started_at FROM users WHERE id = ?").bind(userId).first<{ trial_started_at: number | null }>();
  return row?.trial_started_at ?? null;
}

describe("deneme süresi (ilk deneme toplantısından 7 gün)", () => {
  it("süre ilk toplantıyla başlar; dolunca kalan toplantılar da düşer ve toplantı dışı yapay zekâ kapanır", async () => {
    const harness: Harness = await defaultHarness();
    const startMs: number = harness.clock.nowMs;
    let session: Session = await signInWithGoogle(harness, `google-${crypto.randomUUID()}`);
    expect(await trialMe(harness, session)).toMatchObject({ trialMeetingsLeft: 3, trialEndsAt: null });
    expect(await trialStartedAt(session.userId)).toBeNull();

    expect((await start(harness, session, null, null)).status).toBe(201);
    expect(await trialStartedAt(session.userId)).toBe(startMs);
    const endsAt: string = new Date(startMs + 7 * dayMs).toISOString();
    expect(await trialMe(harness, session)).toMatchObject({ trialMeetingsLeft: 2, accountTrialMeetingsLeft: 2, trialEndsAt: endsAt });

    // 6. gün: ikinci toplantı başlar, süre ilk toplantıdan sayılmaya devam eder.
    harness.clock.nowMs = startMs + 6 * dayMs;
    session = await refreshed(harness, session);
    expect((await start(harness, session, null, null)).status).toBe(201);
    expect(await trialStartedAt(session.userId)).toBe(startMs);

    // 7. gün: bir toplantı kalsa da deneme bitti.
    harness.clock.nowMs = startMs + 7 * dayMs;
    session = await refreshed(harness, session);
    const logs = vi.spyOn(console, "log");
    const refused = await expectError(await start(harness, session, null, null), 402, "trial_exhausted");
    expect(refused.error.message).toContain("süren doldu (7 gün)");
    expect(logs.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"reason":"expired"'))).toBe(true);
    logs.mockRestore();
    const expiredRefusals = await env.DB.prepare("SELECT count FROM trial_refusals WHERE day = ? AND reason = 'expired'")
      .bind(new Date(harness.clock.nowMs).toISOString().slice(0, 10))
      .first<{ count: number }>();
    expect(expiredRefusals?.count).toBe(1);
    expect(await trialMe(harness, session)).toMatchObject({ plan: "trial", trialMeetingsLeft: 0, accountTrialMeetingsLeft: 0, trialEndsAt: endsAt });
    const account: Response = await harness.call(
      req("POST", "/v1/llm/messages", { token: session.accessToken, json: { effort: "low", max_tokens: 10, messages: [{ role: "user", content: "x" }] } }),
    );
    await expectError(account, 402, "subscription_required");

    // Abone olunca deneme bitişi gösterilmez ve toplantı abonelikten açılır.
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * dayMs);
    expect(await trialMe(harness, session)).toMatchObject({ plan: "subscription", trialEndsAt: null });
    expect((await start(harness, session, null, null)).status).toBe(201);
  });

  it("silinip aynı kimlikle yeniden açılan hesap denemenin başlangıcını devralır", async () => {
    const harness: Harness = await defaultHarness();
    const startMs: number = harness.clock.nowMs;
    const subject: string = `google-${crypto.randomUUID()}`;
    const first: Session = await signInWithGoogle(harness, subject);
    expect((await start(harness, first, null, null)).status).toBe(201);
    harness.clock.nowMs = startMs + 3 * dayMs;
    expect((await deleteMe(harness, await refreshed(harness, first), null)).status).toBe(204);
    const identityHash: string = await trialIdentityHash(env.TRIAL_HASH_SECRET, "google", subject);
    const ledger = await env.DB.prepare("SELECT trial_started_at FROM trial_identity_ledger WHERE identity_hash = ?").bind(identityHash).first();
    expect(ledger).toEqual({ trial_started_at: startMs });

    const again: Session = await signInWithGoogle(harness, subject);
    expect(await trialStartedAt(again.userId)).toBe(startMs);
    expect(await trialMe(harness, again)).toMatchObject({ trialMeetingsLeft: 2, trialEndsAt: new Date(startMs + 7 * dayMs).toISOString() });
    expect((await start(harness, again, null, null)).status).toBe(201);
    expect(await trialStartedAt(again.userId)).toBe(startMs);

    harness.clock.nowMs = startMs + 8 * dayMs;
    await expectError(await start(harness, await refreshed(harness, again), null, null), 402, "trial_exhausted");
  });
});
