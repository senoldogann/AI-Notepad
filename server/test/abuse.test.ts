import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import type { Env } from "../src/env";
import { cleanupExpiredRows } from "../src/cleanup";
import { elevenLabsSpeechToTextUrl } from "../src/transcribe";
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
  wavFile,
} from "./helpers";

const anthropicUrl: string = "https://api.anthropic.com/v1/messages";

function transcribe(harness: Harness, session: Session, meetingId: string, audio: Uint8Array, contentType: string, environment: Env | null): Promise<Response> {
  return harness.call(
    req("POST", "/v1/transcribe", {
      token: session.accessToken,
      headers: { "x-meeting-id": meetingId, "content-type": contentType, "content-length": String(audio.byteLength) },
      body: audio,
      env: environment,
    }),
  );
}

function stubScribe(harness: Harness, durationSeconds: number): { calls: number } {
  const counter = { calls: 0 };
  harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
    await request.arrayBuffer();
    counter.calls += 1;
    return Response.json({ language_code: "tur", language_probability: 1, text: "", words: [], audio_duration_secs: durationSeconds });
  });
  return counter;
}

/** Toplantının ses durumu ve süren (kesinleşmemiş) ayırma sayısı. */
async function meetingAudio(meetingId: string): Promise<{ audio_seconds: number; open_reservations: number; transcription_closed: number }> {
  const row = await env.DB.prepare(
    `SELECT audio_seconds, transcription_closed,
       (SELECT COUNT(*) FROM usage_reservations WHERE meeting_id = ?1) AS open_reservations
     FROM meeting_sessions WHERE id = ?1`,
  )
    .bind(meetingId)
    .first<{ audio_seconds: number; open_reservations: number; transcription_closed: number }>();
  if (row === null) {
    throw new Error("toplantı yok");
  }
  return row;
}

function llm(harness: Harness, session: Session, meetingId: string): Promise<Response> {
  return harness.call(
    req("POST", "/v1/llm/messages", {
      token: session.accessToken,
      headers: { "x-meeting-id": meetingId },
      json: { effort: "low", max_tokens: 2000, messages: [{ role: "user", content: "x" }] },
    }),
  );
}

function stubHaiku(harness: Harness): void {
  harness.stub(anthropicUrl, async (): Promise<Response> =>
    Response.json({
      id: "msg_1",
      type: "message",
      role: "assistant",
      model: "claude-haiku-5-5",
      content: [{ type: "text", text: "ok" }],
      stop_reason: "end_turn",
      stop_sequence: null,
      usage: { input_tokens: 100, output_tokens: 50, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
    }),
  );
}

describe("deneme ses süresi birikimli sınırı", () => {
  it("toplantının yüklemeleri birikimli sayılır; en uzun süreyi aşan yükleme ElevenLabs'e gitmez", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    // Deneme toplantısı 2 dakika (120 saniye) olsun.
    const short: Env = envWith({ TRIAL_MAX_MEETING_MINUTES: "2" });
    const meeting: StartedMeetingBody = await (await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {}, env: short }))).json<StartedMeetingBody>();
    const scribe = stubScribe(harness, 50);
    // 8 kHz, 8 bit, tek kanal: 8000 B/s; 50 saniye.
    const fifty: Uint8Array = wavFile(8000, 1, 8, 8000 * 50);
    expect((await transcribe(harness, session, meeting.meetingId, fifty, "audio/wav", short)).status).toBe(200);
    expect((await transcribe(harness, session, meeting.meetingId, fifty, "audio/wav", short)).status).toBe(200);
    await expectError(await transcribe(harness, session, meeting.meetingId, fifty, "audio/wav", short), 413, "audio_too_long");
    expect(scribe.calls).toBe(2);
    expect(await meetingAudio(meeting.meetingId)).toEqual({ audio_seconds: 100, open_reservations: 0, transcription_closed: 0 });
  });

  it("49 dakikadan uzun toplantıda parça sınırı başına bir dakika örtüşme payı vardır; payın ötesi reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    // 50 dakikalık toplantı: bir parça sınırı, 60 sn pay (3000 + 60 sn).
    const long: Env = envWith({ TRIAL_MAX_MEETING_MINUTES: "50" });
    const meeting: StartedMeetingBody = await (await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {}, env: long }))).json<StartedMeetingBody>();
    const scribe = stubScribe(harness, 1530);
    // 8 kHz, 8 bit, tek kanal: 8000 B/s; 1530 saniye.
    const part: Uint8Array = wavFile(8000, 1, 8, 8000 * 1530);
    expect((await transcribe(harness, session, meeting.meetingId, part, "audio/wav", long)).status).toBe(200);
    expect((await transcribe(harness, session, meeting.meetingId, part, "audio/wav", long)).status).toBe(200);
    await expectError(await transcribe(harness, session, meeting.meetingId, wavFile(8000, 1, 8, 8000), "audio/wav", long), 413, "audio_too_long");
    expect(scribe.calls).toBe(2);
    expect(await meetingAudio(meeting.meetingId)).toEqual({ audio_seconds: 3060, open_reservations: 0, transcription_closed: 0 });
  });

  it("yeniden işlenen toplantı en çok kaydın gerçek süresi kadar yeni ses yazar (reprocess_audio_cap)", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    const scribe = stubScribe(harness, 10);
    const ten: Uint8Array = wavFile(8000, 1, 8, 8000 * 10);
    expect((await transcribe(harness, session, meeting.meetingId, ten, "audio/wav", null)).status).toBe(200);
    await env.DB.prepare("UPDATE meeting_sessions SET reprocess_audio_cap = 15 WHERE id = ?").bind(meeting.meetingId).run();
    await expectError(await transcribe(harness, session, meeting.meetingId, ten, "audio/wav", null), 413, "audio_too_long");
    await env.DB.prepare("UPDATE meeting_sessions SET reprocess_audio_cap = 20 WHERE id = ?").bind(meeting.meetingId).run();
    expect((await transcribe(harness, session, meeting.meetingId, ten, "audio/wav", null)).status).toBe(200);
    expect(scribe.calls).toBe(2);
  });

  it("yalnızca PCM WAV kabul edilir: sıkıştırılmış türler (süresi boyuttan kestirilemez) 415 alır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    const scribe = stubScribe(harness, 10);
    for (const type of ["audio/ogg", "audio/mp4", "audio/mpeg", "audio/webm", "audio/aac"]) {
      await expectError(await transcribe(harness, session, meeting.meetingId, new Uint8Array(5_000), type, null), 415, "unsupported_media_type");
    }
    expect(scribe.calls).toBe(0);
  });

  it("gerçek süre ayrılanı aşarsa süre yazılır, ses hakkı kapanır ve alarm logu düşer", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    stubScribe(harness, 500);
    const alerts = vi.spyOn(console, "error");
    // WAV başlığı 8 saniye diyor; ElevenLabs 500 s diyor.
    expect((await transcribe(harness, session, meeting.meetingId, wavFile(8000, 1, 8, 8000 * 8), "audio/wav", null)).status).toBe(200);
    expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"transcription_overrun"'))).toBe(true);
    alerts.mockRestore();
    expect(await meetingAudio(meeting.meetingId)).toEqual({ audio_seconds: 500, open_reservations: 0, transcription_closed: 1 });
    await expectError(await transcribe(harness, session, meeting.meetingId, wavFile(8000, 1, 8, 8000), "audio/wav", null), 403, "transcription_closed");
  });

  it("toplantıda aynı anda tek ses isteği işlenir; ikincisi 409 transcription_in_progress alır, ilki bitince açılır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    let release: () => void = (): void => undefined;
    const gate: Promise<void> = new Promise<void>((resolve: () => void): void => {
      release = resolve;
    });
    let calls: number = 0;
    harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
      await request.arrayBuffer();
      calls += 1;
      await gate;
      return Response.json({ language_code: "tur", language_probability: 1, text: "", words: [], audio_duration_secs: 10 });
    });
    const ten: Uint8Array = wavFile(8000, 1, 8, 8000 * 10);
    const first: Promise<Response> = transcribe(harness, session, meeting.meetingId, ten, "audio/wav", null);
    // İlk istek ElevenLabs'te beklerken ikinci istek gelir.
    for (let attempt: number = 0; attempt < 50 && calls === 0; attempt += 1) {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 10);
      });
    }
    expect(calls).toBe(1);
    await expectError(await transcribe(harness, session, meeting.meetingId, ten, "audio/wav", null), 409, "transcription_in_progress");
    release();
    expect((await first).status).toBe(200);
    expect((await transcribe(harness, session, meeting.meetingId, ten, "audio/wav", null)).status).toBe(200);
    expect(await meetingAudio(meeting.meetingId)).toEqual({ audio_seconds: 20, open_reservations: 0, transcription_closed: 0 });
  });

  it("kesinleşmemiş ses ayırmasının süresi dolunca toplantı yeniden ses kabul eder ve temizlik harcamayı yazar", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    // Worker kesinleştiremeden durmuş gibi: süren ses ayırması kalmış.
    const nowMs: number = harness.clock.nowMs;
    const day: string = new Date(nowMs).toISOString().slice(0, 10);
    await env.DB.prepare(
      `INSERT INTO usage_reservations (id, user_id, meeting_id, kind, month, day, tokens, trial_account_tokens, account_tokens,
         audio_seconds, estimated_micro_usd, trial_spend, created_at, expires_at)
       VALUES (?, ?, ?, 'audio', ?, ?, 0, 0, 0, 60, 4000, 1, ?, ?)`,
    )
      .bind(crypto.randomUUID(), session.userId, meeting.meetingId, day.slice(0, 7), day, nowMs, nowMs + 20 * 60_000)
      .run();
    stubScribe(harness, 10);
    const ten: Uint8Array = wavFile(8000, 1, 8, 8000 * 10);
    await expectError(await transcribe(harness, session, meeting.meetingId, ten, "audio/wav", null), 409, "transcription_in_progress");
    harness.clock.nowMs += 20 * 60_000 + 1;
    const later: Session = await refreshed(harness, session);
    expect((await transcribe(harness, later, meeting.meetingId, ten, "audio/wav", null)).status).toBe(200);
    const before = await env.DB.prepare("SELECT micro_usd, trial_micro_usd FROM daily_spend WHERE day = ?").bind(day).first<{ micro_usd: number; trial_micro_usd: number }>();
    const report = await cleanupExpiredRows(env.DB, new Date(harness.clock.nowMs), { batchSize: 100, maxBatchesPerTable: 2 });
    expect(report["usage_reservations"]).toBe(1);
    const after = await env.DB.prepare("SELECT micro_usd, trial_micro_usd FROM daily_spend WHERE day = ?").bind(day).first<{ micro_usd: number; trial_micro_usd: number }>();
    expect({ micro: (after?.micro_usd ?? 0) - (before?.micro_usd ?? 0), trial: (after?.trial_micro_usd ?? 0) - (before?.trial_micro_usd ?? 0) }).toEqual({
      micro: 4000,
      trial: 4000,
    });
    expect(await meetingAudio(meeting.meetingId)).toEqual({ audio_seconds: 10, open_reservations: 0, transcription_closed: 0 });
  });

  it("geçersiz ve PCM olmayan WAV reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    await expectError(await transcribe(harness, session, meeting.meetingId, new Uint8Array(1000), "audio/wav", null), 400, "invalid_body");
    const mulaw: Uint8Array = wavFile(8000, 1, 8, 8000);
    new DataView(mulaw.buffer).setUint16(20, 7, true);
    await expectError(await transcribe(harness, session, meeting.meetingId, mulaw, "audio/wav", null), 400, "invalid_body");
    // Başlıktaki bayt hızı tutarsız (gerçek süreyi kısa göstermeye çalışır).
    const lying: Uint8Array = wavFile(8000, 1, 8, 8000);
    new DataView(lying.buffer).setUint32(28, 1_000_000, true);
    await expectError(await transcribe(harness, session, meeting.meetingId, lying, "audio/wav", null), 400, "invalid_body");
  });

  it("FLAC kabul edilmez", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    await expectError(await transcribe(harness, session, meeting.meetingId, new Uint8Array(1000), "audio/flac", null), 415, "unsupported_media_type");
  });

  it("abonede aylık süre de birikimli ayrılır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    await env.DB.prepare("INSERT INTO monthly_usage (user_id, month, audio_seconds) VALUES (?, ?, ?)")
      .bind(session.userId, new Date(harness.clock.nowMs).toISOString().slice(0, 7), 10 * 3600 - 80)
      .run();
    stubScribe(harness, 50);
    const fifty: Uint8Array = wavFile(8000, 1, 8, 8000 * 50);
    expect((await transcribe(harness, session, meeting.meetingId, fifty, "audio/wav", null)).status).toBe(200);
    await expectError(await transcribe(harness, session, meeting.meetingId, fifty, "audio/wav", null), 403, "monthly_cap_reached");
  });
});

describe("abonenin token sınırları", () => {
  it("aylık token sınırı yeni toplantı açarak aşılamaz", async () => {
    const harness: Harness = await defaultHarness();
    stubHaiku(harness);
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    await env.DB.prepare("INSERT INTO monthly_usage (user_id, month, input_tokens) VALUES (?, ?, ?)")
      .bind(session.userId, new Date(harness.clock.nowMs).toISOString().slice(0, 7), 6_500_000 - 500)
      .run();
    for (let index: number = 0; index < 2; index += 1) {
      const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
      expect(meeting.tokenBudget).toBe(2_600_000);
      await expectError(await llm(harness, session, meeting.meetingId), 403, "monthly_cap_reached");
    }
  });

  it("max_tokens en dar sınıra (aylık kalan) kısılır ve kullanım aylık/günlük satırlara yazılır", async () => {
    const harness: Harness = await defaultHarness();
    let maxTokens: number = 0;
    harness.stub(anthropicUrl, async (request: Request): Promise<Response> => {
      maxTokens = (await request.json<{ max_tokens: number }>()).max_tokens;
      return Response.json({
        id: "msg_1",
        type: "message",
        role: "assistant",
        model: "claude-haiku-5-5",
        content: [{ type: "text", text: "ok" }],
        stop_reason: "end_turn",
        stop_sequence: null,
        usage: { input_tokens: 100, output_tokens: 50, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
      });
    });
    const session: Session = await signIn(harness);
    const month: string = new Date(harness.clock.nowMs).toISOString().slice(0, 7);
    await env.DB.prepare("INSERT INTO monthly_usage (user_id, month, input_tokens) VALUES (?, ?, ?)").bind(session.userId, month, 6_500_000 - 1500).run();
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    expect((await llm(harness, session, meeting.meetingId)).status).toBe(200);
    expect(maxTokens).toBeLessThan(1500);
    expect(maxTokens).toBeGreaterThan(1000);
    const monthly = await env.DB.prepare("SELECT input_tokens, output_tokens FROM monthly_usage WHERE user_id = ? AND month = ?")
      .bind(session.userId, month)
      .first<{ input_tokens: number; output_tokens: number }>();
    expect(monthly).toEqual({ input_tokens: 6_500_000 - 1500 + 100, output_tokens: 50 });
    const open = await env.DB.prepare("SELECT COUNT(*) AS count FROM usage_reservations WHERE user_id = ?").bind(session.userId).first<{ count: number }>();
    expect(open?.count).toBe(0);
    const daily = await env.DB.prepare("SELECT tokens_used FROM daily_usage WHERE user_id = ?")
      .bind(session.userId)
      .first<{ tokens_used: number }>();
    expect(daily).toEqual({ tokens_used: 150 });
  });

  it("günlük token sınırı aşılınca 429, ertesi gün açılır", async () => {
    const harness: Harness = await defaultHarness();
    stubHaiku(harness);
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    await env.DB.prepare("INSERT INTO daily_usage (user_id, day, tokens_used) VALUES (?, ?, ?)")
      .bind(session.userId, new Date(harness.clock.nowMs).toISOString().slice(0, 10), 3_000_000 - 100)
      .run();
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    await expectError(await llm(harness, session, meeting.meetingId), 429, "daily_cap_reached");
    harness.clock.nowMs += 86_400_000;
    const later: Session = await refreshed(harness, session);
    const next: StartedMeetingBody = await (await startMeeting(harness, later)).json<StartedMeetingBody>();
    expect((await llm(harness, later, next.meetingId)).status).toBe(200);
  });

  it("yeni toplantıyla kapanan toplantı ek süre almaz; normal biten alır", async () => {
    const harness: Harness = await defaultHarness();
    stubHaiku(harness);
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    const first: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    const second: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    await expectError(await llm(harness, session, first.meetingId), 403, "meeting_not_active");
    const reason = await env.DB.prepare("SELECT end_reason FROM meeting_sessions WHERE id = ?").bind(first.meetingId).first<{ end_reason: string }>();
    expect(reason?.end_reason).toBe("superseded");

    await harness.call(req("POST", `/v1/meetings/${second.meetingId}/end`, { token: session.accessToken }));
    expect((await llm(harness, session, second.meetingId)).status).toBe(200);
  });

  it("günlük toplantı başlatma sayısı sınırlıdır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    const limited: Env = envWith({ MAX_MEETING_STARTS_PER_DAY: "2" });
    const start = (): Promise<Response> => harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {}, env: limited }));
    expect((await start()).status).toBe(201);
    expect((await start()).status).toBe(201);
    await expectError(await start(), 429, "daily_cap_reached");
  });
});
