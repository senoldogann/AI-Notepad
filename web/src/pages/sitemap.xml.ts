// Site haritası: arama motorlarına açık sayfalar ve blog yazıları.
import type { APIRoute } from "astro";
import { type BlogPost, blogEntries, blogPost } from "../lib/blog";
import { blogPostPath, type PageKey, indexedPages, pageUrl } from "../routes";
import { siteConfig } from "../site";

/** Site haritası XML'i (mutlak adresler verilen sırayla). Saf fonksiyondur. */
export function sitemapXml(urls: readonly string[]): string {
  const entries: string[] = urls.map((url: string): string => `  <url>\n    <loc>${url}</loc>\n  </url>`);
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${entries.join("\n")}\n</urlset>\n`;
}

export const GET: APIRoute = async (): Promise<Response> => {
  const origin: string = siteConfig.siteOrigin;
  const posts: readonly BlogPost[] = (await blogEntries()).map(blogPost);
  const urls: readonly string[] = [
    ...indexedPages.map((page: PageKey): string => pageUrl(page, origin)),
    ...posts.map((post: BlogPost): string => `${origin}${blogPostPath(post.slug)}`),
  ];
  return new Response(sitemapXml(urls), { headers: { "content-type": "application/xml; charset=utf-8" } });
};
