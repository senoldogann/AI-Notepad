// Site haritası: arama motorlarına açık sayfalar.
import type { APIRoute } from "astro";
import { type PageKey, indexedPages, pageUrl } from "../routes";
import { siteConfig } from "../site";

/** Site haritası XML'i. Saf fonksiyondur. */
export function sitemapXml(origin: string): string {
  const entries: string[] = indexedPages.map((page: PageKey): string => `  <url>\n    <loc>${pageUrl(page, origin)}</loc>\n  </url>`);
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${entries.join("\n")}\n</urlset>\n`;
}

export const GET: APIRoute = (): Response =>
  new Response(sitemapXml(siteConfig.siteOrigin), { headers: { "content-type": "application/xml; charset=utf-8" } });
