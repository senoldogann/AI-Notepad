import { ApiError } from "./errors";

/**
 * Uygulamanın sürüm başlıkları: Mac uygulaması her abonelik sunucusu isteğine `x-app-version` (pazarlama sürümü ve yapı
 * numarası, ör. "0.1.10 (19)") ve `x-os-version` (ör. "macOS 15.4.1") koyar. `GET /v1/me` sonuncularını hesabın
 * satırına yazar (yönetim panelinde sürüm benimsenmesi); telemetri toplamları uygulama sürümüyle gruplanır. İçerik
 * taşımazlar.
 */

/** `x-app-version` biçimi: 2–4 bileşenli sürüm, boşluk, parantez içinde yapı numarası. */
const appVersionPattern: RegExp = /^[0-9]{1,4}(\.[0-9]{1,4}){1,3} \([0-9]{1,9}\)$/;
/** `x-os-version` biçimi: "macOS" ve 2–3 bileşenli sürüm. */
const osVersionPattern: RegExp = /^macOS [0-9]{1,3}\.[0-9]{1,3}(\.[0-9]{1,3})?$/;

/** Aynı sürümlerle son görülme anı en çok bu sıklıkla yeniden yazılır (her `/v1/me` bir D1 yazımı olmasın). */
const lastSeenRefreshMs: number = 3_600_000;

/** İstemcinin bildirdiği sürümler. */
export interface ClientVersions {
  readonly appVersion: string;
  readonly osVersion: string;
}

/** `x-app-version` değeri biçime uyuyorsa kendisi; değilse `bad_request`. Saf fonksiyondur. */
function parseAppVersion(value: string): string {
  if (!appVersionPattern.test(value)) {
    throw new ApiError("bad_request", "x-app-version başlığı \"<sürüm> (<yapı>)\" biçiminde olmalı.");
  }
  return value;
}

/** Zorunlu `x-app-version` başlığı (telemetri uçları); yoksa ya da geçersizse `bad_request`. Saf fonksiyondur. */
export function requiredAppVersion(request: Request): string {
  const value: string | null = request.headers.get("x-app-version");
  if (value === null) {
    throw new ApiError("bad_request", "x-app-version başlığı gerekli.");
  }
  return parseAppVersion(value);
}

/**
 * İsteğe bağlı sürüm başlıkları: ikisi de yoksa null (site ve eski uygulamalar); yalnızca biri varsa ya da biri
 * geçersizse `bad_request` (yarım bilgi sessizce yok sayılmaz). Saf fonksiyondur.
 */
export function optionalClientVersions(request: Request): ClientVersions | null {
  const app: string | null = request.headers.get("x-app-version");
  const os: string | null = request.headers.get("x-os-version");
  if (app === null && os === null) {
    return null;
  }
  if (app === null || os === null) {
    throw new ApiError("bad_request", "x-app-version ve x-os-version başlıkları birlikte gönderilmeli.");
  }
  if (!osVersionPattern.test(os)) {
    throw new ApiError("bad_request", "x-os-version başlığı \"macOS <sürüm>\" biçiminde olmalı.");
  }
  return { appVersion: parseAppVersion(app), osVersion: os };
}

/**
 * Hesabın son uygulama ve macOS sürümünü ve son görülme anını yazar. Sürümler aynıysa ve son görülme bir saatten
 * yeniyse satır değişmez (yazım yapılmaz).
 */
export async function recordClientVersions(db: D1Database, userId: string, versions: ClientVersions, now: Date): Promise<void> {
  const nowMs: number = now.getTime();
  await db
    .prepare(
      `UPDATE users SET last_app_version = ?1, last_os_version = ?2, last_seen_at = ?3
       WHERE id = ?4 AND (last_app_version IS NOT ?1 OR last_os_version IS NOT ?2 OR last_seen_at IS NULL OR last_seen_at < ?5)`,
    )
    .bind(versions.appVersion, versions.osVersion, nowMs, userId, nowMs - lastSeenRefreshMs)
    .run();
}
