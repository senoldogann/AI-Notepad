// Cloudflare Pages `_headers` dosyası: sıkı CSP, HSTS, Referrer-Policy, Permissions-Policy ve önbellek kuralları.
// Derlemede yapılandırmadan üretilir (astro.config.ts).
//
// CSP iki katmanlıdır. Pages, birden çok kurala uyan adreste aynı başlığın değerlerini virgülle birleştirir; tarayıcı
// virgülle ayrılmış her politikayı ayrı ayrı uygular (hepsine uyan yüklenir). `/*` kuralı tüm dış hizmetlere izin veren
// geniş politikayı taşır (sayfası olmayan adresler, ör. bilinmeyen adresin 404'ü, için); her sayfanın kendi kuralı
// yalnızca o sayfanın kullandığı hizmetlere izin veren dar politikayı ekler. Böylece Apple betiği yalnızca giriş
// sayfasında, Turnstile yalnızca iletişim sayfasında çalışabilir. Google ile giriş Google'a yönlendirir; betik yüklenmez.
// Cloudflare Web Analytics işaretçisi her sayfada olduğundan iki katmanın da tüm politikalarında açıktır.
import { appleAuthScriptUrl, appleIdOrigin, type SiteConfig, turnstileOrigin } from "../config";
import { blogPostPattern, type PageKey, privatePages, routes } from "../routes";

/** Sayfaların yüklediği dış hizmetler. */
export type ExternalService = "appleSignIn" | "turnstile";

/** Bir dış hizmetin CSP yönergelerine eklediği kaynaklar. */
interface ServiceSources {
  readonly script: readonly string[];
  readonly style: readonly string[];
  readonly connect: readonly string[];
  readonly frame: readonly string[];
  readonly formAction: readonly string[];
}

/** Adresin kaynağı (şema + alan adı + kapı). Saf fonksiyondur. */
function originOf(url: string): string {
  return new URL(url).origin;
}

/**
 * Hizmetlerin kaynakları. Apple ile giriş açılır pencere kullanır; betik Apple'ın CDN'inden gelir.
 */
const serviceSources: Readonly<Record<ExternalService, ServiceSources>> = {
  appleSignIn: { script: [originOf(appleAuthScriptUrl)], style: [], connect: [], frame: [appleIdOrigin], formAction: [appleIdOrigin] },
  turnstile: { script: [turnstileOrigin], style: [], connect: [], frame: [turnstileOrigin], formAction: [] },
};

/**
 * Cloudflare Web Analytics (çerezsiz): Pages projesinde panelden açılır ve işaretçi betiğini her sayfaya kendisi ekler.
 * Betik bu kaynaktan yüklenir, ölçümleri ikinci kaynağa gönderir. Her sayfada çalıştığı için hizmet listesine değil
 * geniş ve dar politikaların hepsine eklenir (birleşen politikalardan biri izin vermezse betik engellenir).
 */
const webAnalyticsScriptOrigin: string = "https://static.cloudflareinsights.com";
const webAnalyticsConnectOrigin: string = "https://cloudflareinsights.com";

/** Tüm dış hizmetler (geniş politika). */
const allServices: readonly ExternalService[] = ["appleSignIn", "turnstile"];

/** Sayfaların kullandığı dış hizmetler: giriş sayfası Apple, iletişim sayfası Turnstile; diğerleri hiçbiri. */
export const pageServices: Readonly<Record<PageKey, readonly ExternalService[]>> = {
  home: [],
  pricing: [],
  download: [],
  compare: [],
  vsGranola: [],
  vsOtter: [],
  blog: [],
  mcp: [],
  signIn: ["appleSignIn"],
  account: [],
  contact: ["turnstile"],
  admin: [],
  privacy: [],
  terms: [],
  notFound: [],
};

/** Yönergenin değeri: sabit kaynaklar ve hizmetlerin kaynakları; hiç kaynak yoksa `'none'`. Saf fonksiyondur. */
function directive(name: string, base: readonly string[], services: readonly ExternalService[], pick: (sources: ServiceSources) => readonly string[]): string {
  const sources: readonly string[] = [...base, ...services.flatMap((service: ExternalService): readonly string[] => pick(serviceSources[service]))];
  return `${name} ${sources.length === 0 ? "'none'" : sources.join(" ")}`;
}

/**
 * Verilen dış hizmetlere izin veren içerik güvenlik politikası. Satır içi betik ve stil yoktur; `'unsafe-inline'`
 * kullanılmaz. Saf fonksiyondur.
 */
export function contentSecurityPolicy(config: SiteConfig, services: readonly ExternalService[]): string {
  const directives: readonly string[] = [
    "default-src 'none'",
    directive("script-src", ["'self'", webAnalyticsScriptOrigin], services, (sources: ServiceSources): readonly string[] => sources.script),
    directive("style-src", ["'self'"], services, (sources: ServiceSources): readonly string[] => sources.style),
    "img-src 'self'",
    // Ana sayfadaki tanıtım videosu (public/video) yalnızca siteden yüklenir.
    "media-src 'self'",
    "font-src 'self'",
    directive("connect-src", ["'self'", originOf(config.apiBase), webAnalyticsConnectOrigin], services, (sources: ServiceSources): readonly string[] => sources.connect),
    directive("frame-src", [], services, (sources: ServiceSources): readonly string[] => sources.frame),
    "manifest-src 'self'",
    directive("form-action", ["'self'"], services, (sources: ServiceSources): readonly string[] => sources.formAction),
    "base-uri 'none'",
    "object-src 'none'",
    "frame-ancestors 'none'",
    ...(config.siteOrigin.startsWith("https:") ? ["upgrade-insecure-requests"] : []),
  ];
  return directives.join("; ");
}

/** Tarayıcı özellikleri: sitenin hiçbirine ihtiyacı yok. */
const permissionsPolicy: string = [
  "accelerometer=()",
  "autoplay=()",
  "camera=()",
  "display-capture=()",
  "geolocation=()",
  "gyroscope=()",
  "magnetometer=()",
  "microphone=()",
  "midi=()",
  "payment=()",
  "usb=()",
  "browsing-topics=()",
].join(", ");

/** Tüm sayfa kimlikleri (`routes` sırasıyla). */
const allPages: readonly PageKey[] = Object.keys(routes) as PageKey[];

/** `_headers` dosyasının içeriği. Saf fonksiyondur. */
export function pagesHeaders(config: SiteConfig): string {
  const lines: readonly string[] = [
    "/*",
    `  Content-Security-Policy: ${contentSecurityPolicy(config, allServices)}`,
    "  Strict-Transport-Security: max-age=63072000; includeSubDomains; preload",
    "  Referrer-Policy: strict-origin-when-cross-origin",
    `  Permissions-Policy: ${permissionsPolicy}`,
    "  X-Content-Type-Options: nosniff",
    "  X-Frame-Options: DENY",
    // Apple ile giriş açılır pencere kullanır: açtığımız pencereyle bağ korunur, başka sayfalar bizi açamaz.
    "  Cross-Origin-Opener-Policy: same-origin-allow-popups",
    "  Cross-Origin-Resource-Policy: same-origin",
    "",
    // Her sayfanın dar politikası (geniş politikaya eklenir, ikisi birlikte uygulanır).
    ...allPages.flatMap((page: PageKey): string[] => [
      routes[page],
      `  Content-Security-Policy: ${contentSecurityPolicy(config, pageServices[page])}`,
      ...(privatePages.includes(page) ? ["  Cache-Control: no-store"] : []),
      "",
    ]),
    // Blog yazıları (`/blog/<kısa ad>`) sayfa kimliği taşımaz; hepsi dış hizmetsiz dar politikayı alır.
    blogPostPattern,
    `  Content-Security-Policy: ${contentSecurityPolicy(config, [])}`,
    "",
    // Adı içerik özeti taşıyan derleme çıktıları değişmez.
    "/_astro/*",
    "  Cache-Control: public, max-age=31536000, immutable",
    "",
    // Yazı tipinin adında özet yok: güncellenirse ayda bir tazelenir.
    "/fonts/*",
    "  Cache-Control: public, max-age=2592000",
    "",
    // Tanıtım videosu ve kapak görseli: adlarında özet yok, ayda bir tazelenir.
    "/video/*",
    "  Cache-Control: public, max-age=2592000",
    "",
  ];
  return lines.join("\n");
}
