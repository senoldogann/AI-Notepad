import { z } from "zod";
import type { Config } from "./config";
import { randomId } from "./crypto";
import { ApiError } from "./errors";
import { parseWithSchema } from "./http";
import { log } from "./log";

/** Rapor türü: uygulama içi geri bildirim, çökme raporu (MetricKit JSON) ya da sitedeki iletişim formu. */
export type ReportKind = "feedback" | "crash" | "contact";

/** Raporun yönetici durumu. */
export type ReportStatus = "open" | "done";

/** Çökme raporu JSON'unun en çok uzunluğu (karakter). */
export const crashPayloadMaxChars: number = 512 * 1024;

/**
 * `POST /v1/reports` gövdesinin en çok baytı: çökme JSON'u bir JSON dizgesi içinde gelir ve kaçışlarla (`\"`) büyür;
 * 512 K karakterlik yük + %40 kaçış payı + diğer alanlar. Gövde bu sınırı aşarsa hiç ayrıştırılmaz (`413`).
 */
export const reportBodyMaxBytes: number = 768 * 1024;

/** Yönetici listesinde sayfa boyu. */
export const reportPageSize: number = 50;

/** Liste özetinin en çok uzunluğu (karakter). */
const summaryMaxChars: number = 200;

const reportKindSchema = z.enum(["feedback", "crash", "contact"]);
const reportStatusSchema = z.enum(["open", "done"]);
const messageSchema = z.string().trim().min(1).max(5000);
const emailSchema = z.email().max(254);
const appVersionSchema = z.string().trim().min(1).max(40);
const osSchema = z.string().trim().min(1).max(80);

/**
 * `POST /v1/reports` gövdesi; alanlar türe göre:
 * - `contact` (site): `message`, `email` ve `turnstileToken` zorunlu;
 * - `feedback` (uygulama): `message` zorunlu, `email` isteğe bağlı;
 * - `crash` (uygulama): `payload` (JSON nesnesi, en çok 512 K karakter) zorunlu, `message` ve `email` isteğe bağlı.
 * `appVersion` ve `os` her türde isteğe bağlıdır. Türe ait olmayan alan (ör. `feedback` ile `payload`) reddedilir:
 * sessizce yok sayılmaz.
 */
export const reportSchema = z.discriminatedUnion("kind", [
  z.strictObject({
    kind: z.literal("contact"),
    message: messageSchema,
    email: emailSchema,
    turnstileToken: z.string().min(1).max(4096),
    appVersion: appVersionSchema.optional(),
    os: osSchema.optional(),
  }),
  z.strictObject({
    kind: z.literal("feedback"),
    message: messageSchema,
    email: emailSchema.optional(),
    appVersion: appVersionSchema.optional(),
    os: osSchema.optional(),
  }),
  z.strictObject({
    kind: z.literal("crash"),
    payload: z.string().min(2).max(crashPayloadMaxChars),
    message: messageSchema.optional(),
    email: emailSchema.optional(),
    appVersion: appVersionSchema.optional(),
    os: osSchema.optional(),
  }),
]);

/** Doğrulanmış rapor gövdesi. */
export type ReportInput = z.output<typeof reportSchema>;

/** Saklanacak rapor alanları (yokları null). */
interface NewReport {
  readonly kind: ReportKind;
  readonly userId: string | null;
  readonly email: string | null;
  readonly appVersion: string | null;
  readonly os: string | null;
  readonly message: string | null;
  readonly payload: string | null;
  readonly summary: string;
}

/** Mach istisna türleri (`mach/exception_types.h`). */
const machExceptionNames: Readonly<Record<number, string>> = {
  1: "EXC_BAD_ACCESS",
  2: "EXC_BAD_INSTRUCTION",
  3: "EXC_ARITHMETIC",
  4: "EXC_EMULATION",
  5: "EXC_SOFTWARE",
  6: "EXC_BREAKPOINT",
  10: "EXC_CRASH",
  11: "EXC_RESOURCE",
  12: "EXC_GUARD",
};

/** POSIX sinyalleri (Darwin numaraları). */
const signalNames: Readonly<Record<number, string>> = {
  4: "SIGILL",
  5: "SIGTRAP",
  6: "SIGABRT",
  8: "SIGFPE",
  9: "SIGKILL",
  10: "SIGBUS",
  11: "SIGSEGV",
  13: "SIGPIPE",
  15: "SIGTERM",
};

/** MetricKit `MXCrashDiagnostic` JSON'undan imza için okunan alanlar; geri kalanı yok sayılır. */
const crashMetaDataSchema = z.object({
  exceptionType: z.number().int().optional(),
  signal: z.number().int().optional(),
  exceptionReason: z.object({ exceptionName: z.string().optional(), className: z.string().optional() }).optional(),
});
const crashDiagnosticSchema = z.object({ diagnosticMetaData: crashMetaDataSchema });
/** `MXDiagnosticPayload` (çökme dizisi) ya da tek `MXCrashDiagnostic`. */
const metricKitSchema = z.union([z.object({ crashDiagnostics: z.array(crashDiagnosticSchema).min(1) }), crashDiagnosticSchema]);

/** En çok `limit` karakter (Unicode kod noktası; vekil çift bölünmez). Saf fonksiyondur. */
function truncateChars(text: string, limit: number): string {
  return Array.from(text).slice(0, limit).join("");
}

/**
 * Çökme JSON'u nesne olmalıdır (değilse `invalid_body`). MetricKit biçimindeyse ilk çökmenin kısa imzası
 * (`EXC_BAD_ACCESS · SIGSEGV · NSInvalidArgumentException`), değilse null. Saf fonksiyondur.
 */
export function crashPayloadSignature(payload: string): string | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(payload);
  } catch {
    throw new ApiError("invalid_body", "Çökme raporu (payload) geçerli JSON değil.");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new ApiError("invalid_body", "Çökme raporu (payload) bir JSON nesnesi olmalı.");
  }
  const metricKit = metricKitSchema.safeParse(parsed);
  if (!metricKit.success) {
    return null;
  }
  const diagnostic = "crashDiagnostics" in metricKit.data ? metricKit.data.crashDiagnostics[0] : metricKit.data;
  const meta = diagnostic?.diagnosticMetaData;
  if (meta === undefined) {
    return null;
  }
  const parts: string[] = [
    meta.exceptionType === undefined ? null : (machExceptionNames[meta.exceptionType] ?? `exceptionType ${meta.exceptionType}`),
    meta.signal === undefined ? null : (signalNames[meta.signal] ?? `signal ${meta.signal}`),
    meta.exceptionReason?.exceptionName ?? meta.exceptionReason?.className ?? null,
  ].filter((part: string | null): part is string => part !== null && part.length > 0);
  return parts.length === 0 ? null : truncateChars(parts.join(" · "), summaryMaxChars);
}

/**
 * Yönetici listesindeki özet: mesajın ilk 200 karakteri; çökmede imza, yoksa kullanıcının notu, o da yoksa
 * "crash report". Saf fonksiyondur.
 */
export function reportSummary(input: ReportInput): string {
  if (input.kind !== "crash") {
    return truncateChars(input.message, summaryMaxChars);
  }
  const signature: string | null = crashPayloadSignature(input.payload);
  if (signature !== null) {
    return signature;
  }
  return input.message === undefined ? "crash report" : truncateChars(input.message, summaryMaxChars);
}

/** Gövdeden saklanacak satır. Saf fonksiyondur. */
function newReport(input: ReportInput, userId: string | null): NewReport {
  return {
    kind: input.kind,
    userId,
    email: input.email ?? null,
    appVersion: input.appVersion ?? null,
    os: input.os ?? null,
    message: input.message ?? null,
    payload: input.kind === "crash" ? input.payload : null,
    summary: reportSummary(input),
  };
}

/** UTC günün ilk anı (ms). Saf fonksiyondur. */
export function utcDayStartMs(now: Date): number {
  return Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
}

/**
 * Raporu saklar ve kimliğini döndürür. Tüm kullanıcılar için günlük sınır (`REPORTS_PER_DAY`, UTC günü) ekleme ile
 * aynı ifadededir: eşzamanlı istekler sınırı aşamaz; aşılırsa `daily_cap_reached` (429). Log içerik, e-posta ya da yük
 * taşımaz.
 */
export async function createReport(db: D1Database, config: Config, input: ReportInput, userId: string | null, now: Date): Promise<string> {
  const report: NewReport = newReport(input, userId);
  const id: string = randomId();
  const inserted: D1Result = await db
    .prepare(
      `INSERT INTO reports (id, kind, status, created_at, user_id, email, app_version, os, message, payload, summary)
       SELECT ?, ?, 'open', ?, ?, ?, ?, ?, ?, ?, ?
       WHERE (SELECT COUNT(*) FROM reports WHERE created_at >= ?) < ?`,
    )
    .bind(
      id,
      report.kind,
      now.getTime(),
      report.userId,
      report.email,
      report.appVersion,
      report.os,
      report.message,
      report.payload,
      report.summary,
      utcDayStartMs(now),
      config.reportsPerDay,
    )
    .run();
  if (inserted.meta.changes !== 1) {
    log("warn", "reports_daily_cap_reached", { kind: report.kind, cap: config.reportsPerDay });
    throw new ApiError("daily_cap_reached", "Bugün çok fazla rapor alındı; yarın yeniden dene.");
  }
  log("info", "report_received", { reportId: id, kind: report.kind, userId: report.userId, payloadChars: report.payload?.length ?? 0 });
  return id;
}

/** Yönetici listesi süzgeci; null süzmez. `before`: yalnızca bu andan (ms) önce oluşturulanlar. */
export interface ReportFilter {
  readonly kind: ReportKind | null;
  readonly status: ReportStatus | null;
  readonly before: number | null;
}

/** `?kind=&status=&before=<ms>`; boş ya da eksik değer süzgeç yok demektir, başka parametre reddedilir. */
const reportListQuerySchema = z.strictObject({
  kind: z.union([z.literal(""), reportKindSchema]).optional(),
  status: z.union([z.literal(""), reportStatusSchema]).optional(),
  before: z.union([z.literal(""), z.string().regex(/^[1-9][0-9]{0,14}$/)]).optional(),
});

/** Sorgu parametrelerini süzgece çevirir; geçersizse `invalid_body`. Saf fonksiyondur. */
export function parseReportFilter(url: URL): ReportFilter {
  const query = parseWithSchema(reportListQuerySchema, Object.fromEntries(url.searchParams));
  return {
    kind: query.kind === undefined || query.kind === "" ? null : query.kind,
    status: query.status === undefined || query.status === "" ? null : query.status,
    before: query.before === undefined || query.before === "" ? null : Number(query.before),
  };
}

/** Yönetici listesindeki rapor (büyük alanlar olmadan). */
export interface ReportListItem {
  readonly id: string;
  readonly kind: ReportKind;
  readonly status: ReportStatus;
  /** ISO 8601 (UTC). */
  readonly createdAt: string;
  readonly userId: string | null;
  readonly email: string | null;
  readonly appVersion: string | null;
  readonly os: string | null;
  readonly summary: string;
}

/** Liste sayfası; `nextBefore` sonraki sayfanın `before` değeri (ms), son sayfada null. */
export interface ReportList {
  readonly items: readonly ReportListItem[];
  readonly nextBefore: number | null;
}

/** Raporun tamamı. */
export interface ReportDetail {
  readonly id: string;
  readonly kind: ReportKind;
  readonly status: ReportStatus;
  readonly createdAt: string;
  readonly userId: string | null;
  readonly email: string | null;
  readonly appVersion: string | null;
  readonly os: string | null;
  readonly message: string | null;
  readonly payload: string | null;
}

interface ReportListRow {
  readonly id: string;
  readonly kind: ReportKind;
  readonly status: ReportStatus;
  readonly created_at: number;
  readonly user_id: string | null;
  readonly email: string | null;
  readonly app_version: string | null;
  readonly os: string | null;
  readonly summary: string;
}

interface ReportDetailRow extends Omit<ReportListRow, "summary"> {
  readonly message: string | null;
  readonly payload: string | null;
}

/** Satırın liste öğesi. Saf fonksiyondur. */
function listItem(row: ReportListRow): ReportListItem {
  return {
    id: row.id,
    kind: row.kind,
    status: row.status,
    createdAt: new Date(row.created_at).toISOString(),
    userId: row.user_id,
    email: row.email,
    appVersion: row.app_version,
    os: row.os,
    summary: row.summary,
  };
}

/**
 * Bir sayfaya `pageSize + 1` satırdan (yeniden eskiye) sayfayı ve sonraki imleci çıkarır. İmleç milisaniyedir; aynı
 * milisaniyedeki raporlar sayfa sınırında bölünmesin diye sondaki eş zamanlı grup sonraki sayfaya bırakılır
 * (`nextBefore` = grubun anı + 1). Bütün sayfa tek milisaniyedeyse (pratikte olmaz: rapor IP başına dakikada 5) sayfa
 * olduğu gibi döner ve o milisaniyenin fazlası atlanır. Saf fonksiyondur.
 */
export function pageOf(rows: readonly ReportListRow[], pageSize: number): { readonly rows: readonly ReportListRow[]; readonly nextBefore: number | null } {
  if (rows.length <= pageSize) {
    return { rows, nextBefore: null };
  }
  const page: readonly ReportListRow[] = rows.slice(0, pageSize);
  const boundary: number = page[page.length - 1]?.created_at ?? 0;
  if (rows[pageSize]?.created_at !== boundary) {
    return { rows: page, nextBefore: boundary };
  }
  const complete: readonly ReportListRow[] = page.filter((row: ReportListRow): boolean => row.created_at > boundary);
  return complete.length === 0 ? { rows: page, nextBefore: boundary } : { rows: complete, nextBefore: boundary + 1 };
}

/** Raporları yeniden eskiye listeler (sayfa 50); büyük alanlar (`message`, `payload`) okunmaz. */
export async function listReports(db: D1Database, filter: ReportFilter): Promise<ReportList> {
  const result = await db
    .prepare(
      `SELECT id, kind, status, created_at, user_id, email, app_version, os, summary FROM reports
       WHERE (?1 IS NULL OR kind = ?1) AND (?2 IS NULL OR status = ?2) AND created_at < ?3
       ORDER BY created_at DESC, id DESC LIMIT ?4`,
    )
    .bind(filter.kind, filter.status, filter.before ?? Number.MAX_SAFE_INTEGER, reportPageSize + 1)
    .all<ReportListRow>();
  const page = pageOf(result.results, reportPageSize);
  return { items: page.rows.map(listItem), nextBefore: page.nextBefore };
}

/** Raporun tamamı; yoksa `not_found`. */
export async function getReport(db: D1Database, id: string): Promise<ReportDetail> {
  const row: ReportDetailRow | null = await db
    .prepare("SELECT id, kind, status, created_at, user_id, email, app_version, os, message, payload FROM reports WHERE id = ?")
    .bind(id)
    .first<ReportDetailRow>();
  if (row === null) {
    throw new ApiError("not_found", "Rapor bulunamadı.");
  }
  return {
    id: row.id,
    kind: row.kind,
    status: row.status,
    createdAt: new Date(row.created_at).toISOString(),
    userId: row.user_id,
    email: row.email,
    appVersion: row.app_version,
    os: row.os,
    message: row.message,
    payload: row.payload,
  };
}

/** `POST /v1/admin/reports/{id}` gövdesi. */
export const reportStatusUpdateSchema = z.strictObject({ status: reportStatusSchema });

/** Raporun durumunu değiştirir (aynı durum yeniden yazılabilir); yoksa `not_found`. */
export async function setReportStatus(db: D1Database, id: string, status: ReportStatus): Promise<void> {
  const updated: D1Result = await db.prepare("UPDATE reports SET status = ? WHERE id = ?").bind(status, id).run();
  if (updated.meta.changes !== 1) {
    throw new ApiError("not_found", "Rapor bulunamadı.");
  }
  log("info", "report_status_changed", { reportId: id, status });
}
