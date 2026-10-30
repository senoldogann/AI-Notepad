// Sayfaların adresleri (sonda eğik çizgi yok). Sunucu ve Mac uygulaması bu adreslerin bir kısmını sabit yazar:
// Stripe Checkout dönüşü `/account?payment=done`, Checkout iptali `/pricing`, Müşteri Portalı dönüşü `/account`, Mac
// uygulaması `/sign-in?app=1&nonce=…`, Apple ile giriş dönüşü `/sign-in`, davet bağlantısı `/invite?code=…`
// (server/src/referrals.ts `inviteUrl`; değişirse paylaşılmış bağlantılar kırılır). Burada değişen adres oralarda
// da değişmelidir.

/** Sayfa kimlikleri. */
export type PageKey =
  | "home"
  | "pricing"
  | "download"
  | "compare"
  | "vsGranola"
  | "vsOtter"
  | "blog"
  | "mcp"
  | "signIn"
  | "account"
  | "invite"
  | "contact"
  | "admin"
  | "privacy"
  | "terms"
  | "notFound";

/** Sayfaların yolları. */
export const routes: Readonly<Record<PageKey, string>> = {
  home: "/",
  pricing: "/pricing",
  download: "/download",
  compare: "/compare",
  vsGranola: "/vs/granola",
  vsOtter: "/vs/otter",
  blog: "/blog",
  mcp: "/mcp",
  signIn: "/sign-in",
  account: "/account",
  invite: "/invite",
  contact: "/contact",
  admin: "/admin",
  privacy: "/privacy",
  terms: "/terms",
  notFound: "/404",
};

/** Arama motorlarına açık sayfalar (hesap, yönetim ve 404 kişiye özel ya da içeriksizdir). */
export const indexedPages: readonly PageKey[] = ["home", "pricing", "download", "compare", "vsGranola", "vsOtter", "blog", "mcp", "signIn", "invite", "contact", "privacy", "terms"];

/** Önbelleğe alınmayan kişiye özel sayfalar. */
export const privatePages: readonly PageKey[] = ["account", "admin"];

/** Sayfanın mutlak adresi (ana sayfa sonda eğik çizgiyle: `https://alan/`). Saf fonksiyondur. */
export function pageUrl(page: PageKey, origin: string): string {
  return `${origin}${routes[page]}`;
}

/** Blog yazılarının yol kalıbı (`_headers` kuralı): `/blog/<kısa ad>`. */
export const blogPostPattern: string = `${routes.blog}/*`;

/** Blogun RSS akışı (src/pages/blog/rss.xml.ts). */
export const blogFeedPath: string = `${routes.blog}/rss.xml`;

/** Blog yazısının yolu: `/blog/<kısa ad>`. Saf fonksiyondur. */
export function blogPostPath(slug: string): string {
  return `${routes.blog}/${slug}`;
}

/** Blog yazısı: sayfa kimliği yerine kısa adıyla anılır (yazılar içerik koleksiyonundan gelir). */
export interface BlogPostRef {
  readonly blogPostSlug: string;
}

/** Sitedeki bir sayfa: sabit sayfa ya da blog yazısı. */
export type SitePage = PageKey | BlogPostRef;

/** Sayfanın yolu. Saf fonksiyondur. */
export function sitePagePath(page: SitePage): string {
  return typeof page === "string" ? routes[page] : blogPostPath(page.blogPostSlug);
}

/** Sayfanın ait olduğu sayfa kimliği (üst çubukta etkin bağlantı için): blog yazısı blog sayfasına aittir. Saf fonksiyondur. */
export function sitePageKey(page: SitePage): PageKey {
  return typeof page === "string" ? page : "blog";
}
