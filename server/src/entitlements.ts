import type { Config, SubscriptionPlan } from "./config";
import { type LiveEngine, liveEngine } from "./deepgram";
import { ApiError } from "./errors";
import { type ReservationLimit, remainingOf, subscriberAccountTokenLimit, trialAccountTokenLimit } from "./reservations";
import { type MonthlyUsage, monthlyUsage, nextDayStartMs, nextMonthStartMs } from "./usage";

/** Webhook'un yazdığı abonelik durumu. */
export interface SubscriptionState {
  readonly status: string;
  readonly currentPeriodEnd: number;
  /** İptal edilmiş aboneliğin biteceği an (ms); yenilenecekse null. */
  readonly cancelAt: number | null;
  /** Aboneliğin `past_due` durumuna geçtiği an (ms; webhook'un işlediği an); `past_due` değilse null. */
  readonly pastDueSince: number | null;
}

/** Kullanıcının planı: deneme ya da abonelik. */
export type Plan = "trial" | "subscription";

/**
 * Aboneliğin erişim durumu: `active` (ödenmiş dönem), `grace` (`past_due`, dönem sonundan sonra ek süre içinde),
 * `none` (erişim yok: `unpaid`, `canceled`, `incomplete_expired`, süresi geçmiş ya da bilinmeyen durum).
 */
export type SubscriptionAccess = "active" | "grace" | "none";

/** Toplantı dışı yapay zekâ hakkının dönemi (UTC): abonede ay, denemede gün. */
export type AccountTokensPeriod = "month" | "day";

/** Toplantı dışı yapay zekâ (Sor, notu yeniden yazma, düzenleme, görev aracı) hakkının kullanımı. */
export interface AccountTokenAllowance {
  /** Dönemde sayılan token: kesinleşmiş kullanım + süren çağrıların ayırması (sınırın denetlediği miktar). */
  readonly used: number;
  readonly cap: number;
  readonly period: AccountTokensPeriod;
  /** Dönemin bittiği (hakkın sıfırlandığı) an, ms. */
  readonly resetsAtMs: number;
}

/** `GET /v1/me` yanıtı. */
export interface Entitlements {
  readonly userId: string;
  readonly plan: Plan;
  readonly trialMeetingsTotal: number;
  /** Denemenin süresi (gün; ilk deneme toplantısından başlar). */
  readonly trialDays: number;
  /** Etkin kalan deneme: hesap ve (bildirilen doğrulanmış cihaz varsa) cihaz kalanının küçüğü; süre dolduysa 0. */
  readonly trialMeetingsLeft: number;
  /** Hesabın kalan denemesi; süre dolduysa 0. */
  readonly accountTrialMeetingsLeft: number;
  /** Deneme süresinin bittiği an (ilk deneme toplantısı + `TRIAL_DAYS`); deneme başlamadıysa ya da abonelikte null. */
  readonly trialEndsAt: string | null;
  /** Bildirilen cihazın kalan denemesi; cihaz bildirilmediyse ya da kayıtlı değilse null. */
  readonly deviceTrialMeetingsLeft: number | null;
  readonly monthlyHoursUsed: number;
  readonly monthlyHoursCap: number;
  /**
   * Yeni toplantının canlı metin motoru: `deepgram` (bulut; jeton `POST /v1/live/deepgram-token`) ya da `whisperkit`
   * (Mac'te; Deepgram kapalı ya da bütçesi dolu). Jeton yine reddedilebilir; istemci o zaman da Mac'e geçer.
   */
  readonly liveEngine: LiveEngine;
  /**
   * Toplantı dışı yapay zekâ hakkı (Sor, notu yeniden yazma, düzenleme, görev aracı). Abonelik erişimi varsa (`plan:
   * subscription`) aylık `MONTHLY_ACCOUNT_TOKEN_CAP`, yoksa (deneme) günlük `TRIAL_ACCOUNT_DAILY_TOKENS`; dönemi
   * `accountTokensPeriod`. `accountTokensUsed` sınırın saydığı miktardır (kesinleşmiş + süren çağrılar; sınırı biraz
   * aşabilir). Denemede hak yalnızca deneme başlamış ve bitmemişken kullanılabilir (bkz. `requireAccountLLMAccess`).
   */
  readonly accountTokensUsed: number;
  readonly accountTokensCap: number;
  readonly accountTokensPeriod: AccountTokensPeriod;
  /** Toplantı dışı hakkın sıfırlandığı an (ISO 8601): abonede sonraki UTC ayının, denemede sonraki UTC gününün başı. */
  readonly accountTokensResetsAt: string;
  /** Aylık sınırların (`monthlyHoursCap`, abonede `accountTokensCap`) sıfırlandığı an: sonraki UTC ayının başı (ISO 8601). */
  readonly monthlyResetsAt: string;
  /**
   * Şimdi açılacak toplantının en çok süresi (dakika); toplantının ses hakkı da budur (son geçiş en çok bu kadar sesi
   * yazıya döker). Denemede `TRIAL_MAX_MEETING_MINUTES`, abonede `SUBSCRIBER_MAX_MEETING_MINUTES` ile aylık kalanın
   * küçüğü (bkz. `subscriberMeetingMaxMinutes`). İstemci içe aktarılacak dosyayı kuyruğa almadan buna göre reddeder.
   */
  readonly meetingMaxMinutes: number;
  readonly subscription: {
    readonly status: string;
    readonly currentPeriodEnd: string;
    /** İptal edildiyse erişimin biteceği an (yenilenmez); yenilenecekse null. */
    readonly cancelAt: string | null;
    readonly access: SubscriptionAccess;
    /** `past_due` ek süresinin bittiği an; ek süre yoksa null. */
    readonly graceEndsAt: string | null;
    /** Plan (aylık ya da yıllık); fiyatı tanınmayan eski abonelikte null. Haklar plana bakmaz. */
    readonly plan: SubscriptionPlan | null;
  } | null;
}

/** Kullanıcının abonelik satırındaki plan; satır yoksa ya da plan tanınmıyorsa null. */
export async function subscriptionPlan(db: D1Database, userId: string): Promise<SubscriptionPlan | null> {
  const row: { plan: SubscriptionPlan | null } | null = await db
    .prepare("SELECT plan FROM subscriptions WHERE user_id = ?")
    .bind(userId)
    .first<{ plan: SubscriptionPlan | null }>();
  return row?.plan ?? null;
}

/** `past_due` ek süresinin bittiği an (ms): `past_due`'ya geçiş + `pastDueGraceMs`; `past_due` değilse null. Saf fonksiyondur. */
export function graceEndsAtMs(subscription: SubscriptionState, pastDueGraceMs: number): number | null {
  return subscription.status === "past_due" && subscription.pastDueSince !== null ? subscription.pastDueSince + pastDueGraceMs : null;
}

/**
 * Yenilenecek `active`/`trialing` aboneliğin dönem sonundan sonra erişimi koruduğu süre: Stripe yenileme faturasını dönem
 * sonunda keser ve ödemeyi alır; yeni dönem sonunu taşıyan webhook birkaç dakika ile saatler arasında gecikebilir. Bu
 * sürede abone denemeye düşmez (`/v1/me` planı, toplantı başlatma deneme yoluna ve DeviceCheck'e girmez).
 */
export const subscriptionRenewalGraceMs: number = 48 * 3_600_000;

/**
 * `active`/`trialing` aboneliğin erişiminin bittiği an (ms): yenilenecekse (`cancelAt` yok ya da dönem sonundan sonra)
 * dönem sonu + `subscriptionRenewalGraceMs`, dönem sonunda bitecekse dönem sonu. Saf fonksiyondur.
 */
export function paidAccessEndsAtMs(subscription: SubscriptionState): number {
  const renews: boolean = subscription.cancelAt === null || subscription.cancelAt > subscription.currentPeriodEnd;
  return renews ? subscription.currentPeriodEnd + subscriptionRenewalGraceMs : subscription.currentPeriodEnd;
}

/**
 * Aboneliğin erişim durumu. `active`/`trialing` dönem sonuna dek, yenilenecekse yenileme webhook'u gecikebileceği için
 * `subscriptionRenewalGraceMs` daha (`paidAccessEndsAtMs`); `past_due` ödemenin başarısız olduğu andan (`pastDueSince`;
 * Stripe yenilemede dönem sonunu hemen ilerlettiği için dönem sonundan değil) `pastDueGraceMs` boyunca (Stripe ödemeyi
 * yeniden denerken) erişimi korur. Saf fonksiyondur.
 */
export function subscriptionAccess(subscription: SubscriptionState | null, now: Date, pastDueGraceMs: number): SubscriptionAccess {
  if (subscription === null) {
    return "none";
  }
  if (["active", "trialing"].includes(subscription.status) && paidAccessEndsAtMs(subscription) > now.getTime()) {
    return "active";
  }
  const graceEnd: number | null = graceEndsAtMs(subscription, pastDueGraceMs);
  if (graceEnd !== null && graceEnd > now.getTime()) {
    return "grace";
  }
  return "none";
}

/**
 * Abonelik bitmiş mi: `canceled`, `incomplete_expired` ya da dönemi geçmiş `unpaid`. Bitmemiş abonelik (`active`,
 * `trialing`, `past_due`, `unpaid`, `incomplete`, `paused`) ek süresi geçmiş olsa da Stripe'ta yaşar: yeni Checkout
 * açılmaz (Portal'dan yönetilir) ve başka bir aboneliğin olayı onu ezmez (bkz. `handleStripeWebhook`; SQL koşulu bu
 * fonksiyonla aynıdır). Saf fonksiyondur.
 */
export function isTerminalSubscription(subscription: SubscriptionState, now: Date): boolean {
  if (subscription.status === "canceled" || subscription.status === "incomplete_expired") {
    return true;
  }
  return subscription.status === "unpaid" && subscription.currentPeriodEnd <= now.getTime();
}

/** Abonelik hak veriyor mu (`active` ya da `grace`). Saf fonksiyondur. */
export function hasSubscriptionAccess(subscription: SubscriptionState | null, now: Date, pastDueGraceMs: number): boolean {
  return subscriptionAccess(subscription, now, pastDueGraceMs) !== "none";
}

/** Kullanıcının abonelik durumu (yoksa null). */
export async function subscriptionState(db: D1Database, userId: string): Promise<SubscriptionState | null> {
  const row: { status: string; current_period_end: number; cancel_at: number | null; past_due_since: number | null } | null = await db
    .prepare("SELECT status, current_period_end, cancel_at, past_due_since FROM subscriptions WHERE user_id = ?")
    .bind(userId)
    .first<{ status: string; current_period_end: number; cancel_at: number | null; past_due_since: number | null }>();
  return row === null
    ? null
    : { status: row.status, currentPeriodEnd: row.current_period_end, cancelAt: row.cancel_at, pastDueSince: row.past_due_since };
}

/** Hesabın deneme durumu. */
export interface TrialState {
  /** Harcanan deneme toplantısı: toplantılar + aynı kimliğin silinmiş hesaplarından devralınan. */
  readonly used: number;
  /** İlk deneme toplantısının başladığı an (ms; devralınmış olabilir); deneme başlamadıysa null. */
  readonly startedAt: number | null;
  /** Hesabın denemesinin bir Mac'e (DeviceCheck) bağlandığı an (ms); bağlanmadıysa null. */
  readonly deviceVerifiedAt: number | null;
}

/**
 * Kullanıcının deneme durumu: harcanan deneme toplantısı (deneme toplantıları + `users.carried_trial_meetings`, bkz.
 * `trialLedger.ts`), denemenin başladığı an (`users.trial_started_at`) ve Mac doğrulaması
 * (`users.trial_device_verified_at`).
 */
export async function userTrialState(db: D1Database, userId: string): Promise<TrialState> {
  const row: { used: number; started_at: number | null; device_verified_at: number | null } | null = await db
    .prepare(
      `SELECT (SELECT COUNT(*) FROM meeting_sessions WHERE user_id = ?1 AND kind = 'trial')
         + COALESCE((SELECT carried_trial_meetings FROM users WHERE id = ?1), 0) AS used,
         (SELECT trial_started_at FROM users WHERE id = ?1) AS started_at,
         (SELECT trial_device_verified_at FROM users WHERE id = ?1) AS device_verified_at`,
    )
    .bind(userId)
    .first<{ used: number; started_at: number | null; device_verified_at: number | null }>();
  return { used: row?.used ?? 0, startedAt: row?.started_at ?? null, deviceVerifiedAt: row?.device_verified_at ?? null };
}

/** Deneme süresinin bittiği an (ms); deneme başlamadıysa null. Saf fonksiyondur. */
export function trialEndsAtMs(state: TrialState, trialDurationMs: number): number | null {
  return state.startedAt === null ? null : state.startedAt + trialDurationMs;
}

/** Deneme süresi doldu mu (başlamamış deneme dolmaz). Saf fonksiyondur. */
export function isTrialExpired(state: TrialState, trialDurationMs: number, now: Date): boolean {
  const endsAt: number | null = trialEndsAtMs(state, trialDurationMs);
  return endsAt !== null && endsAt <= now.getTime();
}

/** Kalan deneme toplantısı: süre dolduysa 0, yoksa toplam − harcanan. Saf fonksiyondur. */
export function trialMeetingsLeft(state: TrialState, config: Config, now: Date): number {
  return isTrialExpired(state, config.trialDurationMs, now) ? 0 : Math.max(0, config.trialMeetings - state.used);
}

/** Kayıtlı cihazda (tüm hesaplarca) harcanan deneme sayısı; cihaz kayıtlı değilse null. */
export async function deviceTrialMeetingsUsed(db: D1Database, deviceId: string): Promise<number | null> {
  const row: { registered: number; count: number } | null = await db
    .prepare(
      `SELECT EXISTS (SELECT 1 FROM devices WHERE id = ?) AS registered,
         (SELECT COUNT(*) FROM meeting_sessions WHERE device_id = ? AND kind = 'trial') AS count`,
    )
    .bind(deviceId, deviceId)
    .first<{ registered: number; count: number }>();
  return row === null || row.registered === 0 ? null : row.count;
}

/** Toplantıya bağlı olmayan çağrının hakkı: abonelik ya da deneme (deneme ayrıca küçük günlük sınıra tabidir). */
export type AccountLLMAccess = "subscription" | "trial";

/**
 * Deneme ilk toplantıyla başladı mı: `users.trial_started_at` dolu ve DeviceCheck politikası `required` ise deneme bir
 * Mac'e bağlanmış (`users.trial_device_verified_at`). Deneme toplantısı DeviceCheck'i, IP başına yeni deneme sınırını ve
 * deneme süresini başlatır; toplantı dışı deneme çağrısı bunları atlayamasın diye yalnızca başlamış denemede açılır.
 * Saf fonksiyondur.
 */
export function isTrialStarted(trial: TrialState, config: Config): boolean {
  return trial.startedAt !== null && (config.deviceCheck.policy === "off" || trial.deviceVerifiedAt !== null);
}

/**
 * Toplantıya bağlı olmayan yapay zekâ çağrısı (Sor, notu yeniden yazma, düzenleme, görev aracı) hakkı: erişimi olan
 * abonelik (`active` ya da `grace`) ya da ilk toplantıyla başlamış (`isTrialStarted`), toplantıları harcanmamış ve
 * süresi dolmamış deneme. Deneme hiç başlamadıysa `trial_not_started` (önce bir toplantı başlatılmalı); bittiyse
 * (toplantılar harcanmış ya da süre dolmuş) ve abonelik yoksa `subscription_required`. Hak toplantı bütçesiyle değil,
 * kullanıcının günlük ve aylık token sınırıyla ve küçük çağrı başı `max_tokens` ile sınırlanır; denemede ayrıca
 * `TRIAL_ACCOUNT_DAILY_TOKENS`, abonelikte ayrıca `MONTHLY_ACCOUNT_TOKEN_CAP`.
 */
export async function requireAccountLLMAccess(db: D1Database, config: Config, userId: string, now: Date): Promise<AccountLLMAccess> {
  const [subscription, trial]: [SubscriptionState | null, TrialState] = await Promise.all([
    subscriptionState(db, userId),
    userTrialState(db, userId),
  ]);
  if (hasSubscriptionAccess(subscription, now, config.pastDueGraceMs)) {
    return "subscription";
  }
  if (!isTrialStarted(trial, config)) {
    throw new ApiError("trial_not_started", "Ücretsiz deneme ilk toplantıyla başlar; önce bir toplantı başlat.");
  }
  if (trialMeetingsLeft(trial, config, now) > 0) {
    return "trial";
  }
  throw new ApiError("subscription_required", "Deneme bitti; toplantı dışında yapay zekâ özellikleri için abone ol.");
}

/**
 * Toplantı dışı yapay zekâ hakkının kullanımı: abonelik erişimi varsa aylık abone sınırı, yoksa denemenin günlük
 * sınırı. Kullanım, sınırın kendisinin denetlediği kalan miktardan çıkarılır (aynı SQL).
 */
export async function accountTokenAllowance(db: D1Database, config: Config, userId: string, subscriber: boolean, now: Date): Promise<AccountTokenAllowance> {
  const limit: ReservationLimit = subscriber ? subscriberAccountTokenLimit(config, userId, now) : trialAccountTokenLimit(config, userId, now);
  const cap: number = subscriber ? config.monthlyAccountTokenCap : config.trialAccountDailyTokens;
  const [remaining]: number[] = await remainingOf(db, [limit]);
  return {
    used: Math.max(0, cap - (remaining ?? cap)),
    cap,
    period: subscriber ? "month" : "day",
    resetsAtMs: subscriber ? nextMonthStartMs(now) : nextDayStartMs(now),
  };
}

/** Abonenin yeni toplantısının en çok süresi (dakika): üst sınır ile aylık kalanın küçüğü, en az 1. Saf fonksiyondur. */
export function subscriberMeetingMaxMinutes(config: Config, remainingSeconds: number): number {
  return Math.max(1, Math.min(config.subscriberMaxMeetingMinutes, Math.floor(remainingSeconds / 60)));
}

/** Saatin onda biri hassasiyetle saat. Saf fonksiyondur. */
export function hoursRoundedUp(seconds: number): number {
  return Math.ceil((seconds / 3600) * 10) / 10;
}

/**
 * Hak durumu: plan, etkin kalan deneme (cihaz bildirildiyse hesap ve cihazın küçüğü; süre dolduysa 0), denemenin
 * bitiş anı, aylık kullanım, sınır, canlı metin motoru ve abonelik erişimi (ek süre dahil). `deviceId` istemcinin bildirdiği App Attest anahtar kimliğidir; yalnızca
 * gösterim içindir, hak toplantı başlatırken imzalı onayla yeniden denetlenir.
 */
export async function entitlements(db: D1Database, config: Config, userId: string, deviceId: string | null, now: Date): Promise<Entitlements> {
  const [subscription, plan, trial, deviceUsed, usage, engine]: [
    SubscriptionState | null,
    SubscriptionPlan | null,
    TrialState,
    number | null,
    MonthlyUsage,
    LiveEngine,
  ] = await Promise.all([
    subscriptionState(db, userId),
    subscriptionPlan(db, userId),
    userTrialState(db, userId),
    deviceId === null ? Promise.resolve(null) : deviceTrialMeetingsUsed(db, deviceId),
    monthlyUsage(db, userId, now),
    liveEngine(db, config),
  ]);
  const access: SubscriptionAccess = subscriptionAccess(subscription, now, config.pastDueGraceMs);
  const allowance: AccountTokenAllowance = await accountTokenAllowance(db, config, userId, access !== "none", now);
  const accountLeft: number = trialMeetingsLeft(trial, config, now);
  const trialEnd: number | null = access === "none" ? trialEndsAtMs(trial, config.trialDurationMs) : null;
  const deviceLeft: number | null = deviceUsed === null ? null : Math.max(0, config.trialMeetings - deviceUsed);
  return {
    userId,
    plan: access === "none" ? "trial" : "subscription",
    trialMeetingsTotal: config.trialMeetings,
    trialDays: config.trialDays,
    trialMeetingsLeft: deviceLeft === null ? accountLeft : Math.min(accountLeft, deviceLeft),
    accountTrialMeetingsLeft: accountLeft,
    trialEndsAt: trialEnd === null ? null : new Date(trialEnd).toISOString(),
    deviceTrialMeetingsLeft: deviceLeft,
    monthlyHoursUsed: hoursRoundedUp(usage.usedSeconds),
    monthlyHoursCap: config.monthlyCapSeconds / 3600,
    liveEngine: engine,
    accountTokensUsed: allowance.used,
    accountTokensCap: allowance.cap,
    accountTokensPeriod: allowance.period,
    accountTokensResetsAt: new Date(allowance.resetsAtMs).toISOString(),
    monthlyResetsAt: new Date(nextMonthStartMs(now)).toISOString(),
    meetingMaxMinutes:
      access === "none" ? config.trialMaxMeetingMinutes : subscriberMeetingMaxMinutes(config, config.monthlyCapSeconds - usage.usedSeconds),
    subscription:
      subscription === null
        ? null
        : {
            status: subscription.status,
            currentPeriodEnd: new Date(subscription.currentPeriodEnd).toISOString(),
            cancelAt: subscription.cancelAt === null ? null : new Date(subscription.cancelAt).toISOString(),
            access,
            graceEndsAt: access === "grace" ? new Date(graceEndsAtMs(subscription, config.pastDueGraceMs) ?? 0).toISOString() : null,
            plan,
          },
  };
}
