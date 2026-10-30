import Anthropic from "@anthropic-ai/sdk";
import { continueAfterDisconnect, runAfterResponse } from "../background";
import type { Config } from "../config";
import { ApiError, ProviderApiError, isRetryableStatus } from "../errors";
import { jsonResponse } from "../http";
import { type LogFields, errorName, log } from "../log";
import type { MeetingRow } from "../meetings";
import type { AccountLLMAccess } from "../entitlements";
import type { RequestContext } from "../platform";
import { type RetryOptions, withRetries } from "../retry";
import {
  type ReservationCheck,
  type ReservationLimit,
  type TokenUsage,
  type UsageReservation,
  dailyTokenLimit,
  llmReservation,
  meetingTokenLimit,
  monthlyTokenLimit,
  remainingOf,
  reserveUsage,
  settleLLMStatements,
  subscriberAccountTokenLimit,
  tightestLimit,
  trialAccountTokenLimit,
} from "../reservations";
import { recordMeetingFailure, recordOpsEvents } from "../opsEvents";
import { llmCostMicroUsd } from "../usage";
import { type LLMRequest, clampMaxTokens, estimateInputTokens, upstreamParams } from "./request";
import { type LLMUsageTag, llmUsageStatement, llmUsageTagOf } from "./usageBuckets";

/** Akışsız çağrının zaman aşımı: yanıt başlığı ancak üretim bitince gelir, bu yüzden toplam süredir. */
const messageTimeoutMs: number = 120_000;
/** Akışlı çağrının ilk bayt (yanıt başlığı) zaman aşımı; akışın toplam süresi sınırlanmaz. */
const streamFirstByteTimeoutMs: number = 30_000;

/** Üst servis çağrısının sonucu: değer ya da istemciye dönecek hata (kesinleştirme her iki durumda yapılmıştır). */
type CallOutcome<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly error: ApiError };

/**
 * Çağrının bağlı olduğu bütçe: açık bir toplantı (kayıt sırasında ve ek sürede; toplantı bütçesi de düşer) ya da
 * yalnızca hesap (Sor, notu yeniden yazma, düzenleme, görev aracı; kullanıcının günlük ve aylık sınırı ve daha küçük
 * çağrı başı `max_tokens`).
 */
export type LLMScope =
  | { readonly kind: "meeting"; readonly userId: string; readonly meeting: MeetingRow }
  | { readonly kind: "account"; readonly userId: string; readonly access: AccountLLMAccess };

/** Deneme kullanıcısının toplantısız çağrısı mı (ayrıca küçük günlük sınır). Saf fonksiyondur. */
function isTrialAccountCall(scope: LLMScope): boolean {
  return scope.kind === "account" && scope.access === "trial";
}

/** Abonenin toplantısız çağrısı mı (ayrıca aylık `MONTHLY_ACCOUNT_TOKEN_CAP`). Saf fonksiyondur. */
function isSubscriberAccountCall(scope: LLMScope): boolean {
  return scope.kind === "account" && scope.access === "subscription";
}

/**
 * Çağrının sınırları: toplantı bütçesi (toplantıda) ya da denemenin günlük / abonenin aylık hesap çağrısı sınırı, sonra
 * kullanıcının aylık ve günlük token sınırı.
 */
function llmLimits(config: Config, scope: LLMScope, now: Date): ReservationLimit[] {
  const scoped: ReservationLimit =
    scope.kind === "meeting"
      ? meetingTokenLimit(scope.meeting.id, now)
      : scope.access === "trial"
        ? trialAccountTokenLimit(config, scope.userId, now)
        : subscriberAccountTokenLimit(config, scope.userId, now);
  return [scoped, monthlyTokenLimit(config, scope.userId, now), dailyTokenLimit(config, scope.userId, now)];
}

/** Çağrının harcaması deneme tavanına da sayılır mı: deneme toplantısı ya da denemedeki hesap çağrısı. Saf fonksiyondur. */
function isTrialSpend(scope: LLMScope): boolean {
  return scope.kind === "meeting" ? scope.meeting.kind === "trial" : scope.access === "trial";
}

/** Log alanı: toplantı kimliği ya da hesap çağrısında null. Saf fonksiyondur. */
function scopeMeetingId(scope: LLMScope): string | null {
  return scope.kind === "meeting" ? scope.meeting.id : null;
}

/**
 * Anthropic istemcisi (dış sistem bağlantısı): yeniden denemeyi SDK değil `withRetries` yapar (uyarı loglanır). Zaman
 * aşımı çağrı başına verilir (`messageTimeoutMs`, `streamFirstByteTimeoutMs`); SDK onu yanıt başlığı gelene dek uygular.
 */
function anthropicClient(context: RequestContext, config: Config): Anthropic {
  return new Anthropic({ apiKey: config.secrets.anthropic, fetch: context.platform.fetch, maxRetries: 0, timeout: messageTimeoutMs });
}

/** Bağlantı hatası ve geçici durumlar (408, 409, 429, 5xx, 529) yeniden denenir. Saf fonksiyondur. */
export function isRetryableAnthropicError(error: unknown): boolean {
  if (error instanceof Anthropic.APIUserAbortError) {
    return false;
  }
  if (error instanceof Anthropic.APIConnectionError) {
    return true;
  }
  return error instanceof Anthropic.APIError && error.status !== undefined && isRetryableStatus(error.status);
}

/** SDK hatasını istemci hatasına çevirir; üst servis mesajı (içerik yankılayabilir) taşınmaz, yalnızca durum loglanır. */
function mapAnthropicError(error: unknown, userId: string, meetingId: string | null): ApiError {
  if (error instanceof Anthropic.APIError) {
    log("error", "anthropic_failed", { userId, meetingId, status: error.status ?? null, requestId: error.requestID ?? null });
    if (error.status !== undefined && !isRetryableStatus(error.status)) {
      return new ProviderApiError("anthropic", "upstream_rejected", `Yapay zekâ isteği reddedildi (durum ${error.status}).`);
    }
    return new ProviderApiError("anthropic", "upstream_unavailable", "Yapay zekâ servisi şu an yanıt vermiyor; biraz sonra yeniden dene.");
  }
  log("error", "anthropic_failed", { userId, meetingId, error: errorName(error) });
  return new ProviderApiError("anthropic", "upstream_unavailable", "Yapay zekâ servisi şu an yanıt vermiyor; biraz sonra yeniden dene.");
}

/** Toplam girdi tokenı (önbellek okuma/yazma dahil). Saf fonksiyondur. */
function totalInputTokens(usage: { input_tokens: number | null; cache_creation_input_tokens: number | null; cache_read_input_tokens: number | null }): number {
  return (usage.input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0);
}

/**
 * Başarıyla biterse toplantıya ilk not anını (`meeting_sessions.first_note_at`) yazacak çağrının toplantısı: not
 * yazma ve düzenleme istemcide `effort: medium` ile gelir (canlı çeviri ve hızlı özellikler `low`); hesap çağrısında
 * ve `low`'da null. Saf fonksiyondur.
 */
export function noteMeetingIdOf(scope: LLMScope, request: LLMRequest): string | null {
  return scope.kind === "meeting" && request.effort === "medium" ? scope.meeting.id : null;
}

/**
 * Ayırmayı gerçek kullanımla kesinleştirir ve gerçek maliyeti günlük harcamaya ekler (denemedeyse deneme payına da);
 * kullanım aynı işlemde çağrının günlük token kovasına (`usageTag`) da yazılır. `noteMeetingId` verildiyse (başarılı not
 * çağrısı) aynı işlemde toplantının ilk not anı yazılır (yalnızca boşsa).
 */
async function chargeUsage(
  db: D1Database,
  scope: LLMScope,
  reservation: UsageReservation,
  usage: TokenUsage,
  usageTag: LLMUsageTag,
  noteMeetingId: string | null,
  now: Date,
): Promise<void> {
  const noteStatements: D1PreparedStatement[] =
    noteMeetingId === null
      ? []
      : [db.prepare("UPDATE meeting_sessions SET first_note_at = ? WHERE id = ? AND first_note_at IS NULL").bind(now.getTime(), noteMeetingId)];
  await db.batch([
    llmUsageStatement(db, reservation.day, usageTag, usage),
    ...settleLLMStatements(db, reservation, usage, llmCostMicroUsd(usage.inputTokens, usage.outputTokens), now),
    ...noteStatements,
  ]);
  log("info", "llm_usage", { userId: scope.userId, meetingId: scopeMeetingId(scope), inputTokens: usage.inputTokens, outputTokens: usage.outputTokens });
}

/**
 * İstek gönderildikten sonra başarısız olan çağrı: kullanıcının sayaçlarına bir şey yazılmaz, ayırma kapanır; Anthropic
 * girdiyi işlemiş olabileceği için tahmini girdi maliyeti günlük harcamaya sayılır.
 */
async function chargeFailure(db: D1Database, reservation: UsageReservation, estimatedInput: number, now: Date): Promise<void> {
  await db.batch(settleLLMStatements(db, reservation, { inputTokens: 0, outputTokens: 0 }, llmCostMicroUsd(estimatedInput, 0), now));
}

/** Akışsız çağrı ve kesinleştirmesi (başarıda gerçek kullanım, hatada `chargeFailure`). */
async function callMessage(
  db: D1Database,
  client: Anthropic,
  retry: RetryOptions,
  params: Anthropic.MessageCreateParamsNonStreaming,
  scope: LLMScope,
  reservation: UsageReservation,
  estimatedInput: number,
  usageTag: LLMUsageTag,
  noteMeetingId: string | null,
  now: Date,
): Promise<CallOutcome<Anthropic.Message>> {
  let message: Anthropic.Message;
  try {
    message = await withRetries(retry, (): Promise<Anthropic.Message> => client.messages.create(params, { timeout: messageTimeoutMs }));
  } catch (error: unknown) {
    await chargeFailure(db, reservation, estimatedInput, now);
    return { ok: false, error: mapAnthropicError(error, scope.userId, scopeMeetingId(scope)) };
  }
  const usage: TokenUsage = { inputTokens: totalInputTokens(message.usage), outputTokens: message.usage.output_tokens };
  await chargeUsage(db, scope, reservation, usage, usageTag, noteMeetingId, now);
  return { ok: true, value: message };
}

/** Anthropic akışı. */
type MessageStream = AsyncIterable<Anthropic.RawMessageStreamEvent> & { controller: AbortController };

/** Akışı açar (ilk bayt zaman aşımıyla); açılamazsa `chargeFailure` ile kesinleştirir. */
async function openStream(
  db: D1Database,
  client: Anthropic,
  retry: RetryOptions,
  params: Anthropic.MessageCreateParamsNonStreaming,
  scope: LLMScope,
  reservation: UsageReservation,
  estimatedInput: number,
  now: Date,
): Promise<CallOutcome<MessageStream>> {
  try {
    const stream: MessageStream = await withRetries(retry, () => client.messages.create({ ...params, stream: true }, { timeout: streamFirstByteTimeoutMs }));
    return { ok: true, value: stream };
  } catch (error: unknown) {
    await chargeFailure(db, reservation, estimatedInput, now);
    return { ok: false, error: mapAnthropicError(error, scope.userId, scopeMeetingId(scope)) };
  }
}

/**
 * Haiku vekili. Girdi tahmini sınırı aşarsa 413. `max_tokens` çağrı başı sınırla (toplantıda `LLM_MAX_TOKENS`, hesap
 * çağrısında daha küçük `LLM_ACCOUNT_MAX_TOKENS`) ve en dar kalan sınıra (`llmLimits`) göre kısılır; `tahmin +
 * max_tokens` tek koşullu ifadeyle süreli bir ayırma satırı olarak ayrılır (eşzamanlı çağrılar ve yeniden başlatılan
 * toplantılar sınırları aşamaz). Üst çağrı ve kesinleştirme `continueAfterDisconnect` ile istemci koparsa da tamamlanır:
 * yanıt bitince gerçek kullanım yazılır; üst çağrı başarısızsa tahmini girdi maliyeti harcamaya sayılır; akış kesilirse
 * ayrılan miktar harcanmış sayılır. Worker kesinleştiremeden durursa ayırmanın süresi dolar (bkz. `reservations.ts`).
 */
export async function proxyLLM(db: D1Database, context: RequestContext, config: Config, scope: LLMScope, request: LLMRequest): Promise<Response> {
  const estimatedInput: number = estimateInputTokens(request);
  if (estimatedInput > config.llm.maxInputTokens) {
    throw new ApiError("payload_too_large", `Girdi çok uzun (tahmini ${estimatedInput} token, en çok ${config.llm.maxInputTokens}).`);
  }
  const now: Date = context.platform.now();
  const limits: ReservationLimit[] = llmLimits(config, scope, now);
  const tightest: { readonly remaining: number; readonly error: ApiError } = tightestLimit(limits, await remainingOf(db, limits));
  const callMax: number = scope.kind === "meeting" ? config.llm.maxTokens : config.llm.accountMaxTokens;
  const maxTokens: number = clampMaxTokens(request.max_tokens, callMax, tightest.remaining, estimatedInput, tightest.error);
  const reservedTokens: number = estimatedInput + maxTokens;
  const reservation: UsageReservation = llmReservation(
    {
      userId: scope.userId,
      meetingId: scopeMeetingId(scope),
      tokens: reservedTokens,
      trialAccountCall: isTrialAccountCall(scope),
      subscriberAccountCall: isSubscriberAccountCall(scope),
      estimatedMicroUsd: llmCostMicroUsd(estimatedInput, maxTokens),
      trialSpend: isTrialSpend(scope),
    },
    now,
  );
  await reserveUsage(
    db,
    reservation,
    limits.map((limit: ReservationLimit): ReservationCheck => ({ limit, amount: reservedTokens })),
  );
  const client: Anthropic = anthropicClient(context, config);
  const params: Anthropic.MessageCreateParamsNonStreaming = upstreamParams(request, maxTokens);
  const retry: RetryOptions = {
    service: "anthropic",
    attempts: 3,
    baseDelayMs: context.platform.retryBaseDelayMs,
    isRetryable: isRetryableAnthropicError,
    recordRetry: context.platform.recordRetry,
  };
  const logFields: LogFields = { userId: scope.userId, meetingId: scopeMeetingId(scope), reservationId: reservation.id };

  const noteMeetingId: string | null = noteMeetingIdOf(scope, request);
  const usageTag: LLMUsageTag = llmUsageTagOf(scope.kind, request);

  if (request.stream !== true) {
    const outcome: CallOutcome<Anthropic.Message> = await continueAfterDisconnect(
      context,
      callMessage(db, client, retry, params, scope, reservation, estimatedInput, usageTag, noteMeetingId, now),
      "llm_settle_failed",
      logFields,
    );
    if (!outcome.ok) {
      throw outcome.error;
    }
    return jsonResponse(200, outcome.value);
  }

  const opened: CallOutcome<MessageStream> = await continueAfterDisconnect(
    context,
    openStream(db, client, retry, params, scope, reservation, estimatedInput, now),
    "llm_settle_failed",
    logFields,
  );
  if (!opened.ok) {
    throw opened.error;
  }
  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
  runAfterResponse(
    context,
    pumpStream(db, opened.value, writable, scope, reservation, estimatedInput, maxTokens, usageTag, noteMeetingId, now),
    "llm_settle_failed",
    logFields,
  );
  return new Response(readable, {
    status: 200,
    headers: { "content-type": "text/event-stream; charset=utf-8", "cache-control": "no-store" },
  });
}

/** SSE olayı satırları. Saf fonksiyondur. */
export function sseEvent(type: string, data: object): string {
  return `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`;
}

/**
 * Anthropic akışını olay olay istemciye aktarır ve kullanımı sayar (`message_start` girdi, `message_delta` çıktı).
 * Akış ortasında hata olursa istemciye `error` olayı gider (üst servis mesajı olmadan); hata servis sayacına ve
 * (toplantıdaysa) toplantıya yazılır. İstemci koparsa üst akış iptal edilir. Akış tamamlanmadıysa ayrılan bütçenin
 * tamamı harcanmış sayılır; yalnızca tamamlanan akış toplantının ilk not anını yazar (`noteMeetingId`).
 */
async function pumpStream(
  db: D1Database,
  stream: MessageStream,
  writable: WritableStream<Uint8Array>,
  scope: LLMScope,
  reservation: UsageReservation,
  estimatedInput: number,
  maxTokens: number,
  usageTag: LLMUsageTag,
  noteMeetingId: string | null,
  now: Date,
): Promise<void> {
  const writer: WritableStreamDefaultWriter<Uint8Array> = writable.getWriter();
  const encoder: TextEncoder = new TextEncoder();
  let inputTokens: number | null = null;
  let outputTokens: number | null = null;
  let completed: boolean = false;
  let clientGone: boolean = false;
  /** İstemciye yazar; istemci koptuysa üst akışı iptal eder ve false döndürür. */
  const forward = async (text: string): Promise<boolean> => {
    try {
      await writer.write(encoder.encode(text));
      return true;
    } catch {
      clientGone = true;
      stream.controller.abort();
      log("info", "llm_client_disconnected", { userId: scope.userId, meetingId: scopeMeetingId(scope) });
      return false;
    }
  };
  try {
    for await (const event of stream) {
      if (event.type === "message_start") {
        inputTokens = totalInputTokens(event.message.usage);
      } else if (event.type === "message_delta") {
        outputTokens = event.usage.output_tokens;
        if (typeof event.usage.input_tokens === "number") {
          inputTokens = Math.max(inputTokens ?? 0, totalInputTokens(event.usage));
        }
      } else if (event.type === "message_stop") {
        completed = true;
      }
      if (!(await forward(sseEvent(event.type, event)))) {
        break;
      }
    }
  } catch (error: unknown) {
    if (!clientGone) {
      stream.controller.abort();
      const retryable: boolean = isRetryableAnthropicError(error);
      log("warn", "anthropic_stream_failed", { userId: scope.userId, meetingId: scopeMeetingId(scope), error: errorName(error), retryable });
      const errorType: string = retryable ? "overloaded_error" : "api_error";
      await forward(sseEvent("error", { type: "error", error: { type: errorType, message: "Yapay zekâ akışı yarıda kesildi." } }));
      await recordOpsEvents(db, [{ kind: "provider_error", detail: "anthropic" }], now);
      if (scope.kind === "meeting") {
        await recordMeetingFailure(db, scope.userId, scope.meeting.id, "upstream_unavailable:anthropic", now);
      }
    }
  } finally {
    const finished: boolean = completed && outputTokens !== null;
    const usage: TokenUsage = finished
      ? { inputTokens: inputTokens ?? estimatedInput, outputTokens: outputTokens ?? maxTokens }
      : { inputTokens: inputTokens ?? estimatedInput, outputTokens: maxTokens };
    try {
      await chargeUsage(db, scope, reservation, usage, usageTag, finished ? noteMeetingId : null, now);
    } finally {
      if (!clientGone) {
        await writer.close();
      }
    }
  }
}
