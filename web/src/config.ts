// Sitenin tek yapılandırma kaynağı. Burada gizli değer yoktur: hepsi tarayıcıya açık değerlerdir.

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
  /** DMG indirme adresi. */
  readonly dmgUrl: string;
}

/** Apple ile girişin JS kütüphanesi (Apple'ın CDN'i; CSP'de bu kaynağa izin verilir). */
export const appleAuthScriptUrl: string = "https://appleid.cdn-apple.com/appleauth/static/jsapi/appleid/1/en_US/appleid.auth.js";
/** Apple'ın giriş penceresi ve jeton kaynağı. */
export const appleIdOrigin: string = "https://appleid.apple.com";
/** Turnstile betiği (açık işleme kipinde). */
export const turnstileScriptUrl: string = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
/** Turnstile kaynağı (betik ve iframe). */
export const turnstileOrigin: string = "https://challenges.cloudflare.com";
/** Kaynak kodun deposu. */
export const repositoryUrl: string = "https://github.com/senoldogann/AI-Notepad";

/** GitHub Releases'teki en son sürümün sayfası (sürüm notları, geliştirici sürümü); her yayında kendiliğinden güncel. */
export const latestReleaseUrl: string = `${repositoryUrl}/releases/latest`;

/** Yayınlanmış en son sürüm (yalnızca sayfada gösterilir; indirme adresi buna bağlı değil). */
export const latestVersion: string = "0.1.3";

/**
 * DMG indirme adresi: her sürüme yüklenen sabit adlı kopya (`AI-Notepad.dmg`, bkz. scripts/release.sh).
 * `releases/latest/download/` her zaman son sürümü indirir; yeni sürümde bağlantı değişmez.
 */
const dmgUrl: string = `${repositoryUrl}/releases/latest/download/AI-Notepad.dmg`;

/** Yayın yapılandırması. */
const productionConfig: SiteConfig = {
  // Alan adı alınınca değişir; sunucudaki SITE_ORIGIN, Apple Services ID alan adı ve Turnstile parçacığıyla birlikte.
  siteOrigin: "https://ainotepad.pages.dev",
  // Üretim Worker'ı (`server/`, `npm run deploy`); alan adı alınınca api.<alan adı> olur.
  apiBase: "https://ainotepad-server-production.senoldogan0233.workers.dev",
  // Cloudflare Turnstile parçacığı "ainotepad" (alan adı ainotepad.pages.dev); alan adı değişince parçacığa eklenir.
  turnstileSiteKey: "0x4AAAAAAFqQUwHe_RGFyX1t",
  // Apple Developer'daki web Services ID'si (dönüş adresleri: <siteOrigin>/tr/giris, <siteOrigin>/en/sign-in).
  appleServiceId: "com.senoldogan.AINotepad.web",
  dmgUrl,
};

/**
 * Yerel uçtan uca deneme: sunucu `npm run dev -- --ip 127.0.0.1` ile 127.0.0.1:8787'de, site localhost:8788'de
 * (sunucunun geliştirme SITE_ORIGIN'i). API adresi IPv4'e sabittir: `localhost` IPv6'ya çözülüp aynı kapıdaki başka bir
 * sürece gidebilir.
 * Turnstile Cloudflare'in her zaman geçen deneme anahtarıyla çalışır; Apple ile giriş yerelde çalışmaz (Apple yalnızca
 * kayıtlı HTTPS alan adlarına izin verir).
 */
const localConfig: SiteConfig = {
  siteOrigin: "http://localhost:8788",
  apiBase: "http://127.0.0.1:8787",
  turnstileSiteKey: "1x00000000000000000000AA",
  appleServiceId: "com.senoldogan.AINotepad.web",
  dmgUrl,
};

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
