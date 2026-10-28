import type Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import { ApiError } from "../errors";

/** Sunucunun kullandığı tek model; istemcinin `model` alanı yok sayılır. */
export const hostedModel: string = "claude-haiku-5-5";

/** Düşünmeye ve yanıt metnine yer kalsın diye istenebilecek en küçük `max_tokens`. */
export const minOutputTokens: number = 1024;

const textBlockSchema = z.strictObject({ type: z.literal("text"), text: z.string().min(1) });
const contentSchema = z.union([z.string().min(1), z.array(textBlockSchema).min(1).max(64)]);
const messageSchema = z.strictObject({ role: z.enum(["user", "assistant"]), content: contentSchema });

/**
 * İstemcinin seçebileceği düşünme derinliği: canlı çeviri ve hızlı özellikler `low`, not üretimi `medium`. Daha
 * yüksek seviyeler maliyeti ve gecikmeyi katladığı için kabul edilmez.
 */
export const hostedEffortSchema = z.enum(["low", "medium"]);

/**
 * İzin verilen Anthropic Messages alt kümesi: zorunlu `effort` (`low` | `medium`, varsayılan yok), `system`, yalnızca
 * metin içerikli `messages`, `max_tokens`, `output_config.format` (json_schema) ve `stream`. `model` kabul edilir ama
 * sunucu kendi modelini kullanır. Araçlar, MCP, dosyalar, görseller, örnekleme parametreleri, `thinking`
 * (gönderilmez; düşünme `effort` ile yönetilir), `output_config.effort`, önbellek işaretleri ve bilinmeyen her alan
 * reddedilir.
 */
export const llmRequestSchema = z
  .strictObject({
    effort: hostedEffortSchema,
    model: z.string().max(64).optional(),
    system: z.union([z.string(), z.array(textBlockSchema).max(16)]).optional(),
    messages: z.array(messageSchema).min(1).max(200),
    max_tokens: z.number().int().positive(),
    output_config: z
      .strictObject({
        format: z.strictObject({ type: z.literal("json_schema"), schema: z.record(z.string(), z.json()) }),
      })
      .optional(),
    stream: z.boolean().optional(),
  })
  .refine((body): boolean => body.messages[0]?.role === "user" && body.messages.at(-1)?.role === "user", {
    message: "İlk ve son mesaj kullanıcıdan olmalı (Haiku 5.5 ön doldurmayı reddeder).",
    path: ["messages"],
  });

export type LLMRequest = z.output<typeof llmRequestSchema>;

/** İsteğin metin baytları (sistem + mesajlar + şema). Saf fonksiyondur. */
export function requestTextBytes(request: LLMRequest): number {
  const encoder: TextEncoder = new TextEncoder();
  const parts: string[] = [
    typeof request.system === "string" ? request.system : (request.system ?? []).map((block): string => block.text).join("\n"),
    ...request.messages.map((message): string =>
      typeof message.content === "string" ? message.content : message.content.map((block): string => block.text).join("\n"),
    ),
    request.output_config?.format === undefined ? "" : JSON.stringify(request.output_config.format.schema),
  ];
  return parts.reduce((sum: number, part: string): number => sum + encoder.encode(part).byteLength, 0);
}

/**
 * Girdi token tahmini: UTF-8 baytı / 3, yukarı yuvarlanır. Haiku 5.5'in yeni tokenizer'ı Türkçe metinde de bayt
 * başına daha az token üretir; tahmin bütçe için üstten sınırdır. Saf fonksiyondur.
 */
export function estimateInputTokens(request: LLMRequest): number {
  return Math.ceil(requestTextBytes(request) / 3) + request.messages.length * 8;
}

/**
 * Anthropic'e gidecek gövde: model sabit, `max_tokens` sınırlanır (`clampedMaxTokens`), effort isteğin doğrulanmış
 * `low`/`medium` değeri. Örnekleme parametreleri, `thinking` ve `fallbacks` gönderilmez (Haiku 5.5'te 400 ya da
 * gereksiz; düşünme varsayılan uyarlamalıdır ve `effort` ile ölçeklenir). Saf fonksiyondur.
 */
export function upstreamParams(request: LLMRequest, clampedMaxTokens: number): Anthropic.MessageCreateParamsNonStreaming {
  const format = request.output_config?.format;
  return {
    model: hostedModel,
    max_tokens: clampedMaxTokens,
    messages: request.messages.map((message): Anthropic.MessageParam => ({
      role: message.role,
      content: typeof message.content === "string" ? message.content : message.content.map((block): Anthropic.TextBlockParam => ({ type: "text", text: block.text })),
    })),
    ...(request.system === undefined
      ? {}
      : {
          system:
            typeof request.system === "string" ? request.system : request.system.map((block): Anthropic.TextBlockParam => ({ type: "text", text: block.text })),
        }),
    output_config: {
      effort: request.effort,
      ...(format === undefined ? {} : { format: { type: "json_schema", schema: format.schema } }),
    },
  };
}

/** İstemcinin `max_tokens`'ı yapılandırma ve kalan bütçeyle sınırlanır; düşünmeye yer kalmıyorsa bütçe bitmiştir. Saf fonksiyondur. */
export function clampMaxTokens(requested: number, configMax: number, remainingBudget: number, estimatedInput: number): number {
  const clamped: number = Math.min(requested, configMax, remainingBudget - estimatedInput);
  if (clamped < Math.min(minOutputTokens, requested)) {
    throw new ApiError("meeting_budget_exhausted", "Bu toplantının yapay zekâ bütçesi doldu; yeni bir toplantı başlat.");
  }
  return clamped;
}
