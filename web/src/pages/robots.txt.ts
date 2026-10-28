// robots.txt: her şey taranabilir (kişiye özel sayfalar `noindex` taşır), site haritasının adresi.
import type { APIRoute } from "astro";
import { siteConfig } from "../site";

export const GET: APIRoute = (): Response =>
  new Response(`User-agent: *\nAllow: /\n\nSitemap: ${siteConfig.siteOrigin}/sitemap.xml\n`, { headers: { "content-type": "text/plain; charset=utf-8" } });
