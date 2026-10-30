import { activeAccessSql, lastDays, paidSubscriptionSql } from "./admin";
import { freeInviteMonthSql } from "./referrals";
import type { OpsEventKind } from "./opsEvents";
import { dayKey } from "./usage";

/**
 * Yönetim panelinin "kullanıcıyı anlama" görünümü (`GET /v1/admin/insights`): sorunlar (son 7 ve 30 gün), ürün hunisi
 * (son 30 gün), indirmelerin kaynağı (son 30 gün), abonelik iptal nedenleri ve davet programının özeti (son 30 gün ve en
 * çok davet edenler). Hepsi mevcut tablolardan toplama sorgularıyla; kimlik olarak yalnızca hesap UUID'si döner.
 */

/** Huni ve indirme dökümünün gün sayısı (bugün dahil). */
export const insightDays: number = 30;

/** "Sorunlar" kutusunun kısa penceresi (bugün dahil). */
export const problemShortDays: number = 7;

/** Listelenen en çok Referer alan adı. */
export const referrerHostLimit: number = 20;

/** Listelenen en çok son iptal. */
export const recentCancellationLimit: number = 20;

/** Listelenen en çok davet eden. */
export const topReferrerLimit: number = 10;

/** Ayrıntı başına sayı (hata kodu, servis, kaynak, alan adı, neden). Boş ayrıntı `""`. */
export interface DetailCount {
  readonly detail: string;
  readonly count: number;
}

/** Bir penceredeki sorunlar; listeler çoktan aza. */
export interface ProblemWindow {
  readonly trialCapacityReached: number;
  readonly spendCeilingReached: number;
  /** Ürün retleri (hata koduna göre; `opsEvents.countedRefusalCodes`). */
  readonly refusals: readonly DetailCount[];
  /** Üst servis hataları (servise göre: `anthropic`, `elevenlabs`, `deepgram`, `devicecheck`, `stripe`, …). */
  readonly providerErrors: readonly DetailCount[];
  /** 5xx yanıtlar (hata koduna göre) ve toplamı. */
  readonly serverErrors: readonly DetailCount[];
  readonly serverErrorsTotal: number;
}

/** Huninin adımı. */
export type FunnelStep =
  | "downloads"
  | "accounts"
  | "first_meeting"
  | "first_note"
  | "three_meetings"
  | "subscribed"
  | "subscribed_via_invite"
  | "canceled";

/** Huni adımının sayısı. */
export interface FunnelCount {
  readonly step: FunnelStep;
  readonly count: number;
}

/**
 * Son 30 günün hunisi. `downloads`: o günlerin indirmeleri (ağ başına günde bir); diğer adımlar son 30 günde açılan
 * hesaplar (kohort): `accounts` hepsi, `first_meeting` en az bir toplantı başlatanlar, `first_note` bir toplantısında
 * not tamamlananlar (`meeting_sessions.first_note_at`; `noteTrackingSince`'ten önceki toplantılar sayılmaz),
 * `three_meetings` en az 3 toplantı, `subscribed` ödemesi tamamlanmış aboneliği olanlar, `subscribed_via_invite`
 * bunlardan davet koduyla abone olanlar (davet satırı katılmış), `canceled` abone olanlardan iptal edenler (bitmiş ya da
 * dönem sonunda bitecek). Adımlar iç içe değildir (ör. toplantısız abone olunabilir); her adım kohorttan bağımsız
 * sayılır. Son iki adım `subscribed`'ın alt kümesidir.
 */
export interface Funnel {
  readonly days: number;
  readonly steps: readonly FunnelCount[];
}

/** Son 30 günün indirme dökümü: kaynağa (`?src=`) ve Referer alan adına göre (boş: Referer yok). */
export interface DownloadBreakdown {
  readonly total: number;
  readonly bySource: readonly DetailCount[];
  readonly byReferrerHost: readonly DetailCount[];
}

/** Son iptal. */
export interface RecentCancellation {
  readonly userId: string;
  readonly at: string;
  readonly reason: string | null;
  readonly feedback: string | null;
  readonly comment: string | null;
}

/** Saklanan iptal nedenleri (en çok 180 gün): Müşteri Portalı seçeneğine ve Stripe nedenine göre, ve son iptaller. Boş seçenek `""`. */
export interface CancellationSummary {
  readonly total: number;
  readonly byFeedback: readonly DetailCount[];
  readonly byReason: readonly DetailCount[];
  readonly recent: readonly RecentCancellation[];
}

/** Davet eden: davet sayaçları (tüm zamanlar; silinmiş arkadaşların satırları dahil). */
export interface InviteReferrer {
  readonly userId: string;
  readonly joined: number;
  readonly pending: number;
  readonly granted: number;
  readonly voided: number;
}

/**
 * Davet programının özeti. Son 30 gün (bugün dahil): `checkouts` kodun Checkout'a götürüldüğü (satırın açıldığı),
 * `joined` kodla abone olunan, `firstPayments` davetlinin ilk ücretli faturasının ödendiği, `granted` davet edene ödül
 * verilen davetler; `voided` o günlerde düşen ya da yıllık sınıra takılan davetlerin nedene göre dökümü (çoktan aza;
 * `capped` yıllık sınır). `inFreeMonth`: şu an davetin ücretsiz ilk ayındaki aboneler (istatistikteki
 * `freeInviteMonth` ile aynı). `topReferrers`: kodla en çok abone getiren hesaplar (tüm zamanlar, en çok
 * `topReferrerLimit`).
 */
export interface InviteSummary {
  readonly days: number;
  readonly checkouts: number;
  readonly joined: number;
  readonly firstPayments: number;
  readonly granted: number;
  readonly voided: readonly DetailCount[];
  readonly inFreeMonth: number;
  readonly topReferrers: readonly InviteReferrer[];
}

/** `GET /v1/admin/insights` yanıtı. */
export interface AdminInsights {
  readonly generatedAt: string;
  readonly problems: { readonly last7Days: ProblemWindow; readonly last30Days: ProblemWindow };
  readonly funnel: Funnel;
  readonly downloads: DownloadBreakdown;
  readonly cancellations: CancellationSummary;
  readonly invites: InviteSummary;
}

interface OpsRow {
  readonly kind: OpsEventKind;
  readonly detail: string;
  readonly count: number;
}

interface KeyCountRow {
  readonly key: string | null;
  readonly count: number;
}

interface FunnelRow {
  readonly accounts: number;
  readonly first_meeting: number;
  readonly first_note: number;
  readonly three_meetings: number;
  readonly subscribed: number;
  readonly via_invite: number;
  readonly canceled: number;
}

interface InviteWindowRow {
  readonly checkouts: number;
  readonly joined: number;
  readonly first_payments: number;
  readonly granted: number;
}

interface InviteReferrerRow {
  readonly user_id: string;
  readonly joined: number;
  readonly pending: number;
  readonly granted: number;
  readonly voided: number;
}

interface CancellationRow {
  readonly user_id: string;
  readonly created_at: number;
  readonly reason: string | null;
  readonly feedback: string | null;
  readonly comment: string | null;
}

/** Bir türün ayrıntı sayıları, çoktan aza (eşitse ada göre). Saf fonksiyondur. */
function countsOfKind(rows: readonly OpsRow[], kind: OpsEventKind): DetailCount[] {
  return rows
    .filter((row: OpsRow): boolean => row.kind === kind)
    .map((row: OpsRow): DetailCount => ({ detail: row.detail, count: row.count }))
    .sort((left: DetailCount, right: DetailCount): number => right.count - left.count || left.detail.localeCompare(right.detail));
}

/** Ayrıntının sayısı (yoksa 0). Saf fonksiyondur. */
function countOf(counts: readonly DetailCount[], detail: string): number {
  return counts.find((item: DetailCount): boolean => item.detail === detail)?.count ?? 0;
}

/** Penceredeki sayaç satırlarından sorun özeti. Saf fonksiyondur. */
export function problemWindow(rows: readonly OpsRow[]): ProblemWindow {
  const refusals: DetailCount[] = countsOfKind(rows, "refusal");
  const serverErrors: DetailCount[] = countsOfKind(rows, "server_error");
  return {
    trialCapacityReached: countOf(refusals, "trial_capacity_reached"),
    spendCeilingReached: countOf(refusals, "spend_ceiling_reached"),
    refusals,
    providerErrors: countsOfKind(rows, "provider_error"),
    serverErrors,
    serverErrorsTotal: serverErrors.reduce((sum: number, item: DetailCount): number => sum + item.count, 0),
  };
}

/** Anahtar → sayı satırlarını ayrıntı sayılarına çevirir (null anahtar `""`). Saf fonksiyondur. */
function detailCounts(rows: readonly KeyCountRow[]): DetailCount[] {
  return rows.map((row: KeyCountRow): DetailCount => ({ detail: row.key ?? "", count: row.count }));
}

/** Pencerenin ilk günü (`YYYY-MM-DD`, bugün dahil `days` gün). Saf fonksiyondur. */
function firstDayOf(now: Date, days: number): string {
  return lastDays(now, days)[0] ?? dayKey(now);
}

/**
 * Kullanıcıyı anlama görünümü. Huni kohortu `users_created`, toplantı sayıları `meeting_sessions_user` dizinini
 * kullanır; sayaç tabloları gün aralığıyla okunur. Davet özetindeki ücretsiz ay sayısı, istatistikteki
 * `freeInviteMonth` gibi şu an erişimi süren (`activeAccessSql`) faturalı aylık abonelikleri sayar.
 */
export async function adminInsights(db: D1Database, now: Date): Promise<AdminInsights> {
  const shortFirstDay: string = firstDayOf(now, problemShortDays);
  const longFirstDay: string = firstDayOf(now, insightDays);
  const cohortStartMs: number = Date.parse(`${longFirstDay}T00:00:00Z`);
  const opsQuery: string = "SELECT kind, detail, SUM(count) AS count FROM ops_events WHERE day >= ? GROUP BY kind, detail";
  const [
    shortRows,
    longRows,
    downloadTotal,
    funnelRow,
    sourceRows,
    referrerRows,
    cancellationTotal,
    feedbackRows,
    reasonRows,
    recentRows,
    inviteWindowRow,
    inviteVoidRows,
    freeMonthRow,
    topReferrerRows,
  ] = await Promise.all([
      db.prepare(opsQuery).bind(shortFirstDay).all<OpsRow>(),
      db.prepare(opsQuery).bind(longFirstDay).all<OpsRow>(),
      db.prepare("SELECT COALESCE(SUM(count), 0) AS value FROM downloads WHERE day >= ?").bind(longFirstDay).first<{ value: number }>(),
      db
        .prepare(
          `SELECT COUNT(*) AS accounts,
             COALESCE(SUM(CASE WHEN t.meetings > 0 THEN 1 ELSE 0 END), 0) AS first_meeting,
             COALESCE(SUM(t.noted), 0) AS first_note,
             COALESCE(SUM(CASE WHEN t.meetings >= 3 THEN 1 ELSE 0 END), 0) AS three_meetings,
             COALESCE(SUM(t.subscribed), 0) AS subscribed,
             COALESCE(SUM(CASE WHEN t.subscribed = 1 AND t.invited = 1 THEN 1 ELSE 0 END), 0) AS via_invite,
             COALESCE(SUM(t.canceled), 0) AS canceled
           FROM (
             SELECT
               u.carried_trial_meetings + (SELECT COUNT(*) FROM meeting_sessions m WHERE m.user_id = u.id) AS meetings,
               EXISTS (SELECT 1 FROM meeting_sessions m WHERE m.user_id = u.id AND m.first_note_at IS NOT NULL) AS noted,
               EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = u.id AND ${paidSubscriptionSql}) AS subscribed,
               EXISTS (SELECT 1 FROM referral_redemptions r WHERE r.referred_user_id = u.id AND r.joined_at IS NOT NULL) AS invited,
               EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = u.id AND ${paidSubscriptionSql}
                 AND (s.status = 'canceled' OR s.cancel_at IS NOT NULL)) AS canceled
             FROM users u WHERE u.created_at >= ?
           ) t`,
        )
        .bind(cohortStartMs)
        .first<FunnelRow>(),
      db
        .prepare("SELECT source AS key, SUM(count) AS count FROM download_sources WHERE day >= ? GROUP BY source ORDER BY count DESC, source")
        .bind(longFirstDay)
        .all<KeyCountRow>(),
      db
        .prepare(
          `SELECT referrer_host AS key, SUM(count) AS count FROM download_sources WHERE day >= ?
           GROUP BY referrer_host ORDER BY count DESC, referrer_host LIMIT ?`,
        )
        .bind(longFirstDay, referrerHostLimit)
        .all<KeyCountRow>(),
      db.prepare("SELECT COUNT(*) AS value FROM subscription_cancellations").first<{ value: number }>(),
      db.prepare("SELECT feedback AS key, COUNT(*) AS count FROM subscription_cancellations GROUP BY feedback ORDER BY count DESC, feedback").all<KeyCountRow>(),
      db.prepare("SELECT reason AS key, COUNT(*) AS count FROM subscription_cancellations GROUP BY reason ORDER BY count DESC, reason").all<KeyCountRow>(),
      db
        .prepare("SELECT user_id, created_at, reason, feedback, comment FROM subscription_cancellations ORDER BY created_at DESC LIMIT ?")
        .bind(recentCancellationLimit)
        .all<CancellationRow>(),
      db
        .prepare(
          `SELECT COALESCE(SUM(CASE WHEN created_at >= ?1 THEN 1 ELSE 0 END), 0) AS checkouts,
             COALESCE(SUM(CASE WHEN joined_at >= ?1 THEN 1 ELSE 0 END), 0) AS joined,
             COALESCE(SUM(CASE WHEN qualified_at >= ?1 THEN 1 ELSE 0 END), 0) AS first_payments,
             COALESCE(SUM(CASE WHEN status = 'granted' AND rewarded_at >= ?1 THEN 1 ELSE 0 END), 0) AS granted
           FROM referral_redemptions WHERE updated_at >= ?1`,
        )
        .bind(cohortStartMs)
        .first<InviteWindowRow>(),
      db
        .prepare(
          `SELECT CASE WHEN status = 'capped' THEN 'capped' ELSE COALESCE(void_reason, '') END AS key, COUNT(*) AS count
           FROM referral_redemptions WHERE status IN ('void', 'capped') AND updated_at >= ? GROUP BY key ORDER BY count DESC, key`,
        )
        .bind(cohortStartMs)
        .all<KeyCountRow>(),
      db
        .prepare(
          `SELECT COUNT(*) AS value FROM subscriptions s
           WHERE s.complimentary = 0 AND s.plan = 'monthly' AND ${activeAccessSql} AND ${freeInviteMonthSql}`,
        )
        .bind(now.getTime())
        .first<{ value: number }>(),
      db
        .prepare(
          `SELECT referrer_user_id AS user_id,
             SUM(CASE WHEN joined_at IS NOT NULL THEN 1 ELSE 0 END) AS joined,
             SUM(CASE WHEN status IN ('joined', 'qualified') THEN 1 ELSE 0 END) AS pending,
             SUM(CASE WHEN status = 'granted' THEN 1 ELSE 0 END) AS granted,
             SUM(CASE WHEN status IN ('void', 'capped') THEN 1 ELSE 0 END) AS voided
           FROM referral_redemptions WHERE referrer_user_id IS NOT NULL
           GROUP BY referrer_user_id HAVING joined > 0 ORDER BY joined DESC, granted DESC, user_id LIMIT ?`,
        )
        .bind(topReferrerLimit)
        .all<InviteReferrerRow>(),
    ]);
  const funnel: FunnelRow = funnelRow ?? { accounts: 0, first_meeting: 0, first_note: 0, three_meetings: 0, subscribed: 0, via_invite: 0, canceled: 0 };
  const inviteWindow: InviteWindowRow = inviteWindowRow ?? { checkouts: 0, joined: 0, first_payments: 0, granted: 0 };
  return {
    generatedAt: now.toISOString(),
    problems: { last7Days: problemWindow(shortRows.results), last30Days: problemWindow(longRows.results) },
    funnel: {
      days: insightDays,
      steps: [
        { step: "downloads", count: downloadTotal?.value ?? 0 },
        { step: "accounts", count: funnel.accounts },
        { step: "first_meeting", count: funnel.first_meeting },
        { step: "first_note", count: funnel.first_note },
        { step: "three_meetings", count: funnel.three_meetings },
        { step: "subscribed", count: funnel.subscribed },
        { step: "subscribed_via_invite", count: funnel.via_invite },
        { step: "canceled", count: funnel.canceled },
      ],
    },
    downloads: {
      total: downloadTotal?.value ?? 0,
      bySource: detailCounts(sourceRows.results),
      byReferrerHost: detailCounts(referrerRows.results),
    },
    cancellations: {
      total: cancellationTotal?.value ?? 0,
      byFeedback: detailCounts(feedbackRows.results),
      byReason: detailCounts(reasonRows.results),
      recent: recentRows.results.map(
        (row: CancellationRow): RecentCancellation => ({
          userId: row.user_id,
          at: new Date(row.created_at).toISOString(),
          reason: row.reason,
          feedback: row.feedback,
          comment: row.comment,
        }),
      ),
    },
    invites: {
      days: insightDays,
      checkouts: inviteWindow.checkouts,
      joined: inviteWindow.joined,
      firstPayments: inviteWindow.first_payments,
      granted: inviteWindow.granted,
      voided: detailCounts(inviteVoidRows.results),
      inFreeMonth: freeMonthRow?.value ?? 0,
      topReferrers: topReferrerRows.results.map(
        (row: InviteReferrerRow): InviteReferrer => ({ userId: row.user_id, joined: row.joined, pending: row.pending, granted: row.granted, voided: row.voided }),
      ),
    },
  };
}
