import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { cleanupExpiredRows } from "../src/cleanup";
import type { Env } from "../src/env";
import { durationBucket, telemetryDurationBuckets, telemetryExportFormats, telemetryIntegrations } from "../src/telemetry";
import {
  type Harness,
  type Session,
  type StartedMeetingBody,
  blockingLimiter,
  defaultHarness,
  envWith,
  expectError,
  refreshed,
  req,
  signIn,
  signInWithGoogle,
  startMeeting,
} from "./helpers";

const dayMs: number = 86_400_000;
const anthropicUrl: string = "https://api.anthropic.com/v1/messages";
const adminSubject: string = "telemetri-yonetici";
const adminEnv: Env = envWith({ ADMIN_IDENTITIES: `google:${adminSubject}` });
const appHeaders: Readonly<Record<string, string>> = { "x-app-version": "0.1.10 (19)", "x-os-version": "macOS 15.4.1" };

function dayOf(nowMs: number, offsetDays: number): string {
  return new Date(nowMs + offsetDays * dayMs).toISOString().slice(0, 10);
}

/** Hesabın sürüm satırı. */
async function versionRow(userId: string): Promise<{ last_app_version: string | null; last_os_version: string | null; last_seen_at: number | null }> {
  const row = await env.DB.prepare("SELECT last_app_version, last_os_version, last_seen_at FROM users WHERE id = ?")
    .bind(userId)
    .first<{ last_app_version: string | null; last_os_version: string | null; last_seen_at: number | null }>();
  if (row === null) {
    throw new Error("hesap yok");
  }
  return row;
}

function me(harness: Harness, session: Session, headers: Readonly<Record<string, string>>): Promise<Response> {
  return harness.call(req("GET", "/v1/me", { token: session.accessToken, headers }));
}

function postEvents(harness: Harness, session: Session, json: object, headers: Readonly<Record<string, string>>, environment: Env | null): Promise<Response> {
  return harness.call(req("POST", "/v1/telemetry", { token: session.accessToken, json, headers, env: environment }));
}

function postFeatures(harness: Harness, session: Session, json: object): Promise<Response> {
  return harness.call(req("POST", "/v1/telemetry/features", { token: session.accessToken, json, headers: appHeaders }));
}

function zeroCounts(keys: readonly string[]): Record<string, number> {
  return Object.fromEntries(keys.map((key: string): [string, number] => [key, 0]));
}

/** Boş günlük özellik raporu (her alan dolu). */
function featureReport(day: string): Record<string, unknown> {
  return {
    day,
    liveTranslation: false,
    translationLanguage: null,
    ask: false,
    integrations: zeroCounts(telemetryIntegrations),
    exports: zeroCounts(telemetryExportFormats),
    mcp: false,
    onDeviceLive: false,
  };
}

function message(inputTokens: number, outputTokens: number): object {
  return {
    id: "msg_test",
    type: "message",
    role: "assistant",
    model: "claude-haiku-5-5",
    content: [{ type: "text", text: "Merhaba" }],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: { input_tokens: inputTokens, output_tokens: outputTokens, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
  };
}

const basicLLM = { effort: "low", max_tokens: 1000, messages: [{ role: "user", content: "Çevir." }] };

/** Amacın günlük satırı; yoksa null. */
async function purposeRow(day: string, purpose: string): Promise<{ input_tokens: number; output_tokens: number; calls: number } | null> {
  return env.DB.prepare("SELECT input_tokens, output_tokens, calls FROM llm_purpose_usage WHERE day = ? AND purpose = ?")
    .bind(day, purpose)
    .first<{ input_tokens: number; output_tokens: number; calls: number }>();
}

describe("uygulama ve macOS sürümü (GET /v1/me)", () => {
  it("iki başlık da varsa yazar; yoksa yazmaz; aynı sürümler bir saat içinde yeniden yazılmaz", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    expect((await me(harness, session, {})).status).toBe(200);
    expect(await versionRow(session.userId)).toEqual({ last_app_version: null, last_os_version: null, last_seen_at: null });

    const firstSeen: number = harness.clock.nowMs;
    expect((await me(harness, session, appHeaders)).status).toBe(200);
    expect(await versionRow(session.userId)).toEqual({ last_app_version: "0.1.10 (19)", last_os_version: "macOS 15.4.1", last_seen_at: firstSeen });

    // 10 dakika sonra aynı sürümler: yazılmaz.
    harness.clock.nowMs += 10 * 60_000;
    expect((await me(harness, session, appHeaders)).status).toBe(200);
    expect((await versionRow(session.userId)).last_seen_at).toBe(firstSeen);
    // Sürüm değişince hemen yazılır.
    expect((await me(harness, session, { ...appHeaders, "x-app-version": "0.1.11 (20)" })).status).toBe(200);
    const changedAt: number = harness.clock.nowMs;
    expect(await versionRow(session.userId)).toEqual({ last_app_version: "0.1.11 (20)", last_os_version: "macOS 15.4.1", last_seen_at: changedAt });
    // Bir saatten sonra aynı sürümlerle son görülme yenilenir (erişim jetonu 15 dakikada dolar: yenilenir).
    harness.clock.nowMs += 61 * 60_000;
    const later: Session = await refreshed(harness, session);
    expect((await me(harness, later, { ...appHeaders, "x-app-version": "0.1.11 (20)" })).status).toBe(200);
    expect((await versionRow(session.userId)).last_seen_at).toBe(harness.clock.nowMs);
  });

  it.each([
    ["yalnızca uygulama sürümü", { "x-app-version": "0.1.10 (19)" }],
    ["yalnızca macOS sürümü", { "x-os-version": "macOS 15.4.1" }],
    ["geçersiz uygulama sürümü", { "x-app-version": "0.1.10", "x-os-version": "macOS 15.4.1" }],
    ["geçersiz macOS sürümü", { "x-app-version": "0.1.10 (19)", "x-os-version": "Windows 11" }],
  ])("%s: 400 bad_request, satır değişmez", async (_: string, headers: Record<string, string>) => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await expectError(await me(harness, session, headers), 400, "bad_request");
    expect((await versionRow(session.userId)).last_app_version).toBeNull();
  });
});

describe("yapay zekâ amacı (x-llm-purpose)", () => {
  interface Context {
    readonly harness: Harness;
    readonly session: Session;
    readonly meeting: StartedMeetingBody;
  }

  async function setup(): Promise<Context> {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    harness.stub(anthropicUrl, async (): Promise<Response> => Response.json(message(300, 50)));
    return { harness, session, meeting };
  }

  function llm(context: Context, headers: Readonly<Record<string, string>>): Promise<Response> {
    return context.harness.call(
      req("POST", "/v1/llm/messages", { token: context.session.accessToken, headers: { "x-meeting-id": context.meeting.meetingId, ...headers }, json: basicLLM }),
    );
  }

  it("bilinen amaç gün ve amaç başına token ve çağrı olarak toplanır", async () => {
    const context: Context = await setup();
    const day: string = dayOf(context.harness.clock.nowMs, 0);
    const before = await purposeRow(day, "live_translation");
    expect((await llm(context, { "x-llm-purpose": "live_translation" })).status).toBe(200);
    expect((await llm(context, { "x-llm-purpose": "live_translation" })).status).toBe(200);
    const after = await purposeRow(day, "live_translation");
    expect({
      input: (after?.input_tokens ?? 0) - (before?.input_tokens ?? 0),
      output: (after?.output_tokens ?? 0) - (before?.output_tokens ?? 0),
      calls: (after?.calls ?? 0) - (before?.calls ?? 0),
    }).toEqual({ input: 600, output: 100, calls: 2 });
  });

  it("başlığı göndermeyen eski istemcinin çağrısı unattributed satırına yazılır", async () => {
    const context: Context = await setup();
    const day: string = dayOf(context.harness.clock.nowMs, 0);
    const before: number = (await purposeRow(day, "unattributed"))?.calls ?? 0;
    expect((await llm(context, {})).status).toBe(200);
    expect((await purposeRow(day, "unattributed"))?.calls).toBe(before + 1);
  });

  it("bilinmeyen amaç 400 llm_purpose_invalid; üst servis çağrılmaz", async () => {
    const context: Context = await setup();
    const outbound: number = context.harness.outbound.length;
    await expectError(await llm(context, { "x-llm-purpose": "transcript_dump" }), 400, "llm_purpose_invalid");
    expect(context.harness.outbound.length).toBe(outbound);
    expect(await purposeRow(dayOf(context.harness.clock.nowMs, 0), "transcript_dump")).toBeNull();
  });
});

describe("istemci olayları (POST /v1/telemetry)", () => {
  it("durationBucket sınırları dahil eder", () => {
    expect([0, 10, 10.5, 30, 3600, 3600.1, 86_400].map(durationBucket)).toEqual(["le_10", "le_10", "le_30", "le_30", "le_3600", "gt_3600", "gt_3600"]);
    expect(telemetryDurationBuckets.at(-1)).toBe("gt_3600");
  });

  it("olayları gün, tür ve sürüm başına toplar; süreleri kovalara ayırır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const day: string = dayOf(harness.clock.nowMs, 0);
    const headers: Record<string, string> = { "x-app-version": "9.8.7 (654)" };
    const response: Response = await postEvents(
      harness,
      session,
      {
        events: [
          { kind: "deepgram_socket_drop", count: 2 },
          { kind: "deepgram_socket_drop", count: 3 },
          { kind: "recording_overrun", count: 1 },
          { kind: "final_pass_duration", seconds: 45 },
          { kind: "final_pass_duration", seconds: 50.5 },
          { kind: "note_generation_duration", seconds: 4000 },
        ],
      },
      headers,
      null,
    );
    expect(response.status).toBe(202);
    expect((await postEvents(harness, session, { events: [{ kind: "deepgram_socket_drop", count: 1 }] }, headers, null)).status).toBe(202);
    const counts = await env.DB.prepare("SELECT kind, count FROM client_event_counts WHERE day = ? AND app_version = ? ORDER BY kind")
      .bind(day, "9.8.7 (654)")
      .all<{ kind: string; count: number }>();
    expect(counts.results).toEqual([
      { kind: "deepgram_socket_drop", count: 6 },
      { kind: "recording_overrun", count: 1 },
    ]);
    const durations = await env.DB.prepare(
      "SELECT kind, bucket, count, seconds_sum FROM client_event_durations WHERE day = ? AND app_version = ? ORDER BY kind, bucket",
    )
      .bind(day, "9.8.7 (654)")
      .all<{ kind: string; bucket: string; count: number; seconds_sum: number }>();
    expect(durations.results).toEqual([
      { kind: "final_pass_duration", bucket: "le_60", count: 2, seconds_sum: 95.5 },
      { kind: "note_generation_duration", bucket: "gt_3600", count: 1, seconds_sum: 4000 },
    ]);
    // Toplamlar hesaba bağlı değildir.
    const columns = await env.DB.prepare("SELECT name FROM pragma_table_info('client_event_counts')").all<{ name: string }>();
    expect(columns.results.map((row: { name: string }): string => row.name)).not.toContain("user_id");
  });

  it.each([
    ["bilinmeyen tür", { events: [{ kind: "transcript_text", count: 1 }] }],
    ["fazla alan", { events: [{ kind: "deepgram_reconnect", count: 1, meetingTitle: "Gizli" }] }],
    ["sayılan olayda süre", { events: [{ kind: "deepgram_reconnect", seconds: 3 }] }],
    ["süre olayında sayı", { events: [{ kind: "final_pass_duration", count: 3 }] }],
    ["sıfır sayı", { events: [{ kind: "deepgram_reconnect", count: 0 }] }],
    ["negatif süre", { events: [{ kind: "final_pass_duration", seconds: -1 }] }],
    ["boş liste", { events: [] }],
    ["50'den fazla olay", { events: Array.from({ length: 51 }, (): object => ({ kind: "deepgram_reconnect", count: 1 })) }],
    ["kökte fazla alan", { events: [{ kind: "deepgram_reconnect", count: 1 }], userName: "x" }],
  ])("%s: 400 invalid_body", async (_: string, json: object) => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await expectError(await postEvents(harness, session, json, appHeaders, null), 400, "invalid_body");
  });

  it("x-app-version eksik ya da geçersizse 400 bad_request; kimliksiz 401", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const json: object = { events: [{ kind: "deepgram_reconnect", count: 1 }] };
    await expectError(await postEvents(harness, session, json, {}, null), 400, "bad_request");
    await expectError(await postEvents(harness, session, json, { "x-app-version": "<script>" }, null), 400, "bad_request");
    await expectError(await harness.call(req("POST", "/v1/telemetry", { json, headers: appHeaders })), 401, "unauthorized");
  });

  it("16 KB'tan büyük gövde 413 payload_too_large", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const response: Response = await harness.call(
      req("POST", "/v1/telemetry", {
        token: session.accessToken,
        headers: { ...appHeaders, "content-type": "application/json" },
        body: JSON.stringify({ events: [{ kind: "deepgram_reconnect", count: 1 }], pad: "x".repeat(17 * 1024) }),
      }),
    );
    await expectError(response, 413, "payload_too_large");
  });

  it("kullanıcı başına hız sınırı: 429 rate_limited", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const response: Response = await postEvents(
      harness,
      session,
      { events: [{ kind: "deepgram_reconnect", count: 1 }] },
      appHeaders,
      envWith({ TELEMETRY_USER_LIMITER: blockingLimiter }),
    );
    await expectError(response, 429, "rate_limited");
  });

  it("günde 200 istekten sonra 429 daily_cap_reached; ertesi gün sayaç sıfırlanır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const json: object = { events: [{ kind: "deepgram_reconnect", count: 1 }] };
    await env.DB.prepare("UPDATE users SET telemetry_day = ?, telemetry_batches = 199 WHERE id = ?").bind(dayOf(harness.clock.nowMs, 0), session.userId).run();
    expect((await postEvents(harness, session, json, appHeaders, null)).status).toBe(202);
    await expectError(await postEvents(harness, session, json, appHeaders, null), 429, "daily_cap_reached");
    await expectError(await postFeatures(harness, session, featureReport(dayOf(harness.clock.nowMs, -1))), 429, "daily_cap_reached");
    await env.DB.prepare("UPDATE users SET telemetry_day = ? WHERE id = ?").bind(dayOf(harness.clock.nowMs, -1), session.userId).run();
    expect((await postEvents(harness, session, json, appHeaders, null)).status).toBe(202);
    const row = await env.DB.prepare("SELECT telemetry_day, telemetry_batches FROM users WHERE id = ?").bind(session.userId).first<{ telemetry_day: string; telemetry_batches: number }>();
    expect(row).toEqual({ telemetry_day: dayOf(harness.clock.nowMs, 0), telemetry_batches: 1 });
  });
});

describe("özellik kullanımı (POST /v1/telemetry/features)", () => {
  /** Günün özellik satırları. */
  async function featureRows(day: string): Promise<Array<{ feature: string; value: string; users: number; total: number }>> {
    const rows = await env.DB.prepare("SELECT feature, value, users, total FROM feature_usage_daily WHERE day = ? ORDER BY feature, value")
      .bind(day)
      .all<{ feature: string; value: string; users: number; total: number }>();
    return rows.results;
  }

  it("hesap başına gün bir kez sayılır; aynı ya da daha eski gün sayılmaz", async () => {
    const harness: Harness = await defaultHarness();
    const first: Session = await signIn(harness);
    const second: Session = await signIn(harness);
    const day: string = dayOf(harness.clock.nowMs, -3);
    const report: Record<string, unknown> = {
      ...featureReport(day),
      liveTranslation: true,
      translationLanguage: "tr",
      ask: true,
      integrations: { ...zeroCounts(telemetryIntegrations), slack: 2, notion: 1 },
      exports: { ...zeroCounts(telemetryExportFormats), pdf: 3 },
      mcp: true,
    };
    const counted: Response = await postFeatures(harness, first, report);
    expect(counted.status).toBe(200);
    expect(await counted.json()).toEqual({ counted: true });
    const repeated: Response = await postFeatures(harness, first, report);
    expect(await repeated.json()).toEqual({ counted: false });
    expect(await (await postFeatures(harness, first, featureReport(dayOf(harness.clock.nowMs, -4)))).json()).toEqual({ counted: false });
    expect(await (await postFeatures(harness, second, { ...featureReport(day), exports: { ...zeroCounts(telemetryExportFormats), pdf: 1, srt: 2 } })).json()).toEqual({
      counted: true,
    });
    expect(await featureRows(day)).toEqual([
      { feature: "ask", value: "", users: 1, total: 1 },
      { feature: "export", value: "pdf", users: 2, total: 4 },
      { feature: "export", value: "srt", users: 1, total: 2 },
      { feature: "integration", value: "notion", users: 1, total: 1 },
      { feature: "integration", value: "slack", users: 1, total: 2 },
      { feature: "live_translation", value: "", users: 1, total: 1 },
      { feature: "mcp", value: "", users: 1, total: 1 },
      { feature: "report", value: "", users: 2, total: 2 },
      { feature: "translation_language", value: "tr", users: 1, total: 1 },
    ]);
    // Sonraki gün yeniden sayılır.
    expect(await (await postFeatures(harness, first, featureReport(dayOf(harness.clock.nowMs, -2)))).json()).toEqual({ counted: true });
  });

  it.each([
    ["çeviri kapalıyken dil", (day: string): object => ({ ...featureReport(day), translationLanguage: "tr" })],
    ["bilinmeyen dil", (day: string): object => ({ ...featureReport(day), liveTranslation: true, translationLanguage: "klingon" })],
    ["eksik entegrasyon anahtarı", (day: string): object => ({ ...featureReport(day), integrations: { slack: 1 } })],
    ["bilinmeyen dışa aktarma biçimi", (day: string): object => ({ ...featureReport(day), exports: { ...zeroCounts(telemetryExportFormats), xlsx: 1 } })],
    ["fazla alan", (day: string): object => ({ ...featureReport(day), meetingTitle: "Gizli" })],
    ["gelecek gün", (_day: string): object => featureReport("2099-01-01")],
    ["8 günden eski gün", (_day: string): object => featureReport("2026-10-01")],
    ["geçersiz tarih", (_day: string): object => featureReport("dün")],
  ])("%s: 400 invalid_body, sayılmaz", async (_: string, body: (day: string) => object) => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await expectError(await postFeatures(harness, session, body(dayOf(harness.clock.nowMs, -1))), 400, "invalid_body");
    const row = await env.DB.prepare("SELECT telemetry_features_day FROM users WHERE id = ?").bind(session.userId).first<{ telemetry_features_day: string | null }>();
    expect(row?.telemetry_features_day).toBeNull();
  });
});

describe("yönetici telemetri görünümü (GET /v1/admin/telemetry)", () => {
  it("sürüm benimsenmesini, amaçları, olayları ve özellikleri son 30 günden döner", async () => {
    const harness: Harness = await defaultHarness();
    const nowMs: number = harness.clock.nowMs;
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const user: Session = await signIn(harness);
    expect((await me(harness, user, { "x-app-version": "7.0 (1)", "x-os-version": "macOS 26.1" })).status).toBe(200);
    await env.DB.batch([
      env.DB.prepare("INSERT INTO llm_purpose_usage (day, purpose, input_tokens, output_tokens, calls) VALUES (?, 'note', 1000, 200, 2), (?, 'note', 5, 5, 1)").bind(
        dayOf(nowMs, -1),
        dayOf(nowMs, -40),
      ),
      env.DB.prepare("INSERT INTO client_event_counts (day, kind, app_version, count) VALUES (?, 'final_pass_give_up', '7.0 (1)', 4)").bind(dayOf(nowMs, -2)),
      env.DB.prepare(
        "INSERT INTO client_event_durations (day, kind, app_version, bucket, count, seconds_sum) VALUES (?, 'final_pass_duration', '7.0 (1)', 'le_300', 2, 400)",
      ).bind(dayOf(nowMs, -2)),
      env.DB.prepare("INSERT INTO feature_usage_daily (day, feature, value, users, total) VALUES (?1, 'report', '', 5, 5), (?1, 'on_device_live', '', 2, 2)").bind(
        dayOf(nowMs, -5),
      ),
    ]);
    const response: Response = await harness.call(req("GET", "/v1/admin/telemetry", { token: admin.accessToken, env: adminEnv }));
    expect(response.status).toBe(200);
    const body = await response.json<{
      windowDays: number;
      versions: { activeUsers: number; apps: Array<{ version: string; users: number }>; os: Array<{ version: string; users: number }> };
      purposes: { totals: Array<{ purpose: string; inputTokens: number; outputTokens: number; calls: number }>; daily: Array<{ day: string; purpose: string }> };
      events: {
        counts: Array<{ kind: string; appVersion: string; count: number }>;
        daily: Array<{ day: string; kind: string; count: number }>;
        durations: Array<{ kind: string; bucket: string; count: number; secondsSum: number }>;
        durationBuckets: string[];
      };
      features: { reports: number; rows: Array<{ feature: string; value: string; users: number; total: number }> };
    }>();
    expect(body.windowDays).toBe(30);
    expect(body.versions.apps).toContainEqual({ version: "7.0 (1)", users: 1 });
    expect(body.versions.os).toContainEqual({ version: "macOS 26.1", users: 1 });
    expect(body.versions.activeUsers).toBeGreaterThanOrEqual(1);
    expect(body.purposes.totals).toContainEqual({ purpose: "note", inputTokens: 1000, outputTokens: 200, calls: 2 });
    expect(body.purposes.daily.some((row: { day: string }): boolean => row.day === dayOf(nowMs, -40))).toBe(false);
    expect(body.events.counts).toContainEqual({ kind: "final_pass_give_up", appVersion: "7.0 (1)", count: 4 });
    expect(body.events.daily).toContainEqual({ day: dayOf(nowMs, -2), kind: "final_pass_give_up", count: 4 });
    expect(body.events.durations).toContainEqual({ kind: "final_pass_duration", bucket: "le_300", count: 2, secondsSum: 400 });
    expect(body.events.durationBuckets).toEqual([...telemetryDurationBuckets]);
    expect(body.features.reports).toBeGreaterThanOrEqual(5);
    expect(body.features.rows).toContainEqual({ feature: "on_device_live", value: "", users: 2, total: 2 });
    expect(body.features.rows.some((row: { feature: string }): boolean => row.feature === "report")).toBe(false);
    // Yönetici olmayan 403.
    await expectError(await harness.call(req("GET", "/v1/admin/telemetry", { token: user.accessToken, env: adminEnv })), 403, "forbidden");
  });
});

describe("telemetri toplamlarının saklama süresi", () => {
  it("400 günden eski toplamlar silinir", async () => {
    const nowMs: number = Date.UTC(2026, 9, 15, 12, 0, 0);
    await env.DB.batch([
      env.DB.prepare("INSERT INTO llm_purpose_usage (day, purpose, input_tokens, output_tokens, calls) VALUES (?, 'ask_answer', 1, 1, 1), (?, 'ask_answer', 1, 1, 1)").bind(
        dayOf(nowMs, -401),
        dayOf(nowMs, -399),
      ),
      env.DB.prepare("INSERT INTO client_event_counts (day, kind, app_version, count) VALUES (?, 'k', 'v', 1), (?, 'k', 'v', 1)").bind(dayOf(nowMs, -401), dayOf(nowMs, -399)),
      env.DB.prepare(
        "INSERT INTO client_event_durations (day, kind, app_version, bucket, count, seconds_sum) VALUES (?, 'k', 'v', 'le_10', 1, 1), (?, 'k', 'v', 'le_10', 1, 1)",
      ).bind(dayOf(nowMs, -401), dayOf(nowMs, -399)),
      env.DB.prepare("INSERT INTO feature_usage_daily (day, feature, value, users, total) VALUES (?, 'ask', '', 1, 1), (?, 'ask', '', 1, 1)").bind(
        dayOf(nowMs, -401),
        dayOf(nowMs, -399),
      ),
    ]);
    const report = await cleanupExpiredRows(env.DB, new Date(nowMs), { batchSize: 100, maxBatchesPerTable: 2 });
    expect(report["llm_purpose_usage"]).toBeGreaterThanOrEqual(1);
    for (const table of ["llm_purpose_usage", "client_event_counts", "client_event_durations", "feature_usage_daily"]) {
      const old = await env.DB.prepare(`SELECT COUNT(*) AS count FROM ${table} WHERE day = ?`).bind(dayOf(nowMs, -401)).first<{ count: number }>();
      const recent = await env.DB.prepare(`SELECT COUNT(*) AS count FROM ${table} WHERE day = ?`).bind(dayOf(nowMs, -399)).first<{ count: number }>();
      expect({ table, old: old?.count, recent: recent?.count }).toEqual({ table, old: 0, recent: 1 });
    }
  });
});
