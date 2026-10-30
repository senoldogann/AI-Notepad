import { z } from "zod";
import type { Env } from "./env";

/** App Attest zorunluluğu: `required` ise toplantı başlatmak doğrulanmış cihaz ister. */
export type AttestPolicy = "required" | "optional";

/** App Attest ortamı (`aaguid`): geliştirme ya da yayın. */
export type AttestEnvironment = "development" | "production";

/** Stripe anahtarının modu: canlı ya da test. */
export type StripeMode = "live" | "test";

/** Abonelik planı: aylık ya da yıllık (aynı ürünün iki fiyatı; haklar plana bakmaz). */
export type SubscriptionPlan = "monthly" | "yearly";

/** Davet programı anahtarı (`REFERRAL_POLICY`): `off` ise yeni kod verilmez ve kod kabul edilmez. */
export type ReferralPolicy = "on" | "off";

/** Bizim abonelik fiyatlarımız (Stripe fiyat kimlikleri). */
export interface StripePrices {
  readonly monthly: string;
  readonly yearly: string;
}

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

/**
 * Deepgram canlı metninin anahtarı (bkz. `deepgram.ts`). Tek anahtar `DEEPGRAM_POLICY`'dir:
 * - `on`: açık toplantısı olan kullanıcıya kısa ömürlü Deepgram jetonu verilir; tahmini harcama bütçeye ulaşınca durur;
 * - `off`: jeton verilmez, `/v1/me` canlı motoru `whisperkit` der (yerel geliştirme, testler, acil kapatma).
 */
export type DeepgramAccess = { readonly policy: "off" } | { readonly policy: "on"; readonly apiKey: string };

/** Deepgram canlı metni: anahtar ve ücretsiz kredi bütçesi (politika kapalıyken de yönetici istatistiği için okunur). */
export interface DeepgramConfig {
  readonly access: DeepgramAccess;
  /** Ücretsiz kredinin canlı metne ayrılan kısmı (mikro USD; ömür boyu, aylık değil). */
  readonly budgetMicroUsd: number;
  /** Akış dakikası başına fiyat (mikro USD). */
  readonly microUsdPerMinute: number;
}

/**
 * Yönetim panelinden blog yayını (bkz. `blog.ts`): yazılar `owner/repo` deposunun `branch` dalındaki
 * `web/src/content/blog/*.md` dosyalarıdır. `token` gizli `GITHUB_BLOG_TOKEN`'dır; girilmemişse null ve blog uçları
 * `503 blog_unavailable` döner.
 */
export interface BlogConfig {
  readonly owner: string;
  readonly repo: string;
  readonly branch: string;
  readonly token: string | null;
}

/**
 * Yönetim panelindeki site istatistikleri (bkz. `siteAnalytics.ts`): Cloudflare hesabı (`CF_ANALYTICS_ACCOUNT_ID`),
 * Web Analytics site etiketi (`CF_ANALYTICS_SITE_TAG`) ve gizli `CF_ANALYTICS_TOKEN`. Biri eksikse null'dır ve uç
 * `503 analytics_unavailable` döner.
 */
export interface SiteAnalyticsConfig {
  readonly accountId: string | null;
  readonly siteTag: string | null;
  readonly token: string | null;
}

/** Ortamdan doğrulanmış, tipli yapılandırma. */
export interface Config {
  readonly environment: "development" | "production";
  readonly siteOrigin: string;
  readonly appleClientIds: readonly string[];
  /** Google kimlik jetonunda kabul edilen `aud` değerleri (OAuth istemci kimlikleri). */
  readonly googleClientIds: readonly string[];
  /** Yönetici API'sine erişebilen kimlikler (`<sağlayıcı>:<sub>`); boşsa kimse yönetici değildir. */
  readonly adminIdentities: readonly string[];
  /** Yönetici uçlarının Cloudflare Access denetimi (bkz. `requireCloudflareAccess`). */
  readonly access: CloudflareAccessConfig;
  /** `GET /v1/download/mac` yönlendirmesinin hedefi (DMG). */
  readonly dmgUrl: string;
  /** DMG ile aynı GitHub sürümündeki Sparkle appcast'i; `GET /v1/download/mac/version` sürümü buradan okur. */
  readonly appcastUrl: string;
  /**
   * Aylık abonelik fiyatı (USD; Stripe fiyatıyla elle aynı tutulur): yönetici MRR tahmini, davet indirimi (yıllıkta tek
   * seferlik indirim tutarı) ve davet ödülü (davet edenin müşteri bakiyesi alacağı) bundan hesaplanır.
   */
  readonly priceUsdMonthly: number;
  /** Yıllık abonelik fiyatı (USD); yalnızca yönetici MRR tahmini için (ayda 1/12'si sayılır). */
  readonly priceUsdYearly: number;
  /** Davet programı açık mı (`REFERRAL_POLICY`). */
  readonly referralPolicy: ReferralPolicy;
  /**
   * Davet edenin aynı anda açık tutabileceği en çok davet (`REFERRAL_MAX_PENDING`; bkz. `referrals.openReferralCount`):
   * dolunca kodu yeni arkadaş kabul etmez (`409 referral_limit_reached`).
   */
  readonly referralMaxPending: number;
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
  readonly deepgram: DeepgramConfig;
  readonly blog: BlogConfig;
  readonly siteAnalytics: SiteAnalyticsConfig;
  readonly dailySpendCeilingMicroUsd: number;
  /** Deneme harcamasının (deneme toplantıları ve denemedeki hesap çağrıları) günlük ayrı tavanı. */
  readonly dailyTrialSpendCeilingMicroUsd: number;
  readonly refreshTokenMs: number;
  /** Aylık (`STRIPE_PRICE_ID`) ve yıllık (`STRIPE_YEARLY_PRICE_ID`) fiyat. */
  readonly stripePrices: StripePrices;
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

/**
 * Stripe webhook'unun yapılandırması: yalnızca ortam, Stripe sırları ve davet kartı özetinin sırrı. Webhook bununla çalışır; ilgisiz bir ayarın
 * (ör. `DEVICECHECK_PRIVATE_KEY`, `DEEPGRAM_API_KEY`) hatası ödeme olaylarını durdurmaz. `Config` bunu kapsar.
 */
export interface StripeWebhookConfig {
  readonly environment: "development" | "production";
  /** Stripe anahtarının modu (`sk_live_`/`rk_live_` → `live`, `sk_test_`/`rk_test_` → `test`). */
  readonly stripeMode: StripeMode;
  /** Abonelik fiyatları: webhook yalnızca bu fiyatlı (ya da `metadata.user_id` taşıyan) aboneliklere dokunur. */
  readonly stripePrices: StripePrices;
  readonly secrets: {
    readonly stripe: string;
    readonly stripeWebhook: string;
    /** Davet edilenin kart parmak izi özetinin (`referrals.referralCardHash`) HMAC sırrı. */
    readonly trialHash: string;
  };
}

/** Cloudflare Access: ekip alan adı ve uygulamanın AUD etiketi (boşsa denetim kapalı: null). */
export interface CloudflareAccessConfig {
  readonly teamDomain: string;
  readonly audience: string | null;
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
  readonly APPCAST_URL: string;
  readonly STRIPE_PRICE_ID: string;
  readonly STRIPE_YEARLY_PRICE_ID: string;
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
    ["APPCAST_URL", isPlaceholderUrl(settings.APPCAST_URL)],
    ["STRIPE_PRICE_ID", containsPlaceholder(settings.STRIPE_PRICE_ID)],
    ["STRIPE_YEARLY_PRICE_ID", containsPlaceholder(settings.STRIPE_YEARLY_PRICE_ID)],
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
  CF_ACCESS_TEAM_DOMAIN: z.string().regex(/^[a-z0-9-]+\.cloudflareaccess\.com$/),
  /** Access uygulamasının AUD etiketi; boşsa yönetici uçlarında Access denetimi kapalıdır. */
  CF_ACCESS_AUD: z.string().regex(/^([0-9a-f]{64})?$/),
  DMG_URL: z.url({ protocol: /^https$/ }),
  APPCAST_URL: z.url({ protocol: /^https$/ }),
  PRICE_USD_MONTHLY: positiveNumber,
  PRICE_USD_YEARLY: positiveNumber,
  REFERRAL_POLICY: z.enum(["on", "off"]),
  REFERRAL_MAX_PENDING: positiveInt,
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
  DEEPGRAM_POLICY: z.enum(["on", "off"]),
  DEEPGRAM_BUDGET_USD: positiveNumber,
  DEEPGRAM_USD_PER_MINUTE: positiveNumber,
  DEEPGRAM_API_KEY: z.string().optional(),
  DAILY_SPEND_CEILING_USD: positiveNumber,
  DAILY_TRIAL_SPEND_CEILING_USD: positiveNumber,
  REFRESH_TOKEN_DAYS: positiveInt,
  STRIPE_PRICE_ID: z.string().startsWith("price_"),
  STRIPE_YEARLY_PRICE_ID: z.string().startsWith("price_"),
  /** `sahip/ad`: GitHub kullanıcı ya da kuruluş adı ve depo adı. */
  GITHUB_BLOG_REPO: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/),
  /** Dal adı: boşluk, `..` ve git'in yasakladığı işaretler yok. */
  GITHUB_BLOG_BRANCH: z
    .string()
    .regex(/^[A-Za-z0-9._/-]{1,100}$/)
    .refine((name: string): boolean => !name.includes("..") && !name.startsWith("/") && !name.endsWith("/") && !name.endsWith(".lock")),
  /** Girilmişse boşluksuz ve en az 20 karakter; girilmemişse blog yayını kapalıdır (`503 blog_unavailable`). */
  GITHUB_BLOG_TOKEN: z.string().regex(/^\S{20,}$/).optional(),
  /** Cloudflare hesap kimliği ve Web Analytics site etiketi: 32 onaltılık karakter ya da boş (site istatistikleri kapalı). */
  CF_ANALYTICS_ACCOUNT_ID: z.string().regex(/^(?:[0-9a-f]{32})?$/),
  CF_ANALYTICS_SITE_TAG: z.string().regex(/^(?:[0-9a-f]{32})?$/),
  /** Girilmişse boşluksuz ve en az 20 karakter; girilmemişse site istatistikleri kapalıdır (`503 analytics_unavailable`). */
  CF_ANALYTICS_TOKEN: z.string().regex(/^\S{20,}$/).optional(),
  ACCESS_TOKEN_SECRET: z.string().min(32),
  TRIAL_HASH_SECRET: z.string().min(32),
  ANTHROPIC_API_KEY: secret,
  ELEVENLABS_API_KEY: secret,
  STRIPE_SECRET_KEY: secret.regex(stripeKeyPattern),
  STRIPE_WEBHOOK_SECRET: secret,
  TURNSTILE_SECRET_KEY: secret,
});

/** Webhook'un okuduğu ayarlar (`envSchema`'nın parçası; deneme sırrı davetteki kart özeti içindir). */
const stripeWebhookSchema = envSchema.pick({
  ENVIRONMENT: true,
  STRIPE_SECRET_KEY: true,
  STRIPE_WEBHOOK_SECRET: true,
  STRIPE_PRICE_ID: true,
  STRIPE_YEARLY_PRICE_ID: true,
  TRIAL_HASH_SECRET: true,
});

/** İki fiyat kimliği; aynıysa `ConfigError` (aylık ve yıllık ayırt edilemez, plan ve MRR yanlış olur). Saf fonksiyondur. */
function stripePricesOf(monthly: string, yearly: string): StripePrices {
  if (monthly === yearly) {
    throw new ConfigError(["STRIPE_YEARLY_PRICE_ID"]);
  }
  return { monthly, yearly };
}

/** Anahtarın modu. Saf fonksiyondur. */
function stripeModeOf(key: string): StripeMode {
  return stripeKeyPattern.exec(key)?.[1] === "live" ? "live" : "test";
}

/** Yalnızca webhook'un ayarlarını doğrular; hatada alan adlarını taşıyan `ConfigError`. */
export function parseStripeWebhookConfig(env: Env): StripeWebhookConfig {
  const parsed = stripeWebhookSchema.safeParse(env);
  if (!parsed.success) {
    throw new ConfigError(parsed.error.issues.map((issue: z.core.$ZodIssue): string => issue.path.join(".")));
  }
  return {
    environment: parsed.data.ENVIRONMENT,
    stripeMode: stripeModeOf(parsed.data.STRIPE_SECRET_KEY),
    stripePrices: stripePricesOf(parsed.data.STRIPE_PRICE_ID, parsed.data.STRIPE_YEARLY_PRICE_ID),
    secrets: { stripe: parsed.data.STRIPE_SECRET_KEY, stripeWebhook: parsed.data.STRIPE_WEBHOOK_SECRET, trialHash: parsed.data.TRIAL_HASH_SECRET },
  };
}

/** Üretimde test modu Stripe anahtarı mı (gerçek ödemeler alınmaz; uyarı yazılır). Saf fonksiyondur. */
export function isStripeTestModeInProduction(config: StripeWebhookConfig): boolean {
  return config.environment === "production" && config.stripeMode === "test";
}

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
  const deepgram: DeepgramConfig = deepgramConfig(value);
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
    access: { teamDomain: value.CF_ACCESS_TEAM_DOMAIN, audience: value.CF_ACCESS_AUD === "" ? null : value.CF_ACCESS_AUD },
    dmgUrl: value.DMG_URL,
    appcastUrl: value.APPCAST_URL,
    priceUsdMonthly: value.PRICE_USD_MONTHLY,
    priceUsdYearly: value.PRICE_USD_YEARLY,
    referralPolicy: value.REFERRAL_POLICY,
    referralMaxPending: value.REFERRAL_MAX_PENDING,
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
    deepgram,
    blog: blogConfig(value.GITHUB_BLOG_REPO, value.GITHUB_BLOG_BRANCH, value.GITHUB_BLOG_TOKEN),
    siteAnalytics: {
      accountId: value.CF_ANALYTICS_ACCOUNT_ID === "" ? null : value.CF_ANALYTICS_ACCOUNT_ID,
      siteTag: value.CF_ANALYTICS_SITE_TAG === "" ? null : value.CF_ANALYTICS_SITE_TAG,
      token: value.CF_ANALYTICS_TOKEN ?? null,
    },
    dailySpendCeilingMicroUsd: Math.round(value.DAILY_SPEND_CEILING_USD * 1_000_000),
    dailyTrialSpendCeilingMicroUsd: Math.round(value.DAILY_TRIAL_SPEND_CEILING_USD * 1_000_000),
    refreshTokenMs: value.REFRESH_TOKEN_DAYS * 86_400_000,
    stripePrices: stripePricesOf(value.STRIPE_PRICE_ID, value.STRIPE_YEARLY_PRICE_ID),
    stripeMode: stripeModeOf(value.STRIPE_SECRET_KEY),
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

/** Deepgram ayarları. */
interface DeepgramSettings {
  readonly DEEPGRAM_POLICY: "on" | "off";
  readonly DEEPGRAM_BUDGET_USD: number;
  readonly DEEPGRAM_USD_PER_MINUTE: number;
  readonly DEEPGRAM_API_KEY?: string | undefined;
}

/**
 * Deepgram yapılandırması. `off` ise anahtara bakılmaz. `on` ise gizli `DEEPGRAM_API_KEY` en az 16 karakter olmalı;
 * değilse `ConfigError`. Saf fonksiyondur.
 */
function deepgramConfig(settings: DeepgramSettings): DeepgramConfig {
  const budgetMicroUsd: number = Math.round(settings.DEEPGRAM_BUDGET_USD * 1_000_000);
  const microUsdPerMinute: number = Math.round(settings.DEEPGRAM_USD_PER_MINUTE * 1_000_000);
  if (settings.DEEPGRAM_POLICY === "off") {
    return { access: { policy: "off" }, budgetMicroUsd, microUsdPerMinute };
  }
  const apiKey: string = settings.DEEPGRAM_API_KEY ?? "";
  if (apiKey.length < 16) {
    throw new ConfigError(["DEEPGRAM_API_KEY"]);
  }
  return { access: { policy: "on", apiKey }, budgetMicroUsd, microUsdPerMinute };
}

/**
 * Blog yayınının deposu, dalı ve jetonu. `GITHUB_BLOG_REPO` şemada `sahip/ad` biçiminde doğrulanmıştır; jeton
 * girilmemişse null. Saf fonksiyondur.
 */
function blogConfig(repository: string, branch: string, token: string | undefined): BlogConfig {
  const [owner, repo]: string[] = repository.split("/");
  if (owner === undefined || repo === undefined) {
    throw new ConfigError(["GITHUB_BLOG_REPO"]);
  }
  return { owner, repo, branch, token: token ?? null };
}
