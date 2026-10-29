import { hmacSha256Hex } from "./crypto";
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

/** Sitedeki indirme düğmelerinin sabit kaynak adları (`GET /v1/download/mac?src=<kaynak>`). */
export const siteDownloadSources = ["home-hero", "home-cta", "download-page", "account"] as const;

/** İndirmenin kaynağı: sitedeki düğme, parametresiz (`direct`: dış bağlantı ya da elle yazılmış adres) ya da tanınmayan (`other`). */
export type DownloadSource = (typeof siteDownloadSources)[number] | "direct" | "other";

/** Referer alan adının en çok uzunluğu; daha uzunu ya da geçersizi `other` sayılır. */
const referrerHostMaxLength: number = 100;

/** `src` parametresinin kaynağı: yoksa `direct`, izin listesinde değilse `other`. Saf fonksiyondur. */
export function downloadSourceOf(param: string | null): DownloadSource {
  if (param === null || param === "") {
    return "direct";
  }
  return siteDownloadSources.find((source: DownloadSource): boolean => source === param) ?? "other";
}

/**
 * Referer başlığının yalnızca alan adı (küçük harf, baştaki `www.` atılır): yol, sorgu ve tam adres saklanmaz. Başlık
 * yoksa boş metin; http(s) değilse, çözülemiyorsa ya da alan adı biçiminde değilse `other`. Saf fonksiyondur.
 */
export function referrerHostOf(referer: string | null): string {
  if (referer === null || referer === "") {
    return "";
  }
  if (!URL.canParse(referer)) {
    return "other";
  }
  const url: URL = new URL(referer);
  const host: string = url.hostname.toLowerCase().replace(/^www\./, "");
  const valid: boolean = (url.protocol === "https:" || url.protocol === "http:") && host.length <= referrerHostMaxLength && /^[a-z0-9.-]+$/.test(host);
  return valid ? host : "other";
}

/** Sayılacak indirmenin kaynağı ve Referer alan adı. */
export interface DownloadOrigin {
  readonly source: DownloadSource;
  readonly referrerHost: string;
}

/**
 * Bugünün (UTC) indirme sayaçlarını (`downloads` toplamı, `download_sources` kaynak ve Referer alan adı) artırır. Aynı
 * ağdan aynı gün gelen tekrar indirme sayılmaz ve D1'e yazmaz (tek okuma): ağ, `visitorKey`'in (`clientIpKey`; IPv6'da
 * /64 önek) gün ile birlikte HMAC özetiyle `download_visitors`'ta tutulur; özet günler arasında bağlanamaz ve ertesi gün
 * silinir. Böylece adresi döngüyle çağırmak D1 yazımı harcatamaz. Sayaçlar IP, tarayıcı ya da başka bir tanımlayıcı
 * tutmaz.
 *
 * Bilinçli istisna (projenin "hatayı yutma" kuralına karşı izinli durum): D1 yazımı başarısız olursa hata adıyla uyarı
 * loglanır ve fonksiyon normal döner. İndirme istatistik yüzünden engellenmemeli; kayıp yalnızca bir sayaçtır ve log
 * uyarısı onu görünür kılar.
 */
export async function countDownload(db: D1Database, hashSecret: string, visitorKey: string, origin: DownloadOrigin, now: Date): Promise<void> {
  const day: string = dayKey(now);
  const visitorHash: string = await hmacSha256Hex(hashSecret, `download:${day}:${visitorKey}`);
  try {
    const first: { day: string } | null = await db
      .prepare("INSERT INTO download_visitors (day, visitor_hash) VALUES (?, ?) ON CONFLICT(day, visitor_hash) DO NOTHING RETURNING day")
      .bind(day, visitorHash)
      .first<{ day: string }>();
    if (first === null) {
      return;
    }
    await db.batch([
      db.prepare("INSERT INTO downloads (day, count) VALUES (?, 1) ON CONFLICT(day) DO UPDATE SET count = count + 1").bind(day),
      db
        .prepare(
          `INSERT INTO download_sources (day, source, referrer_host, count) VALUES (?, ?, ?, 1)
           ON CONFLICT(day, source, referrer_host) DO UPDATE SET count = count + 1`,
        )
        .bind(day, origin.source, origin.referrerHost),
    ]);
  } catch (error: unknown) {
    log("warn", "download_count_failed", { error: errorName(error) });
  }
}
