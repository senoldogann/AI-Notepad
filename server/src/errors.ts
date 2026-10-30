/** İstemciye dönen hata kodları; her biri sabit bir HTTP durumuna bağlıdır. */
export type ErrorCode =
  | "bad_request"
  | "invalid_body"
  | "unauthorized"
  | "invalid_token"
  | "forbidden"
  | "not_found"
  | "method_not_allowed"
  | "length_required"
  | "payload_too_large"
  | "unsupported_media_type"
  | "rate_limited"
  | "turnstile_failed"
  | "attestation_required"
  | "attestation_invalid"
  | "assertion_invalid"
  | "challenge_invalid"
  | "subscription_required"
  | "subscription_exists"
  | "complimentary_subscription"
  | "trial_exhausted"
  | "trial_not_started"
  | "trial_ip_limit"
  | "trial_device_used"
  | "device_check_required"
  | "device_check_invalid"
  | "monthly_cap_reached"
  | "daily_cap_reached"
  | "transcription_closed"
  | "transcription_in_progress"
  | "meeting_not_active"
  | "reprocess_limit_reached"
  | "meeting_budget_exhausted"
  | "audio_too_long"
  | "upstream_rejected"
  | "upstream_unavailable"
  | "spend_ceiling_reached"
  | "trial_capacity_reached"
  | "deepgram_unavailable"
  | "deepgram_grant_limit"
  | "referral_invalid"
  | "referral_self"
  | "referral_not_eligible"
  | "referral_unavailable"
  | "referral_limit_reached"
  | "blog_unavailable"
  | "blog_post_exists"
  | "blog_conflict"
  | "blog_post_invalid"
  | "webhook_invalid"
  | "internal_error";

const statusByCode: Readonly<Record<ErrorCode, number>> = {
  bad_request: 400,
  invalid_body: 400,
  unauthorized: 401,
  invalid_token: 401,
  forbidden: 403,
  not_found: 404,
  method_not_allowed: 405,
  length_required: 411,
  payload_too_large: 413,
  unsupported_media_type: 415,
  rate_limited: 429,
  turnstile_failed: 403,
  attestation_required: 403,
  attestation_invalid: 400,
  assertion_invalid: 403,
  challenge_invalid: 400,
  subscription_required: 402,
  subscription_exists: 409,
  complimentary_subscription: 409,
  trial_exhausted: 402,
  trial_not_started: 403,
  trial_ip_limit: 429,
  trial_device_used: 403,
  device_check_required: 400,
  device_check_invalid: 400,
  monthly_cap_reached: 403,
  daily_cap_reached: 429,
  transcription_closed: 403,
  transcription_in_progress: 409,
  meeting_not_active: 403,
  reprocess_limit_reached: 409,
  meeting_budget_exhausted: 429,
  audio_too_long: 413,
  upstream_rejected: 502,
  upstream_unavailable: 502,
  spend_ceiling_reached: 503,
  trial_capacity_reached: 503,
  deepgram_unavailable: 503,
  deepgram_grant_limit: 429,
  referral_invalid: 404,
  referral_self: 403,
  referral_not_eligible: 409,
  referral_unavailable: 503,
  referral_limit_reached: 409,
  blog_unavailable: 503,
  blog_post_exists: 409,
  blog_conflict: 409,
  blog_post_invalid: 500,
  webhook_invalid: 400,
  internal_error: 500,
};

/**
 * İstemciye gösterilecek hata. Mesaj kullanıcıya/istemciye açıktır: gizli değer, jeton, toplantı içeriği ya da üst
 * servis gövdesi içermez.
 */
export class ApiError extends Error {
  override readonly name: string = "ApiError";
  readonly code: ErrorCode;
  readonly status: number;

  constructor(code: ErrorCode, message: string) {
    super(message);
    this.code = code;
    this.status = statusByCode[code];
  }
}

/**
 * Üst servisin başarısızlığından doğan istemci hatası (`upstream_rejected` ya da `upstream_unavailable`): hangi servisin
 * (`anthropic`, `elevenlabs`, `stripe`, `turnstile`, kimlik sağlayıcısı anahtarları) başarısız olduğunu taşır; yönetim
 * panelindeki servis hatası sayacı bundan yazılır (`opsEvents.ts`). İstemciye giden gövde `ApiError` ile aynıdır.
 */
export class ProviderApiError extends ApiError {
  override readonly name: string = "ProviderApiError";
  readonly service: string;

  constructor(service: string, code: "upstream_rejected" | "upstream_unavailable", message: string) {
    super(code, message);
    this.service = service;
  }
}

/** Üst servis (Anthropic, ElevenLabs, Deepgram, Apple, Google, Stripe, Turnstile, DeviceCheck, GitHub) hatası; gövde değil yalnızca durum taşır. */
export class UpstreamError extends Error {
  override readonly name: string = "UpstreamError";
  readonly service: string;
  readonly status: number;
  readonly retryable: boolean;

  constructor(service: string, status: number, retryable: boolean, detail: string) {
    super(`${service} isteği başarısız (durum ${status}): ${detail}`);
    this.service = service;
    this.status = status;
    this.retryable = retryable;
  }
}

/** HTTP durumu yeniden denenebilir mi (zaman aşımı, hız sınırı, sunucu hatası). Saf fonksiyondur. */
export function isRetryableStatus(status: number): boolean {
  return status === 408 || status === 409 || status === 429 || status >= 500;
}
