// Sitenin tek yapılandırma kaynağı. Burada gizli değer yoktur: hepsi tarayıcıya açık değerlerdir.

/**
 * Ürünün adı: sayfa başlıkları, paylaşım kartı etiketleri, metinler ve logonun erişilebilir adı bundan üretilir. Ad
 * değişince yalnızca burası değişir (sitede elle yazılmış başka kopyası yoktur; görsel dosyalar README'de listelidir).
 */
export const productName: string = "Gistsmith";

/**
 * Kart ekstresinde görünen ad (Stripe Managed Payments: satıcı Link). Stripe hesabındaki alan adı ayarından gelir; ad ya
 * da alan adı değişince Stripe panelindeki ayarla birlikte değişir.
 */
export const cardStatementDescriptor: string = "LINK.COM* GISTSMITH.COM";

/** Tarihlerin ve sayıların yazıldığı yerel ayar (gün ay yıl); sayfalar `<html lang="en">`. */
export const siteLocale: string = "en-GB";

/**
 * IndexNow anahtarı (Bing, Yandex, Seznam, Naver…: yeni ve değişen blog yazılarını bildirir; scripts/indexnow.ts).
 * Anahtarlar tasarım gereği açıktır: arama motoru sahipliği sitenin kökündeki `/<anahtar>.txt` dosyasıyla doğrular
 * (derlemede bu değerden yazılır, src/pages/[indexNowKey].txt.ts). Değiştirmek için yeni 32 onaltılık karakter yaz.
 */
export const indexNowKey: string = "7eda66071a60b65f673c57a6e4e97f08";

/** Derleme hedefi: yerel sunucuya karşı geliştirme ya da yayın. */
export type WebTarget = "local" | "production";

/** Sitenin tarayıcıya açık yapılandırması. */
export interface SiteConfig {
  /** Sitenin kaynağı (şema + alan adı); kanonik adresler, site haritası ve Apple dönüş adresi bundan üretilir. */
  readonly siteOrigin: string;
  /** Abonelik sunucusunun (Cloudflare Worker) kaynağı; sondaki eğik çizgi yok. */
  readonly apiBase: string;
  /** Cloudflare Turnstile site anahtarı (açık değer; gizli anahtar yalnızca sunucuda). */
  readonly turnstileSiteKey: string;
  /** Apple ile giriş web Services ID'si; sunucunun `APPLE_CLIENT_IDS` listesinde de olmalı. */
  readonly appleServiceId: string;
  /** Google ile girişin web OAuth istemci kimliği; sunucunun kabul ettiği Google istemci kimliklerinde de olmalı. */
  readonly googleClientId: string;
}

/** Apple ile girişin JS kütüphanesi (Apple'ın CDN'i; CSP'de bu kaynağa izin verilir). */
export const appleAuthScriptUrl: string = "https://appleid.cdn-apple.com/appleauth/static/jsapi/appleid/1/en_US/appleid.auth.js";
/** Apple'ın giriş penceresi ve jeton kaynağı. */
export const appleIdOrigin: string = "https://appleid.apple.com";
/** Turnstile betiği (açık işleme kipinde). */
export const turnstileScriptUrl: string = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
/** Turnstile kaynağı (betik ve iframe). */
export const turnstileOrigin: string = "https://challenges.cloudflare.com";
/**
 * Uygulama adına girişte (açılır pencere yok) sayfanın yönlendirdiği yetkilendirme adresleri. Üst düzey gezinti CSP'ye
 * takılmaz; dönüş `<siteOrigin>/sign-in` adresine `#` parçasıyla gelir.
 */
export const appleAuthorizeUrl: string = `${appleIdOrigin}/auth/authorize`;
export const googleAuthorizeUrl: string = "https://accounts.google.com/o/oauth2/v2/auth";

/**
 * Google ile girişin web OAuth istemcisi (Google Cloud Console; onay ekranındaki ad "Gistsmith"). İzinli JavaScript
 * kaynakları: https://gistsmith.com, http://localhost:8788, http://localhost. Açık değerdir.
 */
const googleWebClientId: string = "461373321454-ku1ot0ildt8b9toe7aerq1imidfgu1ah.apps.googleusercontent.com";

/** Yayın yapılandırması. */
const productionConfig: SiteConfig = {
  // Sunucudaki SITE_ORIGIN, Apple Services ID alan adı, Google istemcisinin izinli kaynağı ve Turnstile parçacığının
  // alan adlarıyla birlikte değişir.
  siteOrigin: "https://gistsmith.com",
  // Üretim Worker'ı (`server/`, `npm run deploy`), özel alan adında.
  apiBase: "https://api.gistsmith.com",
  // Cloudflare Turnstile parçacığı "ainotepad"; gistsmith.com parçacığın alan adlarında olmalı.
  turnstileSiteKey: "0x4AAAAAAFqQUwHe_RGFyX1t",
  // Apple Developer'daki web Services ID'si (dönüş adresi: <siteOrigin>/sign-in).
  appleServiceId: "com.senoldogan.AINotepad.web",
  googleClientId: googleWebClientId,
};

/**
 * Yerel uçtan uca deneme: sunucu `npm run dev -- --ip 127.0.0.1` ile 127.0.0.1:8787'de, site localhost:8788'de
 * (sunucunun geliştirme SITE_ORIGIN'i). API adresi IPv4'e sabittir: `localhost` IPv6'ya çözülüp aynı kapıdaki başka bir
 * sürece gidebilir.
 * Turnstile Cloudflare'in her zaman geçen deneme anahtarıyla çalışır; Apple ile giriş yerelde çalışmaz (Apple yalnızca
 * kayıtlı HTTPS alan adlarına izin verir). Google ile giriş, istemcinin izinli kaynaklarında `http://localhost:8788` ve
 * `http://localhost` varsa yerelde de çalışır.
 */
const localConfig: SiteConfig = {
  siteOrigin: "http://localhost:8788",
  apiBase: "http://127.0.0.1:8787",
  turnstileSiteKey: "1x00000000000000000000AA",
  appleServiceId: "com.senoldogan.AINotepad.web",
  googleClientId: googleWebClientId,
};

/**
 * Sitedeki indirme düğmesinin yeri: sunucunun `?src=` izin listesiyle (`server/src/downloads.ts` →
 * `siteDownloadSources`) aynı olmalı; tanınmayan değer `other` sayılır.
 */
export type DownloadSource = "home-hero" | "home-cta" | "download-page" | "account";

/**
 * Mac indirme adresi: sunucu indirmeyi düğmenin yeriyle (`src`) sayar ve DMG'ye yönlendirir (302). Sitedeki tüm
 * indirme düğmeleri bunu kullanır. Saf fonksiyondur.
 */
export function macDownloadUrl(config: SiteConfig, source: DownloadSource): string {
  return `${config.apiBase}/v1/download/mac?src=${source}`;
}

/** Hedefe göre yapılandırmalar. */
export const siteConfigs: Readonly<Record<WebTarget, SiteConfig>> = {
  local: localConfig,
  production: productionConfig,
};

/** Derleme hedefi tanımsız ya da geçersiz: `PUBLIC_WEB_TARGET` ayarlanmalı. */
export class WebTargetError extends Error {
  override readonly name: string = "WebTargetError";
}

/** `PUBLIC_WEB_TARGET` değerini doğrular. Saf fonksiyondur; geçersizse `WebTargetError`. */
export function parseWebTarget(value: string | undefined): WebTarget {
  if (value === "local" || value === "production") {
    return value;
  }
  throw new WebTargetError(
    `PUBLIC_WEB_TARGET "local" ya da "production" olmalı; gelen: ${JSON.stringify(value ?? null)}. npm betikleri bunu ayarlar.`,
  );
}
