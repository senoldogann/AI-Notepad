// Görsel deneme: derlenmiş site (scripts/serve.ts) sunulurken tüm sayfaların 1440 ve 390 px açık ve koyu, 360 px açık tam sayfa
// görüntülerini alır; yatay taşmayı, konsol hatalarını ve CSP ihlallerini raporlar. Ayrıca ana sayfa gösteriminin
// birkaç karesini, tema düğmesini ve gösterimin ana iş parçacığı maliyetini (5 sn, Chrome başarım ölçüleri) denetler.
// Hesap ve yönetim sayfaları için tarayıcıya örnek bir oturum yazılır ve sunucu yanıtları aşağıdaki örnek verilerle
// karşılanır: bu yalnızca görünüm denetimidir; sunucuyla gerçek akış sunucunun kendi testlerindedir. Hesap sayfası her
// plan durumunda (deneme başlamadı, sürüyor, son toplantı; bitti; abonelik etkin, aylık sınır dolu, iptal edildi ve sınıra
// yakın, ödeme bekliyor, ödeme gecikmiş, bitti; davetin ücretsiz ilk ayı; ücretsiz erişim) ve yüklenemeyince (yeniden deneme
// düğmesi) çekilir; abonede davet kartı, denemede plan seçimi ve davet bağlantısıyla gelen kodun doğrulanması da çekilir.
// Örnek veriler yerel API adresine verilir: sunulan site yerel derleme (`npm run build:local`) değilse betik hemen durur.
// Sayfa sonundaki
// çekme katmanı (açık/koyu, masaüstü/telefon) ve gösterimin üç turdan sonra durup düğmesinin "baştan oynat"a döndüğü de
// denetlenir.
// Yönetim panelinin blog görünümü listeyle (haftalık düzen uyarısı, sitede aç bağlantıları dahil), kaydedilmiş yayındaki yazının
// düzenleyicisiyle (sonuç bildirimi, paylaşım bağlantıları, kapak seçici), görsel ekleme bölümüyle (WebP'ye çevrilmiş örnek
// görsel) ve görsel eklendikten sonraki Markdown önizlemesiyle çekilir. Blog dizini kapaklı kartlarla, yazı sayfaları
// kapakları ve ilgili yazılarla çekilir.
// Kullanım: node scripts/screenshots.ts <site adresi> <çıktı klasörü> <Chrome yolu>
import { mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
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
type AccountState =
  | "trial-new"
  | "trial-running"
  | "trial-last"
  | "trial-ended"
  | "active"
  | "limit"
  | "canceling"
  | "grace"
  | "overdue"
  | "ended"
  | "invite-month"
  | "complimentary";

/** Hesap sayfasının örnek yanıtı: bir plan durumu ya da `/v1/me`'nin hiç okunamadığı durum (yeniden deneme düğmesi). */
type AccountFixture = AccountState | "load-failed";

/** Sunulan site yerel derleme değil: istekler örnek verilerle karşılanamaz. */
class WrongBuildError extends Error {
  override readonly name: string = "WrongBuildError";
}

/**
 * Görüntülenecek sayfa; `ready` sayfanın hazır olduğunu gösteren seçici (Turnstile ağı hiç boşaltmaz). `account` hesap
 * sayfasının hangi durumla çekileceğidir (diğer sayfalarda null).
 */
interface Target {
  readonly name: string;
  readonly path: string;
  readonly ready: string;
  readonly signedIn: boolean;
  readonly account: AccountFixture | null;
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
  { name: "fi", path: "/fi", ready: "main", signedIn: false, account: null },
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
  { name: "account", path: "/account?payment=done", ready: "#referral-card:not(.hidden) #referral-stats .stat", signedIn: true, account: "active" },
  { name: "account-trial-new", path: "/account", ready: "#account-content:not(.hidden)", signedIn: true, account: "trial-new" },
  { name: "account-trial-running", path: "/account", ready: "#account-content:not(.hidden)", signedIn: true, account: "trial-running" },
  { name: "account-trial-last", path: "/account", ready: "#account-content:not(.hidden)", signedIn: true, account: "trial-last" },
  { name: "account-trial-ended", path: "/account", ready: "#account-content:not(.hidden)", signedIn: true, account: "trial-ended" },
  { name: "account-limit", path: "/account", ready: "#referral-card:not(.hidden) #referral-stats .stat", signedIn: true, account: "limit" },
  { name: "account-canceling", path: "/account", ready: "#referral-card:not(.hidden) #referral-stats .stat", signedIn: true, account: "canceling" },
  { name: "account-grace", path: "/account", ready: "#referral-card:not(.hidden) #referral-stats .stat", signedIn: true, account: "grace" },
  { name: "account-overdue", path: "/account", ready: "#account-content:not(.hidden)", signedIn: true, account: "overdue" },
  { name: "account-ended", path: "/account", ready: "#account-content:not(.hidden)", signedIn: true, account: "ended" },
  { name: "account-invite-month", path: "/account", ready: "#referral-card:not(.hidden) #referral-note:not(.hidden)", signedIn: true, account: "invite-month" },
  { name: "account-complimentary", path: "/account", ready: "#referral-card:not(.hidden) #referral-stats .stat", signedIn: true, account: "complimentary" },
  { name: "account-load-failed", path: "/account", ready: "#account-retry:not(.hidden)", signedIn: true, account: "load-failed" },
  // Davet koduyla gelinir: kod saklanır (sonraki hesap sayfalarında da dolar), bu yüzden hesap sayfalarından sonra.
  { name: "account-invite", path: "/account?code=k7m2-qx9d&plan=monthly", ready: "#invite-status.invite__ok", signedIn: true, account: "trial-ended" },
  { name: "invite-code", path: "/invite?code=K7M2QX9D", ready: "#invite-code-box:not(.hidden)", signedIn: false, account: null },
  { name: "admin", path: "/admin", ready: "#kpi-ov-mrr-spark svg", signedIn: true, account: null },
  { name: "admin-revenue", path: "/admin#revenue", ready: "#trend-revenue-rows tr", signedIn: true, account: null },
  { name: "admin-growth", path: "/admin#growth", ready: "#insights-funnel-rows tr", signedIn: true, account: null },
  { name: "admin-engagement", path: "/admin#engagement", ready: "#product-cohorts-rows tr", signedIn: true, account: null },
  { name: "admin-reliability", path: "/admin#reliability", ready: "#product-outcomes-rows tr", signedIn: true, account: null },
  { name: "admin-costs", path: "/admin#costs", ready: "#product-costs-rows tr", signedIn: true, account: null },
  { name: "admin-users", path: "/admin#users", ready: "#users-rows tr", signedIn: true, account: null },
  { name: "admin-user", path: "/admin#users", ready: "#users-rows tr", signedIn: true, account: null },
  { name: "admin-user-free", path: "/admin#users", ready: "#users-rows tr", signedIn: true, account: null },
  { name: "admin-user-grant", path: "/admin#users", ready: "#users-rows tr", signedIn: true, account: null },
  { name: "admin-operations", path: "/admin#operations", ready: "#ops-open-rows tr", signedIn: true, account: null },
  { name: "admin-inbox", path: "/admin#inbox", ready: "#inbox-list .inbox__item", signedIn: true, account: null },
  { name: "admin-blog", path: "/admin#blog", ready: "#blog-rows tr", signedIn: true, account: null },
  { name: "admin-blog-editor", path: "/admin#blog", ready: "#blog-rows tr", signedIn: true, account: null },
];

/** Örnek blog yazısının kısa adı (listede yayında; düzenleyici bunu açar ve kaydeder). */
const exampleBlogSlug: string = "turn-a-meeting-into-a-task-list";

/** Düzenleyicide eklenen örnek görselin alternatif metni ve ondan türeyen dosya adı (admin-blog-image.ts). */
const exampleImageAlt: string = "Task list in a shared doc";
const exampleImageName: string = "task-list-in-a-shared-doc.webp";

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

/** Sitenin `public/` klasörü (düzenleyiciye örnek görsel olarak paylaşım kartı yüklenir). */
const publicDir: string = fileURLToPath(new URL("../public/", import.meta.url));

/** Son 30 gün (`YYYY-MM-DD`, UTC). Saf fonksiyondur. */
function last30Days(now: Date): string[] {
  return Array.from({ length: 30 }, (_: unknown, index: number): string => new Date(now.getTime() - (29 - index) * 86_400_000).toISOString().slice(0, 10));
}

/**
 * Hesap durumuna göre örnek `/v1/referral` yanıtı: ücretsiz erişimde ödül uygulanmaz; davetin ücretsiz ilk ayında kod
 * yoktur. Saf fonksiyondur.
 */
function referralFixture(state: AccountState, now: Date): object {
  const inviteMonth: boolean = state === "invite-month";
  return {
    enabled: true,
    code: inviteMonth ? null : "K7M2QX9D",
    inviteUrl: inviteMonth ? null : "http://localhost:8788/invite?code=K7M2QX9D",
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
  // Aylık sınır sonraki UTC ayının başında sıfırlanır (sunucunun `monthlyResetsAt`'i).
  const monthlyResetsAt: string = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)).toISOString();
  const base = { userId: "usr_example", trialMeetingsTotal: 3, trialDays: 7, monthlyHoursCap: 10, monthlyResetsAt };
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
    // Son deneme toplantısı: ölçer sarı.
    "trial-last": { ...base, plan: "trial", trialMeetingsLeft: 1, trialEndsAt: at(3), monthlyHoursUsed: 1.6, subscription: null },
    "trial-ended": { ...base, plan: "trial", trialMeetingsLeft: 0, trialEndsAt: at(-1), monthlyHoursUsed: 2.1, subscription: null },
    active: { ...base, plan: "subscription", trialMeetingsLeft: 0, trialEndsAt: null, monthlyHoursUsed: 3.4, subscription: subscription("active", null) },
    // Aylık sınır dolu: ölçer sarı, kalan saat yerine sıfırlanma günü.
    limit: { ...base, plan: "subscription", trialMeetingsLeft: 0, trialEndsAt: null, monthlyHoursUsed: 10, subscription: subscription("active", null) },
    // Sınırın %80'inin üstü: ölçer sarı.
    canceling: { ...base, plan: "subscription", trialMeetingsLeft: 0, trialEndsAt: null, monthlyHoursUsed: 8.4, subscription: subscription("active", at(20)) },
    grace: { ...base, plan: "subscription", trialMeetingsLeft: 0, trialEndsAt: null, monthlyHoursUsed: 1.2, subscription: subscription("grace", null) },
    // Ek süre bitti, ödeme hâlâ alınamadı: erişim yok, abonelik Stripe'ta sürer (Yönet düğmesinin yanında uyarı).
    overdue: {
      ...base,
      plan: "trial",
      trialMeetingsLeft: 0,
      trialEndsAt: at(-60),
      monthlyHoursUsed: 0,
      subscription: { status: "past_due", plan: "monthly", currentPeriodEnd: at(-9), cancelAt: null, complimentary: false, access: "none", graceEndsAt: null },
    },
    // Davetle gelen abonenin ücretsiz ilk ayı: davet kodu ilk ücretli aydan sonra açılır.
    "invite-month": { ...base, plan: "subscription", trialMeetingsLeft: 0, trialEndsAt: null, monthlyHoursUsed: 0.4, subscription: subscription("active", null) },
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

/** Örnek blog yazıları: yayında, taslak ve 7 günden sonraya zamanlanmış (haftalık düzen uyarısı görünür). Saf fonksiyondur. */
function blogFixtures(now: Date): Readonly<Record<string, object>> {
  const day = (offset: number): string => new Date(now.getTime() + offset * 86_400_000).toISOString().slice(0, 10);
  const post = (slug: string, title: string, published: number, draft: boolean, status: string, cover: string | null): object => ({
    slug,
    title,
    description: "A five-step method for leaving every meeting with a clear list of who does what, by when. Works anywhere.",
    author: "Senol Dogan",
    published: day(published),
    updated: null,
    cover,
    draft,
    status,
    sha: `${slug.length.toString(16).padStart(2, "0")}${"a1b2c3d4e5".repeat(4)}`.slice(0, 40),
  });
  const live: object = { ...post(exampleBlogSlug, "Turn a meeting into a task list: a simple method", -2, false, "live", "violet"), updated: day(-1) };
  return {
    // Düzenleyicide eklenen görselin yükleme yanıtı (aynı yol her yöntemde aynı örneği alır).
    [`/v1/admin/blog/posts/${exampleBlogSlug}/images/${exampleImageName}`]: {
      path: `/blog/${exampleBlogSlug}/${exampleImageName}`,
      sha: "f".repeat(40),
      bytes: 48_213,
      width: 1200,
      height: 630,
    },
    "/v1/admin/blog/posts": {
      today: day(0),
      posts: [
        post("what-to-ask-before-recording-a-call", "What to ask before you record a call with a client", 12, false, "scheduled", null),
        post("weekly-notes-template", "A weekly notes template that people actually read", 3, true, "draft", "mint"),
        live,
        post("meeting-notes-on-mac-without-a-bot", "How to take meeting notes on a Mac without a bot joining the call", -9, false, "live", null),
      ],
    },
    [`/v1/admin/blog/posts/${exampleBlogSlug}`]: {
      ...live,
      body: [
        "Most meeting notes describe what people said. What you need afterwards is shorter: **who** does *what*, by when.",
        "",
        "## The format: one line per task",
        "",
        "1. Write the owner first.",
        "2. Then the outcome, as a verb.",
        "3. Then a date — see [the guide](/blog/meeting-notes-on-mac-without-a-bot) or [Gistsmith](https://gistsmith.com).",
        "",
        "> Nobody rereads the paragraph, so the task quietly disappears.",
        "",
        "Raw HTML stays text: <script>alert(1)</script> and a [bad link](javascript:alert(1)).",
        "",
        "```",
        "Mia: send the pricing draft, by Friday",
        "```",
        "",
        "| Owner | Task | Due |",
        "| --- | --- | --- |",
        "| Mia | Pricing draft | Fri |",
      ].join("\n"),
    },
  };
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
    // İlk hesap davetle abone oldu (rozet "Invite").
    invite: index === 0 ? "invited" : null,
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
    invitedBy: null,
    invites: null,
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
      referrals: { joined: 9, pending: 3, granted: 5, voided: 2, voidedByReason: [{ reason: "card_reused", count: 1 }, { reason: "refunded", count: 1 }] },
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
        invite: "invited",
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
      // Davetle gelen yıllık abone; kendisi de iki arkadaş davet etti (biri ödülü bekliyor, biri kart yüzünden düştü).
      invitedBy: {
        referrerUserId: exampleUserIds[2],
        code: "K7M2QX9D",
        status: "qualified",
        voidReason: null,
        inFreeMonth: false,
        cardChecked: true,
        createdAt: at(-12),
        joinedAt: at(-12),
        qualifiedAt: at(-12),
        rewardDueAt: at(18),
        rewardedAt: null,
        updatedAt: at(-12),
      },
      invites: {
        code: "P4W8NZ3R",
        joined: 2,
        pending: 1,
        rewarded: 0,
        voided: 1,
        rewardsLeftThisYear: 12,
        rewardsPerYear: 12,
        nextRewardAt: at(26),
        friends: [
          { userId: exampleUserIds[3], status: "joined", voidReason: null, createdAt: at(-4), joinedAt: at(-4), qualifiedAt: null, rewardDueAt: null, rewardedAt: null, updatedAt: at(-4) },
          { userId: null, status: "void", voidReason: "card_reused", createdAt: at(-3), joinedAt: at(-3), qualifiedAt: null, rewardDueAt: null, rewardedAt: null, updatedAt: at(-3) },
        ],
      },
      timeline: [
        { kind: "subscription_period_end", at: at(20), detail: "active" },
        { kind: "subscription_cancel_at", at: at(20), detail: null },
        { kind: "invite_reward_due", at: at(18), detail: null },
        { kind: "subscription_updated", at: at(-1), detail: "active" },
        { kind: "invite_friend_joined", at: at(-4), detail: exampleUserIds[3] },
        { kind: "trial_ends", at: at(-5), detail: null },
        { kind: "trial_device_verified", at: at(-12), detail: null },
        { kind: "trial_started", at: at(-12), detail: null },
        { kind: "invite_first_payment", at: at(-12), detail: null },
        { kind: "invite_joined", at: at(-12), detail: null },
        { kind: "invite_checkout", at: at(-12), detail: null },
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
          { step: "subscribed_via_invite", count: 4 },
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
      invites: {
        days: 30,
        checkouts: 9,
        joined: 5,
        firstPayments: 3,
        granted: 2,
        voided: [
          { detail: "card_reused", count: 1 },
          { detail: "canceled_before_payment", count: 1 },
        ],
        inFreeMonth: 2,
        topReferrers: [
          { userId: exampleUserIds[2], joined: 4, pending: 1, granted: 3, voided: 0 },
          { userId: exampleUserIds[0], joined: 2, pending: 1, granted: 0, voided: 1 },
        ],
      },
    },
    // Ürün verisi: az veriyle (birkaç hesap) dolu ve boş hücreler; bu ayın satırı kısmi, başlamamış kohort haftaları null.
    "/v1/admin/product": {
      generatedAt: now.toISOString(),
      engagement: {
        activeLast7Days: 2,
        activeLast30Days: 3,
        weeks: Array.from({ length: 8 }, (_: unknown, index: number) => ({
          weekStart: at((index - 7) * 7).slice(0, 10),
          activeUsers: index % 3 === 0 ? 0 : 2,
          meetings: index % 3 === 0 ? 0 : 3 + (index % 2),
          meetingsPerActiveUser: index % 3 === 0 ? null : (3 + (index % 2)) / 2,
        })),
      },
      cohorts: Array.from({ length: 8 }, (_: unknown, index: number) => ({
        weekStart: at((index - 7) * 7).slice(0, 10),
        signups: index % 2 === 0 ? 0 : 3,
        activeByWeek: Array.from({ length: 5 }, (__: unknown, week: number): number | null => (index + week > 7 ? null : index % 2 === 0 ? 0 : Math.max(0, 2 - week))),
      })),
      retention: { d7: { day: 7, eligible: 4, retained: 1 }, d30: { day: 30, eligible: 2, retained: 1 } },
      timeToStep: {
        days: 90,
        signupToFirstMeeting: { users: 3, medianSeconds: 5_400 },
        firstMeetingToFirstNote: { users: 2, medianSeconds: 1_890 },
        signupToFirstNote: { users: 2, medianSeconds: 93_600 },
      },
      trialOutcomes: { started: 4, converted: 1, exhausted: 1, expired: 1, active: 1 },
      checkout: { started: 2, paid: 1, abandoned: 1, startedLast30Days: 1, abandonedLast30Days: 1 },
      reliability: {
        days: 30,
        meetings: 6,
        failedMeetings: 2,
        failuresByCode: [
          { detail: "meeting_budget_exhausted", count: 1 },
          { detail: "upstream_rejected:elevenlabs", count: 1 },
        ],
        endedMeetings: 5,
        notedMeetings: 4,
        medianNoteSeconds: 95,
        superseded: 1,
        unended: 0,
        open: 1,
        budgetExhausted: 1,
        deepgram: { meetings: 4, baselineGrants: 3, grants: 14, withReconnects: 1, reconnects: 2 },
        onDevice: 2,
        opsDays: days.map((day: string, index: number) => ({ day, refusal: index % 9 === 0 ? 2 : 0, providerError: index === 27 ? 3 : 0, serverError: index === 29 ? 1 : 0 })),
      },
      economics: {
        rates: { llmInputUsdPerMTok: 0.1, llmOutputUsdPerMTok: 0.5, elevenLabsUsdPerHour: 0.22, deepgramUsdPerMinute: 0.0092, priceUsdMonthly: 5.99, priceUsdYearly: 49 },
        months: [
          {
            month: at(-62).slice(0, 7),
            partial: false,
            meetings: 0,
            meetingHours: 0,
            meetingCostUsd: { llm: 0, elevenLabs: 0, deepgram: 0, total: 0 },
            accountLlmUsd: 0,
            perMeeting: null,
            perMeetingHour: null,
            payers: { users: 1, costUsd: 0, costPerUserUsd: 0, listRevenueUsd: 5.99, grossMarginPercent: 100 },
          },
          {
            month: at(-31).slice(0, 7),
            partial: false,
            meetings: 2,
            meetingHours: 1,
            meetingCostUsd: { llm: 0.03, elevenLabs: 0.11, deepgram: 0, total: 0.14 },
            accountLlmUsd: 0,
            perMeeting: { llm: 0.015, elevenLabs: 0.055, deepgram: 0, total: 0.07 },
            perMeetingHour: { llm: 0.03, elevenLabs: 0.11, deepgram: 0, total: 0.14 },
            payers: { users: 1, costUsd: 0, costPerUserUsd: 0, listRevenueUsd: 5.99, grossMarginPercent: 100 },
          },
          {
            month: now.toISOString().slice(0, 7),
            partial: true,
            meetings: 4,
            meetingHours: 3.67,
            meetingCostUsd: { llm: 0.2833, elevenLabs: 0.33, deepgram: 1.196, total: 1.8093 },
            accountLlmUsd: 0.0167,
            perMeeting: { llm: 0.0708, elevenLabs: 0.0825, deepgram: 0.299, total: 0.4523 },
            perMeetingHour: { llm: 0.0773, elevenLabs: 0.09, deepgram: 0.3262, total: 0.4935 },
            payers: { users: 1, costUsd: 1.524, costPerUserUsd: 1.524, listRevenueUsd: 5.99, grossMarginPercent: 74.56 },
          },
        ],
        dailySpend: days.map((day: string, index: number) => ({ day, usd: index > 25 ? wave(index, 0.4) / 2 : 0, trialUsd: index > 27 ? 0.2 : 0 })),
      },
      crashes: {
        total: 3,
        recentDays: 30,
        versions: [
          { version: "0.1.8", total: 2, recent: 1, lastAt: at(-1) },
          { version: "", total: 1, recent: 0, lastAt: at(-100) },
        ],
      },
    },
    // Eğilimler: 90 günün son 40'ında anlık görüntü (öncesi boş), bir para biriminde tahsilat; site istatistikleri ve
    // telemetri az veriyle. Genel bakışın eğrileri ve gelir, büyüme, kullanım, maliyet görünümleri bunlardan çizilir.
    "/v1/admin/trends": {
      windowDays: 30,
      daily: Array.from({ length: 90 }, (_: unknown, index: number) => ({
        day: at(index - 90).slice(0, 10),
        snapshot:
          index < 50
            ? null
            : {
                subscriptionsMonthly: 20 + Math.round((index - 50) * 0.9),
                subscriptionsYearly: 5 + Math.round((index - 50) * 0.2),
                activeUsers7d: 40 + (index - 50) + (index % 5),
                mrrListUsd: (20 + Math.round((index - 50) * 0.9)) * 5.99 + ((5 + Math.round((index - 50) * 0.2)) * 49) / 12,
                spendAnthropicUsd: 3 + (index % 7) * 0.6,
                spendElevenLabsUsd: 1 + (index % 4) * 0.4,
                spendDeepgramUsd: 0.5 + (index % 3) * 0.2,
                invoicedMrr: [{ currency: "usd", mrrCents: 21_400, payingSubscriptions: 30 }],
              },
      })),
      revenue: {
        currencies: [
          {
            currency: "usd",
            mrrCents: 21_400,
            payingSubscriptions: 30,
            arpuCents: 713,
            paidLast30DaysCents: 18_900,
            refundedLast30DaysCents: 599,
            netLast30DaysCents: 16_200,
            ltvCents: 2_140,
            daily: Array.from({ length: 90 }, (_: unknown, index: number) => ({
              day: at(index - 90).slice(0, 10),
              paidCents: index % 3 === 0 ? 599 * (1 + (index % 4)) : 0,
              refundedCents: index === 70 ? 599 : 0,
            })),
          },
        ],
        firstPaymentsLast30Days: 6,
        medianDaysToFirstPayment: 4,
      },
      tokenBuckets: [
        { bucket: "meeting_note", calls: 120, inputTokens: 2_400_000, outputTokens: 310_000 },
        { bucket: "meeting_live_text", calls: 3_400, inputTokens: 1_100_000, outputTokens: 240_000 },
        { bucket: "account_quick", calls: 60, inputTokens: 90_000, outputTokens: 12_000 },
      ],
      languages: [
        { requested: "auto", detected: "en", requests: 80, audioHours: 41.5 },
        { requested: "fi", detected: "fi", requests: 22, audioHours: 9.2 },
      ],
      accountDeletions: [{ detail: "trial", count: 1 }],
      retries: [{ detail: "elevenlabs", count: 3 }],
      campaigns: [{ source: "linkedin", campaign: "launch-fi", count: 14 }],
    },
    "/v1/admin/site-analytics": {
      days: 30,
      pageViews: 1_840,
      visits: 960,
      daily: Array.from({ length: 30 }, (_: unknown, index: number) => ({ day: at(index - 30).slice(0, 10), pageViews: 40 + (index % 6) * 8, visits: 22 + (index % 5) * 4 })),
      topPaths: [
        { key: "/", pageViews: 820, visits: 610 },
        { key: "/pricing", pageViews: 240, visits: 190 },
        { key: "/fi", pageViews: 160, visits: 120 },
      ],
      topReferrers: [
        { key: "", pageViews: 900, visits: 700 },
        { key: "linkedin.com", pageViews: 320, visits: 180 },
      ],
    },
    "/v1/admin/telemetry": {
      windowDays: 30,
      versions: {
        activeUsers: 24,
        apps: [
          { version: "0.1.10 (19)", users: 18 },
          { version: "0.1.9 (18)", users: 6 },
        ],
        os: [{ version: "macOS 26.6.2", users: 24 }],
      },
      purposes: {
        totals: [
          { purpose: "note", inputTokens: 2_400_000, outputTokens: 310_000, calls: 120 },
          { purpose: "live_translation", inputTokens: 1_100_000, outputTokens: 240_000, calls: 3_400 },
        ],
        daily: [{ day: at(-1).slice(0, 10), purpose: "note", inputTokens: 80_000, outputTokens: 10_000, calls: 4 }],
      },
      events: {
        counts: [{ kind: "deepgram_reconnect", appVersion: "0.1.10 (19)", count: 3 }],
        daily: [{ day: at(-1).slice(0, 10), kind: "deepgram_reconnect", count: 3 }],
        durations: [{ kind: "note_generation_duration", bucket: "le_30", count: 12, secondsSum: 240 }],
        durationBuckets: ["le_10", "le_30", "le_60", "le_120", "le_300", "le_600", "le_1200", "le_1800", "le_3600", "gt_3600"],
      },
      features: {
        reports: 140,
        rows: [
          { feature: "live_translation", value: "", users: 60, total: 60 },
          { feature: "ask", value: "", users: 35, total: 80 },
          { feature: "translation_language", value: "tr", users: 40, total: 40 },
          { feature: "export", value: "markdown", users: 12, total: 15 },
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
    ...blogFixtures(now),
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

/**
 * Beklenen konsol hataları: 404 sayfasının kendisi 404 durumuyla gelir; yönetici olmayanın yönetim isteği 403 alır;
 * yüklenemeyen hesap sayfasının `/v1/me` isteği 503 alır ve sayfa hatayı konsola yazar.
 */
function isExpectedConsoleError(message: ConsoleMessage, shot: string): boolean {
  const notFoundDocument: boolean = shot.startsWith("notfound") && message.text().includes("status of 404");
  const adminForbidden: boolean = shot.startsWith("admin-forbidden") && message.text().includes("status of 403");
  const accountLoadFailed: boolean =
    shot.startsWith("account-load-failed") && (message.text().includes("status of 503") || message.text().startsWith("request_failed"));
  return notFoundDocument || adminForbidden || accountLoadFailed;
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
    const cors: Record<string, string> = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type", "access-control-allow-methods": "GET, POST, PUT, DELETE" };
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

/** Örnek yanıtın durum kodu ve gövdesi. */
interface FixtureResponse {
  readonly status: number;
  readonly body: object;
}

/** Hesap sayfasının örnek yanıtları: plan durumunda `/v1/me` ve `/v1/referral`; yüklenemeyen hesapta 503. Saf fonksiyondur. */
function accountResponses(fixture: AccountFixture, now: Date): Readonly<Record<string, FixtureResponse>> {
  if (fixture === "load-failed") {
    return { "/v1/me": { status: 503, body: { error: { code: "unavailable", message: "örnek hata" } } } };
  }
  return { "/v1/me": { status: 200, body: meFixture(fixture, now) }, "/v1/referral": { status: 200, body: referralFixture(fixture, now) } };
}

/**
 * Bu sayfada `/v1/me` ve `/v1/referral` isteklerini verilen hesap durumunun örnek yanıtlarıyla karşılar (bağlamın
 * yönlendirmesinden önce gelir).
 */
async function routeAccount(page: Page, fixture: AccountFixture): Promise<void> {
  for (const [path, response] of Object.entries(accountResponses(fixture, new Date()))) {
    await page.route(`${apiBase}${path}`, async (route: Route): Promise<void> => {
      const cors: Record<string, string> = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type", "access-control-allow-methods": "GET, POST, PUT, DELETE" };
      if (route.request().method() === "OPTIONS") {
        await route.fulfill({ status: 204, headers: cors });
        return;
      }
      await route.fulfill({ status: response.status, headers: cors, contentType: "application/json", body: JSON.stringify(response.body) });
    });
  }
}

/**
 * Sunulan sitenin yerel derleme olduğunu denetler: CSP'nin `connect-src`'si yerel API adresini içermeli. Üretim
 * derlemesinde istekler gerçek API'ye gider, örnek oturum reddedilir ve hesap sayfası girişe yönlenir (ilk hesap
 * görüntüsünün hazır seçicisi zaman aşımına düşer); bu yüzden çekime başlamadan durulur.
 */
async function assertLocalBuild(base: string): Promise<void> {
  const response: Response = await fetch(`${base}/account`);
  const csp: string | null = response.headers.get("content-security-policy");
  if (csp === null) {
    throw new WrongBuildError(`${base}/account CSP başlığı göndermiyor (durum ${response.status}); siteyi scripts/serve.ts ile sunun.`);
  }
  const connect: string | undefined = csp
    .split(";")
    .map((directive: string): string => directive.trim())
    .find((directive: string): boolean => directive.startsWith("connect-src "));
  if (connect === undefined || !connect.split(" ").includes(apiBase)) {
    throw new WrongBuildError(
      `Sunulan site yerel derleme değil: connect-src "${connect ?? "yok"}" içinde ${apiBase} yok. \`npm run build:local\` çalıştırıp scripts/serve.ts'i yeniden başlatın.`,
    );
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
    // İçinde kayan alanlar (ör. yönetim kabuğunun içeriği) yana taşmamalı: sayfa taşmasa da telefonda içerik yana
    // kayar. Görünmez sözde öğeler (ipucu balonu) de bu alanı genişletir; kasıtlı yatay kaydırıcılar hariçtir.
    const intended: string = ".table-scroll, .table-wrap, .detail__payload, .console__sidebar, .comparison, textarea, pre";
    for (const element of Array.from(document.querySelectorAll("body *"))) {
      const overflowX: string = getComputedStyle(element).overflowX;
      if ((overflowX === "auto" || overflowX === "scroll") && !element.matches(intended) && element.scrollWidth > element.clientWidth + 1) {
        offenders.push(`iç yatay kaydırma: ${element.tagName.toLowerCase()}.${String(element.className).split(" ").join(".")} (${element.scrollWidth} > ${element.clientWidth})`);
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
      // Yayındaki yazı açılır ve kaydedilir (örnek `PUT` yanıtı aynı yazıdır): sonuç bildirimi ve paylaşım bağlantıları.
      if (target.name === "admin-blog-editor") {
        await page.click(`#blog-rows .blog-row__title >> text="Turn a meeting into a task list: a simple method"`);
        await page.waitForSelector("#blog-editor-view:not(.hidden)");
        await page.click("#blog-save");
        await page.waitForSelector("#blog-share:not(.hidden)");
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
      // Görsel ekleme: imleç ilk paragrafın sonuna konur, bölüm açılır, PNG seçilir (tarayıcıda WebP'ye çevrilir),
      // alternatif metin yazılır (dosya adı ondan türer) ve çekilir; sonra yüklenir ve bağlantı gövdeye eklenir.
      if (target.name === "admin-blog-editor") {
        await page.$eval("#blog-body", (body: HTMLTextAreaElement): void => {
          const cursor: number = body.value.indexOf("\n\n## The format");
          body.setSelectionRange(cursor, cursor);
        });
        await page.click("#blog-image-open");
        await page.setInputFiles("#blog-image-file", { name: "task-list.png", mimeType: "image/png", buffer: await readFile(join(publicDir, "og.png")) });
        await page.waitForSelector("#blog-image-preview img");
        await page.fill("#blog-image-alt", exampleImageAlt);
        await page.waitForSelector("#blog-image-upload:enabled");
        await page.evaluate((): void => document.getElementById("blog-image")?.scrollIntoView({ block: "start" }));
        await capture(page, outDir, `${shot}-image`, findings);
        await page.click("#blog-image-upload");
        await page.waitForSelector("#blog-image.hidden", { state: "attached" });
        const inserted: boolean = await page.$eval("#blog-body", (body: HTMLTextAreaElement, link: string): boolean => body.value.includes(link), `![${exampleImageAlt}](/blog/${exampleBlogSlug}/${exampleImageName})`);
        if (!inserted) {
          findings.push({ shot, problem: "yüklenen görselin bağlantısı gövdeye eklenmedi" });
        }
      }
      // Düzenleyicinin önizleme sekmesi: Markdown öğeleri, yüklenen görsel (tarayıcıdaki kopyası), kaçışlı HTML ve düz
      // metne dönen güvensiz bağlantı.
      if (target.name === "admin-blog-editor") {
        await page.click("#blog-tab-preview");
        await page.waitForSelector("#blog-preview:not(.hidden) h2");
        await page.waitForSelector("#blog-preview img");
        await page.evaluate((): void => document.getElementById("blog-tab-preview")?.scrollIntoView({ block: "start" }));
        await capture(page, outDir, `${shot}-preview`, findings);
      }
      // Analiz görünümleri kabuğun içinde kayar: alttaki bölümler (tablolar) ayrı bir görüntüde.
      if (["admin", "admin-revenue", "admin-growth", "admin-engagement", "admin-reliability", "admin-costs"].includes(target.name)) {
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
        const cors: Record<string, string> = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type", "access-control-allow-methods": "GET, POST, PUT, DELETE" };
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
  await assertLocalBuild(base);
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
