import Anthropic from "@anthropic-ai/sdk";
import type { Config } from "../config";
import { ApiError, isRetryableStatus } from "../errors";
import { jsonResponse } from "../http";
import { errorName, log } from "../log";
import type { MeetingRow } from "../meetings";
import type { RequestContext } from "../platform";
import { withRetries } from "../retry";
import {
  type ReservationStep,
  type TokenHeadroom,
  meetingTokenStep,
  reserveAll,
  settleMeetingTokenStatement,
  settleUserTokenStatements,
  tokenHeadroom,
  userTokenSteps,
} from "../reservations";
import { addSpendStatement, llmCostMicroUsd } from "../usage";
import { type LLMRequest, clampMaxTokens, estimateInputTokens, upstreamParams } from "./request";

/**
 * Çağrının bağlı olduğu bütçe: açık bir toplantı (kayıt sırasında ve ek sürede; toplantı bütçesi de düşer) ya da
 * yalnızca hesap (Sor, notu yeniden yazma, düzenleme, görev aracı; kullanıcının günlük ve aylık sınırı ve daha küçük
 * çağrı başı `max_tokens`).
 */
export type LLMScope =
  | { readonly kind: "meeting"; readonly userId: string; readonly meeting: MeetingRow }
  | { readonly kind: "account"; readonly userId: string };

/** Log alanı: toplantı kimliği ya da hesap çağrısında null. Saf fonksiyondur. */
function scopeMeetingId(scope: LLMScope): string | null {
  return scope.kind === "meeting" ? scope.meeting.id : null;
}

/** Gerçekleşen token kullanımı. */
interface TokenUsage {
  readonly inputTokens: number;
  readonly outputTokens: number;
}

/** Anthropic istemcisi (dış sistem bağlantısı): yeniden denemeyi SDK değil `withRetries` yapar (uyarı loglanır). */
function anthropicClient(context: RequestContext, config: Config): Anthropic {
  return new Anthropic({ apiKey: config.secrets.anthropic, fetch: context.platform.fetch, maxRetries: 0, timeout: 120_000 });
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
      return new ApiError("upstream_rejected", `Yapay zekâ isteği reddedildi (durum ${error.status}).`);
    }
    return new ApiError("upstream_unavailable", "Yapay zekâ servisi şu an yanıt vermiyor; biraz sonra yeniden dene.");
  }
  log("error", "anthropic_failed", { userId, meetingId, error: errorName(error) });
  return new ApiError("upstream_unavailable", "Yapay zekâ servisi şu an yanıt vermiyor; biraz sonra yeniden dene.");
}

/** Toplam girdi tokenı (önbellek okuma/yazma dahil). Saf fonksiyondur. */
function totalInputTokens(usage: { input_tokens: number | null; cache_creation_input_tokens: number | null; cache_read_input_tokens: number | null }): number {
  return (usage.input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0);
}

/** Ayrılan tokenı (toplantı varsa toplantı, aylık, günlük) gerçek kullanımla değiştirir ve günlük harcamaya ekler. */
async function chargeUsage(db: D1Database, scope: LLMScope, reserved: number, usage: TokenUsage, now: Date): Promise<void> {
  const meetingStatements: D1PreparedStatement[] =
    scope.kind === "meeting" ? [settleMeetingTokenStatement(db, scope.meeting.id, reserved, usage.inputTokens + usage.outputTokens)] : [];
  await db.batch([
    ...meetingStatements,
    ...settleUserTokenStatements(db, scope.userId, reserved, usage.inputTokens, usage.outputTokens, now),
    addSpendStatement(db, now, llmCostMicroUsd(usage.inputTokens, usage.outputTokens)),
  ]);
  log("info", "llm_usage", { userId: scope.userId, meetingId: scopeMeetingId(scope), inputTokens: usage.inputTokens, outputTokens: usage.outputTokens });
}

/**
 * Haiku vekili. Girdi tahmini sınırı aşarsa 413. `max_tokens` çağrı başı sınırla (toplantıda `LLM_MAX_TOKENS`, hesap
 * çağrısında daha küçük `LLM_ACCOUNT_MAX_TOKENS`) ve toplantı bütçesi (varsa), kullanıcının aylık ve günlük token
 * sınırından en dar olanına göre kısılır; `tahmin + max_tokens` hepsinden tek koşullu ifadelerle önceden ayrılır
 * (eşzamanlı çağrılar ve yeniden başlatılan toplantılar sınırları aşamaz). Yanıt bitince gerçek kullanım yazılır;
 * akış kesilirse ayrılan miktar harcanmış sayılır.
 */
export async function proxyLLM(db: D1Database, context: RequestContext, config: Config, scope: LLMScope, request: LLMRequest): Promise<Response> {
  const estimatedInput: number = estimateInputTokens(request);
  if (estimatedInput > config.llm.maxInputTokens) {
    throw new ApiError("payload_too_large", `Girdi çok uzun (tahmini ${estimatedInput} token, en çok ${config.llm.maxInputTokens}).`);
  }
  const now: Date = context.platform.now();
  const headroom: TokenHeadroom = await tokenHeadroom(db, config, scope.userId, now);
  const meetingLimits: ReadonlyArray<readonly [number, ApiError]> =
    scope.kind === "meeting"
      ? [[scope.meeting.token_budget - scope.meeting.tokens_used, new ApiError("meeting_budget_exhausted", "Bu toplantının yapay zekâ bütçesi doldu.")]]
      : [];
  const limits: ReadonlyArray<readonly [number, ApiError]> = [
    ...meetingLimits,
    [headroom.monthly, new ApiError("monthly_cap_reached", "Bu ayki yapay zekâ kullanım sınırına ulaştın; sınır ay başında sıfırlanır.")],
    [headroom.daily, new ApiError("daily_cap_reached", "Bugünkü yapay zekâ kullanım sınırına ulaştın; yarın yeniden dene.")],
  ];
  const [remaining, exhausted]: readonly [number, ApiError] = limits.reduce(
    (tightest: readonly [number, ApiError], limit: readonly [number, ApiError]): readonly [number, ApiError] => (limit[0] < tightest[0] ? limit : tightest),
  );
  const callMax: number = scope.kind === "meeting" ? config.llm.maxTokens : config.llm.accountMaxTokens;
  const maxTokens: number = clampMaxTokens(request.max_tokens, callMax, remaining, estimatedInput, exhausted);
  const reserved: number = estimatedInput + maxTokens;
  const meetingSteps: ReservationStep[] = scope.kind === "meeting" ? [meetingTokenStep(db, scope.meeting.id, reserved)] : [];
  await reserveAll(db, [...meetingSteps, ...userTokenSteps(db, config, scope.userId, reserved, now)]);
  const client: Anthropic = anthropicClient(context, config);
  const params: Anthropic.MessageCreateParamsNonStreaming = upstreamParams(request, maxTokens);
  const retry = {
    service: "anthropic",
    attempts: 3,
    baseDelayMs: context.platform.retryBaseDelayMs,
    isRetryable: isRetryableAnthropicError,
  };

  if (request.stream !== true) {
    let message: Anthropic.Message;
    try {
      message = await withRetries(retry, (): Promise<Anthropic.Message> => client.messages.create(params));
    } catch (error: unknown) {
      await chargeUsage(db, scope, reserved, { inputTokens: 0, outputTokens: 0 }, now);
      throw mapAnthropicError(error, scope.userId, scopeMeetingId(scope));
    }
    await chargeUsage(db, scope, reserved, { inputTokens: totalInputTokens(message.usage), outputTokens: message.usage.output_tokens }, now);
    return jsonResponse(200, message);
  }

  let stream: AsyncIterable<Anthropic.RawMessageStreamEvent> & { controller: AbortController };
  try {
    stream = await withRetries(retry, () => client.messages.create({ ...params, stream: true }));
  } catch (error: unknown) {
    await chargeUsage(db, scope, reserved, { inputTokens: 0, outputTokens: 0 }, now);
    throw mapAnthropicError(error, scope.userId, scopeMeetingId(scope));
  }
  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
  context.waitUntil(pumpStream(db, stream, writable, scope, reserved, estimatedInput, maxTokens, now));
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
 * Akış ortasında hata olursa istemciye `error` olayı gider (üst servis mesajı olmadan). İstemci koparsa üst akış iptal
 * edilir. Akış tamamlanmadıysa ayrılan bütçenin tamamı harcanmış sayılır.
 */
async function pumpStream(
  db: D1Database,
  stream: AsyncIterable<Anthropic.RawMessageStreamEvent> & { controller: AbortController },
  writable: WritableStream<Uint8Array>,
  scope: LLMScope,
  reserved: number,
  estimatedInput: number,
  maxTokens: number,
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
    }
  } finally {
    const usage: TokenUsage =
      completed && outputTokens !== null
        ? { inputTokens: inputTokens ?? estimatedInput, outputTokens }
        : { inputTokens: inputTokens ?? estimatedInput, outputTokens: maxTokens };
    try {
      await chargeUsage(db, scope, reserved, usage, now);
    } finally {
      if (!clientGone) {
        await writer.close();
      }
    }
  }
}
