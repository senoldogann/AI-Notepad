import { telemetryDurationBuckets } from "./telemetry";
import { dayKey } from "./usage";

/**
 * Yönetim panelinin "Telemetri" görünümü (`GET /v1/admin/telemetry`), son 30 gün (bugün dahil): uygulama ve macOS
 * sürümü benimsenmesi (`users.last_*`), amaç başına yapay zekâ tokenları (`llm_purpose_usage`), istemcinin güvenilirlik
 * olayları ve süre dağılımları (`client_event_*`) ve günlük özellik kullanımı (`feature_usage_daily`). Kimlik dönmez.
 */

/** Pencerenin gün sayısı (bugün dahil). */
export const telemetryWindowDays: number = 30;

const dayMs: number = 86_400_000;

/** Sürüm başına etkin hesap. */
export interface VersionCount {
  readonly version: string;
  readonly users: number;
}

/** Amaç başına token ve çağrı. */
export interface PurposeTotal {
  readonly purpose: string;
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly calls: number;
}

/** Günlük amaç satırı. */
export interface PurposeDay extends PurposeTotal {
  readonly day: string;
}

/** Tür ve sürüm başına olay sayısı. */
export interface EventCount {
  readonly kind: string;
  readonly appVersion: string;
  readonly count: number;
}

/** Günlük olay sayısı (tüm sürümler). */
export interface EventDay {
  readonly day: string;
  readonly kind: string;
  readonly count: number;
}

/** Tür ve kova başına süre dağılımı (tüm sürümler). */
export interface DurationCount {
  readonly kind: string;
  readonly bucket: string;
  readonly count: number;
  readonly secondsSum: number;
}

/** Özellik ve değer başına kullanım (hesap-gün sayısı ve toplam). */
export interface FeatureCount {
  readonly feature: string;
  readonly value: string;
  readonly users: number;
  readonly total: number;
}

/** Telemetri görünümünün yanıtı. */
export interface AdminTelemetry {
  readonly windowDays: number;
  /** `activeUsers`: son görülmesi pencerede olan hesaplar; listeler sürümü bilinenler, çoktan aza. */
  readonly versions: { readonly activeUsers: number; readonly apps: readonly VersionCount[]; readonly os: readonly VersionCount[] };
  /** `totals` toplam tokena göre çoktan aza; `daily` gün ve amaç sırasıyla. */
  readonly purposes: { readonly totals: readonly PurposeTotal[]; readonly daily: readonly PurposeDay[] };
  readonly events: {
    readonly counts: readonly EventCount[];
    readonly daily: readonly EventDay[];
    readonly durations: readonly DurationCount[];
    readonly durationBuckets: readonly string[];
  };
  /** `reports`: pencerede gelen günlük rapor sayısı (hesap-gün; payda); `rows` `report` dışındaki satırlar. */
  readonly features: { readonly reports: number; readonly rows: readonly FeatureCount[] };
}

/** Sürüm sütunu başına etkin hesap sayısı. */
async function versionCounts(db: D1Database, column: "last_app_version" | "last_os_version", sinceMs: number): Promise<VersionCount[]> {
  const rows: D1Result<VersionCount> = await db
    .prepare(
      `SELECT ${column} AS version, COUNT(*) AS users FROM users
       WHERE last_seen_at >= ? AND ${column} IS NOT NULL GROUP BY ${column} ORDER BY users DESC, version`,
    )
    .bind(sinceMs)
    .all<VersionCount>();
  return rows.results;
}

/** Telemetri görünümü (son 30 gün, bugün dahil). */
export async function adminTelemetry(db: D1Database, now: Date): Promise<AdminTelemetry> {
  const sinceMs: number = now.getTime() - telemetryWindowDays * dayMs;
  const firstDay: string = dayKey(new Date(now.getTime() - (telemetryWindowDays - 1) * dayMs));
  const [active, apps, os, purposeTotals, purposeDays, eventCounts, eventDays, durations, reports, features] = await Promise.all([
    db.prepare("SELECT COUNT(*) AS users FROM users WHERE last_seen_at >= ?").bind(sinceMs).first<{ users: number }>(),
    versionCounts(db, "last_app_version", sinceMs),
    versionCounts(db, "last_os_version", sinceMs),
    db
      .prepare(
        `SELECT purpose, SUM(input_tokens) AS inputTokens, SUM(output_tokens) AS outputTokens, SUM(calls) AS calls
         FROM llm_purpose_usage WHERE day >= ? GROUP BY purpose ORDER BY inputTokens + outputTokens DESC, purpose`,
      )
      .bind(firstDay)
      .all<PurposeTotal>(),
    db
      .prepare(
        `SELECT day, purpose, input_tokens AS inputTokens, output_tokens AS outputTokens, calls
         FROM llm_purpose_usage WHERE day >= ? ORDER BY day, purpose`,
      )
      .bind(firstDay)
      .all<PurposeDay>(),
    db
      .prepare(
        `SELECT kind, app_version AS appVersion, SUM(count) AS count FROM client_event_counts WHERE day >= ?
         GROUP BY kind, app_version ORDER BY kind, count DESC, app_version`,
      )
      .bind(firstDay)
      .all<EventCount>(),
    db
      .prepare("SELECT day, kind, SUM(count) AS count FROM client_event_counts WHERE day >= ? GROUP BY day, kind ORDER BY day, kind")
      .bind(firstDay)
      .all<EventDay>(),
    db
      .prepare(
        `SELECT kind, bucket, SUM(count) AS count, SUM(seconds_sum) AS secondsSum FROM client_event_durations WHERE day >= ?
         GROUP BY kind, bucket ORDER BY kind, bucket`,
      )
      .bind(firstDay)
      .all<DurationCount>(),
    db
      .prepare("SELECT COALESCE(SUM(users), 0) AS users FROM feature_usage_daily WHERE day >= ? AND feature = 'report'")
      .bind(firstDay)
      .first<{ users: number }>(),
    db
      .prepare(
        `SELECT feature, value, SUM(users) AS users, SUM(total) AS total FROM feature_usage_daily
         WHERE day >= ? AND feature != 'report' GROUP BY feature, value ORDER BY feature, users DESC, value`,
      )
      .bind(firstDay)
      .all<FeatureCount>(),
  ]);
  return {
    windowDays: telemetryWindowDays,
    versions: { activeUsers: active?.users ?? 0, apps, os },
    purposes: { totals: purposeTotals.results, daily: purposeDays.results },
    events: { counts: eventCounts.results, daily: eventDays.results, durations: durations.results, durationBuckets: [...telemetryDurationBuckets] },
    features: { reports: reports?.users ?? 0, rows: features.results },
  };
}
