// Yönetim panelinin düzen metinleri (İngilizce; site dili): menü grupları, görünümlerin adı ve açıklaması, bölüm
// başlıkları, özet ölçülerinin etiketleri, tanım ipuçları ve kısa alt satırları, döküm kartlarının satırları ve genel
// bakıştaki "dikkat" listesi. Tabloların ve görünümlere özgü metinler kendi dosyalarındadır (admin-*-copy.ts, copy.ts).

/** Panelin görünümleri (menü sırasıyla). */
export type AdminView = "overview" | "revenue" | "growth" | "engagement" | "reliability" | "costs" | "users" | "inbox" | "operations" | "blog";

/** Menü grubu: başlık (ilk grup başlıksız) ve görünümleri. */
export interface NavGroup {
  readonly label: string | null;
  readonly views: readonly AdminView[];
}

/** Menünün grupları; görünümlerin sırası buradan gelir. */
export const navGroups: readonly NavGroup[] = [
  { label: null, views: ["overview"] },
  { label: "Analytics", views: ["revenue", "growth", "engagement", "reliability", "costs"] },
  { label: "Manage", views: ["users", "inbox", "operations", "blog"] },
];

/** Tüm görünümler (menü sırasıyla). */
export const adminViews: readonly AdminView[] = navGroups.flatMap((group: NavGroup): readonly AdminView[] => group.views);

/** Görünümün menüdeki adı ve üst çubuktaki açıklaması. */
export interface ViewCopy {
  readonly label: string;
  readonly description: string;
}

/** Özet ölçüsü: etiket ve (varsa) tanım ipucu. */
export interface StatCopy {
  readonly label: string;
  readonly hint: string | null;
}

/** Bölüm: başlık ve kısa açıklama. */
export interface SectionCopy {
  readonly title: string;
  readonly description: string;
}

/** Düzen metinleri. */
export interface AdminLayoutCopy {
  readonly navLabel: string;
  readonly views: Readonly<Record<AdminView, ViewCopy>>;
  readonly periods: { readonly lastDays: string; readonly latest: string; readonly noData: string };
  readonly stats: {
    readonly mrr: StatCopy;
    readonly subscribers: StatCopy;
    readonly newUsers: StatCopy;
    readonly meetings30: StatCopy;
    readonly downloads: StatCopy;
    readonly users: StatCopy;
    readonly trials: StatCopy;
    readonly refusals: StatCopy;
    readonly conversion: StatCopy;
    readonly churn: StatCopy;
    readonly meetings: StatCopy;
    readonly spend: StatCopy;
    readonly elevenLabs: StatCopy;
    readonly deepgram: StatCopy;
    readonly tokens: StatCopy;
  };
  /** Kısa alt satırlar (`{ad}` yer tutuculu). */
  readonly subs: {
    readonly plans: string;
    readonly accountsTotal: string;
    readonly liveNow: string;
    readonly inLast30: string;
    readonly newRecent: string;
    readonly usedUp: string;
    readonly today: string;
    readonly converted: string;
    readonly ending: string;
    readonly meetingHours: string;
    readonly ofCeiling: string;
    readonly ofHours: string;
    readonly ofCredit: string;
    readonly nearCap: string;
  };
  readonly charts: {
    readonly meetings: string;
    readonly newUsers: string;
    readonly downloads: string;
    readonly spend: string;
    readonly subscription: string;
    readonly trial: string;
  };
  readonly attention: {
    readonly title: string;
    readonly empty: string;
    readonly inbox: string;
    readonly disputes: string;
    readonly pastDue: string;
    readonly unpaid: string;
    readonly spend: string;
    readonly elevenLabs: string;
    readonly deepgram: string;
    readonly nearCap: string;
    readonly serverErrors: string;
    readonly providerErrors: string;
    readonly trialCeiling: string;
    readonly spendCeiling: string;
    readonly deepgramStale: string;
    readonly reservations: string;
    readonly unended: string;
  };
  readonly facts: {
    readonly capacity: { readonly title: string; readonly spend: string; readonly elevenLabs: string; readonly deepgram: string; readonly nearCap: string };
    readonly subscriptions: {
      readonly title: string;
      readonly monthly: string;
      readonly yearly: string;
      readonly invite: string;
      readonly grace: string;
      readonly ending: string;
      readonly canceled: string;
      readonly free: string;
    };
    readonly billing: {
      readonly title: string;
      readonly refunds: string;
      readonly disputes: string;
      readonly failed: string;
      readonly duplicates: string;
      readonly pastDue: string;
      readonly unpaid: string;
    };
    readonly signups: { readonly title: string; readonly today: string; readonly week: string; readonly month: string; readonly apple: string; readonly google: string };
    readonly refusals: { readonly title: string; readonly device: string; readonly ip: string; readonly exhausted: string; readonly expired: string; readonly today: string };
    readonly referrals: { readonly title: string; readonly joined: string; readonly pending: string; readonly granted: string; readonly voided: string };
    readonly month: {
      readonly title: string;
      readonly meetings: string;
      readonly open: string;
      readonly deferred: string;
      readonly reprocessed: string;
      readonly hours: string;
      readonly audio: string;
      readonly stream: string;
    };
    readonly tokens: { readonly title: string; readonly total: string; readonly account: string; readonly cap: string; readonly accountCap: string; readonly near: string };
  };
  readonly empty: { readonly recentCancellations: string };
  readonly sections: {
    readonly revenueTrends: SectionCopy;
    readonly billing: SectionCopy;
    readonly conversion: SectionCopy;
    readonly funnel: SectionCopy;
    readonly acquisition: SectionCopy;
    readonly website: SectionCopy;
    readonly invites: SectionCopy;
    readonly activity: SectionCopy;
    readonly retention: SectionCopy;
    readonly features: SectionCopy;
    readonly platform: SectionCopy;
    readonly errors: SectionCopy;
    readonly meetings: SectionCopy;
    readonly app: SectionCopy;
    readonly spend: SectionCopy;
    readonly tokens: SectionCopy;
    readonly live: SectionCopy;
  };
}

export const adminLayoutCopy: AdminLayoutCopy = {
  navLabel: "Dashboard sections",
  views: {
    overview: { label: "Overview", description: "The state of the business at a glance." },
    revenue: { label: "Revenue", description: "Recurring revenue, subscriptions, payments and churn." },
    growth: { label: "Growth", description: "Downloads, sign-ups, the funnel and where people come from." },
    engagement: { label: "Engagement", description: "Who keeps using the app, how much and which features." },
    reliability: { label: "Reliability", description: "Failed meetings, service errors and crashes." },
    costs: { label: "Costs", description: "AI and transcription spend against plan limits." },
    users: { label: "Users", description: "Find an account and open its details." },
    inbox: { label: "Inbox", description: "Feedback, crash reports and contact messages." },
    operations: { label: "Operations", description: "Live meetings, usage reservations and Stripe webhooks." },
    blog: { label: "Blog", description: "Weekly posts: list, schedule and editor." },
  },
  periods: { lastDays: "Total, last {days} days", latest: "Latest · {day}", noData: "No data yet" },
  stats: {
    mrr: { label: "MRR", hint: "Renewing subscriptions; yearly plans count as 1/12 a month. Free invite months are excluded, taxes included." },
    subscribers: { label: "Paying subscribers", hint: "Subscriptions with access right now, including the free first month of an invite. Free access granted by an admin isn't counted." },
    newUsers: { label: "New accounts", hint: "Accounts created in the last 30 days." },
    meetings30: { label: "Meetings", hint: "Meetings started in the last 30 days, trial and subscription." },
    downloads: { label: "Downloads", hint: "All-time downloads; each network counts once a day." },
    users: { label: "Accounts", hint: "All accounts ever created." },
    trials: { label: "Active trials", hint: "Accounts with trial meetings left." },
    refusals: { label: "Trials refused", hint: "Trial starts refused in the last 30 days: a Mac or network that already used one, or a trial that was used up or expired." },
    conversion: { label: "Trial to paid", hint: "Share of all trials that turned into a subscription." },
    churn: { label: "Cancellations", hint: "Subscriptions that ended in the last 30 days." },
    meetings: { label: "Meetings this month", hint: null },
    spend: { label: "AI spend today", hint: "Spend on AI models today against the daily ceiling; requests are refused at the ceiling." },
    elevenLabs: { label: "Transcription capacity", hint: "Audio hours used in the current ElevenLabs plan cycle." },
    deepgram: { label: "Live transcript credit", hint: "Estimated Deepgram spend against the credit; past it, live text runs on the Mac." },
    tokens: { label: "Tokens this month", hint: "AI tokens used by all accounts this month, in meetings and outside them." },
  },
  subs: {
    plans: "{monthly} monthly · {yearly} yearly",
    accountsTotal: "{count} accounts in total",
    liveNow: "{count} live now",
    inLast30: "{count} in the last 30 days",
    newRecent: "+{month} in 30 days · {today} today",
    usedUp: "{count} used up",
    today: "{count} today",
    converted: "{converted} of {started} · 30 days {recent}",
    ending: "{count} more set to end",
    meetingHours: "{hours} meeting hours",
    ofCeiling: "of {ceiling} daily ceiling",
    ofHours: "{used} of {cap} h this cycle",
    ofCredit: "{used} of {budget} credit",
    nearCap: "{count} accounts above 80% of the cap",
  },
  charts: {
    meetings: "Meetings per day",
    newUsers: "New accounts per day",
    downloads: "Downloads per day",
    spend: "AI spend per day",
    subscription: "Subscription",
    trial: "Trial",
  },
  attention: {
    title: "Needs attention",
    empty: "All clear. Nothing needs a look right now.",
    inbox: "Open reports in the inbox",
    disputes: "Payment disputes, 30 days",
    pastDue: "Subscriptions with payment due",
    unpaid: "Unpaid subscriptions",
    spend: "AI spend near today's ceiling",
    elevenLabs: "ElevenLabs hours near the plan limit",
    deepgram: "Deepgram credit nearly used",
    nearCap: "Accounts near the token cap",
    serverErrors: "Server errors (5xx), 7 days",
    providerErrors: "AI or transcription failures, 7 days",
    trialCeiling: "Trials refused at the daily ceiling, 7 days",
    spendCeiling: "Requests refused at the spend ceiling, 7 days",
    deepgramStale: "Live transcripts that never settled",
    reservations: "Expired reservations older than a day",
    unended: "Meetings that never ended, 7 days",
  },
  facts: {
    capacity: { title: "Capacity", spend: "AI spend today", elevenLabs: "ElevenLabs hours", deepgram: "Deepgram credit", nearCap: "Accounts near the token cap" },
    subscriptions: {
      title: "Subscriptions",
      monthly: "Monthly",
      yearly: "Yearly",
      invite: "Free invite month",
      grace: "Payment due (grace)",
      ending: "Set to end",
      canceled: "Cancelled, all time",
      free: "Free access, not billed",
    },
    billing: {
      title: "Billing, 30 days",
      refunds: "Refunds",
      disputes: "Disputes",
      failed: "Failed payments",
      duplicates: "Duplicate subscriptions refunded",
      pastDue: "Payment due now",
      unpaid: "Unpaid now",
    },
    signups: { title: "Sign-ups", today: "Today", week: "Last 7 days", month: "Last 30 days", apple: "With Apple, all time", google: "With Google, all time" },
    refusals: { title: "Trial refusals, 30 days", device: "Mac already used a trial", ip: "Same network, daily limit", exhausted: "Trial used up", expired: "Trial expired", today: "Today, all reasons" },
    referrals: { title: "Invite program, all time", joined: "Joined", pending: "Waiting for first payment", granted: "Rewarded", voided: "Voided" },
    month: {
      title: "This month",
      meetings: "Meetings",
      open: "Live now",
      deferred: "Processed later",
      reprocessed: "Reprocessed",
      hours: "Meeting hours",
      audio: "Transcribed audio",
      stream: "Deepgram stream minutes, all time",
    },
    tokens: { title: "Token usage and caps", total: "All tokens, this month", account: "Outside meetings", cap: "Monthly cap per account", accountCap: "Outside-meeting cap per account", near: "Accounts above 80%" },
  },
  empty: { recentCancellations: "No cancellations yet." },
  sections: {
    revenueTrends: { title: "Revenue", description: "Daily snapshots and collected payments by currency." },
    billing: { title: "Billing and churn", description: "Payment problems and why people leave." },
    conversion: { title: "Conversion and margin", description: "How trials end and what each paying account earns after costs." },
    funnel: { title: "Funnel", description: "From download to subscription for accounts created in the last 30 days." },
    acquisition: { title: "Acquisition", description: "Which buttons, sites and campaigns bring downloads." },
    website: { title: "Website", description: "Cloudflare Web Analytics for gistsmith.com." },
    invites: { title: "Invites", description: "The invite program over the last 30 days." },
    activity: { title: "Activity", description: "Meetings and active accounts over time." },
    retention: { title: "Retention", description: "Weekly activity by sign-up cohort." },
    features: { title: "Features", description: "What people use in the Mac app (anonymous statistics)." },
    platform: { title: "Versions", description: "App and macOS versions in use." },
    errors: { title: "Errors", description: "Refusals, failed service calls and server errors per day." },
    meetings: { title: "Meetings", description: "How meetings end and what goes wrong." },
    app: { title: "Mac app", description: "Crashes, connection drops and processing times reported by the app." },
    spend: { title: "Spend", description: "Daily and monthly cost of AI, transcription and live text." },
    tokens: { title: "Tokens", description: "Where AI tokens go." },
    live: { title: "Live", description: "What is running right now." },
  },
};
