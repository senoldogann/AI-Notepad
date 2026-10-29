import { z } from "zod";
import { continueAfterDisconnect } from "./background";
import type { Config } from "./config";
import { Base64Error, base64Decode, decodeUtf8Strict, randomToken, utf8 } from "./crypto";
import { ApiError, UpstreamError, isRetryableStatus } from "./errors";
import { jsonResponse } from "./http";
import { alertOnElevenLabsCrossing } from "./elevenLabsCapacity";
import { errorName, log } from "./log";
import type { MeetingRow } from "./meetings";
import type { RequestContext } from "./platform";
import { cachedTranscription, storeTranscription, uploadKeyFrom } from "./transcriptionCache";
import {
  type UsageReservation,
  audioReservation,
  meetingAudioIdleLimit,
  meetingAudioLimit,
  monthlyAudioLimit,
  reserveUsage,
  settleAudioStatements,
} from "./reservations";
import { transcriptionCostMicroUsd } from "./usage";

export const elevenLabsSpeechToTextUrl: string = "https://api.elevenlabs.io/v1/speech-to-text";
export const scribeModel: string = "scribe_v2";

/**
 * ElevenLabs isteğinin toplam zaman aşımı: yükleme istemciden akarak gider (95 MB) ve uzun ses dakikalar sürer;
 * istemcinin parça zaman aşımından (300 sn + dakika başına 10 sn, ~49 dakikalık parçada ~13 dk) uzundur.
 */
const elevenLabsTimeoutMs: number = 15 * 60_000;

/**
 * Kabul edilen ses türleri: yalnızca PCM WAV (Mac uygulamasının gönderdiği tek tür, `audio/wav`; eş adları). Süre
 * başlıktan kesin hesaplanır (veri baytı / bayt hızı); sıkıştırılmış türlerde boyuttan süreye güvenilir üst sınır
 * çıkmadığı için (düşük bit hızı, sessizlik) kabul edilmez.
 */
const wavTypes: ReadonlySet<string> = new Set(["audio/wav", "audio/x-wav", "audio/wave"]);

/** WAV başlığı için okunacak en çok bayt. */
const maxWavHeaderBytes: number = 64 * 1024;

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

/** `x-keyterms` başlığı: dolgusuz base64url (yalnızca `A–Z a–z 0–9 - _`). */
const keytermsHeaderPattern: RegExp = /^[A-Za-z0-9_-]+$/;

const keytermsJsonSchema = z.array(z.string());

/**
 * `x-keyterms` başlığını çözer: dolgusuz base64url, içinde UTF-8 JSON dizgi dizisi. Biçim bozuksa `invalid_body`
 * (mesaj değer taşımaz; terimler loglanmaz). Saf fonksiyondur.
 */
export function decodeKeytermsHeader(value: string): string[] {
  const invalid: ApiError = new ApiError("invalid_body", "x-keyterms başlığı dolgusuz base64url ile kodlanmış bir JSON dizgi dizisi olmalı.");
  if (!keytermsHeaderPattern.test(value)) {
    throw invalid;
  }
  let text: string;
  try {
    text = decodeUtf8Strict(base64Decode(value));
  } catch (error: unknown) {
    // `Base64Error`: bozuk base64; `TypeError`: geçersiz UTF-8 (katı çözücü).
    if (error instanceof Base64Error || error instanceof TypeError) {
      throw invalid;
    }
    throw error;
  }
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch (error: unknown) {
    if (error instanceof SyntaxError) {
      throw invalid;
    }
    throw error;
  }
  const parsed = keytermsJsonSchema.safeParse(json);
  if (!parsed.success) {
    throw invalid;
  }
  return parsed.data;
}

/**
 * Parametreleri doğrular: sorguda `language_code`, `diarize`; anahtar terimler `x-keyterms` başlığında
 * (`decodeKeytermsHeader`) ya da tekrar eden `keyterms` sorgu parametresinde. Sorgu biçimi yayımlanmış 0.1.4 Mac
 * uygulaması için kabul edilir; ikisi birlikte gelirse `invalid_body`. Terim sınırları iki biçimde aynıdır. Başka sorgu
 * parametresi reddedilir.
 */
export function parseTranscribeParams(url: URL, keytermsHeader: string | null, maxKeyterms: number): TranscribeParams {
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
  // Sorgudaki `keyterms`: 0.1.4 Mac uygulaması uyumluluğu için.
  const queryKeyterms: string[] = url.searchParams.getAll("keyterms");
  if (keytermsHeader !== null && queryKeyterms.length > 0) {
    throw new ApiError("invalid_body", "Anahtar terimler ya x-keyterms başlığında ya keyterms sorgu parametresinde gönderilmeli, ikisinde birden değil.");
  }
  const keyterms: string[] = keytermsHeader === null ? queryKeyterms : decodeKeytermsHeader(keytermsHeader);
  if (keyterms.length > maxKeyterms) {
    throw new ApiError("invalid_body", `En çok ${maxKeyterms} anahtar terim gönderilebilir.`);
  }
  if (keyterms.some((term: string): boolean => !keytermSchema.safeParse(term).success)) {
    throw new ApiError("invalid_body", "Anahtar terimlerden biri geçersiz (en çok 49 karakter, 5 kelime; <>{}[]\\ yok).");
  }
  return { languageCode: language, diarize: diarize === "true", keyterms };
}

/** Ses türü (parametresiz, küçük harf); WAV değilse `unsupported_media_type`. Saf fonksiyondur. */
export function audioContentType(header: string | null): string {
  const type: string = (header ?? "").split(";")[0]?.trim().toLowerCase() ?? "";
  if (!wavTypes.has(type)) {
    throw new ApiError("unsupported_media_type", "Ses türü desteklenmiyor; yalnızca PCM WAV (audio/wav) kabul edilir.");
  }
  return type;
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

/** Gövdenin baştan okunmuş baytları ve kesin süresi. */
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

/** Üst servis çağrısının sonucu: değer ya da istemciye dönecek hata (kesinleştirme her iki durumda yapılmıştır). */
type CallOutcome<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly error: ApiError };

/** ElevenLabs gönderiminin sonucu; başarısızlıkta sesin tamamının ElevenLabs'e gidip gitmediği (ücretlenmiş olabilir). */
type ElevenLabsResult =
  | { readonly ok: true; readonly transcription: Transcription }
  | { readonly ok: false; readonly error: ApiError; readonly uploaded: boolean };

/**
 * Ses dosyasını ElevenLabs Scribe v2 toplu konuşma tanımaya iletir (konuşmacı ayırma isteğe bağlı). Gövde ham PCM
 * WAV'dır (`Content-Type: audio/wav`, `Content-Length` zorunlu); parametreler sorguda, anahtar terimler `x-keyterms`
 * başlığındadır. Ses bellekte biriktirilmeden akış olarak iletilir (Worker belleği 128 MB); bu yüzden üst istek
 * yeniden denenemez, istemci yeniden dener.
 *
 * Süre sınırı: istekten önce WAV başlığından kesin süre okunur ve toplantının kalan ses süresine ve aylık süreye karşı
 * tek koşullu ifadeyle süreli bir ayırma satırı olarak ayrılır; toplantının yüklemeleri birikimli sayılır ve toplantıda
 * aynı anda tek ses isteği olabilir (süren varsa `409 transcription_in_progress`). Yanıttaki gerçek süreyle kesinleşir;
 * gerçek süre ayrılanı aşarsa süre yine de yazılır, toplantının ses hakkı kapanır ve alarm logu yazılır. Gönderim ve
 * kesinleştirme istemci koparsa da tamamlanır (`continueAfterDisconnect`). Hata durumunda ayırma kapanır; ses
 * ElevenLabs'e tamamen gittiyse tahmini maliyet harcamaya sayılır.
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
  const uploadKey: string | null = uploadKeyFrom(request.headers.get("x-upload-key"));
  if (meeting.transcription_closed !== 0) {
    throw new ApiError("transcription_closed", "Bu toplantının ses işleme hakkı kapandı.");
  }
  const usdPerHour: number = config.transcribe.usdPerHour + (params.keyterms.length > 0 ? config.transcribe.keytermsUsdPerHour : 0);
  const reader: ReadableStreamDefaultReader<Uint8Array> = request.body.getReader();
  let audio: AudioHead;
  let reservation: UsageReservation;
  try {
    audio = await readWavHead(reader, declaredBytes);
    reservation = audioReservation(meeting.user_id, meeting.id, audio.seconds, transcriptionCostMicroUsd(audio.seconds, usdPerHour), meeting.kind === "trial", now);
    await reserveUsage(db, reservation, [
      { limit: meetingAudioIdleLimit(meeting.id, now), amount: 1 },
      { limit: meetingAudioLimit(meeting.id), amount: audio.seconds },
      { limit: monthlyAudioLimit(config, meeting.user_id, meeting.id, now), amount: audio.seconds },
    ]);
  } catch (error: unknown) {
    await reader.cancel();
    throw error;
  }
  const outcome: CallOutcome<Transcription> = await continueAfterDisconnect(
    context,
    transcribeAndSettle(db, context, config, meeting, params, contentType, declaredBytes, reader, audio, reservation, usdPerHour, uploadKey, now),
    "transcription_settle_failed",
    { userId: meeting.user_id, meetingId: meeting.id, reservationId: reservation.id },
  );
  if (!outcome.ok) {
    throw outcome.error;
  }
  return jsonResponse(200, outcome.value);
}

/** ElevenLabs'e gönderir ve ayırmayı kesinleştirir (başarıda gerçek süre ve maliyet; hatada ayırma kapanır). */
async function transcribeAndSettle(
  db: D1Database,
  context: RequestContext,
  config: Config,
  meeting: MeetingRow,
  params: TranscribeParams,
  contentType: string,
  declaredBytes: number,
  reader: ReadableStreamDefaultReader<Uint8Array>,
  audio: AudioHead,
  reservation: UsageReservation,
  usdPerHour: number,
  uploadKey: string | null,
  now: Date,
): Promise<CallOutcome<Transcription>> {
  const result: ElevenLabsResult = await sendToElevenLabs(context, config, meeting, params, contentType, declaredBytes, reader, audio.head);
  if (!result.ok) {
    // Ses ElevenLabs'e tamamen gittiyse işlenmiş (ücretlenmiş) olabilir: tahmini maliyet ve süre ElevenLabs'e sayılır.
    const providerSeconds: number = result.uploaded ? reservation.audioSeconds : 0;
    await db.batch(settleAudioStatements(db, reservation, 0, false, result.uploaded ? reservation.estimatedMicroUsd : 0, providerSeconds, now));
    if (providerSeconds > 0) {
      await alertOnElevenLabsCrossing(db, config, providerSeconds, now);
    }
    return { ok: false, error: result.error };
  }
  const reserved: number = audio.seconds;
  const seconds: number = billableSeconds(result.transcription, reserved);
  // Ayırma WAV başlığından kesindir; 1 saniyelik pay yuvarlama içindir.
  const overrun: boolean = seconds > reserved + 1;
  await db.batch(settleAudioStatements(db, reservation, seconds, overrun, transcriptionCostMicroUsd(seconds, usdPerHour), seconds, now));
  // Kesinleşmeden sonraki denetim yanıtı düşürmez (ses faturalandı; istemci yeniden göndermesin).
  try {
    await alertOnElevenLabsCrossing(db, config, seconds, now);
  } catch (error: unknown) {
    log("alert", "elevenlabs_capacity_check_failed", { userId: meeting.user_id, meetingId: meeting.id, error: errorName(error) });
  }
  if (overrun) {
    log("alert", "transcription_overrun", { userId: meeting.user_id, meetingId: meeting.id, reservedSeconds: reserved, actualSeconds: seconds, contentType });
  }
  log("info", "transcription_usage", { userId: meeting.user_id, meetingId: meeting.id, seconds, bytes: declaredBytes, keyterms: params.keyterms.length });
  if (uploadKey !== null) {
    // Ses kesinleşti ve faturalandı: saklama hatası yanıtı düşürmez (düşürseydi istemci yeniden gönderir, ses yeniden
    // faturalanırdı); alarm yazılır, sonuç döner.
    try {
      await storeTranscription(db, meeting.user_id, meeting.id, uploadKey, result.transcription, now);
    } catch (error: unknown) {
      log("alert", "transcription_cache_failed", { userId: meeting.user_id, meetingId: meeting.id, error: errorName(error) });
    }
  }
  return { ok: true, value: result.transcription };
}

/**
 * Aynı yükleme anahtarıyla tamamlanmış (ödenmiş) sonuç: varsa ses okunmadan ve faturalanmadan döner. Toplantının ek
 * süresi, harcama tavanı ve ses hakkı denetimlerinden önce çağrılır: ödenmiş sonuç her zaman geri alınabilir (yanıtı
 * yolda kaybolan istemci pencere kapandıktan sonra da sonucunu alır). Anahtar yoksa ya da sonuç yoksa null.
 */
export async function cachedTranscriptionResponse(db: D1Database, request: Request, userId: string, meetingId: string, now: Date): Promise<Response | null> {
  const uploadKey: string | null = uploadKeyFrom(request.headers.get("x-upload-key"));
  if (uploadKey === null) {
    return null;
  }
  const cached: object | null = await cachedTranscription(db, userId, meetingId, uploadKey, now);
  if (cached === null) {
    return null;
  }
  await request.body?.cancel();
  log("info", "transcription_repeated", { userId, meetingId });
  return jsonResponse(200, cached);
}

/**
 * Çok parçalı gövdeyi akıtarak ElevenLabs'e gönderir (toplam zaman aşımı `elevenLabsTimeoutMs`) ve yanıtı doğrular;
 * hata gövdesi okunmaz ve iletilmez. Hata fırlatmaz, sonuç döndürür: başarısızlıkta sesin tamamı gönderildi mi
 * (`uploaded`) bilgisiyle.
 */
async function sendToElevenLabs(
  context: RequestContext,
  config: Config,
  meeting: MeetingRow,
  params: TranscribeParams,
  contentType: string,
  declaredBytes: number,
  reader: ReadableStreamDefaultReader<Uint8Array>,
  head: Uint8Array,
): Promise<ElevenLabsResult> {
  const boundary: string = `ainotepad-${randomToken(18)}`;
  const { prefix, suffix } = multipartEnvelope(boundary, multipartFields(params), "audio.wav", contentType);
  const { readable, writable } = new FixedLengthStream(prefix.byteLength + declaredBytes + suffix.byteLength);
  let uploaded: boolean = false;
  const upload: Promise<void> = pipeAudio(reader, head, writable, prefix, suffix, declaredBytes).then((): void => {
    uploaded = true;
  });

  let response: Response;
  try {
    response = await context.platform.fetch(elevenLabsSpeechToTextUrl, {
      method: "POST",
      headers: { "xi-api-key": config.secrets.elevenLabs, "content-type": `multipart/form-data; boundary=${boundary}` },
      body: readable,
      signal: AbortSignal.timeout(elevenLabsTimeoutMs),
    });
  } catch (error: unknown) {
    // Gönderim bizim tarafta kesildiyse (boyut uyuşmazlığı, istemci koptu) asıl neden odur.
    const uploadError: unknown = await upload.then((): null => null, (failure: unknown): unknown => failure);
    if (uploadError instanceof ApiError) {
      return { ok: false, error: uploadError, uploaded: false };
    }
    log("error", "elevenlabs_failed", { userId: meeting.user_id, meetingId: meeting.id, error: errorName(error), uploaded });
    return { ok: false, error: new ApiError("upstream_unavailable", "Konuşma tanıma servisine ulaşılamadı; yeniden dene."), uploaded };
  }
  if (!response.ok) {
    // Üst servis gövdeyi okumadan yanıt verdiyse gönderim kendiliğinden kesilir; beklemeden kaydı arka planda tamamla.
    context.waitUntil(
      upload.catch((failure: unknown): void => {
        log("info", "transcribe_upload_cancelled", { meetingId: meeting.id, error: errorName(failure) });
      }),
    );
    await response.body?.cancel();
    const upstream: UpstreamError = new UpstreamError("elevenlabs", response.status, isRetryableStatus(response.status), "yanıt başarısız");
    log("error", "elevenlabs_failed", { userId: meeting.user_id, meetingId: meeting.id, status: upstream.status, uploaded });
    const error: ApiError = upstream.retryable
      ? new ApiError("upstream_unavailable", "Konuşma tanıma servisi şu an yanıt vermiyor; yeniden dene.")
      : new ApiError("upstream_rejected", `Konuşma tanıma isteği reddedildi (durum ${upstream.status}).`);
    return { ok: false, error, uploaded };
  }
  // Başarılı yanıt gövdenin tamamı okunduktan sonra gelir; gönderim yine de başarısız olduysa yanıt kullanılmaz.
  const uploadFailure: unknown = await upload.then((): null => null, (failure: unknown): unknown => failure);
  if (uploadFailure !== null) {
    await response.body?.cancel();
    log("error", "elevenlabs_upload_failed_after_response", { userId: meeting.user_id, meetingId: meeting.id, error: errorName(uploadFailure) });
    const error: ApiError =
      uploadFailure instanceof ApiError ? uploadFailure : new ApiError("upstream_unavailable", "Konuşma tanıma servisine ses gönderilemedi; yeniden dene.");
    return { ok: false, error, uploaded: false };
  }
  let body: unknown;
  try {
    body = await response.json();
  } catch (error: unknown) {
    log("error", "elevenlabs_malformed", { userId: meeting.user_id, meetingId: meeting.id, error: errorName(error) });
    return { ok: false, error: new ApiError("upstream_unavailable", "Konuşma tanıma yanıtı okunamadı."), uploaded: true };
  }
  const parsed = transcriptionSchema.safeParse(body);
  if (!parsed.success) {
    log("error", "elevenlabs_malformed", { userId: meeting.user_id, meetingId: meeting.id });
    return { ok: false, error: new ApiError("upstream_unavailable", "Konuşma tanıma yanıtı okunamadı."), uploaded: true };
  }
  return { ok: true, transcription: parsed.data };
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
