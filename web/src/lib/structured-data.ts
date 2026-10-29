// Ana sayfanın yapılandırılmış verisi (schema.org JSON-LD): uygulama (`SoftwareApplication`) ve onu sunan işletme
// (`Organization`). Değerler sitenin tek kaynaklarından gelir: ürün adı (config.ts), fiyat ve gereksinimler (copy.ts),
// işletme (legal/operator.ts). `<script type="application/ld+json">` veri bloğudur, çalıştırılmaz; CSP onu engellemez.
import { productName, type SiteConfig } from "../config";
import type { CommonCopy, PageMeta } from "../copy";
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

/** Sayfaya yazılan JSON-LD belgesi. */
export interface StructuredDataDocument {
  readonly "@context": "https://schema.org";
  readonly "@graph": readonly [SoftwareApplicationNode, OrganizationNode];
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

/** Ana sayfanın JSON-LD belgesi. Saf fonksiyondur. */
export function homeStructuredData(config: SiteConfig, common: CommonCopy, meta: PageMeta, operator: Operator): StructuredDataDocument {
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
    ],
  };
}

/**
 * JSON-LD belgesini `<script>` içine güvenle yazılacak metne çevirir: `<` kaçırılır, böylece metindeki `</script>`
 * bloğu erken kapatamaz. Saf fonksiyondur.
 */
export function structuredDataJson(document: StructuredDataDocument): string {
  return JSON.stringify(document).replaceAll("<", "\\u003c");
}
