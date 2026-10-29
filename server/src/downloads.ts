import { UpstreamError } from "./errors";
import { errorName, log } from "./log";
import type { Platform } from "./platform";
import { fetchUpstream } from "./upstream";
import { dayKey } from "./usage";

/** Appcast'in en büyük boyutu (bayt): akış birkaç KB'tır; daha büyüğü okunmaz. */
const appcastMaxBytes: number = 1_048_576;

/**
 * Appcast'teki (Sparkle) en yeni sürümün görünen numarası: ilk `<item>`'ın `sparkle:shortVersionString`'i
 * (`generate_appcast` en yeni sürümü başa yazar). Bulunamazsa nil. Saf fonksiyondur.
 */
export function appcastLatestVersion(xml: string): string | null {
  const item: RegExpExecArray | null = /<item>([\s\S]*?)<\/item>/.exec(xml);
  if (item === null) {
    return null;
  }
  const version: RegExpExecArray | null = /<sparkle:shortVersionString>\s*([0-9]+(?:\.[0-9]+){1,3})\s*<\/sparkle:shortVersionString>/.exec(item[1] ?? "");
  return version === null ? null : (version[1] ?? null);
}

/**
 * Yayınlanmış en son Mac sürümü: DMG ile aynı GitHub sürümündeki appcast'ten okunur, böylece sitedeki numara indirilen
 * DMG ile her zaman aynıdır. Appcast okunamaz ya da sürüm bulunamazsa `UpstreamError`.
 */
export async function latestMacVersion(platform: Platform, appcastUrl: string): Promise<string> {
  const response: Response = await fetchUpstream(platform, "appcast", appcastUrl, (): RequestInit => ({ method: "GET", redirect: "follow" }), 2, 8000);
  const length: number = Number(response.headers.get("content-length") ?? "0");
  if (length > appcastMaxBytes) {
    await response.body?.cancel();
    throw new UpstreamError("appcast", response.status, false, `akış çok büyük (${length} bayt)`);
  }
  const version: string | null = appcastLatestVersion(await response.text());
  if (version === null) {
    throw new UpstreamError("appcast", response.status, false, "akışta sürüm yok");
  }
  return version;
}

/**
 * Bugünün (UTC) indirme sayacını bir artırır. Yalnızca gün ve sayı saklanır: IP, tarayıcı ya da başka bir tanımlayıcı
 * yok.
 *
 * Bilinçli istisna (projenin "hatayı yutma" kuralına karşı tek izinli durum): D1 yazımı başarısız olursa hata adıyla
 * uyarı loglanır ve fonksiyon normal döner. İndirme istatistik yüzünden engellenmemeli; kayıp yalnızca bir sayaçtır ve
 * log uyarısı onu görünür kılar.
 */
export async function countDownload(db: D1Database, now: Date): Promise<void> {
  try {
    await db
      .prepare("INSERT INTO downloads (day, count) VALUES (?, 1) ON CONFLICT(day) DO UPDATE SET count = count + 1")
      .bind(dayKey(now))
      .run();
  } catch (error: unknown) {
    log("warn", "download_count_failed", { error: errorName(error) });
  }
}
