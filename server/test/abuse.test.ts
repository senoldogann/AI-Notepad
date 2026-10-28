import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import type { Env } from "../src/env";
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

async function meetingAudio(meetingId: string): Promise<{ audio_seconds: number; audio_reserved: number; transcription_closed: number }> {
  const row = await env.DB.prepare("SELECT audio_seconds, audio_reserved, transcription_closed FROM meeting_sessions WHERE id = ?")
    .bind(meetingId)
    .first<{ audio_seconds: number; audio_reserved: number; transcription_closed: number }>();
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
    expect(await meetingAudio(meeting.meetingId)).toEqual({ audio_seconds: 100, audio_reserved: 0, transcription_closed: 0 });
  });

  it("düşük bit hızlı Opus en düşük gerçekçi hızla (750 B/s) tahmin edilir ve reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    const scribe = stubScribe(harness, 10);
    // 90 dakikalık deneme = 5400 s; 5 MB / 750 B/s ≈ 6667 s.
    await expectError(await transcribe(harness, session, meeting.meetingId, new Uint8Array(5_000_000), "audio/ogg", null), 413, "audio_too_long");
    expect(scribe.calls).toBe(0);
  });

  it("gerçek süre ayrılanı aşarsa süre yazılır, ses hakkı kapanır ve alarm logu düşer", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    stubScribe(harness, 500);
    const alerts = vi.spyOn(console, "error");
    // 64 KB m4a → üst sınır 64 s; ElevenLabs 500 s diyor.
    expect((await transcribe(harness, session, meeting.meetingId, new Uint8Array(64_000), "audio/mp4", null)).status).toBe(200);
    expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"transcription_overrun"'))).toBe(true);
    alerts.mockRestore();
    expect(await meetingAudio(meeting.meetingId)).toEqual({ audio_seconds: 500, audio_reserved: 0, transcription_closed: 1 });
    await expectError(await transcribe(harness, session, meeting.meetingId, new Uint8Array(1000), "audio/mp4", null), 403, "transcription_closed");
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
    const monthly = await env.DB.prepare("SELECT input_tokens, output_tokens, tokens_reserved FROM monthly_usage WHERE user_id = ? AND month = ?")
      .bind(session.userId, month)
      .first<{ input_tokens: number; output_tokens: number; tokens_reserved: number }>();
    expect(monthly).toEqual({ input_tokens: 6_500_000 - 1500 + 100, output_tokens: 50, tokens_reserved: 0 });
    const daily = await env.DB.prepare("SELECT tokens_used, tokens_reserved FROM daily_usage WHERE user_id = ?")
      .bind(session.userId)
      .first<{ tokens_used: number; tokens_reserved: number }>();
    expect(daily).toEqual({ tokens_used: 150, tokens_reserved: 0 });
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
