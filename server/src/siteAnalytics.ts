import { z } from "zod";
import { lastDays } from "./admin";
import type { SiteAnalyticsConfig } from "./config";
import { ApiError, UpstreamError } from "./errors";
import { log } from "./log";
import type { Platform } from "./platform";
import { utcDayStartMs } from "./reports";
import { fetchUpstream } from "./upstream";

/**
 * Yönetim panelindeki site istatistikleri (`GET /v1/admin/site-analytics`): sitenin Cloudflare Web Analytics toplamları
 * Cloudflare GraphQL API'sinin `rumPageloadEventsAdaptiveGroups` veri kümesinden okunur (yeni veri toplanmaz; çerezsiz
 * işaretçinin zaten saydığı toplamlar). `count` sayfa görüntülemedir, `sum.visits` ziyaret; Cloudflare uyarlamalı
 * örneklemeyle tahmin eder. Yalnızca toplamlar ve yollar/alan adları döner.
 */

/** Cloudflare GraphQL API adresi. */
export const cloudflareGraphqlUrl: string = "https://api.cloudflare.com/client/v4/graphql";

/** İstatistik penceresi (gün, bugün dahil). */
export const siteAnalyticsDays: number = 30;
/** En çok açılan sayfa ve yönlendiren site satırı. */
const topLimit: number = 15;
const analyticsTimeoutMs: number = 15_000;
const analyticsAttempts: number = 2;

/** Ayarları tam site istatistikleri yapılandırması (`requireSiteAnalytics`). */
export interface ActiveSiteAnalytics {
  readonly accountId: string;
  readonly siteTag: string;
  readonly token: string;
}

/** Gün başına sayfa görüntüleme ve ziyaret. */
export interface SiteAnalyticsDay {
  readonly day: string;
  readonly pageViews: number;
  readonly visits: number;
}

/** Anahtar (yol ya da alan adı; doğrudan gelişte boş) başına sayfa görüntüleme ve ziyaret. */
export interface SiteAnalyticsEntry {
  readonly key: string;
  readonly pageViews: number;
  readonly visits: number;
}

/** `GET /v1/admin/site-analytics` yanıtı. Günler `YYYY-MM-DD` (UTC), eskiden yeniye, boş günler 0. */
export interface SiteAnalytics {
  readonly generatedAt: string;
  readonly days: number;
  readonly pageViews: number;
  readonly visits: number;
  readonly daily: readonly SiteAnalyticsDay[];
  readonly topPaths: readonly SiteAnalyticsEntry[];
  readonly topReferrers: readonly SiteAnalyticsEntry[];
}

/** Hesap, site etiketi ve jeton girilmişse etkin yapılandırma; değilse `analytics_unavailable`. Saf fonksiyondur. */
export function requireSiteAnalytics(config: SiteAnalyticsConfig): ActiveSiteAnalytics {
  const missing: string[] = [
    ...(config.accountId === null ? ["CF_ANALYTICS_ACCOUNT_ID"] : []),
    ...(config.siteTag === null ? ["CF_ANALYTICS_SITE_TAG"] : []),
    ...(config.token === null ? ["CF_ANALYTICS_TOKEN"] : []),
  ];
  if (config.accountId === null || config.siteTag === null || config.token === null) {
    throw new ApiError("analytics_unavailable", `Site istatistikleri kapalı: sunucuda ${missing.join(", ")} girilmemiş.`);
  }
  return { accountId: config.accountId, siteTag: config.siteTag, token: config.token };
}

/**
 * GraphQL sorgusu: aynı süzgeçle dört gruplama — toplam, gün, yol ve yönlendiren alan adı (Cloudflare panelinin Web
 * Analytics sorgusuyla aynı alanlar).
 */
const siteAnalyticsQuery: string = `query SiteAnalytics($accountTag: string, $filter: AccountRumPageloadEventsAdaptiveGroupsFilter_InputObject) {
  viewer {
    accounts(filter: { accountTag: $accountTag }) {
      total: rumPageloadEventsAdaptiveGroups(filter: $filter, limit: 1) { count sum { visits } }
      daily: rumPageloadEventsAdaptiveGroups(filter: $filter, limit: ${siteAnalyticsDays + 2}, orderBy: [date_ASC]) { count sum { visits } dimensions { date } }
      topPaths: rumPageloadEventsAdaptiveGroups(filter: $filter, limit: ${topLimit}, orderBy: [count_DESC]) { count sum { visits } dimensions { requestPath } }
      topReferrers: rumPageloadEventsAdaptiveGroups(filter: $filter, limit: ${topLimit}, orderBy: [count_DESC]) { count sum { visits } dimensions { refererHost } }
    }
  }
}`;

const groupFields = { count: z.number().int().nonnegative(), sum: z.object({ visits: z.number().int().nonnegative() }) };
const responseSchema = z.object({
  data: z
    .object({
      viewer: z.object({
        accounts: z.array(
          z.object({
            total: z.array(z.object(groupFields)),
            daily: z.array(z.object({ ...groupFields, dimensions: z.object({ date: z.string() }) })),
            topPaths: z.array(z.object({ ...groupFields, dimensions: z.object({ requestPath: z.string() }) })),
            topReferrers: z.array(z.object({ ...groupFields, dimensions: z.object({ refererHost: z.string() }) })),
          }),
        ),
      }),
    })
    .nullable(),
  errors: z.array(z.object({ message: z.string() })).nullable().optional(),
});

type AnalyticsResponse = z.output<typeof responseSchema>;
type AccountGroups = NonNullable<AnalyticsResponse["data"]>["viewer"]["accounts"][number];

/** Cloudflare'in yanıtını panel biçimine çevirir; günler `days` listesine yerleşir (eksik gün 0). Saf fonksiyondur. */
export function siteAnalyticsOf(groups: AccountGroups, days: readonly string[], now: Date): SiteAnalytics {
  const byDay: Map<string, { count: number; visits: number }> = new Map(
    groups.daily.map((row): [string, { count: number; visits: number }] => [row.dimensions.date, { count: row.count, visits: row.sum.visits }]),
  );
  const total = groups.total[0];
  return {
    generatedAt: now.toISOString(),
    days: days.length,
    pageViews: total === undefined ? 0 : total.count,
    visits: total === undefined ? 0 : total.sum.visits,
    daily: days.map((day: string): SiteAnalyticsDay => ({ day, pageViews: byDay.get(day)?.count ?? 0, visits: byDay.get(day)?.visits ?? 0 })),
    topPaths: groups.topPaths.map((row): SiteAnalyticsEntry => ({ key: row.dimensions.requestPath, pageViews: row.count, visits: row.sum.visits })),
    topReferrers: groups.topReferrers.map((row): SiteAnalyticsEntry => ({ key: row.dimensions.refererHost, pageViews: row.count, visits: row.sum.visits })),
  };
}

/** Gövdeyi JSON olarak çözer; JSON değilse null (şema doğrulaması onu beklenmeyen gövde olarak reddeder). Saf fonksiyondur. */
function parseJsonOrNull(text: string): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch (error: unknown) {
    if (error instanceof SyntaxError) {
      return null;
    }
    throw error;
  }
}

/**
 * Son `siteAnalyticsDays` günün (bugün dahil, UTC) site istatistikleri. Ağ hatası, zaman aşımı ve 5xx uyarıyla yeniden
 * denenir; Cloudflare'in GraphQL hatası (ör. yetkisiz jeton, yanlış site etiketi) ya da beklenmeyen gövde mesajıyla
 * loglanır ve `UpstreamError` olur (istemciye `502 upstream_unavailable`). Jeton loglanmaz.
 */
export async function fetchSiteAnalytics(platform: Platform, analytics: ActiveSiteAnalytics, now: Date): Promise<SiteAnalytics> {
  const days: string[] = lastDays(now, siteAnalyticsDays);
  const startMs: number = utcDayStartMs(now) - (siteAnalyticsDays - 1) * 86_400_000;
  const variables = {
    accountTag: analytics.accountId,
    filter: { siteTag: analytics.siteTag, datetime_geq: new Date(startMs).toISOString(), datetime_leq: now.toISOString() },
  };
  const response: Response = await fetchUpstream(
    platform,
    "cloudflare_analytics",
    cloudflareGraphqlUrl,
    (): RequestInit => ({
      method: "POST",
      headers: { authorization: `Bearer ${analytics.token}`, "content-type": "application/json" },
      body: JSON.stringify({ query: siteAnalyticsQuery, variables }),
    }),
    analyticsAttempts,
    analyticsTimeoutMs,
  );
  const text: string = await response.text();
  const parsed = responseSchema.safeParse(parseJsonOrNull(text));
  if (!parsed.success) {
    log("error", "site_analytics_unexpected_body", { status: response.status, body: text.slice(0, 500) });
    throw new UpstreamError("cloudflare_analytics", response.status, false, "beklenmeyen yanıt gövdesi");
  }
  const errors: ReadonlyArray<{ message: string }> = parsed.data.errors ?? [];
  const account: AccountGroups | undefined = parsed.data.data?.viewer.accounts[0];
  if (errors.length > 0 || account === undefined) {
    const messages: string = errors.map((error: { message: string }): string => error.message).join("; ").slice(0, 500);
    log("error", "site_analytics_failed", { status: response.status, accountId: analytics.accountId, siteTag: analytics.siteTag, errors: messages });
    throw new UpstreamError("cloudflare_analytics", response.status, false, messages === "" ? "hesap bulunamadı" : messages);
  }
  return siteAnalyticsOf(account, days, now);
}
