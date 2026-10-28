import { z } from "zod";
import type { Config } from "./config";
import { randomToken, utf8 } from "./crypto";
import { ApiError, UpstreamError, isRetryableStatus } from "./errors";
import { jsonResponse } from "./http";
import { errorName, log } from "./log";
import type { MeetingRow } from "./meetings";
import type { RequestContext } from "./platform";
import { audioReservationSteps, reserveAll, settleAudioStatements } from "./reservations";
import { addSpendStatement, transcriptionCostMicroUsd } from "./usage";

export const elevenLabsSpeechToTextUrl: string = "https://api.elevenlabs.io/v1/speech-to-text";
export const scribeModel: string = "scribe_v2";

/**
 * Sıkıştırılmış türlerde gerçekçi en düşük bit hızı (bayt/saniye). Süre tahmini = bayt / bu değer: gerçek sürenin
 * üst sınırıdır, ayırma bu tahminle yapılır. Opus 6 kbit/s ≈ 750 B/s; HE-AAC v2 ve MP3 8 kbit/s ≈ 1000 B/s.
 * FLAC kabul edilmez: sessizliği sınırsız sıkıştırdığı için boyuttan süreye üst sınır çıkmaz.
 */
const minBytesPerSecondByType: Readonly<Record<string, number>> = {
  "audio/mp4": 1000,
  "audio/m4a": 1000,
  "audio/x-m4a": 1000,
  "audio/aac": 1000,
  "audio/mpeg": 1000,
  "audio/ogg": 750,
  "audio/webm": 750,
};

/** WAV türleri: süre başlıktan kesin hesaplanır (PCM, veri baytı / bayt hızı). */
const wavTypes: ReadonlySet<string> = new Set(["audio/wav", "audio/x-wav", "audio/wave"]);

/** WAV başlığı için okunacak en çok bayt. */
const maxWavHeaderBytes: number = 64 * 1024;

const fileExtensionByType: Readonly<Record<string, string>> = {
  "audio/wav": "wav",
  "audio/x-wav": "wav",
  "audio/wave": "wav",
  "audio/mp4": "m4a",
  "audio/m4a": "m4a",
  "audio/x-m4a": "m4a",
  "audio/aac": "aac",
  "audio/mpeg": "mp3",
  "audio/ogg": "ogg",
  "audio/webm": "webm",
};

/** ElevenLabs'e iletilecek izinli parametreler. */
export interface TranscribeParams {
  readonly languageCode: string | null;
  readonly diarize: boolean;
  readonly keyterms: readonly string[];
}

/** ElevenLabs anahtar terim kuralları: <50 karakter, en çok 5 kelime, `<>{}[]\` yok. */
const keytermSchema = z
  .string()
  .min(1)
  .max(49)
  .refine((term: string): boolean => !/[<>{}[\]\\]/.test(term) && term.trim().split(/\s+/).length <= 5);

/** Sorgu parametrelerini doğrular: `language_code`, `diarize`, tekrar eden `keyterms`; başka parametre reddedilir. */
export function parseTranscribeParams(url: URL, maxKeyterms: number): TranscribeParams {
  const allowed: ReadonlySet<string> = new Set(["language_code", "diarize", "keyterms"]);
  for (const key of url.searchParams.keys()) {
    if (!allowed.has(key)) {
      throw new ApiError("invalid_body", `Bilinmeyen parametre: ${key}`);
    }
  }
  const language: string | null = url.searchParams.get("language_code");
  if (language !== null && !/^[a-z]{2,3}$/.test(language)) {
    throw new ApiError("invalid_body", "language_code ISO 639-1 ya da 639-3 olmalı.");
  }
  const diarize: string | null = url.searchParams.get("diarize");
  if (diarize !== null && diarize !== "true" && diarize !== "false") {
    throw new ApiError("invalid_body", "diarize true ya da false olmalı.");
  }
  const keyterms: string[] = url.searchParams.getAll("keyterms");
  if (keyterms.length > maxKeyterms) {
    throw new ApiError("invalid_body", `En çok ${maxKeyterms} anahtar terim gönderilebilir.`);
  }
  if (keyterms.some((term: string): boolean => !keytermSchema.safeParse(term).success)) {
    throw new ApiError("invalid_body", "Anahtar terimlerden biri geçersiz (en çok 49 karakter, 5 kelime; <>{}[]\\ yok).");
  }
  return { languageCode: language, diarize: diarize === "true", keyterms };
}

/** Ses türü (parametresiz, küçük harf); izinli değilse `unsupported_media_type`. Saf fonksiyondur. */
export function audioContentType(header: string | null): string {
  const type: string = (header ?? "").split(";")[0]?.trim().toLowerCase() ?? "";
  if (!wavTypes.has(type) && minBytesPerSecondByType[type] === undefined) {
    throw new ApiError("unsupported_media_type", "Ses türü desteklenmiyor (wav, m4a/mp4, aac, mp3, ogg, webm).");
  }
  return type;
}

/** Sıkıştırılmış ses için süre üst sınırı (saniye): bayt / en düşük gerçekçi bit hızı. Saf fonksiyondur. */
export function compressedMaximumSeconds(bytes: number, contentType: string): number {
  const rate: number | undefined = minBytesPerSecondByType[contentType];
  if (rate === undefined) {
    throw new ApiError("unsupported_media_type", "Ses türü desteklenmiyor.");
  }
  return bytes / rate;
}

/** WAV veri bölümünün başladığı konum ve bayt hızı. */
export interface WavLayout {
  readonly dataOffset: number;
  readonly byteRate: number;
}

function invalidWav(reason: string): ApiError {
  return new ApiError("invalid_body", `WAV başlığı geçersiz: ${reason}.`);
}

/**
 * WAV (RIFF) başlığını okur: `fmt ` bölümü PCM (1) ya da genişletilmiş (0xFFFE), 1–8 kanal, 8–192 kHz, 8/16/24/32 bit
 * ve tutarlı bayt hızı olmalı. `data` bölümü henüz gelmediyse null (daha çok bayt gerekir). ElevenLabs PCM'i de
 * başlıktaki bayt hızıyla çözer; süre = veri baytı / bayt hızı kesindir. Saf fonksiyondur.
 */
export function wavLayout(head: Uint8Array): WavLayout | null {
  if (head.byteLength < 12) {
    return null;
  }
  const view: DataView = new DataView(head.buffer, head.byteOffset, head.byteLength);
  const tag = (offset: number): string => String.fromCharCode(...head.subarray(offset, offset + 4));
  if (tag(0) !== "RIFF" || tag(8) !== "WAVE") {
    throw invalidWav("RIFF/WAVE değil");
  }
  let byteRate: number | null = null;
  let offset: number = 12;
  while (offset + 8 <= head.byteLength) {
    const id: string = tag(offset);
    const size: number = view.getUint32(offset + 4, true);
    if (id === "data") {
      if (byteRate === null) {
        throw invalidWav("data bölümü fmt bölümünden önce");
      }
      return { dataOffset: offset + 8, byteRate };
    }
    if (id === "fmt ") {
      if (offset + 8 + 16 > head.byteLength) {
        return null;
      }
      const format: number = view.getUint16(offset + 8, true);
      const channels: number = view.getUint16(offset + 10, true);
      const sampleRate: number = view.getUint32(offset + 12, true);
      const declaredByteRate: number = view.getUint32(offset + 16, true);
      const bits: number = view.getUint16(offset + 22, true);
      const pcm: boolean = format === 1 || format === 0xfffe;
      const valid: boolean =
        pcm &&
        channels >= 1 &&
        channels <= 8 &&
        sampleRate >= 8000 &&
        sampleRate <= 192_000 &&
        [8, 16, 24, 32].includes(bits) &&
        declaredByteRate === (sampleRate * channels * bits) / 8;
      if (!valid) {
        throw invalidWav("PCM değil ya da biçim tutarsız");
      }
      byteRate = declaredByteRate;
    }
    offset += 8 + size + (size % 2);
  }
  if (offset > maxWavHeaderBytes) {
    throw invalidWav("data bölümü bulunamadı");
  }
  return null;
}

/** Gövdenin baştan okunmuş baytları ve süre üst sınırı. */
interface AudioHead {
  readonly head: Uint8Array;
  readonly seconds: number;
}

/** WAV başlığını akıştan okur (en çok 64 KB) ve kesin süreyi hesaplar; okunan baytlar sonra aynen iletilir. */
async function readWavHead(reader: ReadableStreamDefaultReader<Uint8Array>, declaredBytes: number): Promise<AudioHead> {
  let head: Uint8Array = new Uint8Array(0);
  for (;;) {
    const layout: WavLayout | null = wavLayout(head);
    if (layout !== null) {
      return { head, seconds: Math.max(0, declaredBytes - layout.dataOffset) / layout.byteRate };
    }
    if (head.byteLength >= Math.min(maxWavHeaderBytes, declaredBytes)) {
      throw invalidWav("data bölümü bulunamadı");
    }
    const { done, value }: ReadableStreamReadResult<Uint8Array> = await reader.read();
    if (done) {
      throw invalidWav("dosya başlıktan önce bitti");
    }
    const joined: Uint8Array = new Uint8Array(head.byteLength + value.byteLength);
    joined.set(head);
    joined.set(value, head.byteLength);
    head = joined;
  }
}

/** ElevenLabs çok parçalı gövdesinin metin alanları; dosya en sondadır. Saf fonksiyondur. */
export function multipartFields(params: TranscribeParams): Array<readonly [string, string]> {
  const fields: Array<readonly [string, string]> = [
    ["model_id", scribeModel],
    ["diarize", String(params.diarize)],
    ["tag_audio_events", "false"],
    ["no_verbatim", "true"],
    ["timestamps_granularity", "word"],
  ];
  if (params.languageCode !== null) {
    fields.push(["language_code", params.languageCode]);
  }
  return [...fields, ...params.keyterms.map((term: string): readonly [string, string] => ["keyterms", term])];
}

/** Çok parçalı gövdenin dosyadan önceki ve sonraki baytları. Saf fonksiyondur. */
export function multipartEnvelope(boundary: string, fields: ReadonlyArray<readonly [string, string]>, fileName: string, contentType: string): { prefix: Uint8Array; suffix: Uint8Array } {
  const fieldText: string = fields.map(([name, value]): string => `--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`).join("");
  return {
    prefix: utf8(`${fieldText}--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${fileName}"\r\nContent-Type: ${contentType}\r\n\r\n`),
    suffix: utf8(`\r\n--${boundary}--\r\n`),
  };
}

const wordSchema = z.object({
  text: z.string(),
  type: z.enum(["word", "spacing", "audio_event"]),
  start: z.number().nullable().optional(),
  end: z.number().nullable().optional(),
  speaker_id: z.string().nullable().optional(),
  logprob: z.number().optional(),
});

/** ElevenLabs tek kanal yanıtı; istemciye yalnızca bu alanlar döner. */
const transcriptionSchema = z.object({
  language_code: z.string(),
  language_probability: z.number(),
  text: z.string(),
  words: z.array(wordSchema),
  audio_duration_secs: z.number().nullable().optional(),
});

export type Transcription = z.output<typeof transcriptionSchema>;

/** Ücretlendirilecek süre: yanıttaki `audio_duration_secs`; yoksa son kelimenin bitişi ile süre üst sınırından büyüğü. Saf fonksiyondur. */
export function billableSeconds(transcription: Transcription, estimatedSeconds: number): number {
  if (transcription.audio_duration_secs !== null && transcription.audio_duration_secs !== undefined) {
    return transcription.audio_duration_secs;
  }
  const lastEnd: number = transcription.words.reduce((max: number, word): number => Math.max(max, word.end ?? 0), 0);
  return Math.max(lastEnd, estimatedSeconds);
}

/**
 * Ses dosyasını ElevenLabs Scribe v2 toplu konuşma tanımaya iletir (konuşmacı ayırma isteğe bağlı). Gövde ham sestir
 * (`Content-Type: audio/...`, `Content-Length` zorunlu); parametreler sorgudadır. Ses bellekte biriktirilmeden akış
 * olarak iletilir (Worker belleği 128 MB); bu yüzden üst istek yeniden denenemez, istemci yeniden dener.
 *
 * Süre sınırı: istekten önce sürenin üst sınırı (WAV'da başlıktan kesin, sıkıştırılmışta en düşük bit hızından)
 * toplantının en uzun süresine ve aylık süreye karşı tek koşullu ifadelerle ayrılır; toplantının yüklemeleri
 * birikimli sayılır. Yanıttaki gerçek süreyle kesinleşir. Gerçek süre ayrılanı aşarsa (tahmin yanlıştı) süre yine de
 * yazılır, toplantının ses hakkı kapanır ve alarm logu yazılır. Hata durumunda ayırma geri verilir.
 */
export async function proxyTranscription(
  db: D1Database,
  context: RequestContext,
  config: Config,
  meeting: MeetingRow,
  request: Request,
  params: TranscribeParams,
): Promise<Response> {
  const contentType: string = audioContentType(request.headers.get("content-type"));
  const lengthHeader: string | null = request.headers.get("content-length");
  if (lengthHeader === null || !/^\d+$/.test(lengthHeader)) {
    throw new ApiError("length_required", "Content-Length başlığı gerekli.");
  }
  const declaredBytes: number = Number(lengthHeader);
  if (declaredBytes > config.transcribe.maxBytes) {
    throw new ApiError("payload_too_large", `Ses dosyası en çok ${config.transcribe.maxBytes} bayt olabilir.`);
  }
  if (declaredBytes === 0 || request.body === null) {
    throw new ApiError("invalid_body", "Ses dosyası boş.");
  }
  if (meeting.transcription_closed !== 0) {
    throw new ApiError("transcription_closed", "Bu toplantının ses işleme hakkı kapandı.");
  }
  const now: Date = context.platform.now();
  const reader: ReadableStreamDefaultReader<Uint8Array> = request.body.getReader();
  let audio: AudioHead;
  try {
    audio = wavTypes.has(contentType)
      ? await readWavHead(reader, declaredBytes)
      : { head: new Uint8Array(0), seconds: compressedMaximumSeconds(declaredBytes, contentType) };
    await reserveAll(db, audioReservationSteps(db, config, meeting.id, meeting.user_id, audio.seconds, now));
  } catch (error: unknown) {
    await reader.cancel();
    throw error;
  }
  const reserved: number = audio.seconds;
  let transcription: Transcription;
  try {
    transcription = await sendToElevenLabs(context, config, meeting, params, contentType, declaredBytes, reader, audio.head);
  } catch (error: unknown) {
    await db.batch(settleAudioStatements(db, meeting.id, meeting.user_id, reserved, 0, 0, now));
    throw error;
  }
  const seconds: number = billableSeconds(transcription, reserved);
  // Ayırma tahmini üst sınırdır; 1 saniyelik pay yuvarlama içindir.
  const overrun: boolean = seconds > reserved + 1;
  const usdPerHour: number = config.transcribe.usdPerHour + (params.keyterms.length > 0 ? config.transcribe.keytermsUsdPerHour : 0);
  await db.batch([
    ...settleAudioStatements(db, meeting.id, meeting.user_id, reserved, seconds, overrun ? 1 : 0, now),
    addSpendStatement(db, now, transcriptionCostMicroUsd(seconds, usdPerHour)),
  ]);
  if (overrun) {
    log("alert", "transcription_overrun", { userId: meeting.user_id, meetingId: meeting.id, reservedSeconds: reserved, actualSeconds: seconds, contentType });
  }
  log("info", "transcription_usage", { userId: meeting.user_id, meetingId: meeting.id, seconds, bytes: declaredBytes, keyterms: params.keyterms.length });
  return jsonResponse(200, transcription);
}

/** Çok parçalı gövdeyi akıtarak ElevenLabs'e gönderir ve yanıtı doğrular; hata gövdesi okunmaz ve iletilmez. */
async function sendToElevenLabs(
  context: RequestContext,
  config: Config,
  meeting: MeetingRow,
  params: TranscribeParams,
  contentType: string,
  declaredBytes: number,
  reader: ReadableStreamDefaultReader<Uint8Array>,
  head: Uint8Array,
): Promise<Transcription> {
  const boundary: string = `ainotepad-${randomToken(18)}`;
  const { prefix, suffix } = multipartEnvelope(boundary, multipartFields(params), `audio.${fileExtensionByType[contentType] ?? "bin"}`, contentType);
  const { readable, writable } = new FixedLengthStream(prefix.byteLength + declaredBytes + suffix.byteLength);
  const upload: Promise<void> = pipeAudio(reader, head, writable, prefix, suffix, declaredBytes);

  let response: Response;
  try {
    response = await context.platform.fetch(elevenLabsSpeechToTextUrl, {
      method: "POST",
      headers: { "xi-api-key": config.secrets.elevenLabs, "content-type": `multipart/form-data; boundary=${boundary}` },
      body: readable,
    });
  } catch (error: unknown) {
    // Gönderim bizim tarafta kesildiyse (boyut uyuşmazlığı) asıl neden odur.
    const uploadError: unknown = await upload.then((): null => null, (failure: unknown): unknown => failure);
    if (uploadError instanceof ApiError) {
      throw uploadError;
    }
    log("error", "elevenlabs_failed", { userId: meeting.user_id, meetingId: meeting.id, error: errorName(error) });
    throw new ApiError("upstream_unavailable", "Konuşma tanıma servisine ulaşılamadı; yeniden dene.");
  }
  if (response.ok) {
    // Başarılı yanıt gövdenin tamamı okunduktan sonra gelir.
    await upload;
  } else {
    // Üst servis gövdeyi okumadan yanıt verdiyse gönderim kendiliğinden kesilir; beklemeden kaydı arka planda tamamla.
    context.waitUntil(
      upload.catch((failure: unknown): void => {
        log("info", "transcribe_upload_cancelled", { meetingId: meeting.id, error: errorName(failure) });
      }),
    );
    await response.body?.cancel();
    const upstream: UpstreamError = new UpstreamError("elevenlabs", response.status, isRetryableStatus(response.status), "yanıt başarısız");
    log("error", "elevenlabs_failed", { userId: meeting.user_id, meetingId: meeting.id, status: upstream.status });
    throw upstream.retryable
      ? new ApiError("upstream_unavailable", "Konuşma tanıma servisi şu an yanıt vermiyor; yeniden dene.")
      : new ApiError("upstream_rejected", `Konuşma tanıma isteği reddedildi (durum ${upstream.status}).`);
  }
  const parsed = transcriptionSchema.safeParse(await response.json());
  if (!parsed.success) {
    log("error", "elevenlabs_malformed", { userId: meeting.user_id, meetingId: meeting.id });
    throw new ApiError("upstream_unavailable", "Konuşma tanıma yanıtı okunamadı.");
  }
  return parsed.data;
}

/**
 * Önceden okunmuş baştaki baytları ve gövdenin kalanını çok parçalı zarfın içine akıtır; bildirilen uzunluktan farklı
 * bayt gelirse akışı hatayla keser (`FixedLengthStream` da uzunluğu zorlar).
 */
async function pipeAudio(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  head: Uint8Array,
  writable: WritableStream<Uint8Array>,
  prefix: Uint8Array,
  suffix: Uint8Array,
  declaredBytes: number,
): Promise<void> {
  const writer: WritableStreamDefaultWriter<Uint8Array> = writable.getWriter();
  try {
    await writer.write(prefix);
    let total: number = head.byteLength;
    if (total > declaredBytes) {
      throw new ApiError("payload_too_large", "Ses dosyası bildirilen boyuttan büyük.");
    }
    if (total > 0) {
      await writer.write(head);
    }
    for (;;) {
      const { done, value }: ReadableStreamReadResult<Uint8Array> = await reader.read();
      if (done) {
        break;
      }
      total += value.byteLength;
      if (total > declaredBytes) {
        throw new ApiError("payload_too_large", "Ses dosyası bildirilen boyuttan büyük.");
      }
      await writer.write(value);
    }
    if (total !== declaredBytes) {
      throw new ApiError("invalid_body", "Ses dosyası bildirilen boyuttan küçük.");
    }
    await writer.write(suffix);
    await writer.close();
  } catch (error: unknown) {
    // Asıl hata aşağıda fırlatılır; temizlik adımlarının ikincil hataları onu gölgelemesin.
    await reader.cancel().catch((): void => undefined);
    await writer.abort(error).catch((): void => undefined);
    throw error;
  }
}
