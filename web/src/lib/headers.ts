// Cloudflare Pages `_headers` dosyası: sıkı CSP (yalnızca site, Apple ve Google ile giriş, Turnstile ve API kaynakları),
// HSTS, Referrer-Policy, Permissions-Policy ve önbellek kuralları. Derlemede yapılandırmadan üretilir (astro.config.ts).
import { appleAuthScriptUrl, appleIdOrigin, googleGsiBase, googleScriptUrl, type SiteConfig, turnstileOrigin } from "../config";
import { type PageKey, privatePages, routes } from "../routes";

/** Adresin kaynağı (şema + alan adı + kapı). Saf fonksiyondur. */
function originOf(url: string): string {
  return new URL(url).origin;
}

/**
 * İçerik güvenlik politikası. Satır içi betik ve stil yoktur; `'unsafe-inline'` kullanılmaz. Google Identity Services
 * için Google'ın belgelediği kaynaklar eklenir: betik `gsi/client`, stil `gsi/style`, iframe ve istekler `gsi/`. Saf
 * fonksiyondur.
 */
export function contentSecurityPolicy(config: SiteConfig): string {
  const appleCdn: string = originOf(appleAuthScriptUrl);
  const directives: readonly string[] = [
    "default-src 'none'",
    `script-src 'self' ${appleCdn} ${turnstileOrigin} ${googleScriptUrl}`,
    `style-src 'self' ${googleGsiBase}style`,
    "img-src 'self'",
    "font-src 'self'",
    `connect-src 'self' ${originOf(config.apiBase)} ${googleGsiBase}`,
    `frame-src ${turnstileOrigin} ${appleIdOrigin} ${googleGsiBase}`,
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
    // Apple ve Google ile giriş açılır pencere kullanır: açtığımız pencereyle bağ korunur, başka sayfalar bizi açamaz.
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
    // Kişiye özel sayfalar (hesap, yönetim) önbelleğe alınmaz.
    ...privatePages.flatMap((page: PageKey): string[] => [routes[page], "  Cache-Control: no-store"]),
    "",
  ];
  return lines.join("\n");
}
