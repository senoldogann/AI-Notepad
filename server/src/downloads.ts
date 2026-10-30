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

/**
 * Kampanya bağlantılarının izinli `utm_source` değerleri (`GET /v1/download/mac?utm_source=<kaynak>&utm_campaign=<ad>`).
 * Listede olmayan kaynak `other` sayılır: adres döngüyle çağrılarak sayaç tablosuna rastgele değer yazılamaz.
 */
export const campaignSources = [
  "producthunt",
  "hackernews",
  "reddit",
  "x",
  "linkedin",
  "facebook",
  "instagram",
  "youtube",
  "tiktok",
  "mastodon",
  "bluesky",
  "github",
  "newsletter",
  "email",
  "blog",
  "google",
  "bing",
  "chatgpt",
  "perplexity",
  "partner",
] as const;

/** Kampanya kaynağı: izin listesinden ya da tanınmayan (`other`). */
export type CampaignSource = (typeof campaignSources)[number] | "other";

/** Kampanya adının biçimi: küçük harf, rakam, `-` ve `_`; en çok 40 karakter. */
const campaignNamePattern: RegExp = /^[a-z0-9][a-z0-9_-]{0,39}$/;

/** İndirmenin kampanyası: kaynak ve ad (yoksa boş metin, biçimi geçersizse `other`). */
export interface DownloadCampaign {
  readonly source: CampaignSource;
  readonly campaign: string;
}

/**
 * `utm_source` ve `utm_campaign` parametrelerinin kampanyası; `utm_source` yoksa ya da boşsa null (kampanyasız
 * indirme). Kaynak izin listesinde değilse `other`; ad küçük harfe çevrilir, biçimi geçersizse `other`, yoksa boş.
 * Saf fonksiyondur.
 */
export function downloadCampaignOf(utmSource: string | null, utmCampaign: string | null): DownloadCampaign | null {
  if (utmSource === null || utmSource === "") {
    return null;
  }
  const lowerSource: string = utmSource.toLowerCase();
  const source: CampaignSource = campaignSources.find((candidate: CampaignSource): boolean => candidate === lowerSource) ?? "other";
  if (utmCampaign === null || utmCampaign === "") {
    return { source, campaign: "" };
  }
  const lowerCampaign: string = utmCampaign.toLowerCase();
  return { source, campaign: campaignNamePattern.test(lowerCampaign) ? lowerCampaign : "other" };
}

/** Sayılacak indirmenin kaynağı, Referer alan adı ve (varsa) kampanyası. */
export interface DownloadOrigin {
  readonly source: DownloadSource;
  readonly referrerHost: string;
  readonly campaign: DownloadCampaign | null;
}

/**
 * Bugünün (UTC) indirme sayaçlarını (`downloads` toplamı, `download_sources` kaynak ve Referer alan adı, kampanyalı
 * indirmede `download_campaigns`) artırır. Aynı
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
      ...(origin.campaign === null
        ? []
        : [
            db
              .prepare(
                `INSERT INTO download_campaigns (day, utm_source, utm_campaign, count) VALUES (?, ?, ?, 1)
                 ON CONFLICT(day, utm_source, utm_campaign) DO UPDATE SET count = count + 1`,
              )
              .bind(day, origin.campaign.source, origin.campaign.campaign),
          ]),
    ]);
  } catch (error: unknown) {
    log("warn", "download_count_failed", { error: errorName(error) });
  }
}
