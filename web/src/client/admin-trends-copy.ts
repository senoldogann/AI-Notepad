// Yönetim panelinin eğilim verisinin metinleri (İngilizce; yalnızca yönetici görür): günlük anlık görüntü grafikleri,
// gerçek gelir, token kovaları, konuşma tanıma dilleri, hesap silmeleri ve yeniden denemeler, indirme kampanyaları ve
// site istatistikleri. Sayfa (admin.astro) ve betik (admin-trends.ts) aynı nesneyi kullanır; DOM'a dokunmaz.

/** Token kovası (sunucu `llmUsageBuckets`). */
export type TrendTokenBucket = "meeting_note" | "meeting_live_structured" | "meeting_live_text" | "account_note" | "account_quick";

/** Görünümün grafikleri (betik `chart-trend-<id>` çizer). */
export type TrendChartId = "mrr" | "subscribers" | "active" | "spend" | "revenue";

/** Görünümün tabloları (betik `trend-<id>-rows` ve `trend-<id>-empty` doldurur). */
export type TrendTableId = "revenue" | "tokens" | "languages" | "events" | "campaigns" | "paths" | "referrers";

/** Tablo tanımı: başlık, sütunlar (sayı sütunu sağa yaslanır), boş bildirimi ve not. */
export interface TrendTableCopy {
  readonly title: string;
  readonly columns: readonly { readonly label: string; readonly numeric: boolean }[];
  readonly empty: string;
  readonly note: string;
}

/** Görünüm metinleri. `{ad}` yer tutucuları değerlerle doldurulur. */
export interface AdminTrendsCopy {
  readonly chartsNote: string;
  readonly charts: Readonly<Record<TrendChartId, { readonly title: string; readonly main: string; readonly accent: string | null }>>;
  readonly tables: Readonly<Record<TrendTableId, TrendTableCopy>>;
  readonly buckets: Readonly<Record<TrendTokenBucket, string>>;
  /** `{days}`, `{count}`. */
  readonly firstPayments: string;
  /** `{days}`. */
  readonly medianToPaid: string;
  readonly noMedian: string;
  readonly eventKinds: { readonly deletion: string; readonly retry: string };
  readonly autoLanguage: string;
  readonly direct: string;
  readonly noCampaign: string;
  /** Sitenin günlük sayfa görüntüleme grafiği: başlık ve okumadaki seri adı. */
  readonly siteChart: { readonly title: string; readonly pageViews: string };
  /** `{days}`, `{views}`, `{visits}`. */
  readonly siteSummary: string;
  readonly siteUnavailable: string;
  readonly none: string;
}

/** Görünüm metinleri. */
export const adminTrendsCopy: AdminTrendsCopy = {
  chartsNote:
    "Daily snapshots written by the nightly job for the finished UTC day. Days before the first snapshot are empty. Spend is the server's estimate; Deepgram counts the stream time charged to its budget.",
  charts: {
    mrr: { title: "MRR at list price", main: "MRR", accent: null },
    subscribers: { title: "Renewing subscribers", main: "Monthly", accent: "Yearly" },
    active: { title: "Active users (7 days, with a meeting)", main: "Active users", accent: null },
    spend: { title: "Spend by provider", main: "Anthropic", accent: "ElevenLabs + Deepgram" },
    revenue: { title: "Payments and refunds", main: "Paid", accent: "Refunded" },
  },
  tables: {
    revenue: {
      title: "Revenue by currency",
      columns: [
        { label: "Currency", numeric: false },
        { label: "MRR", numeric: true },
        { label: "Paying", numeric: true },
        { label: "ARPU", numeric: true },
        { label: "Paid 30 d", numeric: true },
        { label: "Refunds 30 d", numeric: true },
        { label: "Net 30 d", numeric: true },
        { label: "LTV", numeric: true },
      ],
      empty: "No paid invoices recorded yet.",
      note:
        "From Stripe invoices: MRR is each renewing subscription's last paid invoice without tax (yearly ÷ 12); ARPU = MRR ÷ paying subscriptions. Net = paid − tax − refunds (refunds include tax). LTV = all-time net ÷ subscriptions that ever paid. Stripe fees are not deducted.",
    },
    tokens: {
      title: "AI tokens by inferred feature",
      columns: [
        { label: "Bucket", numeric: false },
        { label: "Calls", numeric: true },
        { label: "Input", numeric: true },
        { label: "Output", numeric: true },
      ],
      empty: "No AI calls in this window.",
      note: "The server infers the feature from the request: meeting or account call, effort and whether a JSON schema is sent. Approximate.",
    },
    languages: {
      title: "Transcription languages",
      columns: [
        { label: "Requested", numeric: false },
        { label: "Detected", numeric: false },
        { label: "Requests", numeric: true },
        { label: "Audio h", numeric: true },
      ],
      empty: "No transcriptions in this window.",
      note: "",
    },
    events: {
      title: "Account deletions and retries",
      columns: [
        { label: "Event", numeric: false },
        { label: "Detail", numeric: false },
        { label: "Count", numeric: true },
      ],
      empty: "No deletions or retries in this window.",
      note: "Deletions by segment at deletion time (subscriber, trial, signup). Retries are upstream calls retried after a temporary error, by service.",
    },
    campaigns: {
      title: "Downloads by campaign",
      columns: [
        { label: "utm_source", numeric: false },
        { label: "utm_campaign", numeric: false },
        { label: "Downloads", numeric: true },
      ],
      empty: "No campaign downloads in this window.",
      note: "Counted on /v1/download/mac?utm_source=…&utm_campaign=…; unknown sources and malformed names are “other”.",
    },
    paths: {
      title: "Top pages",
      columns: [
        { label: "Path", numeric: false },
        { label: "Views", numeric: true },
        { label: "Visits", numeric: true },
      ],
      empty: "No page views in this window.",
      note: "",
    },
    referrers: {
      title: "Top referrers",
      columns: [
        { label: "Site", numeric: false },
        { label: "Views", numeric: true },
        { label: "Visits", numeric: true },
      ],
      empty: "No page views in this window.",
      note: "Cloudflare Web Analytics, sampled estimates.",
    },
  },
  buckets: {
    meeting_note: "Meeting note (medium)",
    meeting_live_structured: "Live, structured (translation)",
    meeting_live_text: "Live, text (catch-up, questions)",
    account_note: "Note rewrite and editing",
    account_quick: "Ask, share translation, tasks",
  },
  firstPayments: "First payments in the last {days} days: {count}",
  medianToPaid: "Median time from sign-up to first payment: {days} days",
  noMedian: "No first payments recorded yet.",
  eventKinds: { deletion: "Account deleted", retry: "Upstream retry" },
  autoLanguage: "auto",
  direct: "(direct)",
  noCampaign: "(none)",
  siteChart: { title: "Page views per day", pageViews: "Page views" },
  siteSummary: "Last {days} days: {views} page views, {visits} visits",
  siteUnavailable: "Not configured: set CF_ANALYTICS_ACCOUNT_ID, CF_ANALYTICS_SITE_TAG and the CF_ANALYTICS_TOKEN secret on the server.",
  none: "—",
};
