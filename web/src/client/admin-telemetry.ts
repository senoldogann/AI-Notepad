// Yönetim panelinin telemetri görünümü (`/v1/admin/telemetry`, son 30 gün): sürüm benimsenmesi (Mac uygulamasının ve
// macOS'un sürümüne göre etkin hesaplar), amaca göre yapay zekâ tokenları, istemci güvenilirlik olayları (uygulama
// sürümüne ve güne göre), son geçiş ve not süresinin dağılımı, günlük özellik raporları. Sürümler hesap başına son
// değerdir; diğer her şey hesaba bağlı olmayan günlük toplamdır. Yanıt sınırda katı biçimde doğrulanır.
import {
  ApiResponseError,
  type JsonObject,
  type JsonValue,
  type RawResponse,
  numberField,
  objectArrayField,
  objectField,
  parseObject,
  stringField,
} from "./api";
import { fillTable, formatCompact, formatCount, formatDay, formatRate, node, tableRow } from "./admin-format";
import {
  type AdminTelemetryCopy,
  type CountEventKind,
  type DurationEventKind,
  type FeatureName,
  type FlagFeature,
  type LlmPurpose,
  adminTelemetryCopy,
  countEventKinds,
  durationEventKinds,
  featureNames,
  flagFeatures,
  llmPurposes,
} from "./admin-telemetry-copy";
import { fill } from "./copy";
import { element } from "./dom";
import { authorizedSend } from "./session";
import { siteLocale } from "../config";

const telemetryText: AdminTelemetryCopy = adminTelemetryCopy;

const telemetryPath: string = "/v1/admin/telemetry";

/** Sürüm başına hesap sayısı. */
export interface VersionUsers {
  readonly version: string;
  readonly users: number;
}

/** Amacın token toplamı. */
export interface PurposeTotal {
  readonly purpose: LlmPurpose;
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly calls: number;
}

/** Amacın bir günlük token toplamı. */
export interface PurposeDay extends PurposeTotal {
  readonly day: string;
}

/** Sayılan olayın uygulama sürümüne göre toplamı. */
export interface EventCount {
  readonly kind: CountEventKind;
  readonly appVersion: string;
  readonly count: number;
}

/** Sayılan olayın bir günlük toplamı. */
export interface EventDay {
  readonly day: string;
  readonly kind: CountEventKind;
  readonly count: number;
}

/** Süre dilimi: ölçüm sayısı ve süreler toplamı (saniye). */
export interface DurationBucket {
  readonly kind: DurationEventKind;
  readonly bucket: string;
  readonly count: number;
  readonly secondsSum: number;
}

/** Özelliğin (ve varsa değerinin) kullanıcı-günü ve kullanım toplamı. */
export interface FeatureRow {
  readonly feature: FeatureName;
  readonly value: string;
  readonly users: number;
  readonly total: number;
}

/** `GET /v1/admin/telemetry` yanıtı. */
export interface AdminTelemetry {
  readonly windowDays: number;
  readonly versions: { readonly activeUsers: number; readonly apps: readonly VersionUsers[]; readonly os: readonly VersionUsers[] };
  readonly purposes: { readonly totals: readonly PurposeTotal[]; readonly daily: readonly PurposeDay[] };
  readonly events: {
    readonly counts: readonly EventCount[];
    readonly daily: readonly EventDay[];
    readonly durations: readonly DurationBucket[];
    readonly durationBuckets: readonly string[];
  };
  readonly features: { readonly reports: number; readonly rows: readonly FeatureRow[] };
}

/** Telemetri görünümünün dışarıya açtığı işlemler. */
export interface TelemetryView {
  /** Görünümü (yeniden) yükler. */
  readonly refresh: () => Promise<void>;
  /** İlk açılışta yükler (sonrakilerde bir şey yapmaz). */
  readonly ensureLoaded: () => Promise<void>;
}

const dayPattern: RegExp = /^\d{4}-\d{2}-\d{2}$/;
/** Süre dilimi etiketi: `le_<saniye>` (en çok) ya da `gt_<saniye>` (üstü). */
const bucketPattern: RegExp = /^(le|gt)_(\d{1,6})$/;

// ---------- Okuma ----------

/** Değeri izinli metinlerden biri olan alan; değilse `ApiResponseError`. */
function literalField<Literal extends string>(object: JsonObject, key: string, allowed: readonly Literal[], response: RawResponse, path: string): Literal {
  const value: string = stringField(object, key, response, path);
  const match: Literal | undefined = allowed.find((candidate: Literal): boolean => candidate === value);
  if (match === undefined) {
    throw new ApiResponseError(path, response.status, `"${key}" bilinmeyen değer "${value}"`, response.text);
  }
  return match;
}

/** Negatif olmayan sayı alanı; değilse `ApiResponseError`. */
function countField(object: JsonObject, key: string, response: RawResponse, path: string): number {
  const value: number = numberField(object, key, response, path);
  if (value < 0) {
    throw new ApiResponseError(path, response.status, `"${key}" negatif`, response.text);
  }
  return value;
}

/** `YYYY-MM-DD` gün alanı. */
function dayField(object: JsonObject, response: RawResponse, path: string): string {
  const day: string = stringField(object, "day", response, path);
  if (!dayPattern.test(day)) {
    throw new ApiResponseError(path, response.status, `"day" YYYY-MM-DD değil: ${day}`, response.text);
  }
  return day;
}

/** Süre dilimi etiketini doğrular. */
function requireBucket(bucket: string, response: RawResponse, path: string): string {
  if (!bucketPattern.test(bucket)) {
    throw new ApiResponseError(path, response.status, `süre dilimi bilinmeyen biçimde: ${bucket}`, response.text);
  }
  return bucket;
}

/** Süre dilimi etiketleri dizisi (sıralı). */
function bucketListField(object: JsonObject, key: string, response: RawResponse, path: string): string[] {
  const value: JsonValue | undefined = object[key];
  if (!Array.isArray(value)) {
    throw new ApiResponseError(path, response.status, `"${key}" dizi değil`, response.text);
  }
  return value.map((item: JsonValue): string => {
    if (typeof item !== "string") {
      throw new ApiResponseError(path, response.status, `"${key}" öğesi metin değil`, response.text);
    }
    return requireBucket(item, response, path);
  });
}

/** Sürüm dizisini okur. */
function versionList(owner: JsonObject, key: string, response: RawResponse, path: string): VersionUsers[] {
  return objectArrayField(owner, key, response, path).map(
    (item: JsonObject): VersionUsers => ({ version: stringField(item, "version", response, path), users: countField(item, "users", response, path) }),
  );
}

/** Amacın token alanlarını okur. */
function purposeTotal(item: JsonObject, response: RawResponse, path: string): PurposeTotal {
  return {
    purpose: literalField(item, "purpose", llmPurposes, response, path),
    inputTokens: countField(item, "inputTokens", response, path),
    outputTokens: countField(item, "outputTokens", response, path),
    calls: countField(item, "calls", response, path),
  };
}

/** `GET /v1/admin/telemetry` yanıtını okur. */
export function parseAdminTelemetry(response: RawResponse, path: string): AdminTelemetry {
  const body: JsonObject = parseObject(response, path);
  const versions: JsonObject = objectField(body, "versions", response, path);
  const purposes: JsonObject = objectField(body, "purposes", response, path);
  const events: JsonObject = objectField(body, "events", response, path);
  const features: JsonObject = objectField(body, "features", response, path);
  return {
    windowDays: countField(body, "windowDays", response, path),
    versions: {
      activeUsers: countField(versions, "activeUsers", response, path),
      apps: versionList(versions, "apps", response, path),
      os: versionList(versions, "os", response, path),
    },
    purposes: {
      totals: objectArrayField(purposes, "totals", response, path).map((item: JsonObject): PurposeTotal => purposeTotal(item, response, path)),
      daily: objectArrayField(purposes, "daily", response, path).map(
        (item: JsonObject): PurposeDay => ({ day: dayField(item, response, path), ...purposeTotal(item, response, path) }),
      ),
    },
    events: {
      counts: objectArrayField(events, "counts", response, path).map(
        (item: JsonObject): EventCount => ({
          kind: literalField(item, "kind", countEventKinds, response, path),
          appVersion: stringField(item, "appVersion", response, path),
          count: countField(item, "count", response, path),
        }),
      ),
      daily: objectArrayField(events, "daily", response, path).map(
        (item: JsonObject): EventDay => ({
          day: dayField(item, response, path),
          kind: literalField(item, "kind", countEventKinds, response, path),
          count: countField(item, "count", response, path),
        }),
      ),
      durations: objectArrayField(events, "durations", response, path).map(
        (item: JsonObject): DurationBucket => ({
          kind: literalField(item, "kind", durationEventKinds, response, path),
          bucket: requireBucket(stringField(item, "bucket", response, path), response, path),
          count: countField(item, "count", response, path),
          secondsSum: countField(item, "secondsSum", response, path),
        }),
      ),
      durationBuckets: bucketListField(events, "durationBuckets", response, path),
    },
    features: {
      reports: countField(features, "reports", response, path),
      rows: objectArrayField(features, "rows", response, path).map(
        (item: JsonObject): FeatureRow => ({
          feature: literalField(item, "feature", featureNames, response, path),
          value: stringField(item, "value", response, path),
          users: countField(item, "users", response, path),
          total: countField(item, "total", response, path),
        }),
      ),
    },
  };
}

/** Telemetri özetini getirir. */
export async function fetchTelemetry(): Promise<AdminTelemetry> {
  return parseAdminTelemetry(await authorizedSend({ method: "GET", path: telemetryPath, body: null, attempts: 3 }), telemetryPath);
}

// ---------- Biçimlendirme (saf) ----------

/** Saniyeyi kısa yazar ("45 s", "2 min", "1.5 min"). Saf fonksiyondur. */
export function formatSeconds(seconds: number): string {
  return seconds < 60
    ? fill(telemetryText.seconds, { value: formatCount(Math.round(seconds)) })
    : fill(telemetryText.minutes, { value: formatCount(Math.round((seconds / 60) * 10) / 10) });
}

/** Süre dilimi etiketinin metni ("≤10 s", ">60 min"); biçim okunurken doğrulanmıştır. Saf fonksiyondur. */
export function bucketLabel(bucket: string): string {
  const match: RegExpExecArray | null = bucketPattern.exec(bucket);
  const seconds: number = Number(match?.[2] ?? "0");
  return fill(match?.[1] === "gt" ? telemetryText.bucketOver : telemetryText.bucketAtMost, { value: formatSeconds(seconds) });
}

/** Dil kodunun İngilizce adı ("Turkish (tr)"); tanınmazsa yalnızca kod. Saf fonksiyondur. */
export function languageLabel(code: string): string {
  const names: Intl.DisplayNames = new Intl.DisplayNames([siteLocale], { type: "language" });
  const name: string | undefined = names.of(code);
  return name === undefined || name === code ? code : `${name} (${code})`;
}

/** Değer etiketi: bilinen kodun adı, bilinmeyen (sunucuya yeni eklenmiş) kod olduğu gibi. Saf fonksiyondur. */
function knownLabel(labels: Readonly<Record<string, string>>, value: string): string {
  return labels[value] ?? value;
}

// ---------- DOM ----------

/** Pay hücresi: ince ölçer ve yüzde. */
function shareCell(part: number, whole: number): HTMLElement {
  const cell: HTMLElement = node("span", "telemetry-share", "");
  const meter: HTMLProgressElement = node("progress", "meter telemetry-share__meter", "");
  meter.max = 1;
  meter.value = whole === 0 ? 0 : part / whole;
  meter.setAttribute("aria-hidden", "true");
  cell.append(meter, node("span", "tabular", formatRate(part, whole)));
  return cell;
}

/** Tabloyu doldurur ve boş satırını gösterir ya da gizler. */
function fillWithEmpty(id: string, rows: readonly HTMLTableRowElement[]): void {
  fillTable(element(`${id}-rows`, HTMLTableSectionElement), rows);
  element(`${id}-empty`, HTMLElement).classList.toggle("hidden", rows.length > 0);
}

/** Sürüm tablosu satırları (çoktan aza). */
function versionRows(versions: readonly VersionUsers[], activeUsers: number): HTMLTableRowElement[] {
  return [...versions]
    .sort((left: VersionUsers, right: VersionUsers): number => right.users - left.users)
    .map((entry: VersionUsers): HTMLTableRowElement => tableRow([node("span", "mono", entry.version), formatCount(entry.users), shareCell(entry.users, activeUsers)]));
}

/** Toplam token. Saf fonksiyondur. */
function tokensOf(total: PurposeTotal): number {
  return total.inputTokens + total.outputTokens;
}

/** Amaç tablosunu ve günlük token tablosunu çizer. */
function renderPurposes(purposes: AdminTelemetry["purposes"]): void {
  const totals: PurposeTotal[] = [...purposes.totals].sort((left: PurposeTotal, right: PurposeTotal): number => tokensOf(right) - tokensOf(left));
  const allTokens: number = totals.reduce((sum: number, total: PurposeTotal): number => sum + tokensOf(total), 0);
  fillWithEmpty(
    "telemetry-purposes",
    totals.map((total: PurposeTotal): HTMLTableRowElement =>
      tableRow([
        telemetryText.purposes[total.purpose],
        formatCount(total.calls),
        formatCompact(total.inputTokens),
        formatCompact(total.outputTokens),
        shareCell(tokensOf(total), allTokens),
      ]),
    ),
  );
  // Gün başına toplam: amaçlar birleştirilir, satırın ipucu amaçların dökümüdür (yeniden eskiye).
  const days: string[] = [...new Set(purposes.daily.map((entry: PurposeDay): string => entry.day))].sort().reverse();
  const dayTotals: { readonly day: string; readonly calls: number; readonly tokens: number; readonly detail: string }[] = days.map((day: string) => {
    const entries: PurposeDay[] = purposes.daily.filter((entry: PurposeDay): boolean => entry.day === day).sort((left: PurposeDay, right: PurposeDay): number => tokensOf(right) - tokensOf(left));
    return {
      day,
      calls: entries.reduce((sum: number, entry: PurposeDay): number => sum + entry.calls, 0),
      tokens: entries.reduce((sum: number, entry: PurposeDay): number => sum + tokensOf(entry), 0),
      detail: entries.map((entry: PurposeDay): string => `${telemetryText.purposes[entry.purpose]}: ${formatCompact(tokensOf(entry))}`).join(" · "),
    };
  });
  const peak: number = Math.max(0, ...dayTotals.map((entry): number => entry.tokens));
  fillWithEmpty(
    "telemetry-tokens-daily",
    dayTotals.map((entry): HTMLTableRowElement => {
      const row: HTMLTableRowElement = tableRow([formatDay(entry.day), formatCount(entry.calls), formatCompact(entry.tokens), shareCell(entry.tokens, peak)]);
      row.title = entry.detail;
      return row;
    }),
  );
}

/** Güvenilirlik olaylarını (türe ve sürüme göre, güne göre) çizer. */
function renderEvents(events: AdminTelemetry["events"]): void {
  const kindRows: HTMLTableRowElement[] = countEventKinds
    .map((kind: CountEventKind): { readonly kind: CountEventKind; readonly entries: EventCount[] } => ({
      kind,
      entries: events.counts.filter((entry: EventCount): boolean => entry.kind === kind).sort((left: EventCount, right: EventCount): number => right.count - left.count),
    }))
    .filter((group): boolean => group.entries.length > 0)
    .map((group): HTMLTableRowElement =>
      tableRow([
        telemetryText.countKinds[group.kind],
        formatCount(group.entries.reduce((sum: number, entry: EventCount): number => sum + entry.count, 0)),
        node("span", "small", group.entries.map((entry: EventCount): string => `${entry.appVersion}: ${formatCount(entry.count)}`).join(" · ")),
      ]),
    );
  fillWithEmpty("telemetry-events", kindRows);
  const days: string[] = [...new Set(events.daily.map((entry: EventDay): string => entry.day))].sort().reverse();
  fillWithEmpty(
    "telemetry-events-daily",
    days.map((day: string): HTMLTableRowElement =>
      tableRow([
        formatDay(day),
        ...countEventKinds.map((kind: CountEventKind): string =>
          formatCount(events.daily.filter((entry: EventDay): boolean => entry.day === day && entry.kind === kind).reduce((sum: number, entry: EventDay): number => sum + entry.count, 0)),
        ),
      ]),
    ),
  );
  for (const kind of durationEventKinds) {
    renderDuration(kind, events.durations.filter((entry: DurationBucket): boolean => entry.kind === kind), events.durationBuckets);
  }
}

/** Bir sürenin dağılımını (sunucunun dilim sırasıyla) ve ortalamasını çizer. */
function renderDuration(kind: DurationEventKind, entries: readonly DurationBucket[], buckets: readonly string[]): void {
  const runs: number = entries.reduce((sum: number, entry: DurationBucket): number => sum + entry.count, 0);
  const seconds: number = entries.reduce((sum: number, entry: DurationBucket): number => sum + entry.secondsSum, 0);
  const rows: HTMLTableRowElement[] =
    runs === 0
      ? []
      : buckets.map((bucket: string): HTMLTableRowElement => {
          const count: number = entries.filter((entry: DurationBucket): boolean => entry.bucket === bucket).reduce((sum: number, entry: DurationBucket): number => sum + entry.count, 0);
          return tableRow([bucketLabel(bucket), formatCount(count), shareCell(count, runs)]);
        });
  fillWithEmpty(`telemetry-duration-${kind}`, rows);
  element(`telemetry-duration-${kind}-summary`, HTMLElement).textContent =
    runs === 0 ? "" : fill(telemetryText.durationSummary, { runs: formatCount(runs), mean: formatSeconds(seconds / runs) });
}

/** Bir özelliğin değerli satırları (çoktan aza). Saf fonksiyondur. */
function featureValues(rows: readonly FeatureRow[], feature: FeatureName): FeatureRow[] {
  return rows.filter((row: FeatureRow): boolean => row.feature === feature).sort((left: FeatureRow, right: FeatureRow): number => right.users - left.users);
}

/** Değerli özellik tablosu satırları: değer, kullanıcı-günü, rapora oranı, kullanım. */
function valueRows(rows: readonly FeatureRow[], reports: number, label: (value: string) => string): HTMLTableRowElement[] {
  return rows.map((row: FeatureRow): HTMLTableRowElement => tableRow([label(row.value), formatCount(row.users), shareCell(row.users, reports), formatCount(row.total)]));
}

/** Özellik kullanımını çizer; oranların paydası raporların (kullanıcı-günü) sayısıdır. */
function renderFeatures(features: AdminTelemetry["features"], windowDays: number): void {
  const reports: number = features.reports;
  element("telemetry-features-summary", HTMLElement).textContent = fill(telemetryText.featureReports, { reports: formatCount(reports), days: formatCount(windowDays) });
  const flagRows: HTMLTableRowElement[] =
    reports === 0
      ? []
      : flagFeatures.map((feature: FlagFeature): HTMLTableRowElement => {
          const rows: FeatureRow[] = featureValues(features.rows, feature);
          const users: number = rows.reduce((sum: number, row: FeatureRow): number => sum + row.users, 0);
          const total: number = rows.reduce((sum: number, row: FeatureRow): number => sum + row.total, 0);
          return tableRow([telemetryText.flagFeatures[feature], formatCount(users), shareCell(users, reports), formatCount(total)]);
        });
  fillWithEmpty("telemetry-features", flagRows);
  fillWithEmpty("telemetry-languages", valueRows(featureValues(features.rows, "translation_language"), reports, languageLabel));
  fillWithEmpty(
    "telemetry-integrations",
    valueRows(featureValues(features.rows, "integration"), reports, (value: string): string => knownLabel(telemetryText.integrations, value)),
  );
  fillWithEmpty("telemetry-exports", valueRows(featureValues(features.rows, "export"), reports, (value: string): string => knownLabel(telemetryText.exports, value)));
}

/** Telemetri görünümünü çizer. */
function renderTelemetry(telemetry: AdminTelemetry): void {
  const days: string = formatCount(telemetry.windowDays);
  element("telemetry-window", HTMLElement).textContent = fill(telemetryText.windowNote, { days });
  const active: number = telemetry.versions.activeUsers;
  element("telemetry-active", HTMLElement).textContent = fill(telemetryText.activeUsers, { users: formatCount(active), days });
  fillWithEmpty("telemetry-apps", versionRows(telemetry.versions.apps, active));
  fillWithEmpty("telemetry-os", versionRows(telemetry.versions.os, active));
  renderPurposes(telemetry.purposes);
  renderEvents(telemetry.events);
  renderFeatures(telemetry.features, telemetry.windowDays);
}

/** Telemetri görünümünü bağlar. */
export function createTelemetryView(): TelemetryView {
  const state: { loaded: boolean } = { loaded: false };
  const refresh = async (): Promise<void> => {
    renderTelemetry(await fetchTelemetry());
    state.loaded = true;
  };
  return {
    refresh,
    ensureLoaded: async (): Promise<void> => {
      if (!state.loaded) {
        await refresh();
      }
    },
  };
}
