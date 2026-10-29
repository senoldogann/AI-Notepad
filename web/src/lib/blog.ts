// Blog yazıları: içerik koleksiyonundan (src/content.config.ts) okunur, yeniden eskiye sıralanır; okuma süresi, tarih
// metni ve RSS akışı buradan üretilir.
import { type CollectionEntry, getCollection } from "astro:content";
import { siteLocale } from "../config";
import { blogPostPath } from "../routes";

/** Bir blog yazısının sayfada ve akışta kullanılan bilgileri. */
export interface BlogPost {
  readonly slug: string;
  readonly title: string;
  readonly description: string;
  readonly author: string;
  readonly published: Date;
  /** Yaklaşık okuma süresi (dakika). */
  readonly minutes: number;
}

/** Dakikada okunan sözcük (okuma süresi tahmini). */
const wordsPerMinute: number = 220;

/** Metnin yaklaşık okuma süresi; en az 1 dakika. Saf fonksiyondur. */
export function readingMinutes(text: string): number {
  const words: number = text.split(/\s+/).filter((word: string): boolean => word.length > 0).length;
  return Math.max(1, Math.round(words / wordsPerMinute));
}

/** Koleksiyon girdisini yazı bilgisine çevirir; gövdesi olmayan girdi hata verir. Saf fonksiyondur. */
export function blogPost(entry: CollectionEntry<"blog">): BlogPost {
  if (entry.body === undefined) {
    throw new Error(`Blog yazısının gövdesi yok: ${entry.id} (src/content/blog/${entry.id}.md)`);
  }
  return {
    slug: entry.id,
    title: entry.data.title,
    description: entry.data.description,
    author: entry.data.author,
    published: entry.data.published,
    minutes: readingMinutes(entry.body),
  };
}

/** Tüm blog girdileri, yeniden eskiye (aynı gündekiler başlığa göre). */
export async function blogEntries(): Promise<CollectionEntry<"blog">[]> {
  const entries: CollectionEntry<"blog">[] = await getCollection("blog");
  return [...entries].sort(
    (a: CollectionEntry<"blog">, b: CollectionEntry<"blog">): number =>
      b.data.published.getTime() - a.data.published.getTime() || a.data.title.localeCompare(b.data.title),
  );
}

/** Yayın tarihinin okunur metni (ör. 29 October 2026; UTC). Saf fonksiyondur. */
export function publishedText(date: Date): string {
  return new Intl.DateTimeFormat(siteLocale, { dateStyle: "long", timeZone: "UTC" }).format(date);
}

/** Yayın tarihinin makine biçimi (YYYY-AA-GG; `<time datetime>` ve JSON-LD). Saf fonksiyondur. */
export function publishedIso(date: Date): string {
  return date.toISOString().slice(0, 10);
}

/** XML metin ve öznitelik kaçışı. Saf fonksiyondur. */
function escapeXml(text: string): string {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&apos;");
}

/** RSS akışının başlığı ve açıklaması. */
export interface FeedInfo {
  readonly title: string;
  readonly description: string;
  /** Blog dizininin mutlak adresi. */
  readonly link: string;
  /** Akışın kendi mutlak adresi. */
  readonly self: string;
}

/** Blogun RSS 2.0 akışı (yazılar verilen sırayla). Saf fonksiyondur. */
export function blogFeedXml(feed: FeedInfo, origin: string, posts: readonly BlogPost[]): string {
  const items: string[] = posts.map((post: BlogPost): string => {
    const url: string = `${origin}${blogPostPath(post.slug)}`;
    return [
      "    <item>",
      `      <title>${escapeXml(post.title)}</title>`,
      `      <link>${escapeXml(url)}</link>`,
      `      <guid isPermaLink="true">${escapeXml(url)}</guid>`,
      `      <description>${escapeXml(post.description)}</description>`,
      `      <pubDate>${post.published.toUTCString()}</pubDate>`,
      "    </item>",
    ].join("\n");
  });
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">',
    "  <channel>",
    `    <title>${escapeXml(feed.title)}</title>`,
    `    <link>${escapeXml(feed.link)}</link>`,
    `    <description>${escapeXml(feed.description)}</description>`,
    "    <language>en</language>",
    `    <atom:link href="${escapeXml(feed.self)}" rel="self" type="application/rss+xml" />`,
    ...items,
    "  </channel>",
    "</rss>",
    "",
  ].join("\n");
}
