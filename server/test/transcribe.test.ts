import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { elevenLabsSpeechToTextUrl } from "../src/transcribe";
import {
  type Harness,
  type Session,
  type StartedMeetingBody,
  defaultHarness,
  expectError,
  grantSubscription,
  req,
  signIn,
  startMeeting,
  wavFile,
} from "./helpers";

interface Context {
  readonly harness: Harness;
  readonly session: Session;
  readonly meeting: StartedMeetingBody;
}

async function setup(subscribed: boolean): Promise<Context> {
  const harness: Harness = await defaultHarness();
  const session: Session = await signIn(harness);
  if (subscribed) {
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
  }
  const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
  return { harness, session, meeting };
}

function upload(context: Context, query: string, audio: Uint8Array, contentType: string): Promise<Response> {
  return context.harness.call(
    req("POST", `/v1/transcribe${query}`, {
      token: context.session.accessToken,
      headers: { "x-meeting-id": context.meeting.meetingId, "content-type": contentType, "content-length": String(audio.byteLength) },
      body: audio,
    }),
  );
}

const transcription = {
  language_code: "tur",
  language_probability: 0.98,
  text: "Merhaba dünya",
  words: [
    { text: "Merhaba", type: "word", start: 0.1, end: 0.6, speaker_id: "speaker_0", logprob: -0.1 },
    { text: " ", type: "spacing", start: 0.6, end: 0.7, speaker_id: "speaker_0", logprob: 0 },
    { text: "dünya", type: "word", start: 0.7, end: 1.2, speaker_id: "speaker_1", logprob: -0.2 },
  ],
  audio_duration_secs: 125.5,
};

describe("konuşma tanıma vekili", () => {
  it("yalnızca izinli alanları ElevenLabs'e iletir, süreyi aylık kullanıma yazar", async () => {
    const context: Context = await setup(true);
    const fields: Array<[string, string]> = [];
    let file: File | null = null;
    let key: string | null = null;
    context.harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
      key = request.headers.get("xi-api-key");
      const form: FormData = await request.formData();
      for (const [name, value] of form.entries()) {
        if (typeof value === "string") {
          fields.push([name, value]);
        } else {
          file = value;
        }
      }
      return Response.json(transcription);
    });
    const audio: Uint8Array = new Uint8Array(64_000).fill(7);
    const response: Response = await upload(context, "?language_code=tr&diarize=true&keyterms=Şenol&keyterms=AI%20Notepad", audio, "audio/mp4");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(transcription);
    expect(key).toBe(env.ELEVENLABS_API_KEY);
    expect(fields).toEqual([
      ["model_id", "scribe_v2"],
      ["diarize", "true"],
      ["tag_audio_events", "false"],
      ["no_verbatim", "true"],
      ["timestamps_granularity", "word"],
      ["language_code", "tr"],
      ["keyterms", "Şenol"],
      ["keyterms", "AI Notepad"],
    ]);
    const sent = file as File | null;
    expect(sent?.size).toBe(64_000);
    expect(sent?.name).toBe("audio.m4a");

    const meeting = await env.DB.prepare("SELECT audio_seconds FROM meeting_sessions WHERE id = ?").bind(context.meeting.meetingId).first<{ audio_seconds: number }>();
    expect(meeting?.audio_seconds).toBe(125.5);
    const usage = await env.DB.prepare("SELECT audio_seconds FROM monthly_usage WHERE user_id = ?").bind(context.session.userId).first<{ audio_seconds: number }>();
    expect(usage?.audio_seconds).toBe(125.5);
  });

  it("bilinmeyen parametre, geçersiz terim, çok fazla terim ve izinsiz tür reddedilir", async () => {
    const context: Context = await setup(false);
    const audio: Uint8Array = new Uint8Array(1000);
    await expectError(await upload(context, "?webhook=true", audio, "audio/wav"), 400, "invalid_body");
    await expectError(await upload(context, "?keyterms=%3Cscript%3E", audio, "audio/wav"), 400, "invalid_body");
    await expectError(await upload(context, `?${Array.from({ length: 101 }, (_: unknown, index: number): string => `keyterms=t${index}`).join("&")}`, audio, "audio/wav"), 400, "invalid_body");
    await expectError(await upload(context, "", audio, "video/mp4"), 415, "unsupported_media_type");
    expect(context.harness.outbound.filter((request: Request): boolean => request.url.startsWith(elevenLabsSpeechToTextUrl))).toHaveLength(0);
  });

  it("Content-Length zorunludur ve 95 MB sınırı gövde okunmadan uygulanır", async () => {
    const context: Context = await setup(false);
    const tooBig: Response = await context.harness.call(
      req("POST", "/v1/transcribe", {
        token: context.session.accessToken,
        headers: { "x-meeting-id": context.meeting.meetingId, "content-type": "audio/wav", "content-length": "95000001" },
        body: new Uint8Array(10),
      }),
    );
    await expectError(tooBig, 413, "payload_too_large");
    const stream: ReadableStream<Uint8Array> = new ReadableStream<Uint8Array>({
      start(controller: ReadableStreamDefaultController<Uint8Array>): void {
        controller.enqueue(new Uint8Array(10));
        controller.close();
      },
    });
    const noLength: Response = await context.harness.call(
      req("POST", "/v1/transcribe", {
        token: context.session.accessToken,
        headers: { "x-meeting-id": context.meeting.meetingId, "content-type": "audio/wav" },
        body: stream,
      }),
    );
    await expectError(noLength, 411, "length_required");
  });

  it("boyuttan tahmin edilen süre kalan aylık süreyi aşarsa ElevenLabs'e gitmeden reddedilir", async () => {
    const context: Context = await setup(true);
    await env.DB.prepare("INSERT INTO monthly_usage (user_id, month, audio_seconds) VALUES (?, ?, ?)")
      .bind(context.session.userId, new Date(context.harness.clock.nowMs).toISOString().slice(0, 7), 10 * 3600 - 60)
      .run();
    // En düşük AAC hızı 1000 B/s ile 4 MB ≈ 4000 saniye > kalan 60 saniye.
    await expectError(await upload(context, "", new Uint8Array(4_000_000), "audio/mp4"), 403, "monthly_cap_reached");
    expect(context.harness.outbound.filter((request: Request): boolean => request.url.startsWith(elevenLabsSpeechToTextUrl))).toHaveLength(0);
  });

  it("toplantının en uzun süresinden uzun ses reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    // Ayda 1 dakika kaldı: toplantı en çok 1 dakika sürer.
    await env.DB.prepare("INSERT INTO monthly_usage (user_id, month, audio_seconds) VALUES (?, ?, ?)")
      .bind(session.userId, new Date(harness.clock.nowMs).toISOString().slice(0, 7), 10 * 3600 - 60)
      .run();
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    expect(meeting.maxDurationMinutes).toBe(1);
    // En düşük AAC hızı 1000 B/s ile 4 MB ≈ 4000 saniye > 60 saniye.
    await expectError(await upload({ harness, session, meeting }, "", new Uint8Array(4_000_000), "audio/mp4"), 413, "audio_too_long");
  });

  it("ElevenLabs hatası gövdesi sızdırılmadan 502 olur ve kullanım yazılmaz", async () => {
    const context: Context = await setup(false);
    context.harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
      await request.arrayBuffer();
      return Response.json({ detail: { message: "invalid api key xi-123" } }, { status: 401 });
    });
    const body = await expectError(await upload(context, "?diarize=true", wavFile(16_000, 1, 16, 32_000), "audio/wav"), 502, "upstream_rejected");
    expect(body.error.message).not.toContain("xi-123");
    await context.harness.drain();
    // Ayırma geri verildi, süre yazılmadı.
    const usage = await env.DB.prepare("SELECT audio_seconds, audio_reserved FROM monthly_usage WHERE user_id = ?")
      .bind(context.session.userId)
      .first<{ audio_seconds: number; audio_reserved: number }>();
    expect(usage).toEqual({ audio_seconds: 0, audio_reserved: 0 });
    const meeting = await env.DB.prepare("SELECT audio_seconds, audio_reserved FROM meeting_sessions WHERE id = ?")
      .bind(context.meeting.meetingId)
      .first<{ audio_seconds: number; audio_reserved: number }>();
    expect(meeting).toEqual({ audio_seconds: 0, audio_reserved: 0 });
  });

  it("yanıtta süre yoksa son kelime ile WAV başlığındaki süreden büyüğü ücretlendirilir", async () => {
    const context: Context = await setup(false);
    context.harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
      await request.arrayBuffer();
      return Response.json({ ...transcription, audio_duration_secs: null });
    });
    expect((await upload(context, "", wavFile(16_000, 1, 16, 32_000 * 3), "audio/wav")).status).toBe(200);
    const meeting = await env.DB.prepare("SELECT audio_seconds FROM meeting_sessions WHERE id = ?").bind(context.meeting.meetingId).first<{ audio_seconds: number }>();
    expect(meeting?.audio_seconds).toBe(3);
  });
});
