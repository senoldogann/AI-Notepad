import { z } from "zod";
import { ApiError } from "./errors";
import { dayKey } from "./usage";

/**
 * İstemci telemetrisi (yönetim paneli "Telemetri"): Mac uygulaması Ayarlar'daki "Anonim kullanım istatistiklerini
 * paylaş" açıkken güvenilirlik ve süre olaylarını (`POST /v1/telemetry`) ve günde bir özellik kullanımını
 * (`POST /v1/telemetry/features`) gönderir. Gövdeler yalnızca sabit listelerden değerler, sayılar ve süreler taşır;
 * toplantı içeriği, ad, başlık, adres ya da dosya yolu taşıyamaz. Toplamlar gün başına tutulur ve hesaba bağlı değildir;
 * hesabın satırında yalnızca günlük istek sayısı (kötüye kullanım sınırı) ve son özellik raporunun günü
 * (tekilleştirme) durur.
 *
 * Listeler istemcinin enum'larıyla birebir aynıdır (Swift `ServerParityTests` bu dizileri okur).
 */

/** Sayılan güvenilirlik olayları: Deepgram canlı bağlantısının kopması ve yeniden kurulması, son geçişin yarıda
 * bırakılması, not üretiminin başarısızlığı, kaydın süre sınırına ulaşıp kendiliğinden bitmesi. */
export const telemetryCountKinds = ["deepgram_socket_drop", "deepgram_reconnect", "final_pass_give_up", "note_generation_failed", "recording_overrun"] as const;

/** Süresi ölçülen işler: son geçiş ve not yazımı (saniye). */
export const telemetryDurationKinds = ["final_pass_duration", "note_generation_duration"] as const;

/** Notun gönderildiği entegrasyon türleri (hedef adresi ya da adı değil, yalnızca türü). */
export const telemetryIntegrations = [
  "slack",
  "teams",
  "discord",
  "webhook",
  "notion",
  "apple_notes",
  "markdown_folder",
  "tracker_linear",
  "tracker_jira",
  "tracker_notion",
] as const;

/** Dışa aktarma biçimleri. */
export const telemetryExportFormats = [
  "pdf",
  "html",
  "markdown",
  "docx",
  "transcript_text",
  "srt",
  "copy_markdown",
  "email",
  "pdf_share",
  "link_share",
  "audio_clip",
] as const;

/** Canlı çevirinin hedef dilleri (uygulamanın not dilleri). */
export const telemetryLanguages = [
  "fi", "en", "sv", "nb", "da", "et", "de", "nl", "fr", "es", "pt", "it", "pl", "cs", "sk", "hu", "ro", "bg", "hr", "el", "lv", "lt",
  "ru", "uk", "tr", "az", "ar", "he", "fa", "hi", "zh-Hans", "zh-Hant", "ja", "ko", "id", "vi", "th",
] as const;

/** Süre kovaları: `le_N` N saniyeye kadar (dahil), `gt_3600` bir saatten uzun. */
export const telemetryDurationBuckets = ["le_10", "le_30", "le_60", "le_120", "le_300", "le_600", "le_1200", "le_1800", "le_3600", "gt_3600"] as const;

export type TelemetryCountKind = (typeof telemetryCountKinds)[number];
export type TelemetryDurationKind = (typeof telemetryDurationKinds)[number];
export type TelemetryDurationBucket = (typeof telemetryDurationBuckets)[number];

/** Kovaların üst sınırları (saniye); `telemetryDurationBuckets` ile aynı sırada, son kova sınırsızdır. */
const bucketUpperBounds: ReadonlyArray<readonly [number, TelemetryDurationBucket]> = [
  [10, "le_10"],
  [30, "le_30"],
  [60, "le_60"],
  [120, "le_120"],
  [300, "le_300"],
  [600, "le_600"],
  [1200, "le_1200"],
  [1800, "le_1800"],
  [3600, "le_3600"],
];

/** Kullanıcı başına günde en çok telemetri isteği (iki uç birlikte). */
export const telemetryDailyRequestCap: number = 200;

/** Özellik raporunun en çok kaç gün geriye ait olabileceği (bugün dahil değil). */
const featureReportMaxAgeDays: number = 7;

const dayMs: number = 86_400_000;

/** Sürenin kovası. Saf fonksiyondur. */
export function durationBucket(seconds: number): TelemetryDurationBucket {
  const match: readonly [number, TelemetryDurationBucket] | undefined = bucketUpperBounds.find(
    ([upper]: readonly [number, TelemetryDurationBucket]): boolean => seconds <= upper,
  );
  return match === undefined ? "gt_3600" : match[1];
}

const eventCountSchema = z.number().int().min(1).max(1000);
const usageCountSchema = z.number().int().min(0).max(1000);

/** `POST /v1/telemetry` gövdesi: 1–50 olay; sayılan olay `count`, süre olayı `seconds` taşır. */
export const telemetryEventsSchema = z.strictObject({
  events: z
    .array(
      z.discriminatedUnion("kind", [
        z.strictObject({ kind: z.enum(telemetryCountKinds), count: eventCountSchema }),
        z.strictObject({ kind: z.enum(telemetryDurationKinds), seconds: z.number().min(0).max(86_400) }),
      ]),
    )
    .min(1)
    .max(50),
});

export type TelemetryEvents = z.output<typeof telemetryEventsSchema>;

/**
 * `POST /v1/telemetry/features` gövdesi: raporun ait olduğu UTC günü ve o gün kullanılan özellikler. Entegrasyon ve
 * dışa aktarma nesneleri her türü içermelidir (eksik ya da fazla anahtar reddedilir). Çeviri dili yalnızca canlı çeviri
 * kullanıldıysa verilir.
 */
export const featureUsageSchema = z
  .strictObject({
    day: z.iso.date(),
    liveTranslation: z.boolean(),
    translationLanguage: z.enum(telemetryLanguages).nullable(),
    ask: z.boolean(),
    integrations: z.record(z.enum(telemetryIntegrations), usageCountSchema),
    exports: z.record(z.enum(telemetryExportFormats), usageCountSchema),
    mcp: z.boolean(),
    onDeviceLive: z.boolean(),
  })
  .refine((body: { liveTranslation: boolean; translationLanguage: string | null }): boolean => body.liveTranslation || body.translationLanguage === null, {
    path: ["translationLanguage"],
  });

export type FeatureUsage = z.output<typeof featureUsageSchema>;

/** Toplanmış sayılan olay. */
interface CountAggregate {
  readonly kind: TelemetryCountKind;
  readonly count: number;
}

/** Toplanmış süre kovası. */
interface DurationAggregate {
  readonly kind: TelemetryDurationKind;
  readonly bucket: TelemetryDurationBucket;
  readonly count: number;
  readonly secondsSum: number;
}

/** Gövdedeki olayların tür (ve kova) başına toplamı: tek toplu işlemde her anahtar bir kez yazılır. Saf fonksiyondur. */
export function aggregateEvents(events: TelemetryEvents["events"]): { readonly counts: CountAggregate[]; readonly durations: DurationAggregate[] } {
  const counts: Map<TelemetryCountKind, number> = new Map();
  const durations: Map<string, DurationAggregate> = new Map();
  for (const event of events) {
    if ("count" in event) {
      counts.set(event.kind, (counts.get(event.kind) ?? 0) + event.count);
    } else {
      const bucket: TelemetryDurationBucket = durationBucket(event.seconds);
      const key: string = `${event.kind}|${bucket}`;
      const previous: DurationAggregate | undefined = durations.get(key);
      durations.set(key, {
        kind: event.kind,
        bucket,
        count: (previous?.count ?? 0) + 1,
        secondsSum: (previous?.secondsSum ?? 0) + event.seconds,
      });
    }
  }
  return {
    counts: [...counts].map(([kind, count]: [TelemetryCountKind, number]): CountAggregate => ({ kind, count })),
    durations: [...durations.values()],
  };
}

/**
 * Telemetri isteğini hesabın günlük sayacına (UTC) yazar; günde `telemetryDailyRequestCap`'ten fazlası
 * `daily_cap_reached`. Sayaç tek koşullu ifadeyle artar (eşzamanlı istekler sınırı aşamaz).
 */
export async function countTelemetryRequest(db: D1Database, userId: string, now: Date): Promise<void> {
  const row: { telemetry_batches: number } | null = await db
    .prepare(
      `UPDATE users SET telemetry_batches = CASE WHEN telemetry_day = ?1 THEN telemetry_batches + 1 ELSE 1 END, telemetry_day = ?1
       WHERE id = ?2 RETURNING telemetry_batches`,
    )
    .bind(dayKey(now), userId)
    .first<{ telemetry_batches: number }>();
  if (row === null) {
    throw new ApiError("not_found", "Hesap bulunamadı.");
  }
  if (row.telemetry_batches > telemetryDailyRequestCap) {
    throw new ApiError("daily_cap_reached", "Bugünkü telemetri sınırı doldu; yarın yeniden dene.");
  }
}

/** Olayları bugünün (UTC) ve uygulama sürümünün toplamlarına ekler (tek toplu işlem). */
export async function recordTelemetryEvents(db: D1Database, events: TelemetryEvents["events"], appVersion: string, now: Date): Promise<void> {
  const day: string = dayKey(now);
  const aggregated = aggregateEvents(events);
  await db.batch([
    ...aggregated.counts.map(
      (entry: CountAggregate): D1PreparedStatement =>
        db
          .prepare(
            `INSERT INTO client_event_counts (day, kind, app_version, count) VALUES (?, ?, ?, ?)
             ON CONFLICT(day, kind, app_version) DO UPDATE SET count = count + excluded.count`,
          )
          .bind(day, entry.kind, appVersion, entry.count),
    ),
    ...aggregated.durations.map(
      (entry: DurationAggregate): D1PreparedStatement =>
        db
          .prepare(
            `INSERT INTO client_event_durations (day, kind, app_version, bucket, count, seconds_sum) VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT(day, kind, app_version, bucket) DO UPDATE SET count = count + excluded.count, seconds_sum = seconds_sum + excluded.seconds_sum`,
          )
          .bind(day, entry.kind, appVersion, entry.bucket, entry.count, entry.secondsSum),
    ),
  ]);
}

/** Özellik satırının artışı. */
export interface FeatureIncrement {
  readonly feature: string;
  readonly value: string;
  readonly total: number;
}

/**
 * Raporun özellik satırları: `report` her zaman (payda), açık bayraklar birer, kullanılan entegrasyon ve dışa aktarma
 * türleri (sayısı > 0) kullanım sayısıyla. Saf fonksiyondur.
 */
export function featureIncrements(usage: FeatureUsage): FeatureIncrement[] {
  const flag = (enabled: boolean, feature: string): FeatureIncrement[] => (enabled ? [{ feature, value: "", total: 1 }] : []);
  const counted = (feature: string, counts: Readonly<Record<string, number>>): FeatureIncrement[] =>
    Object.entries(counts)
      .filter(([, count]: [string, number]): boolean => count > 0)
      .map(([value, count]: [string, number]): FeatureIncrement => ({ feature, value, total: count }));
  return [
    { feature: "report", value: "", total: 1 },
    ...flag(usage.liveTranslation, "live_translation"),
    ...(usage.translationLanguage === null ? [] : [{ feature: "translation_language", value: usage.translationLanguage, total: 1 }]),
    ...flag(usage.ask, "ask"),
    ...counted("integration", usage.integrations),
    ...counted("export", usage.exports),
    ...flag(usage.mcp, "mcp"),
    ...flag(usage.onDeviceLive, "on_device_live"),
  ];
}

/** Raporun günü bugün ile `featureReportMaxAgeDays` gün öncesi arasında olmalı (UTC); değilse `invalid_body`. Saf fonksiyondur. */
function requireFeatureReportDay(day: string, now: Date): void {
  const oldest: string = dayKey(new Date(now.getTime() - featureReportMaxAgeDays * dayMs));
  if (day > dayKey(now) || day < oldest) {
    throw new ApiError("invalid_body", "İstek gövdesi geçersiz: day: too_old_or_future");
  }
}

/**
 * Günlük özellik raporunu sayar: hesabın son raporlanan günü bu günden eskiyse (ya da hiç yoksa) gün hesaba yazılır ve
 * satırlar günün toplamlarına eklenir (`true`); aynı gün ya da daha eskisi yeniden sayılmaz (`false`).
 */
export async function recordFeatureUsage(db: D1Database, userId: string, usage: FeatureUsage, now: Date): Promise<boolean> {
  requireFeatureReportDay(usage.day, now);
  const claimed: D1Result = await db
    .prepare("UPDATE users SET telemetry_features_day = ?1 WHERE id = ?2 AND (telemetry_features_day IS NULL OR telemetry_features_day < ?1)")
    .bind(usage.day, userId)
    .run();
  if (claimed.meta.changes === 0) {
    return false;
  }
  await db.batch(
    featureIncrements(usage).map(
      (increment: FeatureIncrement): D1PreparedStatement =>
        db
          .prepare(
            `INSERT INTO feature_usage_daily (day, feature, value, users, total) VALUES (?, ?, ?, 1, ?)
             ON CONFLICT(day, feature, value) DO UPDATE SET users = users + 1, total = total + excluded.total`,
          )
          .bind(usage.day, increment.feature, increment.value, increment.total),
    ),
  );
  return true;
}
