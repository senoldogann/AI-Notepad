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
  /** Kullanıcı başına aylık token sınırı (tüm toplantılar). */
  readonly monthlyTokenCap: number;
  /** Kullanıcı başına günlük token sınırı. */
  readonly dailyTokenCap: number;
  /** Kullanıcı başına günde en çok toplantı başlatma. */
  readonly maxMeetingStartsPerDay: number;
  readonly llm: {
    readonly maxTokens: number;
    /** Toplantıya bağlı olmayan (hesap) çağrının en çok `max_tokens`'ı. */
    readonly accountMaxTokens: number;
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

/**
 * Üretim yapılandırmasında yer tutucu (örnek ya da yerel) değer var: dağıtım tamamlanmamıştır. Yalnızca ayar adlarını
 * taşır, değerleri değil.
 */
export class ConfigPlaceholderError extends ConfigError {
  override readonly name: string = "ConfigPlaceholderError";
}

/** Yer tutucu denetiminin baktığı gizli olmayan ayarlar. */
export interface PlaceholderCandidates {
  readonly SITE_ORIGIN: string;
  readonly APP_ATTEST_APP_IDS: readonly string[];
  readonly EMAIL_FROM: string;
  readonly EMAIL_LINK_URL: string;
  readonly STRIPE_PRICE_ID: string;
}

/** Örnek (RFC 2606) ya da yerel alan adı mı. Saf fonksiyondur. */
function isPlaceholderHost(host: string): boolean {
  return host === "localhost" || /(^|\.)example\.(com|org|net)$/i.test(host);
}

/** URL'nin alan adı yer tutucu mu. Saf fonksiyondur. */
function isPlaceholderUrl(url: string): boolean {
  return isPlaceholderHost(new URL(url).hostname);
}

/** `Ad <adres@alan>` ya da `adres@alan` biçimindeki göndericinin alan adı yer tutucu mu. Saf fonksiyondur. */
function isPlaceholderSender(from: string): boolean {
  const domain: string | undefined = /@([^\s>]+)/.exec(from)?.[1];
  return domain === undefined || isPlaceholderHost(domain.toLowerCase());
}

/**
 * Yer tutucu değer taşıyan ayarların adları: örnek ya da yerel alan adı (`SITE_ORIGIN`, `EMAIL_LINK_URL`,
 * `EMAIL_FROM`), `TEAMID` ile başlayan App Attest uygulama kimliği, `placeholder` içeren Stripe fiyat kimliği. Saf
 * fonksiyondur.
 */
export function placeholderSettings(settings: PlaceholderCandidates): string[] {
  const checks: ReadonlyArray<readonly [string, boolean]> = [
    ["SITE_ORIGIN", isPlaceholderUrl(settings.SITE_ORIGIN)],
    ["APP_ATTEST_APP_IDS", settings.APP_ATTEST_APP_IDS.some((appId: string): boolean => appId.startsWith("TEAMID"))],
    ["EMAIL_FROM", isPlaceholderSender(settings.EMAIL_FROM)],
    ["EMAIL_LINK_URL", isPlaceholderUrl(settings.EMAIL_LINK_URL)],
    ["STRIPE_PRICE_ID", settings.STRIPE_PRICE_ID.toLowerCase().includes("placeholder")],
  ];
  return checks.filter(([, placeholder]: readonly [string, boolean]): boolean => placeholder).map(([name]: readonly [string, boolean]): string => name);
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
  MONTHLY_TOKEN_CAP: positiveInt,
  DAILY_TOKEN_CAP: positiveInt,
  MAX_MEETING_STARTS_PER_DAY: positiveInt,
  LLM_MAX_TOKENS: positiveInt,
  LLM_ACCOUNT_MAX_TOKENS: positiveInt,
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

/**
 * Ortamı doğrular ve tipli yapılandırmaya çevirir; hatada yalnızca alan adlarını taşıyan `ConfigError` fırlatır.
 * Üretimde yer tutucu değer kalmışsa (`placeholderSettings`) `ConfigPlaceholderError`: sunucu ödeme anında değil, ilk
 * istekte (`/v1/health` dahil) durur. Geliştirme ve testlerde yer tutucular geçerlidir.
 */
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
  if (value.LLM_ACCOUNT_MAX_TOKENS > value.LLM_MAX_TOKENS) {
    throw new ConfigError(["LLM_ACCOUNT_MAX_TOKENS"]);
  }
  if (value.ENVIRONMENT === "production" && value.APP_ATTEST_ENVIRONMENT !== "production") {
    throw new ConfigError(["APP_ATTEST_ENVIRONMENT"]);
  }
  if (value.ENVIRONMENT === "production") {
    const placeholders: string[] = placeholderSettings(value);
    if (placeholders.length > 0) {
      throw new ConfigPlaceholderError(placeholders);
    }
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
    monthlyTokenCap: value.MONTHLY_TOKEN_CAP,
    dailyTokenCap: value.DAILY_TOKEN_CAP,
    maxMeetingStartsPerDay: value.MAX_MEETING_STARTS_PER_DAY,
    llm: {
      maxTokens: value.LLM_MAX_TOKENS,
      accountMaxTokens: value.LLM_ACCOUNT_MAX_TOKENS,
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
