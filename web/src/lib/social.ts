// Sayfanın paylaşım kartı (Open Graph ve Twitter): sabit sayfalar sitenin kartını (`public/og.png`), blog yazıları kendi
// görselini (`/blog/<kısa ad>/og.png`, scripts/make-blog-og.ts) ve yayın/değişiklik tarihlerini taşır. Base.astro yazar.

/** Sitenin genel kartı: `og:type website`, görsel `public/og.png`. */
export interface WebsiteCard {
  readonly kind: "website";
}

/** Makale kartı: `og:type article`, yazının görseli ve tarihleri. */
export interface ArticleCard {
  readonly kind: "article";
  /** Görselin mutlak adresi (1200×630 PNG). */
  readonly image: string;
  readonly imageAlt: string;
  /** YYYY-AA-GG (`article:published_time`). */
  readonly published: string;
  /** YYYY-AA-GG (`article:modified_time`): `updated`, yoksa `published`. */
  readonly modified: string;
}

/** Sayfanın paylaşım kartı. */
export type SocialCard = WebsiteCard | ArticleCard;

/** Sabit sayfaların kartı. */
export const websiteCard: WebsiteCard = { kind: "website" };
