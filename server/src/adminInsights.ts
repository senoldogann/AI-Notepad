import { lastDays, paidSubscriptionSql } from "./admin";
import type { OpsEventKind } from "./opsEvents";
import { dayKey } from "./usage";

/**
 * Yönetim panelinin "kullanıcıyı anlama" görünümü (`GET /v1/admin/insights`): sorunlar (son 7 ve 30 gün), ürün hunisi
 * (son 30 gün), indirmelerin kaynağı (son 30 gün) ve abonelik iptal nedenleri. Hepsi mevcut tablolardan toplama
 * sorgularıyla; kimlik olarak yalnızca hesap UUID'si döner.
 */

/** Huni ve indirme dökümünün gün sayısı (bugün dahil). */
export const insightDays: number = 30;

/** "Sorunlar" kutusunun kısa penceresi (bugün dahil). */
export const problemShortDays: number = 7;

/** Listelenen en çok Referer alan adı. */
export const referrerHostLimit: number = 20;

/** Listelenen en çok son iptal. */
export const recentCancellationLimit: number = 20;

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
export type FunnelStep = "downloads" | "accounts" | "first_meeting" | "first_note" | "three_meetings" | "subscribed" | "canceled";

/** Huni adımının sayısı. */
export interface FunnelCount {
  readonly step: FunnelStep;
  readonly count: number;
}

/**
 * Son 30 günün hunisi. `downloads`: o günlerin indirmeleri (ağ başına günde bir); diğer adımlar son 30 günde açılan
 * hesaplar (kohort): `accounts` hepsi, `first_meeting` en az bir toplantı başlatanlar, `first_note` bir toplantısında
 * not tamamlananlar (`meeting_sessions.first_note_at`; `noteTrackingSince`'ten önceki toplantılar sayılmaz),
 * `three_meetings` en az 3 toplantı, `subscribed` ödemesi tamamlanmış aboneliği olanlar, `canceled` bunlardan iptal
 * edenler (bitmiş ya da dönem sonunda bitecek). Adımlar iç içe değildir (ör. toplantısız abone olunabilir); her adım
 * kohorttan bağımsız sayılır.
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

/** `GET /v1/admin/insights` yanıtı. */
export interface AdminInsights {
  readonly generatedAt: string;
  readonly problems: { readonly last7Days: ProblemWindow; readonly last30Days: ProblemWindow };
  readonly funnel: Funnel;
  readonly downloads: DownloadBreakdown;
  readonly cancellations: CancellationSummary;
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
  readonly canceled: number;
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
 * kullanır; sayaç tabloları gün aralığıyla okunur.
 */
export async function adminInsights(db: D1Database, now: Date): Promise<AdminInsights> {
  const shortFirstDay: string = firstDayOf(now, problemShortDays);
  const longFirstDay: string = firstDayOf(now, insightDays);
  const cohortStartMs: number = Date.parse(`${longFirstDay}T00:00:00Z`);
  const opsQuery: string = "SELECT kind, detail, SUM(count) AS count FROM ops_events WHERE day >= ? GROUP BY kind, detail";
  const [shortRows, longRows, downloadTotal, funnelRow, sourceRows, referrerRows, cancellationTotal, feedbackRows, reasonRows, recentRows] =
    await Promise.all([
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
             COALESCE(SUM(t.canceled), 0) AS canceled
           FROM (
             SELECT
               u.carried_trial_meetings + (SELECT COUNT(*) FROM meeting_sessions m WHERE m.user_id = u.id) AS meetings,
               EXISTS (SELECT 1 FROM meeting_sessions m WHERE m.user_id = u.id AND m.first_note_at IS NOT NULL) AS noted,
               EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = u.id AND ${paidSubscriptionSql}) AS subscribed,
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
    ]);
  const funnel: FunnelRow = funnelRow ?? { accounts: 0, first_meeting: 0, first_note: 0, three_meetings: 0, subscribed: 0, canceled: 0 };
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
  };
}
