import { z } from "zod";
import { isoOrNull } from "./admin";
import type { Config } from "./config";
import {
  type SubscriptionAccess,
  type SubscriptionState,
  type TrialState,
  graceEndsAtMs,
  subscriptionAccess,
  trialEndsAtMs,
  trialMeetingsLeft,
} from "./entitlements";
import { ApiError } from "./errors";
import { parseWithSchema } from "./http";
import { type MonthlyUsage, monthKey, monthStartMs, monthlyUsage } from "./usage";

/**
 * Yönetim panelinin kullanıcı listesi ve ayrıntısı. Yalnızca hesap kimliği (UUID), giriş sağlayıcısının adı, plan,
 * kullanım ve zaman damgaları döner: kimlik jetonu, sağlayıcı `sub` değeri, e-posta (saklanmaz), IP ya da özeti ve
 * gizli değer hiçbir yanıtta yoktur.
 */

/** Liste sayfa boyu. */
export const adminUserPageSize: number = 50;

/** Ayrıntıdaki en çok toplantı (yeniden eskiye). */
export const adminUserMeetingLimit: number = 100;

/** Ayrıntıdaki en çok rapor (yeniden eskiye). */
export const adminUserReportLimit: number = 20;

/** Kullanıcı listesi kesimi: abone (erişimi var), ödemesi gecikmiş, iptal edilmiş, denemede ya da hiçbiri. */
export type AdminUserSegment = "subscribed" | "past_due" | "canceled" | "trial" | "free";

/** Giriş sağlayıcısı. */
export type AdminUserProvider = "apple" | "google";

/** Hesabın planı: abonelik erişimi var, deneme başlamış (erişim yok) ya da ikisi de yok. */
export type AdminUserPlan = "subscription" | "trial" | "free";

/** Liste süzgeci; null süzmez. İmleç: önceki sayfanın son satırının (`created_at`, `id`) değeri. */
export interface AdminUserFilter {
  readonly query: string | null;
  readonly segment: AdminUserSegment | null;
  readonly provider: AdminUserProvider | null;
  readonly cursor: AdminUserCursor | null;
}

/** Sayfa imleci. */
export interface AdminUserCursor {
  readonly createdAt: number;
  readonly id: string;
}

/** Listedeki ve ayrıntıdaki aboneliğin özeti. */
export interface AdminSubscription {
  readonly status: string;
  readonly access: SubscriptionAccess;
  readonly currentPeriodEnd: string;
  readonly cancelAt: string | null;
  readonly pastDueSince: string | null;
  readonly graceEndsAt: string | null;
  /** Webhook'un satırı son yazdığı an. */
  readonly updatedAt: string;
}

/** Hesabın deneme durumu. */
export interface AdminTrial {
  readonly used: number;
  readonly left: number;
  readonly startedAt: string | null;
  readonly endsAt: string | null;
}

/** Listedeki kullanıcı. */
export interface AdminUserSummary {
  readonly id: string;
  readonly provider: AdminUserProvider | null;
  readonly createdAt: string;
  readonly plan: AdminUserPlan;
  readonly subscription: AdminSubscription | null;
  readonly trial: AdminTrial;
  readonly meetingsTotal: number;
  readonly hoursThisMonth: number;
  /** Son etkinlik: son toplantı başlangıcı ya da son oturum yenilemesinin geç olanı; hiç yoksa null. */
  readonly lastActiveAt: string | null;
}

/** Liste sayfası; `nextCursor` sonraki sayfanın `cursor` değeri, son sayfada null. */
export interface AdminUserPage {
  readonly items: readonly AdminUserSummary[];
  readonly nextCursor: string | null;
}

/** Toplantının durumu: açık, kullanıcı bitirdi, yeni toplantıyla kapandı ya da bitirilmeden süresi doldu. */
export type AdminMeetingState = "open" | "ended" | "superseded" | "expired";

/** Ayrıntıdaki toplantı. */
export interface AdminMeeting {
  readonly id: string;
  readonly kind: "trial" | "subscription";
  readonly state: AdminMeetingState;
  readonly startedAt: string;
  readonly endedAt: string | null;
  readonly maxEndsAt: string;
  /** Başlangıçtan bitişe (açıksa şimdiye, en çok süreye dek) dakika. */
  readonly durationMinutes: number;
  readonly deferred: boolean;
  readonly reprocessCount: number;
  readonly audioMinutes: number;
  readonly tokensUsed: number;
  readonly tokenBudget: number;
  /** Doğrulanmış (App Attest) cihazdan başlatıldı mı. */
  readonly attested: boolean;
  /** Canlı metin Deepgram'dan mı (jeton almış). */
  readonly deepgram: boolean;
}

/** Ayrıntıdaki rapor (içerik olmadan). */
export interface AdminUserReport {
  readonly id: string;
  readonly kind: string;
  readonly status: string;
  readonly createdAt: string;
  readonly summary: string;
}

/** Bu ayın kullanımı ve sınırları. */
export interface AdminUserUsage {
  /** Aylık süre sınırına sayılan saat (`monthlyUsage().usedSeconds`) ve sınır. */
  readonly usedHours: number;
  readonly capHours: number;
  readonly audioHours: number;
  readonly tokens: number;
  readonly tokenCap: number;
  readonly accountTokens: number;
  readonly accountTokenCap: number;
}

/** Zaman çizelgesi olayı: hesap, deneme ve abonelik satırındaki zaman damgalarından türetilir (geçmiş tutulmaz). */
export type AdminTimelineKind =
  | "account_created"
  | "trial_started"
  | "trial_device_verified"
  | "trial_ends"
  | "subscription_updated"
  | "subscription_past_due"
  | "subscription_cancel_at"
  | "subscription_period_end";

/** Zaman çizelgesi satırı; `detail` abonelik olaylarında durumdur (yoksa null). */
export interface AdminTimelineEntry {
  readonly kind: AdminTimelineKind;
  readonly at: string;
  readonly detail: string | null;
}

/** `GET /v1/admin/users/{id}` yanıtı. */
export interface AdminUserDetail {
  readonly user: AdminUserSummary;
  /** Denemenin bir Mac'e (DeviceCheck) bağlandığı an. */
  readonly trialDeviceVerifiedAt: string | null;
  /** Stripe panelinde müşteriyi bulmak için (gizli değer değildir); hiç ödeme sayfası açmadıysa null. */
  readonly stripeCustomerId: string | null;
  readonly usage: AdminUserUsage;
  readonly meetings: readonly AdminMeeting[];
  readonly reports: readonly AdminUserReport[];
  readonly timeline: readonly AdminTimelineEntry[];
}

const segmentSchema = z.enum(["subscribed", "past_due", "canceled", "trial", "free"]);
const providerSchema = z.enum(["apple", "google"]);

/** `?q=&segment=&provider=&cursor=`; boş ya da eksik değer süzgeç yok demektir, başka parametre reddedilir. */
const userListQuerySchema = z.strictObject({
  q: z.string().regex(/^[0-9a-f-]{0,36}$/).optional(),
  segment: z.union([z.literal(""), segmentSchema]).optional(),
  provider: z.union([z.literal(""), providerSchema]).optional(),
  cursor: z.union([z.literal(""), z.string().regex(/^[1-9][0-9]{0,14}:[0-9a-f-]{36}$/)]).optional(),
});

/** Sorgu parametrelerini süzgece çevirir; geçersizse `invalid_body`. `q` küçük harfe çevrilir. Saf fonksiyondur. */
export function parseAdminUserFilter(url: URL): AdminUserFilter {
  const raw: Record<string, string> = Object.fromEntries(url.searchParams);
  const query = parseWithSchema(userListQuerySchema, { ...raw, ...(raw["q"] === undefined ? {} : { q: raw["q"].trim().toLowerCase() }) });
  const cursorParts: string[] | null = query.cursor === undefined || query.cursor === "" ? null : query.cursor.split(":");
  return {
    query: query.q === undefined || query.q === "" ? null : query.q,
    segment: query.segment === undefined || query.segment === "" ? null : query.segment,
    provider: query.provider === undefined || query.provider === "" ? null : query.provider,
    cursor: cursorParts === null ? null : { createdAt: Number(cursorParts[0]), id: cursorParts[1] ?? "" },
  };
}

/**
 * Abonelik erişimi için SQL koşulu (`subscriptions s`, LEFT JOIN: satır yoksa 0); `entitlements.subscriptionAccess`
 * ile aynıdır. Bağlar: ?1 = şimdi, ?2 = ek süre (ms).
 */
const accessSql: string = `COALESCE((s.status IN ('active', 'trialing') AND s.current_period_end > ?1)
  OR (s.status = 'past_due' AND s.past_due_since + ?2 > ?1), 0)`;

/** Denemeye başlamış (ya da silinmiş hesabından deneme devralmış) hesap için SQL koşulu (`users u`). */
const trialStartedSql: string = "(u.trial_started_at IS NOT NULL OR u.carried_trial_meetings > 0)";

/** Kesimin SQL koşulu (sabit metin; kullanıcı girdisi içermez). Saf fonksiyondur. */
function segmentSql(segment: AdminUserSegment | null): string {
  switch (segment) {
    case null:
      return "1 = 1";
    case "subscribed":
      return `${accessSql} = 1`;
    case "past_due":
      return "s.status = 'past_due'";
    case "canceled":
      return "s.status = 'canceled'";
    case "trial":
      return `${trialStartedSql} AND ${accessSql} = 0`;
    case "free":
      return `s.user_id IS NULL AND NOT ${trialStartedSql}`;
  }
}

/** Kullanıcı satırı (liste ve ayrıntı). */
interface UserRow {
  readonly id: string;
  readonly created_at: number;
  readonly trial_started_at: number | null;
  readonly trial_device_verified_at: number | null;
  readonly carried_trial_meetings: number;
  readonly provider: AdminUserProvider | null;
  readonly status: string | null;
  readonly current_period_end: number | null;
  readonly cancel_at: number | null;
  readonly past_due_since: number | null;
  readonly updated_at: number | null;
  readonly meetings: number;
  readonly trial_meetings: number;
  readonly month_ms: number;
  readonly last_meeting_at: number | null;
  readonly last_token_at: number | null;
}

/**
 * Kullanıcı satırının sütunları. Bağlar: ?1 = şimdi, ?3 = ay başı (ms). Toplantı sayıları `meeting_sessions_user`
 * dizinini, son oturum yenilemesi `refresh_families_user` ve `refresh_tokens_family` dizinlerini kullanır.
 */
const userColumnsSql: string = `u.id, u.created_at, u.trial_started_at, u.trial_device_verified_at, u.carried_trial_meetings,
  (SELECT provider FROM auth_identities a WHERE a.user_id = u.id ORDER BY provider LIMIT 1) AS provider,
  s.status, s.current_period_end, s.cancel_at, s.past_due_since, s.updated_at,
  (SELECT COUNT(*) FROM meeting_sessions m WHERE m.user_id = u.id) AS meetings,
  (SELECT COUNT(*) FROM meeting_sessions m WHERE m.user_id = u.id AND m.kind = 'trial') AS trial_meetings,
  (SELECT COALESCE(SUM(MAX(0, MIN(COALESCE(m.ended_at, ?1), m.max_ends_at, ?1) - m.started_at)), 0)
     FROM meeting_sessions m WHERE m.user_id = u.id AND m.started_at >= ?3) AS month_ms,
  (SELECT MAX(m.started_at) FROM meeting_sessions m WHERE m.user_id = u.id) AS last_meeting_at,
  (SELECT MAX(t.created_at) FROM refresh_families f JOIN refresh_tokens t ON t.family_id = f.id WHERE f.user_id = u.id) AS last_token_at`;

/** Satırın abonelik durumu (satır yoksa null). Saf fonksiyondur. */
function subscriptionOf(row: UserRow): SubscriptionState | null {
  return row.status === null || row.current_period_end === null
    ? null
    : { status: row.status, currentPeriodEnd: row.current_period_end, cancelAt: row.cancel_at, pastDueSince: row.past_due_since };
}

/** Satırın listedeki özeti. Saf fonksiyondur. */
function userSummary(row: UserRow, config: Config, now: Date): AdminUserSummary {
  const subscription: SubscriptionState | null = subscriptionOf(row);
  const access: SubscriptionAccess = subscriptionAccess(subscription, now, config.pastDueGraceMs);
  const trial: TrialState = { used: row.trial_meetings + row.carried_trial_meetings, startedAt: row.trial_started_at, deviceVerifiedAt: row.trial_device_verified_at };
  const trialStarted: boolean = row.trial_started_at !== null || row.carried_trial_meetings > 0;
  const lastActive: number | null = Math.max(row.last_meeting_at ?? 0, row.last_token_at ?? 0) || null;
  return {
    id: row.id,
    provider: row.provider,
    createdAt: new Date(row.created_at).toISOString(),
    plan: access !== "none" ? "subscription" : trialStarted ? "trial" : "free",
    subscription:
      subscription === null
        ? null
        : {
            status: subscription.status,
            access,
            currentPeriodEnd: new Date(subscription.currentPeriodEnd).toISOString(),
            cancelAt: isoOrNull(subscription.cancelAt),
            pastDueSince: isoOrNull(subscription.pastDueSince),
            graceEndsAt: isoOrNull(graceEndsAtMs(subscription, config.pastDueGraceMs)),
            updatedAt: new Date(row.updated_at ?? 0).toISOString(),
          },
    trial: {
      used: trial.used,
      left: trialMeetingsLeft(trial, config, now),
      startedAt: isoOrNull(trial.startedAt),
      endsAt: isoOrNull(trialEndsAtMs(trial, config.trialDurationMs)),
    },
    meetingsTotal: row.meetings,
    hoursThisMonth: Math.round((row.month_ms / 3_600_000) * 100) / 100,
    lastActiveAt: isoOrNull(lastActive),
  };
}

/**
 * Kullanıcı listesi: yeniden eskiye (`created_at`, `id`), kimlik önekiyle, kesimle ve sağlayıcıyla süzülebilir; imleçli
 * sayfalar (`users_created` dizini). Satır başına alt sorgular yalnızca sayfadaki kullanıcılar için çalışır.
 */
export async function listAdminUsers(db: D1Database, config: Config, filter: AdminUserFilter, now: Date): Promise<AdminUserPage> {
  const result = await db
    .prepare(
      `SELECT ${userColumnsSql}
       FROM users u LEFT JOIN subscriptions s ON s.user_id = u.id
       WHERE (?4 IS NULL OR u.id LIKE ?4 || '%')
         AND (?5 IS NULL OR EXISTS (SELECT 1 FROM auth_identities a WHERE a.user_id = u.id AND a.provider = ?5))
         AND (?6 IS NULL OR u.created_at < ?6 OR (u.created_at = ?6 AND u.id < ?7))
         AND ${segmentSql(filter.segment)}
       ORDER BY u.created_at DESC, u.id DESC LIMIT ?8`,
    )
    .bind(
      now.getTime(),
      config.pastDueGraceMs,
      monthStartMs(now),
      filter.query,
      filter.provider,
      filter.cursor === null ? null : filter.cursor.createdAt,
      filter.cursor === null ? "" : filter.cursor.id,
      adminUserPageSize + 1,
    )
    .all<UserRow>();
  const rows: readonly UserRow[] = result.results;
  const page: readonly UserRow[] = rows.slice(0, adminUserPageSize);
  const last: UserRow | undefined = page[page.length - 1];
  return {
    items: page.map((row: UserRow): AdminUserSummary => userSummary(row, config, now)),
    nextCursor: rows.length > adminUserPageSize && last !== undefined ? `${last.created_at}:${last.id}` : null,
  };
}

/** Toplantı satırı (ayrıntı). */
interface MeetingRow {
  readonly id: string;
  readonly kind: "trial" | "subscription";
  readonly started_at: number;
  readonly max_ends_at: number;
  readonly ended_at: number | null;
  readonly end_reason: "ended" | "superseded" | null;
  readonly deferred: number;
  readonly reprocess_count: number;
  readonly audio_seconds: number;
  readonly tokens_used: number;
  readonly token_budget: number;
  readonly attested: number;
  readonly deepgram: number;
}

/** Toplantının durumu. Saf fonksiyondur. */
export function meetingState(row: Pick<MeetingRow, "ended_at" | "end_reason" | "max_ends_at">, nowMs: number): AdminMeetingState {
  if (row.ended_at === null) {
    return row.max_ends_at > nowMs ? "open" : "expired";
  }
  return row.end_reason === "superseded" ? "superseded" : "ended";
}

/** Satırın ayrıntıdaki toplantısı. Saf fonksiyondur. */
function adminMeeting(row: MeetingRow, nowMs: number): AdminMeeting {
  const end: number = Math.min(row.ended_at ?? nowMs, row.max_ends_at, nowMs);
  return {
    id: row.id,
    kind: row.kind,
    state: meetingState(row, nowMs),
    startedAt: new Date(row.started_at).toISOString(),
    endedAt: isoOrNull(row.ended_at),
    maxEndsAt: new Date(row.max_ends_at).toISOString(),
    durationMinutes: Math.round(Math.max(0, end - row.started_at) / 60_000),
    deferred: row.deferred === 1,
    reprocessCount: row.reprocess_count,
    audioMinutes: Math.round((row.audio_seconds / 60) * 10) / 10,
    tokensUsed: row.tokens_used,
    tokenBudget: row.token_budget,
    attested: row.attested === 1,
    deepgram: row.deepgram === 1,
  };
}

/**
 * Hesabın zaman çizelgesi (yeniden eskiye): sunucu abonelik geçmişi tutmaz, yalnızca satırlardaki zaman damgaları
 * (oluşturma, deneme başlangıcı ve bitişi, Mac doğrulaması, aboneliğin son güncellemesi, ödeme gecikmesi, planlanmış
 * iptal ve dönem sonu) gösterilir. Saf fonksiyondur.
 */
export function userTimeline(user: AdminUserSummary, trialDeviceVerifiedAt: string | null): AdminTimelineEntry[] {
  const subscription: AdminSubscription | null = user.subscription;
  const entries: ReadonlyArray<AdminTimelineEntry | null> = [
    { kind: "account_created", at: user.createdAt, detail: null },
    user.trial.startedAt === null ? null : { kind: "trial_started", at: user.trial.startedAt, detail: null },
    trialDeviceVerifiedAt === null ? null : { kind: "trial_device_verified", at: trialDeviceVerifiedAt, detail: null },
    user.trial.endsAt === null ? null : { kind: "trial_ends", at: user.trial.endsAt, detail: null },
    subscription === null ? null : { kind: "subscription_updated", at: subscription.updatedAt, detail: subscription.status },
    subscription === null || subscription.pastDueSince === null ? null : { kind: "subscription_past_due", at: subscription.pastDueSince, detail: null },
    subscription === null || subscription.cancelAt === null ? null : { kind: "subscription_cancel_at", at: subscription.cancelAt, detail: null },
    subscription === null ? null : { kind: "subscription_period_end", at: subscription.currentPeriodEnd, detail: subscription.status },
  ];
  return entries
    .filter((entry: AdminTimelineEntry | null): entry is AdminTimelineEntry => entry !== null)
    .sort((left: AdminTimelineEntry, right: AdminTimelineEntry): number => Date.parse(right.at) - Date.parse(left.at));
}

/** Ayın kullanım satırı. */
interface MonthlyRow {
  readonly audio_seconds: number;
  readonly tokens: number;
  readonly account_tokens: number;
}

/** Saat (yüzde bir hassasiyet). Saf fonksiyondur. */
function hoursOf(seconds: number): number {
  return Math.round((seconds / 3600) * 100) / 100;
}

/** Kullanıcının ayrıntısı; yoksa `not_found`. */
export async function adminUserDetail(db: D1Database, config: Config, userId: string, now: Date): Promise<AdminUserDetail> {
  const nowMs: number = now.getTime();
  const userRow: UserRow | null = await db
    .prepare(`SELECT ${userColumnsSql} FROM users u LEFT JOIN subscriptions s ON s.user_id = u.id WHERE u.id = ?2`)
    .bind(nowMs, userId, monthStartMs(now))
    .first<UserRow>();
  if (userRow === null) {
    throw new ApiError("not_found", "Kullanıcı bulunamadı.");
  }
  const [meetingRows, reportRows, customerRow, monthlyRow, usage]: [
    D1Result<MeetingRow>,
    D1Result<AdminUserReportRow>,
    { stripe_customer_id: string } | null,
    MonthlyRow | null,
    MonthlyUsage,
  ] = await Promise.all([
    db
      .prepare(
        `SELECT m.id, m.kind, m.started_at, m.max_ends_at, m.ended_at, m.end_reason, m.deferred, m.reprocess_count,
           m.audio_seconds, m.tokens_used, m.token_budget, m.device_id IS NOT NULL AS attested,
           EXISTS (SELECT 1 FROM deepgram_live_meetings d WHERE d.meeting_id = m.id) AS deepgram
         FROM meeting_sessions m WHERE m.user_id = ? ORDER BY m.started_at DESC LIMIT ?`,
      )
      .bind(userId, adminUserMeetingLimit)
      .all<MeetingRow>(),
    db
      .prepare("SELECT id, kind, status, created_at, summary FROM reports WHERE user_id = ? ORDER BY created_at DESC LIMIT ?")
      .bind(userId, adminUserReportLimit)
      .all<AdminUserReportRow>(),
    db.prepare("SELECT stripe_customer_id FROM stripe_customers WHERE user_id = ?").bind(userId).first<{ stripe_customer_id: string }>(),
    db
      .prepare("SELECT audio_seconds, input_tokens + output_tokens AS tokens, account_tokens FROM monthly_usage WHERE user_id = ? AND month = ?")
      .bind(userId, monthKey(now))
      .first<MonthlyRow>(),
    monthlyUsage(db, userId, now),
  ]);
  const user: AdminUserSummary = userSummary(userRow, config, now);
  const trialDeviceVerifiedAt: string | null = isoOrNull(userRow.trial_device_verified_at);
  return {
    user,
    trialDeviceVerifiedAt,
    stripeCustomerId: customerRow?.stripe_customer_id ?? null,
    usage: {
      usedHours: hoursOf(usage.usedSeconds),
      capHours: hoursOf(config.monthlyCapSeconds),
      audioHours: hoursOf(monthlyRow?.audio_seconds ?? 0),
      tokens: monthlyRow?.tokens ?? 0,
      tokenCap: config.monthlyTokenCap,
      accountTokens: monthlyRow?.account_tokens ?? 0,
      accountTokenCap: config.monthlyAccountTokenCap,
    },
    meetings: meetingRows.results.map((row: MeetingRow): AdminMeeting => adminMeeting(row, nowMs)),
    reports: reportRows.results.map(
      (row: AdminUserReportRow): AdminUserReport => ({
        id: row.id,
        kind: row.kind,
        status: row.status,
        createdAt: new Date(row.created_at).toISOString(),
        summary: row.summary,
      }),
    ),
    timeline: userTimeline(user, trialDeviceVerifiedAt),
  };
}

/** Rapor satırı (ayrıntı). */
interface AdminUserReportRow {
  readonly id: string;
  readonly kind: string;
  readonly status: string;
  readonly created_at: number;
  readonly summary: string;
}
