import { z } from "zod";
import type { Env } from "./env";

/** App Attest zorunluluğu: `required` ise toplantı başlatmak doğrulanmış cihaz ister. */
export type AttestPolicy = "required" | "optional";

/** App Attest ortamı (`aaguid`): geliştirme ya da yayın. */
export type AttestEnvironment = "development" | "production";

/** Stripe anahtarının modu: canlı ya da test. */
export type StripeMode = "live" | "test";

/** Stripe gizli ya da kısıtlı anahtarının öneki ve modu. */
const stripeKeyPattern: RegExp = /^(?:sk|rk)_(live|test)_/;

/** Apple DeviceCheck API ortamı: geliştirme ya da yayın adresi. */
export type DeviceCheckEnvironment = "development" | "production";

/**
 * Apple DeviceCheck ile Mac başına deneme (bkz. `deviceCheck.ts`). Tek anahtar `DEVICECHECK_POLICY`'dir:
 * - `required`: hesabın denemesi henüz bir Mac'e bağlanmamışsa deneme toplantısı DeviceCheck jetonu ister;
 * - `off`: DeviceCheck hiç çağrılmaz, deneme yalnızca hesap ve IP sınırlarıyla çalışır (yerel geliştirme, testler).
 */
export type DeviceCheckConfig =
  | { readonly policy: "off" }
  | {
      readonly policy: "required";
      readonly environment: DeviceCheckEnvironment;
      /** Apple geliştirici ekip kimliği (JWT `iss`). */
      readonly teamId: string;
      /** DeviceCheck anahtarının kimliği (JWT `kid`). */
      readonly keyId: string;
      /** DeviceCheck anahtarı (.p8, PKCS#8 PEM). */
      readonly privateKeyPem: string;
    };

/** Ortamdan doğrulanmış, tipli yapılandırma. */
export interface Config {
  readonly environment: "development" | "production";
  readonly siteOrigin: string;
  readonly appleClientIds: readonly string[];
  /** Google kimlik jetonunda kabul edilen `aud` değerleri (OAuth istemci kimlikleri). */
  readonly googleClientIds: readonly string[];
  /** Yönetici API'sine erişebilen kimlikler (`<sağlayıcı>:<sub>`); boşsa kimse yönetici değildir. */
  readonly adminIdentities: readonly string[];
  /** `GET /v1/download/mac` yönlendirmesinin hedefi (DMG). */
  readonly dmgUrl: string;
  /** Aylık abonelik fiyatı (USD); yalnızca yönetici istatistiğindeki MRR tahmini için (Stripe çağrılmaz). */
  readonly priceUsdMonthly: number;
  /** Rapor türü başına (geri bildirim, çökme, iletişim) tüm kullanıcılar için günde en çok saklanan bayt. */
  readonly reportBytesPerDay: number;
  readonly attest: {
    readonly policy: AttestPolicy;
    readonly environment: AttestEnvironment;
    readonly appIds: readonly string[];
    readonly allowedCategories: readonly number[];
  };
  readonly deviceCheck: DeviceCheckConfig;
  readonly trialMeetings: number;
  /** Denemenin süresi (gün): hesabın ilk deneme toplantısından başlar; `trialMeetings` ya da bu süre, hangisi önce dolarsa. */
  readonly trialDays: number;
  /** `trialDays` milisaniye olarak. */
  readonly trialDurationMs: number;
  /** Aboneliği olmayan kullanıcının toplantıya bağlı olmayan çağrılarının günlük token sınırı. */
  readonly trialAccountDailyTokens: number;
  /** Bir IP'den bir günde denemeye başlayabilecek yeni hesap sayısı. */
  readonly trialAccountsPerIpPerDay: number;
  readonly trialMaxMeetingMinutes: number;
  readonly subscriberMaxMeetingMinutes: number;
  readonly monthlyCapSeconds: number;
  readonly meetingGraceMs: number;
  /** `past_due` aboneliğin `past_due`'ya geçişten sonra erişimi koruduğu süre. */
  readonly pastDueGraceMs: number;
  readonly trialMeetingTokenBudget: number;
  readonly subscriberMeetingTokenBudget: number;
  /** Kullanıcı başına aylık token sınırı (tüm toplantılar). */
  readonly monthlyTokenCap: number;
  /** Abonenin toplantıya bağlı olmayan (hesap) çağrılarının aylık token sınırı; `monthlyTokenCap`'in parçasıdır. */
  readonly monthlyAccountTokenCap: number;
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
  /** ElevenLabs aylık kredi planı: dönemde işlenebilen ses saati ve dönemin yenilendiği gün (1–28, UTC). */
  readonly elevenLabs: {
    readonly monthlyAudioHours: number;
    readonly billingDay: number;
  };
  readonly dailySpendCeilingMicroUsd: number;
  /** Deneme harcamasının (deneme toplantıları ve denemedeki hesap çağrıları) günlük ayrı tavanı. */
  readonly dailyTrialSpendCeilingMicroUsd: number;
  readonly refreshTokenMs: number;
  readonly stripePriceId: string;
  /** Stripe anahtarının modu (`sk_live_`/`rk_live_` → `live`, `sk_test_`/`rk_test_` → `test`). */
  readonly stripeMode: StripeMode;
  readonly secrets: {
    readonly accessToken: string;
    /** Kimlik deneme defteri (`trialIdentityHash`) ve deneme IP özetinin HMAC sırrı. */
    readonly trialHash: string;
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
  readonly GOOGLE_CLIENT_IDS: readonly string[];
  readonly DMG_URL: string;
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

/** Değer `placeholder` içeriyor mu (büyük/küçük harf fark etmez). Saf fonksiyondur. */
function containsPlaceholder(value: string): boolean {
  return value.toLowerCase().includes("placeholder");
}

/**
 * Yer tutucu değer taşıyan ayarların adları: örnek ya da yerel alan adı (`SITE_ORIGIN`, `DMG_URL`), `TEAMID` ile
 * başlayan App Attest uygulama kimliği, `placeholder` içeren Google istemci kimliği ya da Stripe fiyat kimliği. Saf
 * fonksiyondur.
 */
export function placeholderSettings(settings: PlaceholderCandidates): string[] {
  const checks: ReadonlyArray<readonly [string, boolean]> = [
    ["SITE_ORIGIN", isPlaceholderUrl(settings.SITE_ORIGIN)],
    ["APP_ATTEST_APP_IDS", settings.APP_ATTEST_APP_IDS.some((appId: string): boolean => appId.startsWith("TEAMID"))],
    ["GOOGLE_CLIENT_IDS", settings.GOOGLE_CLIENT_IDS.some(containsPlaceholder)],
    ["DMG_URL", isPlaceholderUrl(settings.DMG_URL)],
    ["STRIPE_PRICE_ID", containsPlaceholder(settings.STRIPE_PRICE_ID)],
  ];
  return checks.filter(([, placeholder]: readonly [string, boolean]): boolean => placeholder).map(([name]: readonly [string, boolean]): string => name);
}

/** Virgülle ayrılmış listeyi parçalara böler (boşluklar kırpılır, boş parçalar atılır). Saf fonksiyondur. */
function splitCsv(value: string): string[] {
  return value.split(",").map((part: string): string => part.trim()).filter((part: string): boolean => part.length > 0);
}

const positiveInt = z.coerce.number().int().positive();
const positiveNumber = z.coerce.number().positive();
const secret = z.string().min(16);
const csv = z.string().min(1).transform(splitCsv);
/** Yönetici kimlikleri: boş olabilir (kimse yönetici değil); her öğe `apple:<sub>` ya da `google:<sub>`. */
const adminIdentityList = z
  .string()
  .transform(splitCsv)
  .refine((identities: string[]): boolean => identities.every((identity: string): boolean => /^(apple|google):\S+$/.test(identity)));

const envSchema = z.object({
  ENVIRONMENT: z.enum(["development", "production"]),
  SITE_ORIGIN: z.url(),
  APPLE_CLIENT_IDS: csv,
  GOOGLE_CLIENT_IDS: csv,
  ADMIN_IDENTITIES: adminIdentityList,
  DMG_URL: z.url({ protocol: /^https$/ }),
  PRICE_USD_MONTHLY: positiveNumber,
  REPORT_BYTES_PER_DAY: positiveInt,
  APP_ATTEST_POLICY: z.enum(["required", "optional"]),
  APP_ATTEST_ENVIRONMENT: z.enum(["development", "production"]),
  APP_ATTEST_APP_IDS: csv,
  APP_ATTEST_ALLOWED_CATEGORIES: csv,
  DEVICECHECK_POLICY: z.enum(["required", "off"]),
  DEVICECHECK_ENVIRONMENT: z.enum(["development", "production"]),
  DEVICECHECK_TEAM_ID: z.string(),
  DEVICECHECK_KEY_ID: z.string(),
  DEVICECHECK_PRIVATE_KEY: z.string().optional(),
  TRIAL_MEETINGS: positiveInt,
  TRIAL_DAYS: positiveInt,
  TRIAL_ACCOUNT_DAILY_TOKENS: positiveInt,
  TRIAL_ACCOUNTS_PER_IP_PER_DAY: positiveInt,
  TRIAL_MAX_MEETING_MINUTES: positiveInt,
  SUBSCRIBER_MAX_MEETING_MINUTES: positiveInt,
  MONTHLY_CAP_HOURS: positiveNumber,
  MEETING_GRACE_MINUTES: positiveInt,
  PAST_DUE_GRACE_DAYS: positiveInt,
  TRIAL_MEETING_TOKEN_BUDGET: positiveInt,
  SUBSCRIBER_MEETING_TOKEN_BUDGET: positiveInt,
  MONTHLY_TOKEN_CAP: positiveInt,
  MONTHLY_ACCOUNT_TOKEN_CAP: positiveInt,
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
  ELEVENLABS_MONTHLY_AUDIO_HOURS: positiveNumber,
  ELEVENLABS_BILLING_DAY: positiveInt.max(28),
  DAILY_SPEND_CEILING_USD: positiveNumber,
  DAILY_TRIAL_SPEND_CEILING_USD: positiveNumber,
  REFRESH_TOKEN_DAYS: positiveInt,
  STRIPE_PRICE_ID: z.string().startsWith("price_"),
  ACCESS_TOKEN_SECRET: z.string().min(32),
  TRIAL_HASH_SECRET: z.string().min(32),
  ANTHROPIC_API_KEY: secret,
  ELEVENLABS_API_KEY: secret,
  STRIPE_SECRET_KEY: secret.regex(stripeKeyPattern),
  STRIPE_WEBHOOK_SECRET: secret,
  TURNSTILE_SECRET_KEY: secret,
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
  if (value.MONTHLY_ACCOUNT_TOKEN_CAP > value.MONTHLY_TOKEN_CAP) {
    throw new ConfigError(["MONTHLY_ACCOUNT_TOKEN_CAP"]);
  }
  if (value.ENVIRONMENT === "production" && value.APP_ATTEST_ENVIRONMENT !== "production") {
    throw new ConfigError(["APP_ATTEST_ENVIRONMENT"]);
  }
  const deviceCheck: DeviceCheckConfig = deviceCheckConfig(value);
  if (value.ENVIRONMENT === "production" && deviceCheck.policy === "required" && deviceCheck.environment !== "production") {
    throw new ConfigError(["DEVICECHECK_ENVIRONMENT"]);
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
    googleClientIds: value.GOOGLE_CLIENT_IDS,
    adminIdentities: value.ADMIN_IDENTITIES,
    dmgUrl: value.DMG_URL,
    priceUsdMonthly: value.PRICE_USD_MONTHLY,
    reportBytesPerDay: value.REPORT_BYTES_PER_DAY,
    attest: {
      policy: value.APP_ATTEST_POLICY,
      environment: value.APP_ATTEST_ENVIRONMENT,
      appIds: value.APP_ATTEST_APP_IDS,
      allowedCategories: categories,
    },
    deviceCheck,
    trialMeetings: value.TRIAL_MEETINGS,
    trialDays: value.TRIAL_DAYS,
    trialDurationMs: value.TRIAL_DAYS * 86_400_000,
    trialAccountDailyTokens: value.TRIAL_ACCOUNT_DAILY_TOKENS,
    trialAccountsPerIpPerDay: value.TRIAL_ACCOUNTS_PER_IP_PER_DAY,
    trialMaxMeetingMinutes: value.TRIAL_MAX_MEETING_MINUTES,
    subscriberMaxMeetingMinutes: value.SUBSCRIBER_MAX_MEETING_MINUTES,
    monthlyCapSeconds: Math.round(value.MONTHLY_CAP_HOURS * 3600),
    meetingGraceMs: value.MEETING_GRACE_MINUTES * 60_000,
    pastDueGraceMs: value.PAST_DUE_GRACE_DAYS * 86_400_000,
    trialMeetingTokenBudget: value.TRIAL_MEETING_TOKEN_BUDGET,
    subscriberMeetingTokenBudget: value.SUBSCRIBER_MEETING_TOKEN_BUDGET,
    monthlyTokenCap: value.MONTHLY_TOKEN_CAP,
    monthlyAccountTokenCap: value.MONTHLY_ACCOUNT_TOKEN_CAP,
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
    elevenLabs: { monthlyAudioHours: value.ELEVENLABS_MONTHLY_AUDIO_HOURS, billingDay: value.ELEVENLABS_BILLING_DAY },
    dailySpendCeilingMicroUsd: Math.round(value.DAILY_SPEND_CEILING_USD * 1_000_000),
    dailyTrialSpendCeilingMicroUsd: Math.round(value.DAILY_TRIAL_SPEND_CEILING_USD * 1_000_000),
    refreshTokenMs: value.REFRESH_TOKEN_DAYS * 86_400_000,
    stripePriceId: value.STRIPE_PRICE_ID,
    stripeMode: stripeKeyPattern.exec(value.STRIPE_SECRET_KEY)?.[1] === "live" ? "live" : "test",
    secrets: {
      accessToken: value.ACCESS_TOKEN_SECRET,
      trialHash: value.TRIAL_HASH_SECRET,
      anthropic: value.ANTHROPIC_API_KEY,
      elevenLabs: value.ELEVENLABS_API_KEY,
      stripe: value.STRIPE_SECRET_KEY,
      stripeWebhook: value.STRIPE_WEBHOOK_SECRET,
      turnstile: value.TURNSTILE_SECRET_KEY,
    },
  };
}

/** Apple ekip ve anahtar kimlikleri 10 karakterlik büyük harf ve rakamdır. */
const appleIdentifierPattern: RegExp = /^[A-Z0-9]{10}$/;

/** DeviceCheck ayarları. */
interface DeviceCheckSettings {
  readonly DEVICECHECK_POLICY: "required" | "off";
  readonly DEVICECHECK_ENVIRONMENT: DeviceCheckEnvironment;
  readonly DEVICECHECK_TEAM_ID: string;
  readonly DEVICECHECK_KEY_ID: string;
  readonly DEVICECHECK_PRIVATE_KEY?: string | undefined;
}

/**
 * DeviceCheck yapılandırması. `off` ise diğer ayarlara bakılmaz. `required` ise ekip ve anahtar kimliği Apple
 * biçiminde (yer tutucu `DEVICECHECK_KEY_ID_PENDING` geçmez) ve gizli `DEVICECHECK_PRIVATE_KEY` PKCS#8 PEM olmalı;
 * değilse geçersiz alanların adlarıyla `ConfigError`. Saf fonksiyondur.
 */
function deviceCheckConfig(settings: DeviceCheckSettings): DeviceCheckConfig {
  if (settings.DEVICECHECK_POLICY === "off") {
    return { policy: "off" };
  }
  const privateKeyPem: string = settings.DEVICECHECK_PRIVATE_KEY ?? "";
  const checks: ReadonlyArray<readonly [string, boolean]> = [
    ["DEVICECHECK_TEAM_ID", appleIdentifierPattern.test(settings.DEVICECHECK_TEAM_ID)],
    ["DEVICECHECK_KEY_ID", appleIdentifierPattern.test(settings.DEVICECHECK_KEY_ID)],
    ["DEVICECHECK_PRIVATE_KEY", privateKeyPem.includes("-----BEGIN PRIVATE KEY-----")],
  ];
  const invalid: string[] = checks.filter(([, valid]: readonly [string, boolean]): boolean => !valid).map(([name]: readonly [string, boolean]): string => name);
  if (invalid.length > 0) {
    throw new ConfigError(invalid);
  }
  return {
    policy: "required",
    environment: settings.DEVICECHECK_ENVIRONMENT,
    teamId: settings.DEVICECHECK_TEAM_ID,
    keyId: settings.DEVICECHECK_KEY_ID,
    privateKeyPem,
  };
}
