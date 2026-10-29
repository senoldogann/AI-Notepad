// Yönetim panelinin sunucu uçları (`/v1/admin/*`, Bearer oturum): özet istatistikler, içgörüler, kullanıcı listesi ve ayrıntısı,
// işletim görünümü, bildirim kutusu listesi, tek bildirim ve durum değişikliği. Yanıtlar api.ts'teki okuyucularla katı biçimde doğrulanır.
// Zaman alanları (`generatedAt`, `createdAt`) Unix ms sayısı ya da ISO 8601 metni olabilir; ikisi de ms'ye çevrilir.
// Bildirim kimliği metin ya da tamsayı olabilir; metne çevrilir.
import {
  ApiResponseError,
  type JsonObject,
  type JsonValue,
  type RawResponse,
  nullableStringField,
  numberField,
  objectArrayField,
  objectField,
  parseObject,
  stringField,
} from "./api";
import { authorizedSend } from "./session";

/** Bir günün değeri (`YYYY-MM-DD`, UTC). */
export interface DayCount {
  readonly day: string;
  readonly count: number;
}

/** Bir günün toplantıları (deneme ve abonelik ayrı). */
export interface DayMeetings {
  readonly day: string;
  readonly trial: number;
  readonly subscription: number;
}

/** Bir günün yapay zekâ harcaması (USD). */
export interface DaySpend {
  readonly day: string;
  readonly usd: number;
}

/** `GET /v1/admin/stats` yanıtı. */
export interface AdminStats {
  /** Unix ms. */
  readonly generatedAt: number;
  readonly downloads: { readonly total: number; readonly last30Days: readonly DayCount[] };
  readonly users: {
    readonly total: number;
    readonly newLast30Days: readonly DayCount[];
    readonly byProvider: { readonly apple: number; readonly google: number };
  };
  readonly trials: { readonly activeTrialUsers: number; readonly exhaustedTrialUsers: number };
  readonly subscriptions: { readonly active: number; readonly grace: number; readonly ending: number; readonly canceledTotal: number; readonly mrrUsd: number };
  readonly meetings: { readonly last30Days: readonly DayMeetings[]; readonly hoursThisMonth: number };
  readonly spend: { readonly todayUsd: number; readonly ceilingUsd: number; readonly last30Days: readonly DaySpend[] };
  readonly tokens: { readonly thisMonth: number };
  readonly reports: { readonly openFeedback: number; readonly openCrash: number; readonly openContact: number };
  /** Stripe anahtarının modu (canlı ya da test). */
  readonly stripe: { readonly mode: StripeMode };
  /** ElevenLabs plan döngüsündeki yazıya çevirme saatleri ve planın sınırı. */
  readonly elevenLabs: { readonly usedHours: number; readonly capHours: number; readonly percent: number };
  /** Deepgram canlı metin bütçesi (ömür boyu, tahmini): harcanan, tavan, yüzde ve bütçeye sayılan akış dakikası. */
  readonly deepgram: { readonly estimatedUsd: number; readonly budgetUsd: number; readonly percent: number; readonly streamMinutes: number };
  /** Denemeden aboneliğe dönüşüm (tüm zamanlar ve son 30 günde denemeye başlayanlar). */
  readonly conversion: {
    readonly trialStarted: number;
    readonly converted: number;
    readonly startedLast30Days: number;
    readonly convertedLast30Days: number;
    readonly subscribedWithoutTrial: number;
  };
  readonly churn: { readonly canceledLast30Days: number; readonly pastDue: number; readonly unpaid: number; readonly duplicateSubscriptions: number };
  readonly billing: { readonly refundsLast30Days: number; readonly disputesLast30Days: number; readonly paymentFailuresLast30Days: number };
  readonly usage: {
    readonly meetingsThisMonth: number;
    readonly deferredThisMonth: number;
    readonly reprocessedThisMonth: number;
    readonly openMeetings: number;
    readonly audioHoursThisMonth: number;
    readonly accountTokensThisMonth: number;
    readonly monthlyTokenCapPerUser: number;
    readonly monthlyAccountTokenCapPerUser: number;
    readonly usersNearTokenCap: number;
  };
  readonly trialRefusals: { readonly last30Days: TrialRefusalCounts; readonly today: TrialRefusalCounts };
}

/** Neden başına reddedilen deneme başlatma. */
export interface TrialRefusalCounts {
  readonly deviceUsed: number;
  readonly exhausted: number;
  readonly expired: number;
  readonly ipDailyLimit: number;
}

/** Kullanıcı listesi kesimi. */
export type UserSegment = "subscribed" | "past_due" | "canceled" | "trial" | "free" | "no_meeting" | "trial_ended" | "inactive" | "failed";

/** Giriş sağlayıcısı süzgeci. */
export type UserProvider = "apple" | "google";

/** Hesabın planı. */
export type UserPlan = "subscription" | "trial" | "free";

/** Aboneliğin erişim durumu. */
export type UserAccess = "active" | "grace" | "none";

/** Kullanıcının aboneliği. Zamanlar Unix ms. */
export interface UserSubscription {
  readonly status: string;
  readonly access: UserAccess;
  readonly currentPeriodEnd: number;
  readonly cancelAt: number | null;
  readonly pastDueSince: number | null;
  readonly graceEndsAt: number | null;
  readonly updatedAt: number;
}

/** Listedeki kullanıcı. Zamanlar Unix ms. */
export interface UserSummary {
  readonly id: string;
  readonly provider: UserProvider | null;
  readonly createdAt: number;
  readonly plan: UserPlan;
  readonly subscription: UserSubscription | null;
  readonly trial: { readonly used: number; readonly left: number; readonly startedAt: number | null; readonly endsAt: number | null };
  readonly meetingsTotal: number;
  readonly hoursThisMonth: number;
  readonly lastActiveAt: number | null;
  /** İsteği başarısız olmuş toplantı sayısı ve en son hatanın kodu. */
  readonly failedMeetings: number;
  readonly lastFailureCode: string | null;
}

/** Kullanıcı listesinin bir sayfası; `nextCursor` sonraki sayfanın imleci (yoksa null). */
export interface UserPage {
  readonly items: readonly UserSummary[];
  readonly nextCursor: string | null;
}

/** Toplantının durumu. */
export type MeetingState = "open" | "ended" | "superseded" | "expired";

/** Kullanıcı ayrıntısındaki toplantı. */
export interface UserMeeting {
  readonly id: string;
  readonly kind: "trial" | "subscription";
  readonly state: MeetingState;
  readonly startedAt: number;
  readonly durationMinutes: number;
  readonly deferred: boolean;
  readonly reprocessCount: number;
  readonly audioMinutes: number;
  readonly tokensUsed: number;
  readonly tokenBudget: number;
  readonly attested: boolean;
  readonly deepgram: boolean;
  /** Toplantıda not tamamlandı mı. */
  readonly noteCompleted: boolean;
  /** Toplantıya bağlı başarısız istek sayısı, son hata kodu ve anı (Unix ms). */
  readonly failureCount: number;
  readonly lastFailureCode: string | null;
  readonly lastFailureAt: number | null;
}

/** Hesabın son abonelik iptalinin nedeni (Stripe). Zaman Unix ms. */
export interface UserCancellation {
  readonly at: number;
  readonly reason: string | null;
  readonly feedback: string | null;
  readonly comment: string | null;
}

/** Ayrıntı (hata kodu, servis, kaynak, alan adı, neden) başına sayı; boş ayrıntı `""`. */
export interface DetailCount {
  readonly detail: string;
  readonly count: number;
}

/** Bir penceredeki sorunlar (listeler çoktan aza). */
export interface ProblemWindow {
  readonly trialCapacityReached: number;
  readonly spendCeilingReached: number;
  readonly refusals: readonly DetailCount[];
  readonly providerErrors: readonly DetailCount[];
  readonly serverErrors: readonly DetailCount[];
  readonly serverErrorsTotal: number;
}

/** Huninin adımı. */
export type FunnelStep = "downloads" | "accounts" | "first_meeting" | "first_note" | "three_meetings" | "subscribed" | "canceled";

/** Son iptal (Unix ms). */
export interface RecentCancellation {
  readonly userId: string;
  readonly at: number;
  readonly reason: string | null;
  readonly feedback: string | null;
  readonly comment: string | null;
}

/** `GET /v1/admin/insights` yanıtı. */
export interface Insights {
  readonly generatedAt: number;
  readonly problems: { readonly last7Days: ProblemWindow; readonly last30Days: ProblemWindow };
  readonly funnel: { readonly days: number; readonly steps: readonly { readonly step: FunnelStep; readonly count: number }[] };
  readonly downloads: { readonly total: number; readonly bySource: readonly DetailCount[]; readonly byReferrerHost: readonly DetailCount[] };
  readonly cancellations: {
    readonly total: number;
    readonly byFeedback: readonly DetailCount[];
    readonly byReason: readonly DetailCount[];
    readonly recent: readonly RecentCancellation[];
  };
}

/** Zaman çizelgesi olayı. */
export type TimelineKind =
  | "account_created"
  | "trial_started"
  | "trial_device_verified"
  | "trial_ends"
  | "subscription_updated"
  | "subscription_past_due"
  | "subscription_cancel_at"
  | "subscription_period_end";

/** Zaman çizelgesi satırı. */
export interface TimelineEntry {
  readonly kind: TimelineKind;
  readonly at: number;
  readonly detail: string | null;
}

/** Kullanıcı ayrıntısındaki rapor. */
export interface UserReport {
  readonly id: string;
  readonly kind: ReportKind;
  readonly status: ReportStatus;
  readonly createdAt: number;
  readonly summary: string;
}

/** `GET /v1/admin/users/{id}` yanıtı. */
export interface UserDetail {
  readonly user: UserSummary;
  readonly trialDeviceVerifiedAt: number | null;
  readonly stripeCustomerId: string | null;
  readonly cancellation: UserCancellation | null;
  readonly usage: {
    readonly usedHours: number;
    readonly capHours: number;
    readonly audioHours: number;
    readonly tokens: number;
    readonly tokenCap: number;
    readonly accountTokens: number;
    readonly accountTokenCap: number;
  };
  readonly meetings: readonly UserMeeting[];
  readonly reports: readonly UserReport[];
  readonly timeline: readonly TimelineEntry[];
}

/** Şu an açık toplantı. */
export interface OpenMeeting {
  readonly id: string;
  readonly userId: string;
  readonly kind: "trial" | "subscription";
  readonly startedAt: number;
  readonly maxEndsAt: number;
  readonly deferred: boolean;
  readonly deepgram: boolean;
}

/** Son çökme raporu. */
export interface RecentCrash {
  readonly id: string;
  readonly status: ReportStatus;
  readonly createdAt: number;
  readonly appVersion: string | null;
  readonly os: string | null;
  readonly summary: string;
}

/** `GET /v1/admin/operations` yanıtı. */
export interface Operations {
  readonly generatedAt: number;
  readonly meetings: { readonly open: number; readonly openItems: readonly OpenMeeting[]; readonly unendedLast7Days: number };
  readonly reservations: { readonly active: number; readonly expired: number; readonly oldestExpiredAt: number | null };
  readonly deepgram: { readonly unsettled: number; readonly stale: number };
  readonly stripe: {
    readonly lastEventAt: number | null;
    readonly eventsLast24Hours: number;
    readonly last7DaysByType: readonly { readonly type: string; readonly count: number }[];
  };
  readonly reports: {
    readonly last7Days: { readonly feedback: number; readonly crash: number; readonly contact: number };
    readonly recentCrashes: readonly RecentCrash[];
  };
}

/** Kullanıcı listesi süzgeci; null süzmez. */
export interface UserFilter {
  readonly query: string | null;
  readonly segment: UserSegment | null;
  readonly provider: UserProvider | null;
}

/** Stripe anahtarının modu. */
export type StripeMode = "live" | "test";

/** Bildirim türü. */
export type ReportKind = "feedback" | "crash" | "contact";

/** Bildirim durumu. */
export type ReportStatus = "open" | "done";

/** Listedeki bildirim. */
export interface ReportSummary {
  readonly id: string;
  readonly kind: ReportKind;
  readonly status: ReportStatus;
  /** Unix ms. */
  readonly createdAt: number;
  readonly userId: string | null;
  readonly email: string | null;
  readonly appVersion: string | null;
  readonly os: string | null;
  readonly summary: string | null;
}

/** Bildirim listesinin bir sayfası; `nextBefore` sonraki sayfanın `before` değeri (yoksa null). */
export interface ReportPage {
  readonly items: readonly ReportSummary[];
  readonly nextBefore: number | null;
}

/** Bildirimin tamamı: mesaj ve (çökme raporunda) JSON metni. */
export interface ReportDetail {
  readonly id: string;
  readonly kind: ReportKind;
  readonly status: ReportStatus;
  readonly createdAt: number;
  readonly userId: string | null;
  readonly email: string | null;
  readonly appVersion: string | null;
  readonly os: string | null;
  readonly message: string | null;
  readonly payload: string | null;
}

const dayPattern: RegExp = /^\d{4}-\d{2}-\d{2}$/;

/** `YYYY-MM-DD` gün alanı. */
function dayField(object: JsonObject, response: RawResponse, path: string): string {
  const day: string = stringField(object, "day", response, path);
  if (!dayPattern.test(day)) {
    throw new ApiResponseError(path, response.status, `"day" YYYY-MM-DD değil: ${day}`, response.text);
  }
  return day;
}

/** Zaman alanı: Unix ms sayısı ya da ISO 8601 metni; ms döner. */
function timestampField(object: JsonObject, key: string, response: RawResponse, path: string): number {
  const value: JsonValue | undefined = object[key];
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && !Number.isNaN(Date.parse(value))) {
    return Date.parse(value);
  }
  throw new ApiResponseError(path, response.status, `"${key}" zaman değil`, response.text);
}

/** Kimlik alanı: metin ya da tamsayı; metin döner. */
function idField(object: JsonObject, response: RawResponse, path: string): string {
  const value: JsonValue | undefined = object["id"];
  if (typeof value === "string" && value !== "") {
    return value;
  }
  if (typeof value === "number" && Number.isInteger(value)) {
    return String(value);
  }
  throw new ApiResponseError(path, response.status, '"id" metin ya da tamsayı değil', response.text);
}

/** Bildirim türü alanı. */
function kindField(object: JsonObject, response: RawResponse, path: string): ReportKind {
  const kind: string = stringField(object, "kind", response, path);
  if (kind !== "feedback" && kind !== "crash" && kind !== "contact") {
    throw new ApiResponseError(path, response.status, `bilinmeyen tür "${kind}"`, response.text);
  }
  return kind;
}

/** Bildirim durumu alanı. */
function statusField(object: JsonObject, response: RawResponse, path: string): ReportStatus {
  const status: string = stringField(object, "status", response, path);
  if (status !== "open" && status !== "done") {
    throw new ApiResponseError(path, response.status, `bilinmeyen durum "${status}"`, response.text);
  }
  return status;
}

/** `GET /v1/admin/stats` yanıtını okur. */
export function parseAdminStats(response: RawResponse, path: string): AdminStats {
  const body: JsonObject = parseObject(response, path);
  const downloads: JsonObject = objectField(body, "downloads", response, path);
  const users: JsonObject = objectField(body, "users", response, path);
  const byProvider: JsonObject = objectField(users, "byProvider", response, path);
  const trials: JsonObject = objectField(body, "trials", response, path);
  const subscriptions: JsonObject = objectField(body, "subscriptions", response, path);
  const meetings: JsonObject = objectField(body, "meetings", response, path);
  const spend: JsonObject = objectField(body, "spend", response, path);
  const tokens: JsonObject = objectField(body, "tokens", response, path);
  const reports: JsonObject = objectField(body, "reports", response, path);
  const stripe: JsonObject = objectField(body, "stripe", response, path);
  const elevenLabs: JsonObject = objectField(body, "elevenLabs", response, path);
  const deepgram: JsonObject = objectField(body, "deepgram", response, path);
  const conversion: JsonObject = objectField(body, "conversion", response, path);
  const churn: JsonObject = objectField(body, "churn", response, path);
  const billing: JsonObject = objectField(body, "billing", response, path);
  const usage: JsonObject = objectField(body, "usage", response, path);
  const refusals: JsonObject = objectField(body, "trialRefusals", response, path);
  const dayCounts =(owner: JsonObject, key: string): DayCount[] =>
    objectArrayField(owner, key, response, path).map((item: JsonObject): DayCount => ({ day: dayField(item, response, path), count: numberField(item, "count", response, path) }));
  return {
    generatedAt: timestampField(body, "generatedAt", response, path),
    downloads: { total: numberField(downloads, "total", response, path), last30Days: dayCounts(downloads, "last30Days") },
    users: {
      total: numberField(users, "total", response, path),
      newLast30Days: dayCounts(users, "newLast30Days"),
      byProvider: { apple: numberField(byProvider, "apple", response, path), google: numberField(byProvider, "google", response, path) },
    },
    trials: {
      activeTrialUsers: numberField(trials, "activeTrialUsers", response, path),
      exhaustedTrialUsers: numberField(trials, "exhaustedTrialUsers", response, path),
    },
    subscriptions: {
      active: numberField(subscriptions, "active", response, path),
      grace: numberField(subscriptions, "grace", response, path),
      ending: numberField(subscriptions, "ending", response, path),
      canceledTotal: numberField(subscriptions, "canceledTotal", response, path),
      mrrUsd: numberField(subscriptions, "mrrUsd", response, path),
    },
    meetings: {
      last30Days: objectArrayField(meetings, "last30Days", response, path).map(
        (item: JsonObject): DayMeetings => ({
          day: dayField(item, response, path),
          trial: numberField(item, "trial", response, path),
          subscription: numberField(item, "subscription", response, path),
        }),
      ),
      hoursThisMonth: numberField(meetings, "hoursThisMonth", response, path),
    },
    spend: {
      todayUsd: numberField(spend, "todayUsd", response, path),
      ceilingUsd: numberField(spend, "ceilingUsd", response, path),
      last30Days: objectArrayField(spend, "last30Days", response, path).map(
        (item: JsonObject): DaySpend => ({ day: dayField(item, response, path), usd: numberField(item, "usd", response, path) }),
      ),
    },
    tokens: { thisMonth: numberField(tokens, "thisMonth", response, path) },
    reports: {
      openFeedback: numberField(reports, "openFeedback", response, path),
      openCrash: numberField(reports, "openCrash", response, path),
      openContact: numberField(reports, "openContact", response, path),
    },
    stripe: { mode: stripeModeField(stripe, response, path) },
    elevenLabs: {
      usedHours: numberField(elevenLabs, "usedHours", response, path),
      capHours: numberField(elevenLabs, "capHours", response, path),
      percent: numberField(elevenLabs, "percent", response, path),
    },
    deepgram: {
      estimatedUsd: numberField(deepgram, "estimatedUsd", response, path),
      budgetUsd: numberField(deepgram, "budgetUsd", response, path),
      percent: numberField(deepgram, "percent", response, path),
      streamMinutes: numberField(deepgram, "streamMinutes", response, path),
    },
    conversion: {
      trialStarted: numberField(conversion, "trialStarted", response, path),
      converted: numberField(conversion, "converted", response, path),
      startedLast30Days: numberField(conversion, "startedLast30Days", response, path),
      convertedLast30Days: numberField(conversion, "convertedLast30Days", response, path),
      subscribedWithoutTrial: numberField(conversion, "subscribedWithoutTrial", response, path),
    },
    churn: {
      canceledLast30Days: numberField(churn, "canceledLast30Days", response, path),
      pastDue: numberField(churn, "pastDue", response, path),
      unpaid: numberField(churn, "unpaid", response, path),
      duplicateSubscriptions: numberField(churn, "duplicateSubscriptions", response, path),
    },
    billing: {
      refundsLast30Days: numberField(billing, "refundsLast30Days", response, path),
      disputesLast30Days: numberField(billing, "disputesLast30Days", response, path),
      paymentFailuresLast30Days: numberField(billing, "paymentFailuresLast30Days", response, path),
    },
    usage: {
      meetingsThisMonth: numberField(usage, "meetingsThisMonth", response, path),
      deferredThisMonth: numberField(usage, "deferredThisMonth", response, path),
      reprocessedThisMonth: numberField(usage, "reprocessedThisMonth", response, path),
      openMeetings: numberField(usage, "openMeetings", response, path),
      audioHoursThisMonth: numberField(usage, "audioHoursThisMonth", response, path),
      accountTokensThisMonth: numberField(usage, "accountTokensThisMonth", response, path),
      monthlyTokenCapPerUser: numberField(usage, "monthlyTokenCapPerUser", response, path),
      monthlyAccountTokenCapPerUser: numberField(usage, "monthlyAccountTokenCapPerUser", response, path),
      usersNearTokenCap: numberField(usage, "usersNearTokenCap", response, path),
    },
    trialRefusals: {
      last30Days: refusalCounts(objectField(refusals, "last30Days", response, path), response, path),
      today: refusalCounts(objectField(refusals, "today", response, path), response, path),
    },
  };
}

/** Neden başına reddedilen deneme sayaçlarını okur. */
function refusalCounts(object: JsonObject, response: RawResponse, path: string): TrialRefusalCounts {
  return {
    deviceUsed: numberField(object, "device_used", response, path),
    exhausted: numberField(object, "exhausted", response, path),
    expired: numberField(object, "expired", response, path),
    ipDailyLimit: numberField(object, "ip_daily_limit", response, path),
  };
}

/** Değeri izinli metinlerden biri olan alan; değilse `ApiResponseError`. */
function literalField<Literal extends string>(object: JsonObject, key: string, allowed: readonly Literal[], response: RawResponse, path: string): Literal {
  const value: string = stringField(object, key, response, path);
  const match: Literal | undefined = allowed.find((candidate: Literal): boolean => candidate === value);
  if (match === undefined) {
    throw new ApiResponseError(path, response.status, `"${key}" bilinmeyen değer "${value}"`, response.text);
  }
  return match;
}

/** Değeri izinli metinlerden biri ya da null olan alan. */
function nullableLiteralField<Literal extends string>(object: JsonObject, key: string, allowed: readonly Literal[], response: RawResponse, path: string): Literal | null {
  return object[key] === null ? null : literalField(object, key, allowed, response, path);
}

/** Mantıksal alan; değilse `ApiResponseError`. */
function booleanField(object: JsonObject, key: string, response: RawResponse, path: string): boolean {
  const value: JsonValue | undefined = object[key];
  if (typeof value !== "boolean") {
    throw new ApiResponseError(path, response.status, `"${key}" mantıksal değil`, response.text);
  }
  return value;
}

/** Zaman ya da null alanı (ms döner). */
function nullableTimestampField(object: JsonObject, key: string, response: RawResponse, path: string): number | null {
  return object[key] === null ? null : timestampField(object, key, response, path);
}

/** Nesne ya da null alanı. */
function nullableObjectField(object: JsonObject, key: string, response: RawResponse, path: string): JsonObject | null {
  return object[key] === null ? null : objectField(object, key, response, path);
}

const segments: readonly UserSegment[] = ["subscribed", "past_due", "canceled", "trial", "free", "no_meeting", "trial_ended", "inactive", "failed"];
const funnelSteps: readonly FunnelStep[] = ["downloads", "accounts", "first_meeting", "first_note", "three_meetings", "subscribed", "canceled"];
const providers: readonly UserProvider[] = ["apple", "google"];
const plans: readonly UserPlan[] = ["subscription", "trial", "free"];
const accesses: readonly UserAccess[] = ["active", "grace", "none"];
const meetingKinds: readonly ("trial" | "subscription")[] = ["trial", "subscription"];
const meetingStates: readonly MeetingState[] = ["open", "ended", "superseded", "expired"];
const timelineKinds: readonly TimelineKind[] = [
  "account_created",
  "trial_started",
  "trial_device_verified",
  "trial_ends",
  "subscription_updated",
  "subscription_past_due",
  "subscription_cancel_at",
  "subscription_period_end",
];

/** Kesim adının geçerli olup olmadığı (sayfadaki seçimden okunurken). Saf fonksiyondur. */
export function userSegmentOf(value: string): UserSegment | null {
  return segments.find((segment: UserSegment): boolean => segment === value) ?? null;
}

/** Sağlayıcı adının geçerli olup olmadığı. Saf fonksiyondur. */
export function userProviderOf(value: string): UserProvider | null {
  return providers.find((provider: UserProvider): boolean => provider === value) ?? null;
}

/** Kullanıcı özetini okur. */
function parseUserSummary(item: JsonObject, response: RawResponse, path: string): UserSummary {
  const subscription: JsonObject | null = nullableObjectField(item, "subscription", response, path);
  const trial: JsonObject = objectField(item, "trial", response, path);
  return {
    id: idField(item, response, path),
    provider: nullableLiteralField(item, "provider", providers, response, path),
    createdAt: timestampField(item, "createdAt", response, path),
    plan: literalField(item, "plan", plans, response, path),
    subscription:
      subscription === null
        ? null
        : {
            status: stringField(subscription, "status", response, path),
            access: literalField(subscription, "access", accesses, response, path),
            currentPeriodEnd: timestampField(subscription, "currentPeriodEnd", response, path),
            cancelAt: nullableTimestampField(subscription, "cancelAt", response, path),
            pastDueSince: nullableTimestampField(subscription, "pastDueSince", response, path),
            graceEndsAt: nullableTimestampField(subscription, "graceEndsAt", response, path),
            updatedAt: timestampField(subscription, "updatedAt", response, path),
          },
    trial: {
      used: numberField(trial, "used", response, path),
      left: numberField(trial, "left", response, path),
      startedAt: nullableTimestampField(trial, "startedAt", response, path),
      endsAt: nullableTimestampField(trial, "endsAt", response, path),
    },
    meetingsTotal: numberField(item, "meetingsTotal", response, path),
    hoursThisMonth: numberField(item, "hoursThisMonth", response, path),
    lastActiveAt: nullableTimestampField(item, "lastActiveAt", response, path),
    failedMeetings: numberField(item, "failedMeetings", response, path),
    lastFailureCode: nullableStringField(item, "lastFailureCode", response, path),
  };
}

/** `GET /v1/admin/users` yanıtını okur. */
export function parseUserPage(response: RawResponse, path: string): UserPage {
  const body: JsonObject = parseObject(response, path);
  return {
    items: objectArrayField(body, "items", response, path).map((item: JsonObject): UserSummary => parseUserSummary(item, response, path)),
    nextCursor: nullableStringField(body, "nextCursor", response, path),
  };
}

/** `GET /v1/admin/users/{id}` yanıtını okur. */
export function parseUserDetail(response: RawResponse, path: string): UserDetail {
  const body: JsonObject = parseObject(response, path);
  const usage: JsonObject = objectField(body, "usage", response, path);
  return {
    user: parseUserSummary(objectField(body, "user", response, path), response, path),
    trialDeviceVerifiedAt: nullableTimestampField(body, "trialDeviceVerifiedAt", response, path),
    stripeCustomerId: nullableStringField(body, "stripeCustomerId", response, path),
    cancellation: parseCancellation(nullableObjectField(body, "cancellation", response, path), response, path),
    usage: {
      usedHours: numberField(usage, "usedHours", response, path),
      capHours: numberField(usage, "capHours", response, path),
      audioHours: numberField(usage, "audioHours", response, path),
      tokens: numberField(usage, "tokens", response, path),
      tokenCap: numberField(usage, "tokenCap", response, path),
      accountTokens: numberField(usage, "accountTokens", response, path),
      accountTokenCap: numberField(usage, "accountTokenCap", response, path),
    },
    meetings: objectArrayField(body, "meetings", response, path).map(
      (item: JsonObject): UserMeeting => ({
        id: idField(item, response, path),
        kind: literalField(item, "kind", meetingKinds, response, path),
        state: literalField(item, "state", meetingStates, response, path),
        startedAt: timestampField(item, "startedAt", response, path),
        durationMinutes: numberField(item, "durationMinutes", response, path),
        deferred: booleanField(item, "deferred", response, path),
        reprocessCount: numberField(item, "reprocessCount", response, path),
        audioMinutes: numberField(item, "audioMinutes", response, path),
        tokensUsed: numberField(item, "tokensUsed", response, path),
        tokenBudget: numberField(item, "tokenBudget", response, path),
        attested: booleanField(item, "attested", response, path),
        deepgram: booleanField(item, "deepgram", response, path),
        noteCompleted: booleanField(item, "noteCompleted", response, path),
        failureCount: numberField(item, "failureCount", response, path),
        lastFailureCode: nullableStringField(item, "lastFailureCode", response, path),
        lastFailureAt: nullableTimestampField(item, "lastFailureAt", response, path),
      }),
    ),
    reports: objectArrayField(body, "reports", response, path).map(
      (item: JsonObject): UserReport => ({
        id: idField(item, response, path),
        kind: kindField(item, response, path),
        status: statusField(item, response, path),
        createdAt: timestampField(item, "createdAt", response, path),
        summary: stringField(item, "summary", response, path),
      }),
    ),
    timeline: objectArrayField(body, "timeline", response, path).map(
      (item: JsonObject): TimelineEntry => ({
        kind: literalField(item, "kind", timelineKinds, response, path),
        at: timestampField(item, "at", response, path),
        detail: nullableStringField(item, "detail", response, path),
      }),
    ),
  };
}

/** İptal nedeni nesnesini okur (null korunur). */
function parseCancellation(object: JsonObject | null, response: RawResponse, path: string): UserCancellation | null {
  return object === null
    ? null
    : {
        at: timestampField(object, "at", response, path),
        reason: nullableStringField(object, "reason", response, path),
        feedback: nullableStringField(object, "feedback", response, path),
        comment: nullableStringField(object, "comment", response, path),
      };
}

/** Ayrıntı sayıları dizisini okur. */
function detailCounts(owner: JsonObject, key: string, response: RawResponse, path: string): DetailCount[] {
  return objectArrayField(owner, key, response, path).map(
    (item: JsonObject): DetailCount => ({ detail: stringField(item, "detail", response, path), count: numberField(item, "count", response, path) }),
  );
}

/** Sorun penceresini okur. */
function parseProblemWindow(object: JsonObject, response: RawResponse, path: string): ProblemWindow {
  return {
    trialCapacityReached: numberField(object, "trialCapacityReached", response, path),
    spendCeilingReached: numberField(object, "spendCeilingReached", response, path),
    refusals: detailCounts(object, "refusals", response, path),
    providerErrors: detailCounts(object, "providerErrors", response, path),
    serverErrors: detailCounts(object, "serverErrors", response, path),
    serverErrorsTotal: numberField(object, "serverErrorsTotal", response, path),
  };
}

/** `GET /v1/admin/insights` yanıtını okur. */
export function parseInsights(response: RawResponse, path: string): Insights {
  const body: JsonObject = parseObject(response, path);
  const problems: JsonObject = objectField(body, "problems", response, path);
  const funnel: JsonObject = objectField(body, "funnel", response, path);
  const downloads: JsonObject = objectField(body, "downloads", response, path);
  const cancellations: JsonObject = objectField(body, "cancellations", response, path);
  return {
    generatedAt: timestampField(body, "generatedAt", response, path),
    problems: {
      last7Days: parseProblemWindow(objectField(problems, "last7Days", response, path), response, path),
      last30Days: parseProblemWindow(objectField(problems, "last30Days", response, path), response, path),
    },
    funnel: {
      days: numberField(funnel, "days", response, path),
      steps: objectArrayField(funnel, "steps", response, path).map((item: JsonObject): { readonly step: FunnelStep; readonly count: number } => ({
        step: literalField(item, "step", funnelSteps, response, path),
        count: numberField(item, "count", response, path),
      })),
    },
    downloads: {
      total: numberField(downloads, "total", response, path),
      bySource: detailCounts(downloads, "bySource", response, path),
      byReferrerHost: detailCounts(downloads, "byReferrerHost", response, path),
    },
    cancellations: {
      total: numberField(cancellations, "total", response, path),
      byFeedback: detailCounts(cancellations, "byFeedback", response, path),
      byReason: detailCounts(cancellations, "byReason", response, path),
      recent: objectArrayField(cancellations, "recent", response, path).map(
        (item: JsonObject): RecentCancellation => ({
          userId: stringField(item, "userId", response, path),
          at: timestampField(item, "at", response, path),
          reason: nullableStringField(item, "reason", response, path),
          feedback: nullableStringField(item, "feedback", response, path),
          comment: nullableStringField(item, "comment", response, path),
        }),
      ),
    },
  };
}

/** `GET /v1/admin/operations` yanıtını okur. */
export function parseOperations(response: RawResponse, path: string): Operations {
  const body: JsonObject = parseObject(response, path);
  const meetings: JsonObject = objectField(body, "meetings", response, path);
  const reservations: JsonObject = objectField(body, "reservations", response, path);
  const deepgram: JsonObject = objectField(body, "deepgram", response, path);
  const stripe: JsonObject = objectField(body, "stripe", response, path);
  const reports: JsonObject = objectField(body, "reports", response, path);
  const reportsLast7Days: JsonObject = objectField(reports, "last7Days", response, path);
  return {
    generatedAt: timestampField(body, "generatedAt", response, path),
    meetings: {
      open: numberField(meetings, "open", response, path),
      openItems: objectArrayField(meetings, "openItems", response, path).map(
        (item: JsonObject): OpenMeeting => ({
          id: idField(item, response, path),
          userId: stringField(item, "userId", response, path),
          kind: literalField(item, "kind", meetingKinds, response, path),
          startedAt: timestampField(item, "startedAt", response, path),
          maxEndsAt: timestampField(item, "maxEndsAt", response, path),
          deferred: booleanField(item, "deferred", response, path),
          deepgram: booleanField(item, "deepgram", response, path),
        }),
      ),
      unendedLast7Days: numberField(meetings, "unendedLast7Days", response, path),
    },
    reservations: {
      active: numberField(reservations, "active", response, path),
      expired: numberField(reservations, "expired", response, path),
      oldestExpiredAt: nullableTimestampField(reservations, "oldestExpiredAt", response, path),
    },
    deepgram: { unsettled: numberField(deepgram, "unsettled", response, path), stale: numberField(deepgram, "stale", response, path) },
    stripe: {
      lastEventAt: nullableTimestampField(stripe, "lastEventAt", response, path),
      eventsLast24Hours: numberField(stripe, "eventsLast24Hours", response, path),
      last7DaysByType: objectArrayField(stripe, "last7DaysByType", response, path).map((item: JsonObject): { readonly type: string; readonly count: number } => ({
        type: stringField(item, "type", response, path),
        count: numberField(item, "count", response, path),
      })),
    },
    reports: {
      last7Days: {
        feedback: numberField(reportsLast7Days, "feedback", response, path),
        crash: numberField(reportsLast7Days, "crash", response, path),
        contact: numberField(reportsLast7Days, "contact", response, path),
      },
      recentCrashes: objectArrayField(reports, "recentCrashes", response, path).map(
        (item: JsonObject): RecentCrash => ({
          id: idField(item, response, path),
          status: statusField(item, response, path),
          createdAt: timestampField(item, "createdAt", response, path),
          appVersion: nullableStringField(item, "appVersion", response, path),
          os: nullableStringField(item, "os", response, path),
          summary: stringField(item, "summary", response, path),
        }),
      ),
    },
  };
}

/** Stripe modu alanı: "live" ya da "test". */
function stripeModeField(object: JsonObject, response: RawResponse, path: string): StripeMode {
  const mode: string = stringField(object, "mode", response, path);
  if (mode !== "live" && mode !== "test") {
    throw new ApiResponseError(path, response.status, `bilinmeyen Stripe modu "${mode}"`, response.text);
  }
  return mode;
}

/** Bildirim listesi öğesini okur. */
function parseReportSummary(item: JsonObject, response: RawResponse, path: string): ReportSummary {
  return {
    id: idField(item, response, path),
    kind: kindField(item, response, path),
    status: statusField(item, response, path),
    createdAt: timestampField(item, "createdAt", response, path),
    userId: nullableStringField(item, "userId", response, path),
    email: nullableStringField(item, "email", response, path),
    appVersion: nullableStringField(item, "appVersion", response, path),
    os: nullableStringField(item, "os", response, path),
    summary: nullableStringField(item, "summary", response, path),
  };
}

/** `GET /v1/admin/reports` yanıtını okur. */
export function parseReportPage(response: RawResponse, path: string): ReportPage {
  const body: JsonObject = parseObject(response, path);
  return {
    items: objectArrayField(body, "items", response, path).map((item: JsonObject): ReportSummary => parseReportSummary(item, response, path)),
    nextBefore: body["nextBefore"] === null ? null : numberField(body, "nextBefore", response, path),
  };
}

/** `GET /v1/admin/reports/{id}` yanıtını okur. */
export function parseReportDetail(response: RawResponse, path: string): ReportDetail {
  const body: JsonObject = parseObject(response, path);
  return {
    id: idField(body, response, path),
    kind: kindField(body, response, path),
    status: statusField(body, response, path),
    createdAt: timestampField(body, "createdAt", response, path),
    userId: nullableStringField(body, "userId", response, path),
    email: nullableStringField(body, "email", response, path),
    appVersion: nullableStringField(body, "appVersion", response, path),
    os: nullableStringField(body, "os", response, path),
    message: nullableStringField(body, "message", response, path),
    payload: nullableStringField(body, "payload", response, path),
  };
}

/** Özet istatistikler. */
export async function fetchStats(): Promise<AdminStats> {
  const path: string = "/v1/admin/stats";
  return parseAdminStats(await authorizedSend({ method: "GET", path, body: null, attempts: 3 }), path);
}

/** Bildirim listesinin bir sayfası (`before` yoksa en yeniler). */
export async function fetchReports(kind: ReportKind, status: ReportStatus, before: number | null): Promise<ReportPage> {
  const query: URLSearchParams = new URLSearchParams({ kind, status });
  if (before !== null) {
    query.set("before", String(before));
  }
  const path: string = `/v1/admin/reports?${query.toString()}`;
  return parseReportPage(await authorizedSend({ method: "GET", path, body: null, attempts: 3 }), path);
}

/** Tek bildirim. */
export async function fetchReport(id: string): Promise<ReportDetail> {
  const path: string = `/v1/admin/reports/${encodeURIComponent(id)}`;
  return parseReportDetail(await authorizedSend({ method: "GET", path, body: null, attempts: 3 }), path);
}

/** Kullanıcı listesinin bir sayfası (`cursor` yoksa en yeniler). */
export async function fetchUsers(filter: UserFilter, cursor: string | null): Promise<UserPage> {
  const query: URLSearchParams = new URLSearchParams({ q: filter.query ?? "", segment: filter.segment ?? "", provider: filter.provider ?? "", cursor: cursor ?? "" });
  const path: string = `/v1/admin/users?${query.toString()}`;
  return parseUserPage(await authorizedSend({ method: "GET", path, body: null, attempts: 3 }), path);
}

/** Tek kullanıcının ayrıntısı. */
export async function fetchUser(id: string): Promise<UserDetail> {
  const path: string = `/v1/admin/users/${encodeURIComponent(id)}`;
  return parseUserDetail(await authorizedSend({ method: "GET", path, body: null, attempts: 3 }), path);
}

/** Kullanıcıyı anlama görünümü (sorunlar, huni, indirme kaynakları, iptal nedenleri). */
export async function fetchInsights(): Promise<Insights> {
  const path: string = "/v1/admin/insights";
  return parseInsights(await authorizedSend({ method: "GET", path, body: null, attempts: 3 }), path);
}

/** İşletim görünümü. */
export async function fetchOperations(): Promise<Operations> {
  const path: string = "/v1/admin/operations";
  return parseOperations(await authorizedSend({ method: "GET", path, body: null, attempts: 3 }), path);
}

/** Bildirimin durumunu değiştirir (204). */
export async function setReportStatus(id: string, status: ReportStatus): Promise<void> {
  const path: string = `/v1/admin/reports/${encodeURIComponent(id)}`;
  await authorizedSend({ method: "POST", path, body: { status }, attempts: 1 });
}
