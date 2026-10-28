/** Worker bağlamaları: `wrangler.jsonc` değişkenleri, gizli değerler (`wrangler secret put`), D1 ve hız sınırları. */
export interface Env {
  readonly DB: D1Database;
  readonly AUTH_IP_LIMITER: RateLimit;
  readonly API_IP_LIMITER: RateLimit;
  readonly START_USER_LIMITER: RateLimit;
  readonly PROXY_USER_LIMITER: RateLimit;

  readonly ENVIRONMENT: string;
  readonly SITE_ORIGIN: string;
  readonly APPLE_CLIENT_IDS: string;
  readonly APP_ATTEST_POLICY: string;
  readonly APP_ATTEST_ENVIRONMENT: string;
  readonly APP_ATTEST_APP_IDS: string;
  readonly APP_ATTEST_ALLOWED_CATEGORIES: string;
  readonly TRIAL_MEETINGS: string;
  readonly TRIAL_ACCOUNTS_PER_IP_PER_DAY: string;
  readonly TRIAL_MAX_MEETING_MINUTES: string;
  readonly SUBSCRIBER_MAX_MEETING_MINUTES: string;
  readonly MONTHLY_CAP_HOURS: string;
  readonly MEETING_GRACE_MINUTES: string;
  readonly PAST_DUE_GRACE_DAYS: string;
  readonly TRIAL_MEETING_TOKEN_BUDGET: string;
  readonly SUBSCRIBER_MEETING_TOKEN_BUDGET: string;
  readonly LLM_MAX_TOKENS: string;
  readonly LLM_MAX_REQUEST_BYTES: string;
  readonly LLM_MAX_INPUT_TOKENS: string;
  readonly TRANSCRIBE_MAX_BYTES: string;
  readonly TRANSCRIBE_MAX_KEYTERMS: string;
  readonly SCRIBE_USD_PER_HOUR: string;
  readonly SCRIBE_KEYTERMS_USD_PER_HOUR: string;
  readonly DAILY_SPEND_CEILING_USD: string;
  readonly REFRESH_TOKEN_DAYS: string;
  readonly EMAIL_SENDER: string;
  readonly EMAIL_FROM: string;
  readonly EMAIL_LINK_URL: string;
  readonly STRIPE_PRICE_ID: string;

  readonly ACCESS_TOKEN_SECRET: string;
  readonly ANTHROPIC_API_KEY: string;
  readonly ELEVENLABS_API_KEY: string;
  readonly STRIPE_SECRET_KEY: string;
  readonly STRIPE_WEBHOOK_SECRET: string;
  readonly TURNSTILE_SECRET_KEY: string;
  readonly RESEND_API_KEY: string;
}
