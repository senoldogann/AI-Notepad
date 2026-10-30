import type { TokenUsage } from "../reservations";
import type { LLMRequest } from "./request";

/**
 * Yapay zekâ token'larının günlük kovaları (`llm_usage_daily`; göç 0043). Sunucu isteğin amacını bilmez; kova isteğin
 * biçiminden çıkarılır (istemci `HostedLLM.swift` → `hostedEffort`): toplantıya bağlı mı (`x-meeting-id`), effort
 * (`medium` not yazma ve düzenleme, `low` canlı ve hızlı özellikler) ve yapılandırılmış çıktı şeması var mı. Çıkarım
 * yaklaşıktır; içerik ve kullanıcı yazılmaz.
 */
export const llmUsageBuckets = [
  // Toplantıda `medium`: toplantı notu (parçalı not, birleştirme, konuşmacı gözden geçirme) ve düzenleme.
  "meeting_note",
  // Toplantıda `low` + şema: yapılandırılmış canlı çeviri (0.1.8 ve sonrası) ve şemalı hızlı özellikler.
  "meeting_live_structured",
  // Toplantıda `low`, şemasız: "Ne kaçırdım?", toplantı sorusu, eski sürümlerin canlı çevirisi.
  "meeting_live_text",
  // Hesap çağrısında `medium`: notu yeniden yazma ve düzenleme.
  "account_note",
  // Hesap çağrısında `low`: Sor, paylaşım çevirisi, görev aracı.
  "account_quick",
] as const;

/** Token kovası. */
export type LLMUsageBucket = (typeof llmUsageBuckets)[number];

/** Çağrının kova etiketi: kova ve akışlı mı. */
export interface LLMUsageTag {
  readonly bucket: LLMUsageBucket;
  readonly streamed: boolean;
}

/** İsteğin kova etiketi. Saf fonksiyondur. */
export function llmUsageTagOf(scope: "meeting" | "account", request: LLMRequest): LLMUsageTag {
  const streamed: boolean = request.stream === true;
  if (scope === "account") {
    return { bucket: request.effort === "medium" ? "account_note" : "account_quick", streamed };
  }
  if (request.effort === "medium") {
    return { bucket: "meeting_note", streamed };
  }
  return { bucket: request.output_config === undefined ? "meeting_live_text" : "meeting_live_structured", streamed };
}

/** Kesinleşen çağrının kovasına günlük ekleme (gün: ayırmanın günü, `daily_usage` ile aynı). */
export function llmUsageStatement(db: D1Database, day: string, tag: LLMUsageTag, usage: TokenUsage): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO llm_usage_daily (day, bucket, calls, streamed_calls, input_tokens, output_tokens) VALUES (?, ?, 1, ?, ?, ?)
       ON CONFLICT(day, bucket) DO UPDATE SET calls = calls + 1, streamed_calls = streamed_calls + excluded.streamed_calls,
         input_tokens = input_tokens + excluded.input_tokens, output_tokens = output_tokens + excluded.output_tokens`,
    )
    .bind(day, tag.bucket, tag.streamed ? 1 : 0, usage.inputTokens, usage.outputTokens);
}
