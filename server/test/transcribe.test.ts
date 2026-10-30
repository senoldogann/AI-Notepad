import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { base64UrlEncode, sha256Hex } from "../src/crypto";
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
  return uploadWith(context, query, audio, contentType, {});
}

function uploadWith(context: Context, query: string, audio: Uint8Array, contentType: string, headers: Readonly<Record<string, string>>): Promise<Response> {
  return context.harness.call(
    req("POST", `/v1/transcribe${query}`, {
      token: context.session.accessToken,
      headers: { "x-meeting-id": context.meeting.meetingId, "content-type": contentType, "content-length": String(audio.byteLength), ...headers },
      body: audio,
    }),
  );
}

/** `x-keyterms` başlığının değeri: UTF-8 JSON'un dolgusuz base64url'i. */
function keytermsHeader(terms: readonly string[]): string {
  return base64UrlEncode(new TextEncoder().encode(JSON.stringify(terms)));
}

/** ElevenLabs'e giden form alanlarını toplayan sahte. */
function stubFormFields(context: Context): Array<[string, string]> {
  const fields: Array<[string, string]> = [];
  context.harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
    const form: FormData = await request.formData();
    for (const [name, value] of form.entries()) {
      if (typeof value === "string") {
        fields.push([name, value]);
      }
    }
    return Response.json(transcription);
  });
  return fields;
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
    const audio: Uint8Array = wavFile(16_000, 1, 16, 64_000);
    const response: Response = await upload(context, "?language_code=tr&diarize=true&keyterms=Şenol&keyterms=AI%20Notepad", audio, "audio/wav");
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
    expect(sent?.size).toBe(64_044);
    expect(sent?.name).toBe("audio.wav");

    const meeting = await env.DB.prepare("SELECT audio_seconds FROM meeting_sessions WHERE id = ?").bind(context.meeting.meetingId).first<{ audio_seconds: number }>();
    expect(meeting?.audio_seconds).toBe(125.5);
    const usage = await env.DB.prepare("SELECT audio_seconds FROM monthly_usage WHERE user_id = ?").bind(context.session.userId).first<{ audio_seconds: number }>();
    expect(usage?.audio_seconds).toBe(125.5);
  });

  it("aynı yükleme anahtarıyla tekrar (yanıt kayboldu) sonucu yeniden işlemeden ve faturalamadan döndürür", async () => {
    const context: Context = await setup(true);
    let calls: number = 0;
    context.harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
      calls += 1;
      await request.formData();
      return Response.json({ ...transcription, audio_duration_secs: 2 });
    });
    const audio: Uint8Array = wavFile(16_000, 1, 16, 64_000);
    const key: string = base64UrlEncode(crypto.getRandomValues(new Uint8Array(32)));
    const first: Response = await uploadWith(context, "", audio, "audio/wav", { "x-upload-key": key });
    expect(first.status).toBe(200);
    const repeated: Response = await uploadWith(context, "", audio, "audio/wav", { "x-upload-key": key });
    expect(repeated.status).toBe(200);
    expect(await repeated.json()).toEqual({ ...transcription, audio_duration_secs: 2 });
    expect(calls).toBe(1);
    const usage = await env.DB.prepare("SELECT audio_seconds FROM monthly_usage WHERE user_id = ?").bind(context.session.userId).first<{ audio_seconds: number }>();
    expect(usage?.audio_seconds).toBe(2);
    // Saklı sonuç şifrelidir: ne düz metin ne de yalnızca sıkıştırılmış (gzip) metin; yalın gzip açılabilirdi.
    const stored = await env.DB.prepare("SELECT ciphertext FROM transcription_results WHERE key_hash = ?")
      .bind(await sha256Hex(key))
      .first<{ ciphertext: ArrayBuffer }>();
    expect(stored).not.toBeNull();
    const bytes: Uint8Array = new Uint8Array(stored?.ciphertext ?? new ArrayBuffer(0));
    expect(bytes.byteLength).toBeGreaterThan(0);
    expect([bytes[0], bytes[1]]).not.toEqual([0x1f, 0x8b]);
    await expect(new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"))).text()).rejects.toThrow();
    // Başka anahtar yeni yüklemedir.
    const other: Response = await uploadWith(context, "", audio, "audio/wav", { "x-upload-key": base64UrlEncode(crypto.getRandomValues(new Uint8Array(32))) });
    expect(other.status).toBe(200);
    expect(calls).toBe(2);
  });

  it("ödenmiş sonuç pencere ve harcama tavanından önce döner; saklama hatası yanıtı düşürmez; büyük sonuç saklanmaz", async () => {
    const context: Context = await setup(true);
    let calls: number = 0;
    let words: object[] = transcription.words;
    context.harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
      calls += 1;
      await request.formData();
      return Response.json({ ...transcription, words, audio_duration_secs: 2 });
    });
    const audio: Uint8Array = wavFile(16_000, 1, 16, 64_000);
    const key: string = base64UrlEncode(crypto.getRandomValues(new Uint8Array(32)));
    expect((await uploadWith(context, "", audio, "audio/wav", { "x-upload-key": key })).status).toBe(200);
    // Toplantı bitti, ek süresi (30 dk) geçti ve günlük harcama tavanı doldu: ödenmiş sonuç (2 saat saklanır) yine döner.
    expect((await context.harness.call(req("POST", `/v1/meetings/${context.meeting.meetingId}/end`, { token: context.session.accessToken }))).status).toBe(200);
    context.harness.clock.nowMs += 45 * 60_000;
    await env.DB.prepare("INSERT INTO daily_spend (day, micro_usd) VALUES (?, ?) ON CONFLICT(day) DO UPDATE SET micro_usd = excluded.micro_usd")
      .bind(new Date(context.harness.clock.nowMs).toISOString().slice(0, 10), 1_000_000_000_000)
      .run();
    const fresh: Session = await (await context.harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: context.session.refreshToken } }))).json<Session>();
    const late: Context = { ...context, session: fresh };
    expect((await uploadWith(late, "", audio, "audio/wav", { "x-upload-key": key })).status).toBe(200);
    expect(calls).toBe(1);
    await env.DB.prepare("DELETE FROM daily_spend").run();

    // Saklama başarısız: ses faturalandı, yanıt yine 200 ve alarm yazılır.
    const second: Context = await setup(true);
    second.harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
      await request.formData();
      return Response.json({ ...transcription, words, audio_duration_secs: 2 });
    });
    const encrypt = vi.spyOn(crypto.subtle, "encrypt").mockRejectedValueOnce(new Error("şifreleme başarısız"));
    const alerts = vi.spyOn(console, "error");
    const failed: Response = await uploadWith(second, "", audio, "audio/wav", { "x-upload-key": base64UrlEncode(crypto.getRandomValues(new Uint8Array(32))) });
    encrypt.mockRestore();
    expect(failed.status).toBe(200);
    expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"transcription_cache_failed"'))).toBe(true);
    alerts.mockRestore();

    // Sıkıştırılsa da 1,9 MB'ı aşan sonuç saklanmaz (uyarı); yanıt döner.
    words = Array.from({ length: 2_000 }, (_: unknown, index: number): object => ({
      text: base64UrlEncode(crypto.getRandomValues(new Uint8Array(1_500))), type: "word", start: index, end: index + 0.5, speaker_id: "speaker_0", logprob: 0,
    }));
    const warnings = vi.spyOn(console, "warn");
    const bigKey: string = base64UrlEncode(crypto.getRandomValues(new Uint8Array(32)));
    const big: Response = await uploadWith(second, "", audio, "audio/wav", { "x-upload-key": bigKey });
    expect(big.status).toBe(200);
    expect(warnings.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"transcription_cache_skipped"'))).toBe(true);
    warnings.mockRestore();
  });

  it("anahtar terimler x-keyterms başlığından (base64url JSON) iletilir; değerler loglanmaz", async () => {
    const context: Context = await setup(true);
    const fields: Array<[string, string]> = stubFormFields(context);
    const lines: string[] = [];
    const spies = (["log", "warn", "error"] as const).map((level) =>
      vi.spyOn(console, level).mockImplementation((...args: unknown[]): void => {
        lines.push(args.map((arg: unknown): string => String(arg)).join(" "));
      }),
    );
    try {
      const response: Response = await uploadWith(context, "?language_code=tr", wavFile(16_000, 1, 16, 32_000), "audio/wav", {
        "x-keyterms": keytermsHeader(["Şenol", "AI Notepad", "Gizli Proje Zümrüt"]),
      });
      expect(response.status).toBe(200);
    } finally {
      for (const spy of spies) {
        spy.mockRestore();
      }
    }
    expect(fields.filter(([name]): boolean => name === "keyterms")).toEqual([
      ["keyterms", "Şenol"],
      ["keyterms", "AI Notepad"],
      ["keyterms", "Gizli Proje Zümrüt"],
    ]);
    expect(lines.some((line: string): boolean => line.includes('"event":"transcription_usage"') && line.includes('"keyterms":3'))).toBe(true);
    expect(lines.some((line: string): boolean => line.includes("Zümrüt"))).toBe(false);
  });

  it("x-keyterms başlığı sorgudakiyle aynı sınırlara tabidir; bozuk biçim ve iki biçim birlikte reddedilir", async () => {
    const context: Context = await setup(false);
    const audio: Uint8Array = wavFile(8000, 1, 8, 8000);
    const send = (value: string, query: string): Promise<Response> => uploadWith(context, query, audio, "audio/wav", { "x-keyterms": value });
    await expectError(await send(keytermsHeader(["<script>"]), ""), 400, "invalid_body");
    await expectError(await send(keytermsHeader(["x".repeat(50)]), ""), 400, "invalid_body");
    await expectError(await send(keytermsHeader(["bir iki üç dört beş altı"]), ""), 400, "invalid_body");
    await expectError(await send(keytermsHeader(Array.from({ length: 101 }, (_: unknown, index: number): string => `t${index}`)), ""), 400, "invalid_body");
    // Dolgulu base64, standart base64 karakterleri, JSON olmayan ve dizgi dizisi olmayan içerik.
    await expectError(await send(`${keytermsHeader(["ab"])}=`, ""), 400, "invalid_body");
    await expectError(await send("+/+/", ""), 400, "invalid_body");
    await expectError(await send(base64UrlEncode(new TextEncoder().encode("Şenol")), ""), 400, "invalid_body");
    await expectError(await send(keytermsHeader([1, 2] as unknown as string[]), ""), 400, "invalid_body");
    await expectError(await send(keytermsHeader(["Şenol"]), "?keyterms=AI"), 400, "invalid_body");
    expect(context.harness.outbound.filter((request: Request): boolean => request.url.startsWith(elevenLabsSpeechToTextUrl))).toHaveLength(0);
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

  it("WAV başlığındaki süre kalan aylık süreyi aşarsa ElevenLabs'e gitmeden reddedilir", async () => {
    const context: Context = await setup(true);
    await env.DB.prepare("INSERT INTO monthly_usage (user_id, month, audio_seconds) VALUES (?, ?, ?)")
      .bind(context.session.userId, new Date(context.harness.clock.nowMs).toISOString().slice(0, 7), 10 * 3600 - 60)
      .run();
    // 8000 B/s ile 70 saniye > kalan 60 saniye.
    await expectError(await upload(context, "", wavFile(8000, 1, 8, 8000 * 70), "audio/wav"), 403, "monthly_cap_reached");
    expect(context.harness.outbound.filter((request: Request): boolean => request.url.startsWith(elevenLabsSpeechToTextUrl))).toHaveLength(0);
  });

  it("aylık süre toplantı başına süre ile sesin büyüğüdür: uzun canlı toplantı ile uzun içe aktarma birbirini örtmez", async () => {
    const context: Context = await setup(true);
    const { harness, session } = context;
    // 10 dakikalık canlı toplantı (sesi yazıya dökülmedi).
    harness.clock.nowMs += 10 * 60_000;
    expect((await harness.call(req("POST", `/v1/meetings/${context.meeting.meetingId}/end`, { token: session.accessToken }))).status).toBe(200);
    // İçe aktarılan 10 dakikalık dosya: oturum açılıp hemen kapanır, ses sonra yazılır.
    const imported: StartedMeetingBody = await (
      await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: { clientRef: "ice-aktarim-l2", deferred: true } }))
    ).json<StartedMeetingBody>();
    expect((await harness.call(req("POST", `/v1/meetings/${imported.meetingId}/end`, { token: session.accessToken }))).status).toBe(200);
    harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
      await request.formData();
      return Response.json({ ...transcription, audio_duration_secs: 600 });
    });
    const audio: Uint8Array = wavFile(8000, 1, 8, 8000 * 600);
    expect((await upload({ harness, session, meeting: imported }, "", audio, "audio/wav")).status).toBe(200);
    await harness.drain();
    // Toplamların büyüğü 10 dk olurdu; toplantı başına büyüklerin toplamı 20 dk.
    const me = await (await harness.call(req("GET", "/v1/me", { token: session.accessToken }))).json<{ monthlyHoursUsed: number }>();
    expect(me.monthlyHoursUsed).toBe(0.4);
  });

  it("parça örtüşmesi aylık süreye sayılmaz: aylık sınıra tam sığan uzun kaydın son parçası reddedilmez", async () => {
    const context: Context = await setup(true);
    const { harness, session } = context;
    // Ayda 3000 sn kaldı (önceki aydan kalma toplantıların sesi gibi sayılır).
    await env.DB.prepare("INSERT INTO monthly_usage (user_id, month, audio_seconds) VALUES (?, ?, ?)")
      .bind(session.userId, new Date(harness.clock.nowMs).toISOString().slice(0, 7), 10 * 3600 - 3000)
      .run();
    expect((await harness.call(req("POST", `/v1/meetings/${context.meeting.meetingId}/end`, { token: session.accessToken }))).status).toBe(200);
    const imported: StartedMeetingBody = await (
      await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: { clientRef: "ice-aktarim-ortusme", deferred: true } }))
    ).json<StartedMeetingBody>();
    let seconds: number = 2968;
    harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
      await request.formData();
      return Response.json({ ...transcription, audio_duration_secs: seconds });
    });
    const target: Context = { harness, session, meeting: imported };
    expect((await upload(target, "", wavFile(8000, 1, 8, 8000 * 2968), "audio/wav")).status).toBe(200);
    // İkinci parça öncekinin son dakikasıyla başlar: 60 sn örtüşme + 32 sn yeni ses.
    seconds = 92;
    expect((await upload(target, "", wavFile(8000, 1, 8, 8000 * 92), "audio/wav")).status).toBe(200);
    const me = await (await harness.call(req("GET", "/v1/me", { token: session.accessToken }))).json<{ monthlyHoursUsed: number }>();
    expect(me.monthlyHoursUsed).toBe(10);
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
    // 8000 B/s ile 70 saniye > 60 saniye.
    await expectError(await upload({ harness, session, meeting }, "", wavFile(8000, 1, 8, 8000 * 70), "audio/wav"), 413, "audio_too_long");
  });

  it("istemci yükleme ortasında koparsa ayırma kapanır, kullanım ve harcama yazılmaz, toplantı yeni ses kabul eder", async () => {
    const context: Context = await setup(false);
    stubFormFields(context);
    const audio: Uint8Array = wavFile(8000, 1, 8, 8000 * 10);
    // Gövde başlıktan sonra kopar (istemci bağlantısı düştü).
    const broken: ReadableStream<Uint8Array> = new ReadableStream<Uint8Array>({
      start(controller: ReadableStreamDefaultController<Uint8Array>): void {
        controller.enqueue(audio.subarray(0, 4096));
        controller.error(new TypeError("istemci bağlantısı koptu"));
      },
    });
    const response: Response = await context.harness.call(
      req("POST", "/v1/transcribe", {
        token: context.session.accessToken,
        headers: { "x-meeting-id": context.meeting.meetingId, "content-type": "audio/wav", "content-length": String(audio.byteLength) },
        body: broken,
      }),
    );
    expect(response.status).toBeGreaterThanOrEqual(400);
    await context.harness.drain();
    const state = await env.DB.prepare(
      "SELECT audio_seconds, (SELECT COUNT(*) FROM usage_reservations WHERE meeting_id = ?1) AS open FROM meeting_sessions WHERE id = ?1",
    )
      .bind(context.meeting.meetingId)
      .first<{ audio_seconds: number; open: number }>();
    expect(state).toEqual({ audio_seconds: 0, open: 0 });
    expect((await upload(context, "", audio, "audio/wav")).status).toBe(200);
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
    // Ayırma kapandı, süre yazılmadı.
    const usage = await env.DB.prepare("SELECT audio_seconds FROM monthly_usage WHERE user_id = ?")
      .bind(context.session.userId)
      .first<{ audio_seconds: number }>();
    expect(usage?.audio_seconds ?? 0).toBe(0);
    const meeting = await env.DB.prepare(
      "SELECT audio_seconds, (SELECT COUNT(*) FROM usage_reservations WHERE meeting_id = ?1) AS open FROM meeting_sessions WHERE id = ?1",
    )
      .bind(context.meeting.meetingId)
      .first<{ audio_seconds: number; open: number }>();
    expect(meeting).toEqual({ audio_seconds: 0, open: 0 });
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
