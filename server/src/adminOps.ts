import { isoOrNull, longestMeetingMs } from "./admin";
import type { Config } from "./config";

/**
 * Yönetim panelinin işletim görünümü: şu an açık toplantılar, bitirilmeden süresi dolan toplantılar, takılı kalmış
 * kullanım ayırmaları ve Deepgram tahminleri, Stripe webhook'unun son olayları ve son raporlar. Kimlik olarak yalnızca
 * hesap ve toplantı UUID'leri döner.
 */

/** Listelenen en çok açık toplantı. */
export const openMeetingLimit: number = 50;

/** Listelenen en çok son çökme raporu. */
export const recentCrashLimit: number = 5;

const hourMs: number = 3_600_000;
const dayMs: number = 86_400_000;

/** Bitirilmeden süresi dolan toplantıların geriye bakış süresi. */
const unendedWindowMs: number = 7 * dayMs;

/** Şu an açık toplantı. */
export interface OpenMeeting {
  readonly id: string;
  readonly userId: string;
  readonly kind: "trial" | "subscription";
  readonly startedAt: string;
  readonly maxEndsAt: string;
  readonly deferred: boolean;
  readonly deepgram: boolean;
}

/** Stripe olay türü başına sayı. */
export interface EventTypeCount {
  readonly type: string;
  readonly count: number;
}

/** Son çökme raporu (içerik olmadan). */
export interface RecentCrash {
  readonly id: string;
  readonly status: string;
  readonly createdAt: string;
  readonly appVersion: string | null;
  readonly os: string | null;
  readonly summary: string;
}

/**
 * `GET /v1/admin/operations` yanıtı.
 * - `meetings.open`: bitmemiş ve en çok süresi dolmamış toplantılar (en yeni `openMeetingLimit` tanesi listelenir);
 *   `unendedLast7Days`: son 7 günde başlayıp bitirilmeden en çok süresi dolan toplantılar (uygulama bitişi
 *   bildiremedi: çökme, ağ kesintisi ya da kapatılan Mac).
 * - `reservations`: süren (`active`) ve süresi dolmuş ama günlük temizliğin henüz kapatmadığı (`expired`) kullanım
 *   ayırmaları; `oldestExpiredAt` bir günden eskiyse temizlik çalışmıyordur.
 * - `deepgram`: tahmini gerçek süreye indirilmemiş toplantılar; `stale` olanların ilk jetonu en uzun toplantı
 *   süresinden eski (toplantı bittiği hâlde indirilmemiş).
 * - `stripe`: son işlenen olayın anı, son 24 saatteki olay sayısı ve son 7 günün türlere göre dağılımı.
 * - `reports`: son 7 günde gelen raporlar (türe göre) ve son çökme raporları.
 */
export interface AdminOperations {
  readonly generatedAt: string;
  readonly meetings: { readonly open: number; readonly openItems: readonly OpenMeeting[]; readonly unendedLast7Days: number };
  readonly reservations: { readonly active: number; readonly expired: number; readonly oldestExpiredAt: string | null };
  readonly deepgram: { readonly unsettled: number; readonly stale: number };
  readonly stripe: { readonly lastEventAt: string | null; readonly eventsLast24Hours: number; readonly last7DaysByType: readonly EventTypeCount[] };
  readonly reports: {
    readonly last7Days: { readonly feedback: number; readonly crash: number; readonly contact: number };
    readonly recentCrashes: readonly RecentCrash[];
  };
}

interface OpenMeetingRow {
  readonly id: string;
  readonly user_id: string;
  readonly kind: "trial" | "subscription";
  readonly started_at: number;
  readonly max_ends_at: number;
  readonly deferred: number;
  readonly deepgram: number;
}

interface CountsRow {
  readonly open: number;
  readonly unended: number;
  readonly active_reservations: number;
  readonly expired_reservations: number;
  readonly oldest_expired: number | null;
  readonly unsettled: number;
  readonly stale: number;
  readonly last_event: number | null;
  readonly events_day: number;
}

interface TypeCountRow {
  readonly type: string;
  readonly count: number;
}

interface CrashRow {
  readonly id: string;
  readonly status: string;
  readonly created_at: number;
  readonly app_version: string | null;
  readonly os: string | null;
  readonly summary: string;
}

/**
 * İşletim görünümü; tümü toplama sorgularıyla, dizinli aralıklarla (`meeting_sessions_started`,
 * `usage_reservations_expires`, `deepgram_live_meetings_unsettled`, `reports_kind_created`).
 */
export async function adminOperations(db: D1Database, config: Config, now: Date): Promise<AdminOperations> {
  const nowMs: number = now.getTime();
  const openSince: number = nowMs - longestMeetingMs(config);
  const weekAgo: number = nowMs - unendedWindowMs;
  const [counts, openRows, typeRows, reportRows, crashRows] = await Promise.all([
    db
      .prepare(
        `SELECT
           (SELECT COUNT(*) FROM meeting_sessions WHERE started_at >= ?2 AND ended_at IS NULL AND max_ends_at > ?1) AS open,
           (SELECT COUNT(*) FROM meeting_sessions WHERE started_at >= ?3 AND ended_at IS NULL AND max_ends_at <= ?1) AS unended,
           (SELECT COUNT(*) FROM usage_reservations WHERE expires_at > ?1) AS active_reservations,
           (SELECT COUNT(*) FROM usage_reservations WHERE expires_at <= ?1) AS expired_reservations,
           (SELECT MIN(expires_at) FROM usage_reservations WHERE expires_at <= ?1) AS oldest_expired,
           (SELECT COUNT(*) FROM deepgram_live_meetings WHERE settled_at IS NULL) AS unsettled,
           (SELECT COUNT(*) FROM deepgram_live_meetings WHERE settled_at IS NULL AND first_grant_at < ?2) AS stale,
           (SELECT MAX(processed_at) FROM stripe_events) AS last_event,
           (SELECT COUNT(*) FROM stripe_events WHERE processed_at >= ?4) AS events_day`,
      )
      .bind(nowMs, openSince, weekAgo, nowMs - 24 * hourMs)
      .first<CountsRow>(),
    db
      .prepare(
        `SELECT m.id, m.user_id, m.kind, m.started_at, m.max_ends_at, m.deferred,
           EXISTS (SELECT 1 FROM deepgram_live_meetings d WHERE d.meeting_id = m.id) AS deepgram
         FROM meeting_sessions m WHERE m.started_at >= ?2 AND m.ended_at IS NULL AND m.max_ends_at > ?1
         ORDER BY m.started_at DESC LIMIT ?3`,
      )
      .bind(nowMs, openSince, openMeetingLimit)
      .all<OpenMeetingRow>(),
    db
      .prepare("SELECT type, COUNT(*) AS count FROM stripe_events WHERE processed_at >= ? GROUP BY type ORDER BY count DESC, type")
      .bind(weekAgo)
      .all<TypeCountRow>(),
    db.prepare("SELECT kind AS type, COUNT(*) AS count FROM reports WHERE created_at >= ? GROUP BY kind").bind(weekAgo).all<TypeCountRow>(),
    db
      .prepare("SELECT id, status, created_at, app_version, os, summary FROM reports WHERE kind = 'crash' ORDER BY created_at DESC LIMIT ?")
      .bind(recentCrashLimit)
      .all<CrashRow>(),
  ]);
  const reportCounts: Map<string, number> = new Map(reportRows.results.map((row: TypeCountRow): [string, number] => [row.type, row.count]));
  return {
    generatedAt: now.toISOString(),
    meetings: {
      open: counts?.open ?? 0,
      openItems: openRows.results.map(
        (row: OpenMeetingRow): OpenMeeting => ({
          id: row.id,
          userId: row.user_id,
          kind: row.kind,
          startedAt: new Date(row.started_at).toISOString(),
          maxEndsAt: new Date(row.max_ends_at).toISOString(),
          deferred: row.deferred === 1,
          deepgram: row.deepgram === 1,
        }),
      ),
      unendedLast7Days: counts?.unended ?? 0,
    },
    reservations: {
      active: counts?.active_reservations ?? 0,
      expired: counts?.expired_reservations ?? 0,
      oldestExpiredAt: isoOrNull(counts?.oldest_expired ?? null),
    },
    deepgram: { unsettled: counts?.unsettled ?? 0, stale: counts?.stale ?? 0 },
    stripe: {
      lastEventAt: isoOrNull(counts?.last_event ?? null),
      eventsLast24Hours: counts?.events_day ?? 0,
      last7DaysByType: typeRows.results.map((row: TypeCountRow): EventTypeCount => ({ type: row.type, count: row.count })),
    },
    reports: {
      last7Days: { feedback: reportCounts.get("feedback") ?? 0, crash: reportCounts.get("crash") ?? 0, contact: reportCounts.get("contact") ?? 0 },
      recentCrashes: crashRows.results.map(
        (row: CrashRow): RecentCrash => ({
          id: row.id,
          status: row.status,
          createdAt: new Date(row.created_at).toISOString(),
          appVersion: row.app_version,
          os: row.os,
          summary: row.summary,
        }),
      ),
    },
  };
}
