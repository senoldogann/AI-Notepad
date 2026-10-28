import { z } from "zod";
import type { Config } from "./config";
import { randomToken, utf8 } from "./crypto";
import { ApiError, UpstreamError, isRetryableStatus } from "./errors";
import { jsonResponse } from "./http";
import { errorName, log } from "./log";
import { type MeetingRow, addMeetingAudioStatement } from "./meetings";
import type { RequestContext } from "./platform";
import { type MonthlyUsage, addAudioUsageStatement, addSpendStatement, monthlyUsage, transcriptionCostMicroUsd } from "./usage";

export const elevenLabsSpeechToTextUrl: string = "https://api.elevenlabs.io/v1/speech-to-text";
export const scribeModel: string = "scribe_v2";

/**
 * İzinli ses türleri ve en yüksek bayt/saniye varsayımı. Süre tahmini (bayt / bu değer) gerçek sürenin alt
 * sınırıdır: kalan süre bu tahmini karşılamıyorsa istek ElevenLabs'e gitmeden reddedilir.
 */
const maxBytesPerSecondByType: Readonly<Record<string, number>> = {
  "audio/wav": 192_000,
  "audio/x-wav": 192_000,
  "audio/wave": 192_000,
  "audio/flac": 192_000,
  "audio/mp4": 40_000,
  "audio/m4a": 40_000,
  "audio/x-m4a": 40_000,
  "audio/aac": 40_000,
  "audio/mpeg": 40_000,
  "audio/ogg": 40_000,
  "audio/webm": 40_000,
};

const fileExtensionByType: Readonly<Record<string, string>> = {
  "audio/wav": "wav",
  "audio/x-wav": "wav",
  "audio/wave": "wav",
  "audio/flac": "flac",
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
  if (maxBytesPerSecondByType[type] === undefined) {
    throw new ApiError("unsupported_media_type", "Ses türü desteklenmiyor (wav, flac, m4a/mp4, aac, mp3, ogg, webm).");
  }
  return type;
}

/** Boyuttan alt sınır süre tahmini (saniye). Saf fonksiyondur. */
export function estimatedMinimumSeconds(bytes: number, contentType: string): number {
  const rate: number | undefined = maxBytesPerSecondByType[contentType];
  if (rate === undefined) {
    throw new ApiError("unsupported_media_type", "Ses türü desteklenmiyor.");
  }
  return bytes / rate;
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

/** Ücretlendirilecek süre: yanıttaki `audio_duration_secs`; yoksa son kelimenin bitişi ile boyut tahmininden büyüğü. Saf fonksiyondur. */
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
 * olarak iletilir (Worker belleği 128 MB); bu yüzden üst istek yeniden denenemez, istemci yeniden dener. Süre
 * yanıttan okunur ve aylık saatten düşer.
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
  const now: Date = context.platform.now();
  const estimated: number = estimatedMinimumSeconds(declaredBytes, contentType);
  const meetingMaxSeconds: number = (meeting.max_ends_at - meeting.started_at) / 1000;
  if (estimated > meetingMaxSeconds) {
    throw new ApiError("audio_too_long", "Ses dosyası toplantının en uzun süresinden uzun.");
  }
  if (meeting.kind === "subscription") {
    const usage: MonthlyUsage = await monthlyUsage(db, meeting.user_id, now);
    if (usage.audioSeconds + estimated > config.monthlyCapSeconds) {
      throw new ApiError("monthly_cap_reached", "Bu ayki kullanım sınırı bu kaydı işlemeye yetmiyor; sınır ay başında sıfırlanır.");
    }
  }

  const boundary: string = `ainotepad-${randomToken(18)}`;
  const { prefix, suffix } = multipartEnvelope(boundary, multipartFields(params), `audio.${fileExtensionByType[contentType] ?? "bin"}`, contentType);
  const { readable, writable } = new FixedLengthStream(prefix.byteLength + declaredBytes + suffix.byteLength);
  const upload: Promise<void> = pipeAudio(request.body, writable, prefix, suffix, declaredBytes);

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
  const seconds: number = billableSeconds(parsed.data, estimated);
  const usdPerHour: number = config.transcribe.usdPerHour + (params.keyterms.length > 0 ? config.transcribe.keytermsUsdPerHour : 0);
  await db.batch([
    addMeetingAudioStatement(db, meeting.id, seconds),
    addAudioUsageStatement(db, meeting.user_id, now, seconds),
    addSpendStatement(db, now, transcriptionCostMicroUsd(seconds, usdPerHour)),
  ]);
  log("info", "transcription_usage", { userId: meeting.user_id, meetingId: meeting.id, seconds, bytes: declaredBytes, keyterms: params.keyterms.length });
  return jsonResponse(200, parsed.data);
}

/**
 * İstemci gövdesini çok parçalı zarfın içine akıtır; bildirilen uzunluktan farklı bayt gelirse akışı hatayla keser
 * (`FixedLengthStream` da uzunluğu zorlar).
 */
async function pipeAudio(body: ReadableStream<Uint8Array>, writable: WritableStream<Uint8Array>, prefix: Uint8Array, suffix: Uint8Array, declaredBytes: number): Promise<void> {
  const writer: WritableStreamDefaultWriter<Uint8Array> = writable.getWriter();
  const reader: ReadableStreamDefaultReader<Uint8Array> = body.getReader();
  try {
    await writer.write(prefix);
    let total: number = 0;
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
    await reader.cancel().catch((): void => undefined);
    await writer.abort(error).catch((): void => undefined);
    throw error;
  }
}
