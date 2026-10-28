// Site haritası: arama motorlarına açık sayfalar, her biri için iki dildeki karşılığı (hreflang).
import type { APIRoute } from "astro";
import { type Lang, type PageKey, indexedPages, langs, pageUrl } from "../i18n/routes";
import { siteConfig } from "../site";

/** Site haritası XML'i. Saf fonksiyondur. */
export function sitemapXml(origin: string): string {
  const entries: string[] = indexedPages.flatMap((page: PageKey): string[] =>
    langs.map((lang: Lang): string => {
      const alternates: string = langs
        .map((alternate: Lang): string => `    <xhtml:link rel="alternate" hreflang="${alternate}" href="${pageUrl(page, alternate, origin)}"/>`)
        .join("\n");
      return `  <url>\n    <loc>${pageUrl(page, lang, origin)}</loc>\n${alternates}\n    <xhtml:link rel="alternate" hreflang="x-default" href="${origin}/"/>\n  </url>`;
    }),
  );
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n${entries.join("\n")}\n</urlset>\n`;
}

export const GET: APIRoute = (): Response =>
  new Response(sitemapXml(siteConfig.siteOrigin), { headers: { "content-type": "application/xml; charset=utf-8" } });
