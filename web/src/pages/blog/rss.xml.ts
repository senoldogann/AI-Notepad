// Blogun RSS akışı (/blog/rss.xml): yazılar yeniden eskiye.
import type { APIRoute } from "astro";
import { copy } from "../../copy";
import { blogEntries, blogFeedXml, blogPost } from "../../lib/blog";
import { blogFeedPath, pageUrl } from "../../routes";
import { siteConfig } from "../../site";

export const GET: APIRoute = async (): Promise<Response> => {
  const origin: string = siteConfig.siteOrigin;
  const xml: string = blogFeedXml(
    { title: copy.blog.feedTitle, description: copy.blog.meta.description, link: pageUrl("blog", origin), self: `${origin}${blogFeedPath}` },
    origin,
    (await blogEntries()).map(blogPost),
  );
  return new Response(xml, { headers: { "content-type": "application/rss+xml; charset=utf-8" } });
};
