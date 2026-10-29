// Sitenin yapılandırılmış verisi (schema.org JSON-LD): ana sayfada uygulama (`SoftwareApplication`), onu sunan işletme
// (`Organization`) ve sık sorulan sorular (`FAQPage`); fiyat sayfasında onun soruları; blog yazılarında `BlogPosting`
// (ön bilgisinden: src/content/blog). Değerler sitenin tek kaynaklarından
// gelir: ürün adı (config.ts), fiyat, gereksinimler ve sorular (copy.ts),
// işletme (legal/operator.ts). `<script type="application/ld+json">` veri bloğudur, çalıştırılmaz; CSP onu engellemez.
import { productName, type SiteConfig } from "../config";
import type { CommonCopy, Faq, PageMeta } from "../copy";
import type { Operator } from "../legal/operator";
import { pageUrl } from "../routes";

/** İşletme düğümü. */
interface OrganizationNode {
  readonly "@type": "Organization";
  readonly "@id": string;
  readonly name: string;
  readonly url: string;
  readonly email: string;
}

/** Aylık fiyat tanımı. */
interface MonthlyPriceNode {
  readonly "@type": "UnitPriceSpecification";
  readonly price: string;
  readonly priceCurrency: string;
  readonly unitCode: "MON";
  readonly billingDuration: "P1M";
  readonly valueAddedTaxIncluded: true;
}

/** Abonelik teklifi. */
interface OfferNode {
  readonly "@type": "Offer";
  readonly price: string;
  readonly priceCurrency: string;
  readonly url: string;
  readonly priceSpecification: MonthlyPriceNode;
}

/** Uygulama düğümü; yayıncı işletme düğümüne `@id` ile bağlanır. */
interface SoftwareApplicationNode {
  readonly "@type": "SoftwareApplication";
  readonly name: string;
  readonly description: string;
  readonly url: string;
  readonly image: string;
  readonly downloadUrl: string;
  readonly applicationCategory: "BusinessApplication";
  readonly operatingSystem: string;
  readonly processorRequirements: string;
  readonly offers: OfferNode;
  readonly publisher: { readonly "@id": string };
}

/** Sık sorulan sorunun yanıtı. */
interface AnswerNode {
  readonly "@type": "Answer";
  readonly text: string;
}

/** Sık sorulan soru. */
interface QuestionNode {
  readonly "@type": "Question";
  readonly name: string;
  readonly acceptedAnswer: AnswerNode;
}

/** Sayfadaki sık sorulan sorular (yalnızca sayfada görünen soru ve yanıtlar). */
interface FaqPageNode {
  readonly "@type": "FAQPage";
  readonly "@id": string;
  readonly url: string;
  readonly mainEntity: readonly QuestionNode[];
}

/** Ana sayfaya yazılan JSON-LD belgesi. */
export interface StructuredDataDocument {
  readonly "@context": "https://schema.org";
  readonly "@graph": readonly [SoftwareApplicationNode, OrganizationNode, FaqPageNode];
}

/** Yalnızca sık sorulan soruları taşıyan JSON-LD belgesi (fiyat sayfası). */
export interface FaqDocument {
  readonly "@context": "https://schema.org";
  readonly "@graph": readonly [FaqPageNode];
}

/**
 * Sayfanın sık sorulan soruları (`FAQPage`): sayfadaki `Faq` bileşeninin gösterdiği aynı `copy.ts` girdilerinden
 * üretilir, metin kopyalanmaz. Saf fonksiyondur.
 */
export function faqPageNode(items: readonly Faq[], url: string): FaqPageNode {
  return {
    "@type": "FAQPage",
    "@id": `${url}#faq`,
    url,
    mainEntity: items.map((item: Faq): QuestionNode => ({ "@type": "Question", name: item.question, acceptedAnswer: { "@type": "Answer", text: item.answer } })),
  };
}

/** Fiyat sayfasının JSON-LD belgesi: yalnızca o sayfanın sık sorulan soruları. Saf fonksiyondur. */
export function faqStructuredData(items: readonly Faq[], url: string): FaqDocument {
  return { "@context": "https://schema.org", "@graph": [faqPageNode(items, url)] };
}

/** Fiyat ya da gereksinim metni beklenen biçimde değil: copy.ts değişti, yapılandırılmış veri güncellenmeli. */
export class StructuredDataSourceError extends Error {
  override readonly name: string = "StructuredDataSourceError";
}

/** Dolar fiyatı ve para birimi. */
interface UsdPrice {
  readonly amount: string;
  readonly currency: "USD";
}

/** `$5.99` biçimindeki fiyat metnini tutara çevirir; başka biçimde `StructuredDataSourceError`. Saf fonksiyondur. */
function usdPrice(price: string): UsdPrice {
  const match: RegExpExecArray | null = /^\$([0-9]+\.[0-9]{2})$/.exec(price);
  const amount: string | undefined = match?.[1];
  if (amount === undefined) {
    throw new StructuredDataSourceError(`Fiyat "$<tutar>" biçiminde olmalı; gelen: ${JSON.stringify(price)} (copy.common.price).`);
  }
  return { amount, currency: "USD" };
}

/** İşletim sistemi ve işlemci gereksinimi. */
interface Requirements {
  readonly operatingSystem: string;
  readonly processor: string;
}

/** `macOS 26 or later · Apple silicon` biçimindeki metni ikiye ayırır; başka biçimde `StructuredDataSourceError`. Saf fonksiyondur. */
function requirements(text: string): Requirements {
  const parts: readonly string[] = text.split(" · ");
  const operatingSystem: string | undefined = parts[0];
  const processor: string | undefined = parts[1];
  if (parts.length !== 2 || operatingSystem === undefined || processor === undefined) {
    throw new StructuredDataSourceError(`Gereksinim "<sistem> · <işlemci>" biçiminde olmalı; gelen: ${JSON.stringify(text)} (copy.common.requirementsShort).`);
  }
  return { operatingSystem, processor };
}

/** Ana sayfanın JSON-LD belgesi: uygulama, işletme ve sayfadaki sık sorulan sorular (`faq`). Saf fonksiyondur. */
export function homeStructuredData(
  config: SiteConfig,
  common: CommonCopy,
  meta: PageMeta,
  operator: Operator,
  faq: readonly Faq[],
): StructuredDataDocument {
  const origin: string = config.siteOrigin;
  const organizationId: string = `${origin}/#organization`;
  const price: UsdPrice = usdPrice(common.price);
  const needs: Requirements = requirements(common.requirementsShort);
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "SoftwareApplication",
        name: productName,
        description: meta.description,
        url: pageUrl("home", origin),
        image: `${origin}/og.png`,
        downloadUrl: pageUrl("download", origin),
        applicationCategory: "BusinessApplication",
        operatingSystem: needs.operatingSystem,
        processorRequirements: needs.processor,
        offers: {
          "@type": "Offer",
          price: price.amount,
          priceCurrency: price.currency,
          url: pageUrl("pricing", origin),
          priceSpecification: {
            "@type": "UnitPriceSpecification",
            price: price.amount,
            priceCurrency: price.currency,
            unitCode: "MON",
            billingDuration: "P1M",
            valueAddedTaxIncluded: true,
          },
        },
        publisher: { "@id": organizationId },
      },
      { "@type": "Organization", "@id": organizationId, name: operator.name, url: origin, email: operator.email },
      faqPageNode(faq, pageUrl("home", origin)),
    ],
  };
}

/** Yazar. */
interface PersonNode {
  readonly "@type": "Person";
  readonly name: string;
}

/** Blog yazısı; yayıncı işletme düğümüne (ana sayfadaki `Organization`) `@id` ile bağlanır. */
interface BlogPostingNode {
  readonly "@type": "BlogPosting";
  readonly "@id": string;
  readonly headline: string;
  readonly description: string;
  readonly url: string;
  readonly mainEntityOfPage: string;
  readonly image: string;
  readonly datePublished: string;
  readonly dateModified: string;
  readonly inLanguage: "en";
  readonly author: PersonNode;
  readonly publisher: { readonly "@type": "Organization"; readonly "@id": string; readonly name: string; readonly url: string };
}

/** Blog yazısı sayfasının JSON-LD belgesi. */
export interface BlogPostingDocument {
  readonly "@context": "https://schema.org";
  readonly "@graph": readonly [BlogPostingNode];
}

/** Blog yazısının JSON-LD'ye giren bilgileri. */
export interface BlogPostingInput {
  readonly url: string;
  readonly title: string;
  readonly description: string;
  readonly author: string;
  /** YYYY-AA-GG. */
  readonly published: string;
}

/** Blog yazısının JSON-LD belgesi (`BlogPosting`). Saf fonksiyondur. */
export function blogPostingStructuredData(config: SiteConfig, operator: Operator, post: BlogPostingInput): BlogPostingDocument {
  const origin: string = config.siteOrigin;
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "BlogPosting",
        "@id": `${post.url}#post`,
        headline: post.title,
        description: post.description,
        url: post.url,
        mainEntityOfPage: post.url,
        image: `${origin}/og.png`,
        datePublished: post.published,
        dateModified: post.published,
        inLanguage: "en",
        author: { "@type": "Person", name: post.author },
        publisher: { "@type": "Organization", "@id": `${origin}/#organization`, name: operator.name, url: origin },
      },
    ],
  };
}

/**
 * JSON-LD belgesini `<script>` içine güvenle yazılacak metne çevirir: `<` kaçırılır, böylece metindeki `</script>`
 * bloğu erken kapatamaz. Saf fonksiyondur.
 */
export function structuredDataJson(document: StructuredDataDocument | FaqDocument | BlogPostingDocument): string {
  return JSON.stringify(document).replaceAll("<", "\\u003c");
}
