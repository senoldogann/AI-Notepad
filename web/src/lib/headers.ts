// Cloudflare Pages `_headers` dosyası: sıkı CSP (yalnızca site, Apple ile giriş, Turnstile ve API kaynakları), HSTS,
// Referrer-Policy, Permissions-Policy ve önbellek kuralları. Derlemede yapılandırmadan üretilir (astro.config.ts).
import { appleAuthScriptUrl, appleIdOrigin, type SiteConfig, turnstileOrigin } from "../config";
import { type Lang, langs, pagePath } from "../i18n/routes";

/** Adresin kaynağı (şema + alan adı + kapı). Saf fonksiyondur. */
function originOf(url: string): string {
  return new URL(url).origin;
}

/** İçerik güvenlik politikası. Satır içi betik ve stil yoktur; `'unsafe-inline'` kullanılmaz. Saf fonksiyondur. */
export function contentSecurityPolicy(config: SiteConfig): string {
  const appleCdn: string = originOf(appleAuthScriptUrl);
  const directives: readonly string[] = [
    "default-src 'none'",
    `script-src 'self' ${appleCdn} ${turnstileOrigin}`,
    "style-src 'self'",
    "img-src 'self'",
    "font-src 'self'",
    `connect-src 'self' ${originOf(config.apiBase)}`,
    `frame-src ${turnstileOrigin} ${appleIdOrigin}`,
    "manifest-src 'self'",
    `form-action 'self' ${appleIdOrigin}`,
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

/** `_headers` dosyasının içeriği. Saf fonksiyondur. */
export function pagesHeaders(config: SiteConfig): string {
  const lines: readonly string[] = [
    "/*",
    `  Content-Security-Policy: ${contentSecurityPolicy(config)}`,
    "  Strict-Transport-Security: max-age=63072000; includeSubDomains; preload",
    "  Referrer-Policy: strict-origin-when-cross-origin",
    `  Permissions-Policy: ${permissionsPolicy}`,
    "  X-Content-Type-Options: nosniff",
    "  X-Frame-Options: DENY",
    // Apple ile giriş açılır pencere kullanır: açtığımız pencereyle bağ korunur, başka sayfalar bizi açamaz.
    "  Cross-Origin-Opener-Policy: same-origin-allow-popups",
    "  Cross-Origin-Resource-Policy: same-origin",
    "",
    // Adı içerik özeti taşıyan derleme çıktıları değişmez.
    "/_astro/*",
    "  Cache-Control: public, max-age=31536000, immutable",
    "",
    // Yazı tipinin adında özet yok: güncellenirse ayda bir tazelenir.
    "/fonts/*",
    "  Cache-Control: public, max-age=2592000",
    "",
    // Kişiye özel sayfalar önbelleğe alınmaz.
    ...langs.flatMap((lang: Lang): string[] => [pagePath("account", lang), pagePath("emailLink", lang)]).flatMap((path: string): string[] => [path, "  Cache-Control: no-store"]),
    "",
  ];
  return lines.join("\n");
}
