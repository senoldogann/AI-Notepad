import { z } from "zod";
import type { Env } from "./env";

/** App Attest zorunluluğu: `required` ise toplantı başlatmak doğrulanmış cihaz ister. */
export type AttestPolicy = "required" | "optional";

/** App Attest ortamı (`aaguid`): geliştirme ya da yayın. */
export type AttestEnvironment = "development" | "production";

/** E-posta gönderimi: Resend ya da yalnızca log yazan geliştirme göndericisi. */
export type EmailConfig =
  | { readonly kind: "dev"; readonly from: string; readonly linkUrl: string }
  | { readonly kind: "resend"; readonly from: string; readonly linkUrl: string; readonly apiKey: string };

/** Ortamdan doğrulanmış, tipli yapılandırma. */
export interface Config {
  readonly environment: "development" | "production";
  readonly siteOrigin: string;
  readonly appleClientIds: readonly string[];
  readonly attest: {
    readonly policy: AttestPolicy;
    readonly environment: AttestEnvironment;
    readonly appIds: readonly string[];
    readonly allowedCategories: readonly number[];
  };
  readonly trialMeetings: number;
  /** Bir IP'den bir günde denemeye başlayabilecek yeni hesap sayısı. */
  readonly trialAccountsPerIpPerDay: number;
  readonly trialMaxMeetingMinutes: number;
  readonly subscriberMaxMeetingMinutes: number;
  readonly monthlyCapSeconds: number;
  readonly meetingGraceMs: number;
  /** `past_due` aboneliğin dönem sonundan sonra erişimi koruduğu süre. */
  readonly pastDueGraceMs: number;
  readonly trialMeetingTokenBudget: number;
  readonly subscriberMeetingTokenBudget: number;
  readonly llm: {
    readonly maxTokens: number;
    readonly maxRequestBytes: number;
    readonly maxInputTokens: number;
  };
  readonly transcribe: {
    readonly maxBytes: number;
    readonly maxKeyterms: number;
    readonly usdPerHour: number;
    readonly keytermsUsdPerHour: number;
  };
  readonly dailySpendCeilingMicroUsd: number;
  readonly refreshTokenMs: number;
  readonly email: EmailConfig;
  readonly stripePriceId: string;
  readonly secrets: {
    readonly accessToken: string;
    readonly anthropic: string;
    readonly elevenLabs: string;
    readonly stripe: string;
    readonly stripeWebhook: string;
    readonly turnstile: string;
  };
}

/** Yapılandırma eksik ya da geçersiz: dağıtım hatasıdır, istemciye ayrıntı verilmez. */
export class ConfigError extends Error {
  override readonly name: string = "ConfigError";
  readonly fields: readonly string[];

  constructor(fields: readonly string[]) {
    super(`Geçersiz yapılandırma alanları: ${fields.join(", ")}`);
    this.fields = fields;
  }
}

const positiveInt = z.coerce.number().int().positive();
const positiveNumber = z.coerce.number().positive();
const secret = z.string().min(16);
const csv = z
  .string()
  .min(1)
  .transform((value: string): string[] => value.split(",").map((part: string): string => part.trim()).filter((part: string): boolean => part.length > 0));

const envSchema = z.object({
  ENVIRONMENT: z.enum(["development", "production"]),
  SITE_ORIGIN: z.url(),
  APPLE_CLIENT_IDS: csv,
  APP_ATTEST_POLICY: z.enum(["required", "optional"]),
  APP_ATTEST_ENVIRONMENT: z.enum(["development", "production"]),
  APP_ATTEST_APP_IDS: csv,
  APP_ATTEST_ALLOWED_CATEGORIES: csv,
  TRIAL_MEETINGS: positiveInt,
  TRIAL_ACCOUNTS_PER_IP_PER_DAY: positiveInt,
  TRIAL_MAX_MEETING_MINUTES: positiveInt,
  SUBSCRIBER_MAX_MEETING_MINUTES: positiveInt,
  MONTHLY_CAP_HOURS: positiveNumber,
  MEETING_GRACE_MINUTES: positiveInt,
  PAST_DUE_GRACE_DAYS: positiveInt,
  TRIAL_MEETING_TOKEN_BUDGET: positiveInt,
  SUBSCRIBER_MEETING_TOKEN_BUDGET: positiveInt,
  LLM_MAX_TOKENS: positiveInt,
  LLM_MAX_REQUEST_BYTES: positiveInt,
  LLM_MAX_INPUT_TOKENS: positiveInt,
  TRANSCRIBE_MAX_BYTES: positiveInt.max(95_000_000),
  TRANSCRIBE_MAX_KEYTERMS: positiveInt.max(1000),
  SCRIBE_USD_PER_HOUR: positiveNumber,
  SCRIBE_KEYTERMS_USD_PER_HOUR: positiveNumber,
  DAILY_SPEND_CEILING_USD: positiveNumber,
  REFRESH_TOKEN_DAYS: positiveInt,
  EMAIL_SENDER: z.enum(["dev", "resend"]),
  EMAIL_FROM: z.string().min(3),
  EMAIL_LINK_URL: z.url(),
  STRIPE_PRICE_ID: z.string().startsWith("price_"),
  ACCESS_TOKEN_SECRET: z.string().min(32),
  ANTHROPIC_API_KEY: secret,
  ELEVENLABS_API_KEY: secret,
  STRIPE_SECRET_KEY: secret,
  STRIPE_WEBHOOK_SECRET: secret,
  TURNSTILE_SECRET_KEY: secret,
  RESEND_API_KEY: z.string().optional(),
});

/** Ortamı doğrular ve tipli yapılandırmaya çevirir; hatada yalnızca alan adlarını taşıyan `ConfigError` fırlatır. */
export function parseConfig(env: Env): Config {
  const parsed = envSchema.safeParse(env);
  if (!parsed.success) {
    throw new ConfigError(parsed.error.issues.map((issue: z.core.$ZodIssue): string => issue.path.join(".")));
  }
  const value = parsed.data;
  const categories: number[] = value.APP_ATTEST_ALLOWED_CATEGORIES.map((part: string): number => Number(part));
  if (categories.some((category: number): boolean => !Number.isInteger(category) || category <= 0)) {
    throw new ConfigError(["APP_ATTEST_ALLOWED_CATEGORIES"]);
  }
  if (value.ENVIRONMENT === "production" && value.APP_ATTEST_ENVIRONMENT !== "production") {
    throw new ConfigError(["APP_ATTEST_ENVIRONMENT"]);
  }
  return {
    environment: value.ENVIRONMENT,
    siteOrigin: new URL(value.SITE_ORIGIN).origin,
    appleClientIds: value.APPLE_CLIENT_IDS,
    attest: {
      policy: value.APP_ATTEST_POLICY,
      environment: value.APP_ATTEST_ENVIRONMENT,
      appIds: value.APP_ATTEST_APP_IDS,
      allowedCategories: categories,
    },
    trialMeetings: value.TRIAL_MEETINGS,
    trialAccountsPerIpPerDay: value.TRIAL_ACCOUNTS_PER_IP_PER_DAY,
    trialMaxMeetingMinutes: value.TRIAL_MAX_MEETING_MINUTES,
    subscriberMaxMeetingMinutes: value.SUBSCRIBER_MAX_MEETING_MINUTES,
    monthlyCapSeconds: Math.round(value.MONTHLY_CAP_HOURS * 3600),
    meetingGraceMs: value.MEETING_GRACE_MINUTES * 60_000,
    pastDueGraceMs: value.PAST_DUE_GRACE_DAYS * 86_400_000,
    trialMeetingTokenBudget: value.TRIAL_MEETING_TOKEN_BUDGET,
    subscriberMeetingTokenBudget: value.SUBSCRIBER_MEETING_TOKEN_BUDGET,
    llm: {
      maxTokens: value.LLM_MAX_TOKENS,
      maxRequestBytes: value.LLM_MAX_REQUEST_BYTES,
      maxInputTokens: value.LLM_MAX_INPUT_TOKENS,
    },
    transcribe: {
      maxBytes: value.TRANSCRIBE_MAX_BYTES,
      maxKeyterms: value.TRANSCRIBE_MAX_KEYTERMS,
      usdPerHour: value.SCRIBE_USD_PER_HOUR,
      keytermsUsdPerHour: value.SCRIBE_KEYTERMS_USD_PER_HOUR,
    },
    dailySpendCeilingMicroUsd: Math.round(value.DAILY_SPEND_CEILING_USD * 1_000_000),
    refreshTokenMs: value.REFRESH_TOKEN_DAYS * 86_400_000,
    email: emailConfig(value.EMAIL_SENDER, value.EMAIL_FROM, value.EMAIL_LINK_URL, value.RESEND_API_KEY),
    stripePriceId: value.STRIPE_PRICE_ID,
    secrets: {
      accessToken: value.ACCESS_TOKEN_SECRET,
      anthropic: value.ANTHROPIC_API_KEY,
      elevenLabs: value.ELEVENLABS_API_KEY,
      stripe: value.STRIPE_SECRET_KEY,
      stripeWebhook: value.STRIPE_WEBHOOK_SECRET,
      turnstile: value.TURNSTILE_SECRET_KEY,
    },
  };
}

/** E-posta göndericisi seçimi; Resend için anahtar zorunludur. */
function emailConfig(sender: "dev" | "resend", from: string, linkUrl: string, resendApiKey: string | undefined): EmailConfig {
  if (sender === "dev") {
    return { kind: "dev", from, linkUrl };
  }
  if (resendApiKey === undefined || resendApiKey.length < 16) {
    throw new ConfigError(["RESEND_API_KEY"]);
  }
  return { kind: "resend", from, linkUrl, apiKey: resendApiKey };
}
