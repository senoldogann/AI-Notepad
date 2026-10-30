import { ApiError, type ErrorCode, ProviderApiError, UpstreamError } from "./errors";
import { errorName, log } from "./log";
import { dayKey } from "./usage";

/**
 * Yönetim panelinin "Sorunlar" sayaçları (`ops_events`) ve toplantının "ne ters gitti" alanları
 * (`meeting_sessions.failure_count`, `last_failure_code`, `last_failure_at`). Sayaçlar gün, tür ve ayrıntı başına
 * toplamdır: kullanıcı, IP ya da içerik yazılmaz.
 */

/**
 * Sayaç türü: ürün reddi (hata kodu), üst servis hatası (servis adı), 5xx yanıt (hata kodu), hesap silme (silinen
 * hesabın kesimi: `subscriber`, `trial`, `signup`; bkz. `account.ts`) ya da üst servis çağrısının yeniden denemesi
 * (servis adı; bkz. `retry.ts`).
 */
export type OpsEventKind = "refusal" | "provider_error" | "server_error" | "account_deleted" | "retry";

/** Tek sayaç artışı. */
export interface OpsEvent {
  readonly kind: OpsEventKind;
  readonly detail: string;
}

/**
 * Sayılan ürün retleri: kullanıcının bir sınıra, kapasiteye ya da hak denetimine takıldığı kodlar. Hepsi kimliği
 * doğrulanmış (ve kullanıcı başına hız sınırlı) isteklerde oluşur. Biçim hataları, kimlik hataları, hız sınırı ve
 * bulunamayan uçlar sayılmaz: kimliksiz bir döngü sayaç yazdırıp D1 yazımı harcatamasın.
 */
export const countedRefusalCodes: ReadonlySet<ErrorCode> = new Set<ErrorCode>([
  "spend_ceiling_reached",
  "trial_capacity_reached",
  "trial_exhausted",
  "trial_ip_limit",
  "trial_device_used",
  "device_check_required",
  "device_check_invalid",
  "attestation_required",
  "attestation_invalid",
  "assertion_invalid",
  "subscription_required",
  "monthly_cap_reached",
  "daily_cap_reached",
  "meeting_budget_exhausted",
  "meeting_not_active",
  "transcription_closed",
  "audio_too_long",
  "reprocess_limit_reached",
  "deepgram_unavailable",
  "deepgram_grant_limit",
  "referral_limit_reached",
]);

/**
 * Başarısız isteğin sayaç artışları. Saf fonksiyondur:
 * - `ProviderApiError` ve `UpstreamError`: servis adıyla `provider_error`;
 * - `countedRefusalCodes` içindeki `ApiError`: kodla `refusal`;
 * - 5xx yanıt (beklenmeyen hata dahil): kodla `server_error`.
 * Bir hata birden çok sayaca girebilir (ör. `spend_ceiling_reached` hem ret hem 503'tür).
 */
export function failureEvents(error: unknown): OpsEvent[] {
  if (error instanceof ApiError) {
    return [
      ...(error instanceof ProviderApiError ? [{ kind: "provider_error" as const, detail: error.service }] : []),
      ...(countedRefusalCodes.has(error.code) ? [{ kind: "refusal" as const, detail: error.code }] : []),
      ...(error.status >= 500 ? [{ kind: "server_error" as const, detail: error.code }] : []),
    ];
  }
  if (error instanceof UpstreamError) {
    return [
      { kind: "provider_error", detail: error.service },
      { kind: "server_error", detail: "upstream_unavailable" },
    ];
  }
  return [{ kind: "server_error", detail: "internal_error" }];
}

/**
 * Toplantının olağan akışındaki kodlar; toplantıya hata olarak yazılmaz: `transcription_in_progress` (aynı parçanın
 * süren isteği; istemci bekleyip yeniden dener), `deepgram_unavailable` ve `deepgram_grant_limit` (canlı metin Mac'te
 * sürer). Deepgram kodları ret sayaçlarında (`countedRefusalCodes`) yine görünür; `transcription_in_progress` istemcinin
 * bekleyip yeniden denediği eşzamanlılık yanıtı olduğu için sayılmaz.
 */
const routineMeetingCodes: ReadonlySet<ErrorCode> = new Set<ErrorCode>(["transcription_in_progress", "deepgram_unavailable", "deepgram_grant_limit"]);

/**
 * Toplantıya yazılacak hata kodu: `ApiError` kodu, üst servis hatalarında `kod:servis` (ör.
 * `upstream_rejected:elevenlabs`), beklenmeyen hatada `internal_error`; olağan akıştaki kodlarda
 * (`routineMeetingCodes`) null. Saf fonksiyondur.
 */
export function meetingFailureCode(error: unknown): string | null {
  if (error instanceof ProviderApiError) {
    return `${error.code}:${error.service}`;
  }
  if (error instanceof ApiError) {
    return routineMeetingCodes.has(error.code) ? null : error.code;
  }
  if (error instanceof UpstreamError) {
    return `upstream_unavailable:${error.service}`;
  }
  return "internal_error";
}

/**
 * Sayaçları bugünün (UTC) satırlarına ekler (tek toplu işlem).
 *
 * Bilinçli istisna (`countDownload` gibi): D1 yazımı başarısız olursa hata adıyla uyarı loglanır ve fonksiyon normal
 * döner. Sayaç asıl hatanın yanıtını değiştirmemeli (D1 kesintisinde zaten 500 dönülüyordur); kayıp yalnızca bir
 * sayaçtır ve log uyarısı onu görünür kılar.
 */
export async function recordOpsEvents(db: D1Database, events: readonly OpsEvent[], now: Date): Promise<void> {
  if (events.length === 0) {
    return;
  }
  const day: string = dayKey(now);
  try {
    await db.batch(
      events.map(
        (event: OpsEvent): D1PreparedStatement =>
          db
            .prepare("INSERT INTO ops_events (day, kind, detail, count) VALUES (?, ?, ?, 1) ON CONFLICT(day, kind, detail) DO UPDATE SET count = count + 1")
            .bind(day, event.kind, event.detail),
      ),
    );
  } catch (error: unknown) {
    log("warn", "ops_event_record_failed", { events: events.length, error: errorName(error) });
  }
}

/**
 * Yeniden deneme sayacını yazan işlev (`Platform.recordRetry`): her çağrı bugünün (UTC, `now()`) `retry` satırını
 * servis adıyla bir artırır. `recordOpsEvents` gibi D1 hatası uyarıyla loglanır, yeniden denemeyi düşürmez.
 */
export function retryRecorder(db: D1Database, now: () => Date): (service: string) => Promise<void> {
  return (service: string): Promise<void> => recordOpsEvents(db, [{ kind: "retry", detail: service }], now());
}

/**
 * Kullanıcının toplantısına hatayı yazar: hata sayısı artar, son kod ve an güncellenir. Başkasının ya da olmayan
 * toplantıda bir şey değişmez. `recordOpsEvents` ile aynı bilinçli istisna: D1 yazımı başarısız olursa uyarı loglanır.
 */
export async function recordMeetingFailure(db: D1Database, userId: string, meetingId: string, code: string, now: Date): Promise<void> {
  try {
    await db
      .prepare(
        `UPDATE meeting_sessions SET failure_count = failure_count + 1, last_failure_code = ?, last_failure_at = ?
         WHERE id = ? AND user_id = ?`,
      )
      .bind(code, now.getTime(), meetingId, userId)
      .run();
  } catch (error: unknown) {
    log("warn", "meeting_failure_record_failed", { userId, meetingId, code, error: errorName(error) });
  }
}
