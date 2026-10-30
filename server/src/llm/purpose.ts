import { ApiError } from "../errors";
import type { TokenUsage } from "../reservations";
import { dayKey } from "../usage";

/**
 * Yapay zekâ çağrısının amacı (`x-llm-purpose` başlığı): uygulamanın her istek kurucusu tek bir amaç taşır. Liste
 * istemcinin `LLMPurpose` enum'uyla birebir aynıdır (Swift `ServerParityTests` bu diziyi okur):
 * - `live_translation`: kayıt sırasında canlı cümle çevirisi;
 * - `missed_summary`: "Ne kaçırdım?"; `live_question`: kayıt sırasında toplantı sorusu;
 * - `note`: tek parça toplantı notu; `note_chunk` ve `note_overview`: uzun toplantının parçalı notu ve birleştirmesi;
 * - `speaker_review`: konuşmacı gözden geçirmesi; `note_edit`: not düzenleme ve yeniden yazma;
 * - `shared_note_translation`: notun paylaşım diline çevirisi;
 * - `ask_search_terms` ve `ask_answer`: Sor'un arama terimleri ve yanıtı;
 * - `task_agent`: görev aracına (Linear, Jira, Notion) iş açan ajan; `connection_test`: Ayarlar'daki bağlantı denemesi.
 */
export const llmPurposes = [
  "live_translation",
  "missed_summary",
  "live_question",
  "note",
  "note_chunk",
  "note_overview",
  "speaker_review",
  "note_edit",
  "shared_note_translation",
  "ask_search_terms",
  "ask_answer",
  "task_agent",
  "connection_test",
] as const;

/** Bilinen amaç ya da başlığı göndermeyen eski istemcinin çağrısı (`unattributed`). */
export type LLMPurpose = (typeof llmPurposes)[number] | "unattributed";

const purposeSet: ReadonlySet<string> = new Set<string>(llmPurposes);

/** Değer bilinen bir amaç mı. Saf fonksiyondur. */
function isKnownPurpose(value: string): value is (typeof llmPurposes)[number] {
  return purposeSet.has(value);
}

/**
 * `x-llm-purpose` başlığının amacı. Başlık yoksa `unattributed`: 0.1.9 ve önceki uygulamalar göndermez, zorunlu
 * olsaydı onların yapay zekâ çağrıları reddedilirdi. Başlık varsa listedeki değerlerden biri olmalı; değilse
 * `llm_purpose_invalid` (bilinmeyen değer hiçbir kovaya yazılmaz). Saf fonksiyondur.
 */
export function llmPurposeOf(header: string | null): LLMPurpose {
  if (header === null) {
    return "unattributed";
  }
  if (!isKnownPurpose(header)) {
    throw new ApiError("llm_purpose_invalid", "x-llm-purpose başlığı bilinen bir yapay zekâ amacı olmalı.");
  }
  return header;
}

/**
 * Kesinleşen çağrının tokenlarını günün (UTC) amaç satırına ekleyen ifade (`llm_purpose_usage`); kullanıcı ya da
 * toplantı yazılmaz. Kesinleştirmenin toplu işlemine eklenir (bkz. `chargeUsage`). Saf fonksiyondur.
 */
export function purposeUsageStatement(db: D1Database, purpose: LLMPurpose, usage: TokenUsage, now: Date): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO llm_purpose_usage (day, purpose, input_tokens, output_tokens, calls) VALUES (?, ?, ?, ?, 1)
       ON CONFLICT(day, purpose) DO UPDATE SET input_tokens = input_tokens + excluded.input_tokens,
         output_tokens = output_tokens + excluded.output_tokens, calls = calls + 1`,
    )
    .bind(dayKey(now), purpose, usage.inputTokens, usage.outputTokens);
}
