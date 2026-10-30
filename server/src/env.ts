/** Worker bağlamaları: `wrangler.jsonc` değişkenleri, gizli değerler (`wrangler secret put`), D1 ve hız sınırları. */
export interface Env {
  readonly DB: D1Database;
  readonly AUTH_IP_LIMITER: RateLimit;
  readonly API_IP_LIMITER: RateLimit;
  readonly START_USER_LIMITER: RateLimit;
  readonly PROXY_USER_LIMITER: RateLimit;
  readonly REPORT_IP_LIMITER: RateLimit;
  readonly DEEPGRAM_USER_LIMITER: RateLimit;
  /** `POST /v1/telemetry` ve `/v1/telemetry/features`: kullanıcı başına dakikada 6 (ayrıca günde 200, bkz. `telemetry.ts`). */
  readonly TELEMETRY_USER_LIMITER: RateLimit;

  readonly ENVIRONMENT: string;
  readonly SITE_ORIGIN: string;
  readonly APPLE_CLIENT_IDS: string;
  readonly GOOGLE_CLIENT_IDS: string;
  readonly ADMIN_IDENTITIES: string;
  readonly CF_ACCESS_TEAM_DOMAIN: string;
  readonly CF_ACCESS_AUD: string;
  readonly DMG_URL: string;
  readonly APPCAST_URL: string;
  readonly PRICE_USD_MONTHLY: string;
  readonly PRICE_USD_YEARLY: string;
  readonly REFERRAL_POLICY: string;
  readonly REFERRAL_MAX_PENDING: string;
  readonly REPORT_BYTES_PER_DAY: string;
  readonly APP_ATTEST_POLICY: string;
  readonly APP_ATTEST_ENVIRONMENT: string;
  readonly APP_ATTEST_APP_IDS: string;
  readonly APP_ATTEST_ALLOWED_CATEGORIES: string;
  readonly DEVICECHECK_POLICY: string;
  readonly DEVICECHECK_ENVIRONMENT: string;
  readonly DEVICECHECK_TEAM_ID: string;
  readonly DEVICECHECK_KEY_ID: string;
  readonly TRIAL_MEETINGS: string;
  readonly TRIAL_DAYS: string;
  readonly TRIAL_ACCOUNT_DAILY_TOKENS: string;
  readonly TRIAL_ACCOUNTS_PER_IP_PER_DAY: string;
  readonly TRIAL_MAX_MEETING_MINUTES: string;
  readonly SUBSCRIBER_MAX_MEETING_MINUTES: string;
  readonly MONTHLY_CAP_HOURS: string;
  readonly MEETING_GRACE_MINUTES: string;
  readonly PAST_DUE_GRACE_DAYS: string;
  readonly TRIAL_MEETING_TOKEN_BUDGET: string;
  readonly SUBSCRIBER_MEETING_TOKEN_BUDGET: string;
  readonly MONTHLY_TOKEN_CAP: string;
  readonly MONTHLY_ACCOUNT_TOKEN_CAP: string;
  readonly DAILY_TOKEN_CAP: string;
  readonly MAX_MEETING_STARTS_PER_DAY: string;
  readonly LLM_MAX_TOKENS: string;
  readonly LLM_ACCOUNT_MAX_TOKENS: string;
  readonly LLM_MAX_REQUEST_BYTES: string;
  readonly LLM_MAX_INPUT_TOKENS: string;
  readonly TRANSCRIBE_MAX_BYTES: string;
  readonly TRANSCRIBE_MAX_KEYTERMS: string;
  readonly SCRIBE_USD_PER_HOUR: string;
  readonly SCRIBE_KEYTERMS_USD_PER_HOUR: string;
  readonly ELEVENLABS_MONTHLY_AUDIO_HOURS: string;
  readonly ELEVENLABS_BILLING_DAY: string;
  readonly DEEPGRAM_POLICY: string;
  readonly DEEPGRAM_BUDGET_USD: string;
  readonly DEEPGRAM_USD_PER_MINUTE: string;
  readonly DAILY_SPEND_CEILING_USD: string;
  readonly DAILY_TRIAL_SPEND_CEILING_USD: string;
  readonly REFRESH_TOKEN_DAYS: string;
  readonly STRIPE_PRICE_ID: string;
  readonly STRIPE_YEARLY_PRICE_ID: string;
  /** Blog yazılarının durduğu GitHub deposu (`sahip/ad`) ve yazıların işlendiği dal (bkz. `blog.ts`). */
  readonly GITHUB_BLOG_REPO: string;
  readonly GITHUB_BLOG_BRANCH: string;

  readonly ACCESS_TOKEN_SECRET: string;
  /** Kimlik deneme defteri ve deneme IP özetlerinin HMAC sırrı (erişim jetonu sırrından ayrı). */
  readonly TRIAL_HASH_SECRET: string;
  readonly ANTHROPIC_API_KEY: string;
  readonly ELEVENLABS_API_KEY: string;
  readonly STRIPE_SECRET_KEY: string;
  readonly STRIPE_WEBHOOK_SECRET: string;
  readonly TURNSTILE_SECRET_KEY: string;
  /** Yalnızca `DEVICECHECK_POLICY=required` iken gerekir (Apple DeviceCheck .p8 anahtarı, PEM). */
  readonly DEVICECHECK_PRIVATE_KEY?: string;
  /** Yalnızca `DEEPGRAM_POLICY=on` iken gerekir (Deepgram API anahtarı; jeton vermek için, Member ya da üstü yetki). */
  readonly DEEPGRAM_API_KEY?: string;
  /**
   * Yönetim panelinden blog yayını için GitHub jetonu (yalnızca bu depoda Contents okuma/yazma yetkili ince ayarlı
   * kişisel erişim jetonu). Yoksa blog uçları `503 blog_unavailable` döner.
   */
  readonly GITHUB_BLOG_TOKEN?: string;
}
