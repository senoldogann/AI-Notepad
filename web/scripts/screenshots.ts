// Görsel deneme: derlenmiş site (scripts/serve.ts) sunulurken tüm sayfaların 1440 ve 390 px açık ve koyu, 360 px açık tam sayfa
// görüntülerini alır; yatay taşmayı, konsol hatalarını ve CSP ihlallerini raporlar. Ayrıca ana sayfa gösteriminin
// birkaç karesini, tema düğmesini ve gösterimin ana iş parçacığı maliyetini (5 sn, Chrome başarım ölçüleri) denetler.
// Hesap ve yönetim sayfaları için tarayıcıya örnek bir oturum yazılır ve sunucu yanıtları aşağıdaki örnek verilerle
// karşılanır: bu yalnızca görünüm denetimidir; sunucuyla gerçek akış sunucunun kendi testlerindedir. Hesap sayfası her
// plan durumunda (deneme başlamadı, sürüyor, bitti; abonelik etkin, iptal edildi, ödeme bekliyor, bitti; ücretsiz erişim) çekilir; abonede davet
// kartı, denemede plan seçimi ve davet bağlantısıyla gelen kodun doğrulanması da çekilir. Sayfa sonundaki
// çekme katmanı (açık/koyu, masaüstü/telefon) ve gösterimin üç turdan sonra durup düğmesinin "baştan oynat"a döndüğü de
// denetlenir.
// Kullanım: node scripts/screenshots.ts <site adresi> <çıktı klasörü> <Chrome yolu>
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { type Browser, type BrowserContext, type CDPSession, type ConsoleMessage, type Page, type Route, chromium } from "playwright-core";
import { siteConfigs } from "../src/config.ts";

/** Ekran boyutu ve renk teması. */
interface Variant {
  readonly name: string;
  readonly width: number;
  readonly colorScheme: "light" | "dark";
}

/** Bir sayfadaki sorunlar. */
interface Finding {
  readonly shot: string;
  readonly problem: string;
}

/** Hesap sayfasının örnek plan durumları (`/v1/me` yanıtı bunlardan seçilir). */
type AccountState = "trial-new" | "trial-running" | "trial-ended" | "active" | "canceling" | "grace" | "ended" | "complimentary";

/**
 * Görüntülenecek sayfa; `ready` sayfanın hazır olduğunu gösteren seçici (Turnstile ağı hiç boşaltmaz). `account` hesap
 * sayfasının hangi durumla çekileceğidir (diğer sayfalarda null).
 */
interface Target {
  readonly name: string;
  readonly path: string;
  readonly ready: string;
  readonly signedIn: boolean;
  readonly account: AccountState | null;
}

const variants: readonly Variant[] = [
  { name: "1440-light", width: 1440, colorScheme: "light" },
  { name: "1440-dark", width: 1440, colorScheme: "dark" },
  { name: "390-light", width: 390, colorScheme: "light" },
  { name: "390-dark", width: 390, colorScheme: "dark" },
  { name: "360-light", width: 360, colorScheme: "light" },
];

const targets: readonly Target[] = [
  { name: "home", path: "/", ready: "main", signedIn: false, account: null },
  { name: "pricing", path: "/pricing", ready: "main", signedIn: false, account: null },
  { name: "download", path: "/download", ready: "main", signedIn: false, account: null },
  { name: "compare", path: "/compare", ready: "main", signedIn: false, account: null },
  { name: "vs-granola", path: "/vs/granola", ready: "main", signedIn: false, account: null },
  { name: "vs-otter", path: "/vs/otter", ready: "main", signedIn: false, account: null },
  { name: "mcp", path: "/mcp", ready: "main", signedIn: false, account: null },
  { name: "blog", path: "/blog", ready: "main", signedIn: false, account: null },
  { name: "blog-no-bot", path: "/blog/meeting-notes-on-mac-without-a-bot", ready: "main", signedIn: false, account: null },
  { name: "blog-task-list", path: "/blog/turn-a-meeting-into-a-task-list", ready: "main", signedIn: false, account: null },
  { name: "blog-recording", path: "/blog/record-teams-zoom-google-meet-on-mac", ready: "main", signedIn: false, account: null },
  { name: "signin", path: "/sign-in", ready: "#google-redirect-button:not(.hidden):enabled", signedIn: false, account: null },
  { name: "signin-app", path: "/sign-in?app=1&nonce=9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", ready: "main", signedIn: false, account: null },
  { name: "contact", path: "/contact", ready: "#contact-submit:not([disabled])", signedIn: false, account: null },
  { name: "privacy", path: "/privacy", ready: "main", signedIn: false, account: null },
  { name: "terms", path: "/terms", ready: "main", signedIn: false, account: null },
  { name: "invite", path: "/invite", ready: "main", signedIn: false, account: null },
  { name: "notfound", path: "/no-such-page", ready: "main", signedIn: false, account: null },
  { name: "account", path: "/account?payment=done", ready: "#referral-card:not(.hidden) #referral-stats:not(:empty)", signedIn: true, account: "active" },
  { name: "account-trial-new", path: "/account", ready: "#account-content:not(.hidden)", signedIn: true, account: "trial-new" },
  { name: "account-trial-running", path: "/account", ready: "#account-content:not(.hidden)", signedIn: true, account: "trial-running" },
  { name: "account-trial-ended", path: "/account", ready: "#account-content:not(.hidden)", signedIn: true, account: "trial-ended" },
  { name: "account-canceling", path: "/account", ready: "#account-content:not(.hidden)", signedIn: true, account: "canceling" },
  { name: "account-grace", path: "/account", ready: "#account-content:not(.hidden)", signedIn: true, account: "grace" },
  { name: "account-ended", path: "/account", ready: "#account-content:not(.hidden)", signedIn: true, account: "ended" },
  { name: "account-complimentary", path: "/account", ready: "#account-content:not(.hidden)", signedIn: true, account: "complimentary" },
  // Davet koduyla gelinir: kod saklanır (sonraki hesap sayfalarında da dolar), bu yüzden hesap sayfalarından sonra.
  { name: "account-invite", path: "/account?code=k7m2-qx9d&plan=monthly", ready: "#invite-status.invite__ok", signedIn: true, account: "trial-ended" },
  { name: "invite-code", path: "/invite?code=K7M2QX9D", ready: "#invite-code-box:not(.hidden)", signedIn: false, account: null },
  { name: "admin", path: "/admin", ready: "#kpi-mrr:not(:empty)", signedIn: true, account: null },
  { name: "admin-insights", path: "/admin#insights", ready: "#insights-funnel-rows tr", signedIn: true, account: null },
  { name: "admin-users", path: "/admin#users", ready: "#users-rows tr", signedIn: true, account: null },
  { name: "admin-user", path: "/admin#users", ready: "#users-rows tr", signedIn: true, account: null },
  { name: "admin-user-free", path: "/admin#users", ready: "#users-rows tr", signedIn: true, account: null },
  { name: "admin-user-grant", path: "/admin#users", ready: "#users-rows tr", signedIn: true, account: null },
  { name: "admin-operations", path: "/admin#operations", ready: "#ops-open-rows tr", signedIn: true, account: null },
  { name: "admin-inbox", path: "/admin#inbox", ready: "#inbox-list .inbox__item", signedIn: true, account: null },
];

/** Örnek kullanıcıların kimlikleri (liste, ayrıntı ve açık toplantılar aynı kimlikleri kullanır). */
const exampleUserIds: readonly string[] = [
  "3f2a9c1e-7b4d-4e8a-9c21-5d6e7f8a9b0c",
  "8c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f",
  "b7e6d5c4-3b2a-4190-8f7e-6d5c4b3a2918",
  "e1f2a3b4-c5d6-4e7f-8091-a2b3c4d5e6f7",
  // Ücretsiz tam erişimi olan hesap (Stripe'ta karşılığı yok).
  "c4d5e6f7-a8b9-4c0d-9e1f-2a3b4c5d6e7f",
];

/** Kullanıcı ayrıntısını açarken tıklanan liste satırı (1'den başlar) ve verme düğmesine basılıp basılmayacağı. */
const userDetailTargets: Readonly<Record<string, { readonly row: number; readonly grant: boolean }>> = {
  "admin-user": { row: 1, grant: false },
  "admin-user-free": { row: 5, grant: false },
  "admin-user-grant": { row: 2, grant: true },
};

/** Yerel derlemenin API adresi (istekler buraya gider ve örnek verilerle karşılanır). */
const apiBase: string = siteConfigs.local.apiBase;

/** Son 30 gün (`YYYY-MM-DD`, UTC). Saf fonksiyondur. */
function last30Days(now: Date): string[] {
  return Array.from({ length: 30 }, (_: unknown, index: number): string => new Date(now.getTime() - (29 - index) * 86_400_000).toISOString().slice(0, 10));
}

/** Hesap durumuna göre örnek `/v1/referral` yanıtı: ücretsiz erişimde ödül uygulanmaz. Saf fonksiyondur. */
function referralFixture(state: AccountState, now: Date): object {
  return {
    enabled: true,
    code: "K7M2QX9D",
    inviteUrl: "http://localhost:8788/invite?code=K7M2QX9D",
    joined: 3,
    rewarded: 1,
    pending: 1,
    nextRewardAt: new Date(now.getTime() + 24 * 86_400_000).toISOString(),
    complimentary: state === "complimentary",
    rewardsLeftThisYear: 11,
    rewardsPerYear: 12,
    rewardUsd: 5.99,
    holdDays: 30,
  };
}

/** Hesap durumuna göre örnek `/v1/me` yanıtı. Saf fonksiyondur. */
function meFixture(state: AccountState, now: Date): object {
  const at = (days: number): string => new Date(now.getTime() + days * 86_400_000).toISOString();
  const base = { userId: "usr_example", trialMeetingsTotal: 3, trialDays: 7, monthlyHoursCap: 10 };
  const subscription = (access: "active" | "grace", cancelAt: string | null): object => ({
    status: access === "grace" ? "past_due" : "active",
    plan: access === "grace" ? "monthly" : cancelAt === null ? "yearly" : "monthly",
    currentPeriodEnd: at(20),
    cancelAt,
    complimentary: false,
    access,
    graceEndsAt: access === "grace" ? at(5) : null,
  });
  const states: Readonly<Record<AccountState, object>> = {
    "trial-new": { ...base, plan: "trial", trialMeetingsLeft: 3, trialEndsAt: null, monthlyHoursUsed: 0, subscription: null },
    "trial-running": { ...base, plan: "trial", trialMeetingsLeft: 2, trialEndsAt: at(5), monthlyHoursUsed: 0.8, subscription: null },
    "trial-ended": { ...base, plan: "trial", trialMeetingsLeft: 0, trialEndsAt: at(-1), monthlyHoursUsed: 2.1, subscription: null },
    active: { ...base, plan: "subscription", trialMeetingsLeft: 0, trialEndsAt: null, monthlyHoursUsed: 3.4, subscription: subscription("active", null) },
    canceling: { ...base, plan: "subscription", trialMeetingsLeft: 0, trialEndsAt: null, monthlyHoursUsed: 7.6, subscription: subscription("active", at(20)) },
    grace: { ...base, plan: "subscription", trialMeetingsLeft: 0, trialEndsAt: null, monthlyHoursUsed: 1.2, subscription: subscription("grace", null) },
    // Aboneliği bitmiş, denemesi de kalmamış eski abone: "plan yok", Abone ol ve (Stripe müşterisi olduğu için) Yönet.
    ended: {
      ...base,
      plan: "trial",
      trialMeetingsLeft: 0,
      trialEndsAt: at(-40),
      monthlyHoursUsed: 0,
      subscription: { status: "canceled", plan: "monthly", currentPeriodEnd: at(-3), cancelAt: at(-3), complimentary: false, access: "none", graceEndsAt: null },
    },
    complimentary: {
      ...base,
      plan: "subscription",
      trialMeetingsLeft: 0,
      trialEndsAt: null,
      monthlyHoursUsed: 2.3,
      subscription: { status: "active", plan: "monthly", currentPeriodEnd: at(36_500), cancelAt: null, complimentary: true, access: "active", graceEndsAt: null },
    },
  };
  return states[state];
}

/** Örnek yanıtlar: yol (sorgusuz) → gövde. */
function fixtures(now: Date): Readonly<Record<string, object>> {
  const days: string[] = last30Days(now);
  const wave = (index: number, scale: number): number => Math.max(0, Math.round((Math.sin(index / 3) + 1.3) * scale + (index % 4)));
  const at = (days: number): string => new Date(now.getTime() + days * 86_400_000).toISOString();
  // Ücretsiz erişimin aboneliği: uygulamaya aylık ve etkin görünür, faturalanmaz; bitiş tarihi yok (dönem sonu 100 yıl).
  const freeSubscription = (updatedAt: string): object => ({
    status: "active",
    plan: "monthly",
    access: "active",
    complimentary: true,
    currentPeriodEnd: at(36_500),
    cancelAt: null,
    pastDueSince: null,
    graceEndsAt: null,
    updatedAt,
  });
  const subscriptions: readonly (object | null)[] = [
    { status: "active", plan: "yearly", access: "active", complimentary: false, currentPeriodEnd: at(20), cancelAt: null, pastDueSince: null, graceEndsAt: null, updatedAt: at(-10) },
    null,
    { status: "past_due", plan: "monthly", access: "grace", complimentary: false, currentPeriodEnd: at(28), cancelAt: null, pastDueSince: at(-2), graceEndsAt: at(5), updatedAt: at(-2) },
    null,
    freeSubscription(at(-3)),
  ];
  const userItems: readonly object[] = exampleUserIds.map((id: string, index: number): object => ({
    id,
    provider: index % 2 === 0 ? "apple" : "google",
    createdAt: now.getTime() - (index + 1) * 5 * 86_400_000,
    plan: ["subscription", "trial", "subscription", "free", "subscription"][index] ?? "free",
    subscription: subscriptions[index] ?? null,
    trial: index >= 3 ? { used: 0, left: 3, startedAt: null, endsAt: null } : { used: index === 1 ? 1 : 3, left: index === 1 ? 2 : 0, startedAt: at(-12), endsAt: at(-5) },
    meetingsTotal: [42, 1, 17, 0, 23][index] ?? 0,
    hoursThisMonth: [8.25, 0.5, 3.1, 0, 4.4][index] ?? 0,
    lastActiveAt: index === 3 ? null : now.getTime() - (index + 1) * 3_600_000,
    failedMeetings: index === 1 ? 1 : index === 2 ? 3 : 0,
    lastFailureCode: index === 1 ? "upstream_rejected:elevenlabs" : index === 2 ? "meeting_budget_exhausted" : null,
  }));
  // Yalın ayrıntı: tek toplantı, rapor ve iptal yok.
  const plainUserDetail = (user: object, timeline: readonly object[]): object => ({
    user,
    trialDeviceVerifiedAt: null,
    stripeCustomerId: null,
    cancellation: null,
    usage: { usedHours: 1.5, capHours: 10, audioHours: 1.4, tokens: 420_000, tokenCap: 6_500_000, accountTokens: 35_000, accountTokenCap: 1_500_000 },
    meetings: [
      { id: "m7", kind: "subscription", state: "ended", startedAt: now.getTime() - 7_200_000, durationMinutes: 44, deferred: false, reprocessCount: 0, audioMinutes: 43.5, tokensUsed: 120_000, tokenBudget: 900_000, attested: true, deepgram: true, noteCompleted: true, failureCount: 0, lastFailureCode: null, lastFailureAt: null },
    ],
    reports: [],
    timeline,
  });
  return {
    "/v1/me": meFixture("active", now),
    "/v1/referral": referralFixture("active", now),
    "/v1/referral/validate": { code: "K7M2QX9D" },
    "/v1/download/mac/version": { version: "0.1.5" },
    "/v1/admin/stats": {
      generatedAt: now.toISOString(),
      downloads: { total: 1284, last30Days: days.map((day: string, index: number) => ({ day, count: wave(index, 9) })) },
      users: { total: 412, newLast30Days: days.map((day: string, index: number) => ({ day, count: wave(index + 5, 3) })), byProvider: { apple: 251, google: 161 } },
      trials: { activeTrialUsers: 96, exhaustedTrialUsers: 188 },
      subscriptions: { active: 71, grace: 2, ending: 5, canceledTotal: 14, monthly: 46, yearly: 18, mrrUsd: 349.04, complimentary: 3, freeInviteMonth: 2 },
      referrals: { joined: 9, pending: 3, granted: 5, voided: 1 },
      meetings: { last30Days: days.map((day: string, index: number) => ({ day, trial: wave(index, 4), subscription: wave(index + 2, 7) })), hoursThisMonth: 213.5 },
      spend: { todayUsd: 6.42, ceilingUsd: 25, last30Days: days.map((day: string, index: number) => ({ day, usd: wave(index + 1, 2.4) + 0.5 })) },
      tokens: { thisMonth: 48_210_000 },
      reports: { openFeedback: 3, openCrash: 1, openContact: 2 },
      stripe: { mode: "test" },
      // Kapasite eşiğin üstünde: kutunun uyarı görünümü de çekilir.
      elevenLabs: { usedHours: 41.5, capHours: 50, percent: 83 },
      deepgram: { estimatedUsd: 61.2, budgetUsd: 200, percent: 30.6, streamMinutes: 14_210 },
      conversion: { trialStarted: 284, converted: 79, startedLast30Days: 61, convertedLast30Days: 17, subscribedWithoutTrial: 6 },
      churn: { canceledLast30Days: 4, pastDue: 2, unpaid: 0, duplicateSubscriptions: 1 },
      billing: { refundsLast30Days: 1, disputesLast30Days: 0, paymentFailuresLast30Days: 3 },
      usage: {
        meetingsThisMonth: 812,
        deferredThisMonth: 37,
        reprocessedThisMonth: 12,
        openMeetings: 4,
        audioHoursThisMonth: 198.4,
        accountTokensThisMonth: 3_120_000,
        monthlyTokenCapPerUser: 6_500_000,
        monthlyAccountTokenCapPerUser: 1_500_000,
        usersNearTokenCap: 0,
      },
      trialRefusals: {
        last30Days: { device_used: 9, exhausted: 41, expired: 12, ip_daily_limit: 3 },
        today: { device_used: 1, exhausted: 2, expired: 0, ip_daily_limit: 0 },
      },
    },
    "/v1/admin/users": {
      items: userItems,
      nextCursor: "1760529600000:e1f2a3b4-c5d6-4e7f-8091-a2b3c4d5e6f7",
    },
    // Ücretsiz erişimli hesap ("kaldır" düğmesi) ve denemedeki hesap ("ver" düğmesi; basınca ücretsiz erişimli döner).
    [`/v1/admin/users/${exampleUserIds[4] ?? ""}`]: plainUserDetail(userItems[4] ?? {}, [
      { kind: "subscription_period_end", at: at(36_500), detail: "active" },
      { kind: "subscription_updated", at: at(-3), detail: "active" },
      { kind: "account_created", at: at(-25), detail: null },
    ]),
    [`/v1/admin/users/${exampleUserIds[1] ?? ""}`]: plainUserDetail(userItems[1] ?? {}, [
      { kind: "trial_ends", at: at(-5), detail: null },
      { kind: "trial_started", at: at(-12), detail: null },
      { kind: "account_created", at: at(-10), detail: null },
    ]),
    [`/v1/admin/users/${exampleUserIds[1] ?? ""}/complimentary`]: plainUserDetail(
      { ...(userItems[1] ?? {}), plan: "subscription", subscription: freeSubscription(at(0)) },
      [
        { kind: "subscription_period_end", at: at(36_500), detail: "active" },
        { kind: "subscription_updated", at: at(0), detail: "active" },
        { kind: "trial_ends", at: at(-5), detail: null },
        { kind: "trial_started", at: at(-12), detail: null },
        { kind: "account_created", at: at(-10), detail: null },
      ],
    ),
    [`/v1/admin/users/${exampleUserIds[0] ?? ""}`]: {
      user: {
        id: exampleUserIds[0],
        provider: "apple",
        createdAt: now.getTime() - 5 * 86_400_000,
        plan: "subscription",
        subscription: { status: "active", plan: "yearly", access: "active", complimentary: false, currentPeriodEnd: at(20), cancelAt: at(20), pastDueSince: null, graceEndsAt: null, updatedAt: at(-1) },
        trial: { used: 3, left: 0, startedAt: at(-12), endsAt: at(-5) },
        meetingsTotal: 42,
        hoursThisMonth: 8.25,
        lastActiveAt: now.getTime() - 3_600_000,
        failedMeetings: 1,
        lastFailureCode: "upstream_unavailable:anthropic",
      },
      trialDeviceVerifiedAt: at(-12),
      stripeCustomerId: "cus_ExampleCustomer01",
      cancellation: { at: at(-1), reason: "cancellation_requested", feedback: "too_expensive", comment: "Great notes, but I only have a few meetings a month." },
      usage: { usedHours: 8.25, capHours: 10, audioHours: 7.9, tokens: 2_310_000, tokenCap: 6_500_000, accountTokens: 410_000, accountTokenCap: 1_500_000 },
      meetings: [
        { id: "m1", kind: "subscription", state: "open", startedAt: now.getTime() - 1_800_000, durationMinutes: 30, deferred: false, reprocessCount: 0, audioMinutes: 28.5, tokensUsed: 41_000, tokenBudget: 900_000, attested: true, deepgram: true, noteCompleted: false, failureCount: 0, lastFailureCode: null, lastFailureAt: null },
        { id: "m2", kind: "subscription", state: "ended", startedAt: now.getTime() - 86_400_000, durationMinutes: 52, deferred: true, reprocessCount: 1, audioMinutes: 51.2, tokensUsed: 310_000, tokenBudget: 900_000, attested: true, deepgram: false, noteCompleted: true, failureCount: 2, lastFailureCode: "upstream_unavailable:anthropic", lastFailureAt: now.getTime() - 86_000_000 },
        { id: "m3", kind: "trial", state: "expired", startedAt: now.getTime() - 9 * 86_400_000, durationMinutes: 90, deferred: false, reprocessCount: 0, audioMinutes: 0, tokensUsed: 0, tokenBudget: 400_000, attested: false, deepgram: false, noteCompleted: false, failureCount: 1, lastFailureCode: "meeting_not_active", lastFailureAt: now.getTime() - 9 * 86_000_000 },
      ],
      reports: [{ id: "rep_1", kind: "feedback", status: "open", createdAt: now.getTime() - 3_600_000, summary: "Would love a keyboard shortcut to start recording" }],
      timeline: [
        { kind: "subscription_period_end", at: at(20), detail: "active" },
        { kind: "subscription_cancel_at", at: at(20), detail: null },
        { kind: "subscription_updated", at: at(-1), detail: "active" },
        { kind: "trial_ends", at: at(-5), detail: null },
        { kind: "trial_device_verified", at: at(-12), detail: null },
        { kind: "trial_started", at: at(-12), detail: null },
        { kind: "account_created", at: at(-12), detail: null },
      ],
    },
    "/v1/admin/insights": {
      generatedAt: now.toISOString(),
      problems: {
        // Son 7 günde deneme tavanına takılan istek var: satırın uyarı görünümü de çekilir.
        last7Days: {
          trialCapacityReached: 14,
          spendCeilingReached: 0,
          refusals: [
            { detail: "trial_capacity_reached", count: 14 },
            { detail: "trial_exhausted", count: 9 },
            { detail: "meeting_budget_exhausted", count: 2 },
          ],
          providerErrors: [{ detail: "elevenlabs", count: 3 }],
          serverErrors: [
            { detail: "trial_capacity_reached", count: 14 },
            { detail: "upstream_unavailable", count: 3 },
          ],
          serverErrorsTotal: 17,
        },
        last30Days: {
          trialCapacityReached: 52,
          spendCeilingReached: 4,
          refusals: [
            { detail: "trial_capacity_reached", count: 52 },
            { detail: "trial_exhausted", count: 41 },
            { detail: "trial_device_used", count: 9 },
            { detail: "spend_ceiling_reached", count: 4 },
            { detail: "meeting_budget_exhausted", count: 6 },
            { detail: "deepgram_unavailable", count: 2 },
          ],
          providerErrors: [
            { detail: "elevenlabs", count: 7 },
            { detail: "anthropic", count: 5 },
            { detail: "devicecheck", count: 1 },
          ],
          serverErrors: [
            { detail: "trial_capacity_reached", count: 52 },
            { detail: "upstream_unavailable", count: 12 },
            { detail: "spend_ceiling_reached", count: 4 },
            { detail: "internal_error", count: 1 },
          ],
          serverErrorsTotal: 69,
        },
      },
      funnel: {
        days: 30,
        steps: [
          { step: "downloads", count: 412 },
          { step: "accounts", count: 168 },
          { step: "first_meeting", count: 121 },
          { step: "first_note", count: 104 },
          { step: "three_meetings", count: 58 },
          { step: "subscribed", count: 17 },
          { step: "canceled", count: 3 },
        ],
      },
      downloads: {
        total: 412,
        bySource: [
          { detail: "home-hero", count: 231 },
          { detail: "download-page", count: 104 },
          { detail: "home-cta", count: 52 },
          { detail: "direct", count: 19 },
          { detail: "account", count: 6 },
        ],
        byReferrerHost: [
          { detail: "gistsmith.com", count: 371 },
          { detail: "", count: 25 },
          { detail: "producthunt.com", count: 11 },
          { detail: "news.ycombinator.com", count: 5 },
        ],
      },
      cancellations: {
        total: 5,
        byFeedback: [
          { detail: "too_expensive", count: 2 },
          { detail: "unused", count: 1 },
          { detail: "missing_features", count: 1 },
          { detail: "", count: 1 },
        ],
        byReason: [
          { detail: "cancellation_requested", count: 4 },
          { detail: "payment_failed", count: 1 },
        ],
        recent: [
          { userId: exampleUserIds[0], at: at(-1), reason: "cancellation_requested", feedback: "too_expensive", comment: "Great notes, but I only have a few meetings a month." },
          { userId: exampleUserIds[2], at: at(-6), reason: "cancellation_requested", feedback: "missing_features", comment: null },
        ],
      },
    },
    "/v1/admin/operations": {
      generatedAt: now.toISOString(),
      meetings: {
        open: 2,
        openItems: [
          { id: "m1", userId: exampleUserIds[0], kind: "subscription", startedAt: at(-0.01), maxEndsAt: at(0.15), deferred: false, deepgram: true },
          { id: "m9", userId: exampleUserIds[1], kind: "trial", startedAt: at(-0.02), maxEndsAt: at(0.04), deferred: true, deepgram: false },
        ],
        unendedLast7Days: 3,
      },
      // Bir günden eski bekleyen ayırma: kutunun uyarı görünümü de çekilir.
      reservations: { active: 5, expired: 2, oldestExpiredAt: at(-1.5) },
      deepgram: { unsettled: 2, stale: 0 },
      stripe: {
        lastEventAt: at(-0.1),
        eventsLast24Hours: 7,
        last7DaysByType: [
          { type: "invoice.paid", count: 18 },
          { type: "customer.subscription.updated", count: 11 },
          { type: "invoice.payment_failed", count: 2 },
        ],
      },
      reports: {
        last7Days: { feedback: 3, crash: 1, contact: 2 },
        recentCrashes: [{ id: "rep_3", status: "open", createdAt: now.getTime() - 7_200_000, appVersion: "0.1.4", os: "macOS 26.1", summary: "EXC_BAD_ACCESS · SIGSEGV" }],
      },
    },
    "/v1/admin/reports": {
      items: [
        { id: "rep_1", kind: "feedback", status: "open", createdAt: now.getTime() - 3_600_000, userId: "usr_example", email: "mia@example.com", appVersion: "0.2.0", os: "macOS 26.1", summary: "Would love a keyboard shortcut to start recording" },
        { id: "rep_2", kind: "feedback", status: "open", createdAt: now.getTime() - 86_400_000, userId: null, email: null, appVersion: "0.2.0", os: "macOS 26.0", summary: "Speaker names were swapped in a long meeting" },
      ],
      nextBefore: null,
    },
    "/v1/admin/reports/rep_1": {
      id: "rep_1",
      kind: "feedback",
      status: "open",
      createdAt: now.getTime() - 3_600_000,
      userId: "usr_example",
      email: "mia@example.com",
      appVersion: "0.2.0",
      os: "macOS 26.1",
      message: "Would love a keyboard shortcut to start recording.\nOtherwise the notes are spot on — thank you!",
      payload: null,
    },
  };
}

/** Komut satırı bağımsız değişkeni; yoksa hata. */
function argument(index: number, name: string): string {
  const value: string | undefined = process.argv[index];
  if (value === undefined || value === "") {
    throw new Error(`Eksik bağımsız değişken: ${name}. Kullanım: node scripts/screenshots.ts <site> <çıktı> <chrome>`);
  }
  return value;
}

/** Beklenen konsol hataları: 404 sayfasının kendisi 404 durumuyla gelir; yönetici olmayanın yönetim isteği 403 alır. */
function isExpectedConsoleError(message: ConsoleMessage, shot: string): boolean {
  const notFoundDocument: boolean = shot.startsWith("notfound") && message.text().includes("status of 404");
  const adminForbidden: boolean = shot.startsWith("admin-forbidden") && message.text().includes("status of 403");
  return notFoundDocument || adminForbidden;
}

/** Sayfanın konsol hatalarını ve yakalanmamış hatalarını toplar. */
function collectErrors(page: Page, shot: () => string, findings: Finding[]): void {
  page.on("console", (message: ConsoleMessage): void => {
    if (message.type() === "error" && !isExpectedConsoleError(message, shot())) {
      findings.push({ shot: shot(), problem: `console: ${message.text().slice(0, 300)} @ ${message.location().url}` });
    }
  });
  page.on("pageerror", (error: Error): void => {
    findings.push({ shot: shot(), problem: `pageerror: ${error.message}` });
  });
}

/** API isteklerini örnek yanıtlarla karşılar; tanımsız yol 404 döner ve sorun olarak kaydedilir. */
async function routeApi(context: BrowserContext, findings: Finding[]): Promise<void> {
  const bodies: Readonly<Record<string, object>> = fixtures(new Date());
  await context.route(`${apiBase}/**`, async (route: Route): Promise<void> => {
    const url: URL = new URL(route.request().url());
    const cors: Record<string, string> = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type", "access-control-allow-methods": "GET, POST, DELETE" };
    if (route.request().method() === "OPTIONS") {
      await route.fulfill({ status: 204, headers: cors });
      return;
    }
    const body: object | undefined = bodies[url.pathname];
    if (body === undefined) {
      findings.push({ shot: "api", problem: `örnek yanıt yok: ${route.request().method()} ${url.pathname}` });
      await route.fulfill({ status: 404, headers: cors, contentType: "application/json", body: JSON.stringify({ error: { code: "not_found", message: "örnek yok" } }) });
      return;
    }
    await route.fulfill({ status: 200, headers: cors, contentType: "application/json", body: JSON.stringify(body) });
  });
}

/**
 * Bu sayfada `/v1/me` ve `/v1/referral` isteklerini verilen hesap durumunun örnek yanıtlarıyla karşılar (bağlamın
 * yönlendirmesinden önce gelir).
 */
async function routeAccount(page: Page, state: AccountState): Promise<void> {
  const now: Date = new Date();
  const bodies: Readonly<Record<string, object>> = { "/v1/me": meFixture(state, now), "/v1/referral": referralFixture(state, now) };
  for (const [path, body] of Object.entries(bodies)) {
    await page.route(`${apiBase}${path}`, async (route: Route): Promise<void> => {
      const cors: Record<string, string> = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type", "access-control-allow-methods": "GET, POST, DELETE" };
      if (route.request().method() === "OPTIONS") {
        await route.fulfill({ status: 204, headers: cors });
        return;
      }
      await route.fulfill({ status: 200, headers: cors, contentType: "application/json", body: JSON.stringify(body) });
    });
  }
}

/** Yatay taşmayı denetler: belge genişliği ve ekran dışına taşan öğeler. */
async function checkOverflow(page: Page, shot: string, findings: Finding[]): Promise<void> {
  const overflow: { readonly scrollWidth: number; readonly viewport: number; readonly offenders: string[] } = await page.evaluate(() => {
    const viewport: number = document.documentElement.clientWidth;
    const offenders: string[] = [];
    for (const element of Array.from(document.querySelectorAll("body *"))) {
      const rect: DOMRect = element.getBoundingClientRect();
      if (rect.width > 0 && (rect.right > viewport + 1 || rect.left < -1) && getComputedStyle(element).position !== "fixed") {
        const insideClip: boolean = element.closest(".film, .faq, dialog, .visually-hidden, .skip-link, .table-wrap, .table-scroll, .detail__payload") !== null;
        if (!insideClip) {
          offenders.push(`${element.tagName.toLowerCase()}.${String(element.className).split(" ").join(".")} (${Math.round(rect.left)}–${Math.round(rect.right)})`);
        }
      }
    }
    return { scrollWidth: document.documentElement.scrollWidth, viewport, offenders: offenders.slice(0, 5) };
  });
  if (overflow.scrollWidth > overflow.viewport) {
    findings.push({ shot, problem: `yatay kaydırma: ${overflow.scrollWidth} > ${overflow.viewport}` });
  }
  for (const offender of overflow.offenders) {
    findings.push({ shot, problem: `ekran dışına taşan öğe: ${offender}` });
  }
}

/** Yazı tipinin yüklenmesini bekler, taşmayı denetler ve tam sayfa görüntüsünü kaydeder. */
async function capture(page: Page, outDir: string, shot: string, findings: Finding[]): Promise<void> {
  await page.evaluate(async (): Promise<void> => {
    await document.fonts.ready;
    // Tam sayfa görüntüde ekranın altındaki tembel yüklenen görseller de görünsün: hepsi yüklenip çözülür.
    const images: HTMLImageElement[] = Array.from(document.images);
    for (const image of images) {
      image.loading = "eager";
    }
    await Promise.all(images.map((image: HTMLImageElement): Promise<void> => image.decode()));
  });
  await checkOverflow(page, shot, findings);
  await page.screenshot({ path: join(outDir, `${shot}.png`), fullPage: true });
}

/** Yeni bağlam: hareket azaltılmış (gösterim son hâlinde, kaydırmaya bağlı belirme içeriği gizlemez). */
async function newContext(browser: Browser, variant: Variant, reducedMotion: "reduce" | "no-preference"): Promise<BrowserContext> {
  return browser.newContext({
    viewport: { width: variant.width, height: 900 },
    deviceScaleFactor: variant.width < 600 ? 2 : 1,
    colorScheme: variant.colorScheme,
    reducedMotion,
    locale: "en-GB",
  });
}

/** Örnek oturumu sekmeye yazar (hesap ve yönetim sayfaları oturum ister). */
async function signIn(page: Page): Promise<void> {
  await page.addInitScript((): void => {
    sessionStorage.setItem("gistsmith.session", JSON.stringify({ accessToken: "example-access", refreshToken: "example-refresh", accessExpiresAt: Date.now() + 3_600_000 }));
  });
}

/** Tüm sayfaların görüntüleri. */
async function capturePages(browser: Browser, base: string, outDir: string, findings: Finding[]): Promise<void> {
  for (const variant of variants) {
    const context: BrowserContext = await newContext(browser, variant, "reduce");
    await routeApi(context, findings);
    for (const target of targets) {
      const shot: string = `${target.name}-${variant.name}`;
      const page: Page = await context.newPage();
      collectErrors(page, (): string => shot, findings);
      if (target.signedIn) {
        await signIn(page);
      }
      if (target.account !== null) {
        await routeAccount(page, target.account);
      }
      await page.goto(`${base}${target.path}`, { waitUntil: "load" });
      await page.waitForSelector(target.ready, { timeout: 20_000 });
      if (target.name === "admin-inbox") {
        await page.click("#inbox-list .inbox__item");
        await page.waitForSelector("#detail-body:not(.hidden)");
      }
      const userDetail: { readonly row: number; readonly grant: boolean } | undefined = userDetailTargets[target.name];
      if (userDetail !== undefined) {
        await page.click(`#users-rows tr:nth-child(${userDetail.row}) .id-button`);
        await page.waitForSelector("#user-detail-view:not(.hidden) #user-meetings tr");
      }
      // Ayrıntı görünür alana kaydırılır; tam sayfa görüntüde yapışkan üst çubuk ortada kalmasın.
      await page.evaluate((): void => window.scrollTo(0, 0));
      await capture(page, outDir, shot, findings);
      // "Ücretsiz erişim ver" düğmesine basılır: ayrıntı sunucunun döndürdüğü ücretsiz erişimli hâliyle yeniden çizilir.
      if (userDetail !== undefined && userDetail.grant) {
        await page.click('#user-complimentary[data-next="grant"]');
        await page.waitForSelector('#user-complimentary[data-next="remove"]:enabled');
        await page.evaluate((): void => window.scrollTo(0, 0));
        await capture(page, outDir, `${shot}-granted`, findings);
      }
      // İçgörüler görünümü kabuğun içinde kayar: alt kartlar (indirme kaynakları, iptal nedenleri) ayrı bir görüntüde.
      if (target.name === "admin-insights") {
        await page.evaluate((): void => document.querySelector(".console__main")?.scrollTo(0, 100_000));
        await capture(page, outDir, `${shot}-bottom`, findings);
      }
      await page.close();
    }
    await context.close();
  }
}

/** Ana sayfa gösteriminin kareleri (animasyon zamanı elle ayarlanır) ve 5 sn'lik ana iş parçacığı ölçüsü. */
async function captureDemo(browser: Browser, base: string, outDir: string, findings: Finding[]): Promise<void> {
  for (const variant of [variants[0], variants[2]]) {
    if (variant === undefined) {
      continue;
    }
    const context: BrowserContext = await newContext(browser, variant, "no-preference");
    const page: Page = await context.newPage();
    const shot: string = `demo-${variant.name}`;
    collectErrors(page, (): string => shot, findings);
    await page.goto(`${base}/`, { waitUntil: "load" });
    const demo = page.locator("#hero-demo");
    await demo.scrollIntoViewIfNeeded();
    for (const seconds of [3, 7.5, 11, 15]) {
      await page.evaluate((ms: number): void => {
        for (const animation of document.getAnimations()) {
          const timing = animation.effect?.getComputedTiming();
          if (timing !== undefined && timing.duration === 18_000) {
            animation.currentTime = ms;
          }
        }
      }, seconds * 1000);
      await page.waitForTimeout(80);
      await demo.screenshot({ path: join(outDir, `${shot}-${String(seconds).replace(".", "_")}s.png`) });
    }
    if (variant.width === 1440) {
      const client: CDPSession = await context.newCDPSession(page);
      await client.send("Performance.enable");
      const before = await client.send("Performance.getMetrics");
      await page.waitForTimeout(5000);
      const after = await client.send("Performance.getMetrics");
      const metric = (metrics: { metrics: { name: string; value: number }[] }, name: string): number => metrics.metrics.find((item): boolean => item.name === name)?.value ?? 0;
      const delta = (name: string): number => Math.round((metric(after, name) - metric(before, name)) * 1000) / 1000;
      console.log("demo_main_thread_5s", {
        taskSeconds: delta("TaskDuration"),
        scriptSeconds: delta("ScriptDuration"),
        styleSeconds: delta("RecalcStyleDuration"),
        layoutSeconds: delta("LayoutDuration"),
        layouts: delta("LayoutCount"),
        styleRecalcs: delta("RecalcStyleCount"),
      });
    }
    await context.close();
  }
}

/**
 * Gösterimin sonu: duraklat düğmesi "oynat"a döner; animasyonlar üçüncü turun sonuna sarılınca gösterim bitmiş notta
 * durmalı ve düğme "baştan oynat" olmalı; basınca yeniden oynamalı. Bitmiş hâlin görüntüsü kaydedilir.
 */
async function checkDemoEnd(browser: Browser, base: string, outDir: string, findings: Finding[]): Promise<void> {
  const variant: Variant = { name: "1440-light", width: 1440, colorScheme: "light" };
  const context: BrowserContext = await newContext(browser, variant, "no-preference");
  const page: Page = await context.newPage();
  collectErrors(page, (): string => "demo-end", findings);
  await page.goto(`${base}/`, { waitUntil: "load" });
  const toggle = page.locator("#hero-demo-toggle");
  await toggle.waitFor({ state: "visible" });
  await toggle.click();
  const pausedLabel: string | null = await toggle.getAttribute("aria-label");
  await toggle.click();
  await page.evaluate((): void => {
    for (const animation of document.getAnimations()) {
      const timing = animation.effect?.getComputedTiming();
      if (timing !== undefined && timing.duration === 18_000 && typeof timing.endTime === "number") {
        animation.currentTime = timing.endTime - 50;
      }
    }
  });
  await page.waitForTimeout(500);
  const state: { readonly finished: boolean; readonly label: string | null } = await page.evaluate(() => ({
    finished: document.getElementById("hero-demo")?.hasAttribute("data-finished") ?? false,
    label: document.getElementById("hero-demo-toggle")?.getAttribute("aria-label") ?? null,
  }));
  if (pausedLabel !== "Play the demo" || !state.finished || state.label !== "Replay the demo") {
    findings.push({ shot: "demo-end", problem: `duraklatma ya da bitiş beklenen gibi değil: ${JSON.stringify({ pausedLabel, ...state })}` });
  }
  await page.locator(".demo-frame").screenshot({ path: join(outDir, "demo-finished-1440-light.png") });
  await toggle.click();
  const replaying: boolean = await page.evaluate((): boolean => document.getElementById("hero-demo")?.hasAttribute("data-finished") === false);
  if (!replaying) {
    findings.push({ shot: "demo-end", problem: "baştan oynat çalışmadı" });
  }
  await context.close();
}

/** Sayfa sonundaki çekme: en alta inilir, tekerlek olayları sürerken görünüm çekilir; üst çubuk yerinde kalmalı. */
async function capturePullReveal(browser: Browser, base: string, outDir: string, findings: Finding[]): Promise<void> {
  for (const variant of variants.slice(0, 4)) {
    const context: BrowserContext = await newContext(browser, variant, "no-preference");
    const page: Page = await context.newPage();
    const shot: string = `pull-${variant.name}`;
    collectErrors(page, (): string => shot, findings);
    await page.goto(`${base}/pricing`, { waitUntil: "load" });
    await page.evaluate((): void => window.scrollTo({ top: document.documentElement.scrollHeight, behavior: "instant" }));
    await page.waitForTimeout(200);
    await page.evaluate((): void => {
      const send = (): void => {
        document.body.dispatchEvent(new WheelEvent("wheel", { deltaY: 40, deltaMode: 0, bubbles: true }));
      };
      send();
      window.setInterval(send, 40);
    });
    await page.waitForTimeout(900);
    const probe: { readonly headerTop: number; readonly armed: boolean } = await page.evaluate(() => ({
      headerTop: document.getElementById("site-header")?.getBoundingClientRect().top ?? -1,
      armed: document.documentElement.classList.contains("pull-armed"),
    }));
    if (Math.abs(probe.headerTop) > 1 || !probe.armed) {
      findings.push({ shot, problem: `çekmede üst çubuk kaydı ya da esneme kapanmadı: ${JSON.stringify(probe)}` });
    }
    await page.screenshot({ path: join(outDir, `${shot}.png`) });
    await context.close();
  }
}

/**
 * Yönetim adresi yöneticiye açık değilse panel belli olmaz: oturumsuz ve sunucu 403 dönerken standart "sayfa bulunamadı"
 * görünümü gelmeli, panel öğeleri sayfada olmamalı ve sekme başlığı panelin adını taşımamalı.
 */
async function checkAdminHidden(browser: Browser, base: string, outDir: string, findings: Finding[]): Promise<void> {
  const cases: readonly { readonly name: string; readonly signedIn: boolean }[] = [
    { name: "admin-signed-out", signedIn: false },
    { name: "admin-forbidden", signedIn: true },
  ];
  for (const variant of [variants[0], variants[3]]) {
    if (variant === undefined) {
      continue;
    }
    for (const item of cases) {
      const shot: string = `${item.name}-${variant.name}`;
      const context: BrowserContext = await newContext(browser, variant, "reduce");
      await context.route(`${apiBase}/**`, async (route: Route): Promise<void> => {
        const cors: Record<string, string> = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type", "access-control-allow-methods": "GET, POST, DELETE" };
        if (route.request().method() === "OPTIONS") {
          await route.fulfill({ status: 204, headers: cors });
          return;
        }
        await route.fulfill({ status: 403, headers: cors, contentType: "application/json", body: JSON.stringify({ error: { code: "forbidden", message: "yönetici değil", identity: "google:example" } }) });
      });
      const page: Page = await context.newPage();
      collectErrors(page, (): string => shot, findings);
      if (item.signedIn) {
        await signIn(page);
      }
      await page.goto(`${base}/admin`, { waitUntil: "load" });
      await page.waitForSelector("#admin-not-found:not([hidden])", { timeout: 10_000 });
      const state: { readonly title: string; readonly panel: boolean; readonly text: string } = await page.evaluate(() => ({
        title: document.title,
        panel: document.getElementById("admin") !== null || document.getElementById("admin-content") !== null,
        text: document.body.innerText,
      }));
      if (state.panel || state.title.includes("Dashboard") || state.text.includes("Dashboard") || state.text.includes("google:example")) {
        findings.push({ shot, problem: `panel belli oluyor: ${JSON.stringify({ title: state.title, panel: state.panel })}` });
      }
      await page.screenshot({ path: join(outDir, `${shot}.png`) });
      await context.close();
    }
  }
}

/** Tema düğmesi: tıklanınca tema değişir, seçim yeniden yüklemede kalır. */
async function checkThemeToggle(browser: Browser, base: string, outDir: string, findings: Finding[]): Promise<void> {
  const variant: Variant = { name: "1440-light", width: 1440, colorScheme: "light" };
  const context: BrowserContext = await newContext(browser, variant, "reduce");
  const page: Page = await context.newPage();
  collectErrors(page, (): string => "theme-toggle", findings);
  await page.goto(`${base}/pricing`, { waitUntil: "load" });
  await page.click("[data-theme-toggle]");
  await page.reload({ waitUntil: "load" });
  const state: { readonly theme: string | undefined; readonly pressed: string | null } = await page.evaluate(() => ({
    theme: document.documentElement.dataset["theme"],
    pressed: document.querySelector("[data-theme-toggle]")?.getAttribute("aria-pressed") ?? null,
  }));
  if (state.theme !== "dark" || state.pressed !== "true") {
    findings.push({ shot: "theme-toggle", problem: `seçim kalmadı: ${JSON.stringify(state)}` });
  }
  await page.screenshot({ path: join(outDir, "theme-toggle-dark.png") });
  await context.close();
}

/** Tüm denetimleri yapar ve sorunları yazdırır; sorun varsa çıkış kodu 1. */
async function main(): Promise<void> {
  const base: string = argument(2, "site adresi").replace(/\/$/, "");
  const outDir: string = argument(3, "çıktı klasörü");
  const chromePath: string = argument(4, "Chrome yolu");
  await mkdir(outDir, { recursive: true });
  const browser: Browser = await chromium.launch({ executablePath: chromePath, headless: true });
  const findings: Finding[] = [];
  try {
    await capturePages(browser, base, outDir, findings);
    await captureDemo(browser, base, outDir, findings);
    await checkDemoEnd(browser, base, outDir, findings);
    await capturePullReveal(browser, base, outDir, findings);
    await checkAdminHidden(browser, base, outDir, findings);
    await checkThemeToggle(browser, base, outDir, findings);
  } finally {
    await browser.close();
  }
  for (const finding of findings) {
    console.log("finding", finding);
  }
  console.log("screenshots_done", { outDir, findings: findings.length });
  process.exitCode = findings.length === 0 ? 0 : 1;
}

await main();
