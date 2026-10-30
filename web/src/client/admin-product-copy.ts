// Yönetim panelinin ürün verisinin metinleri (İngilizce; yalnızca yönetici görür): özet ölçüleri ve tanım ipuçları,
// tablo sütunları ve notları, grafik başlıkları ve değerlere bağlı satırlar. Sayfa (admin.astro) ve betik
// (admin-product.ts) aynı nesneyi kullanır; DOM'a dokunmaz.

/** Ürün görünümünün metinleri. `{ad}` yer tutucuları değerlerle doldurulur. */
export interface AdminProductCopy {
  readonly kpis: {
    readonly wau: string;
    readonly d7: string;
    readonly d30: string;
    readonly checkout: string;
    readonly failed: string;
    readonly notes: string;
    readonly noteTime: string;
    readonly onDevice: string;
  };
  /** Özet ölçülerinin tanım ipuçları. */
  readonly kpiHints: {
    readonly wau: string;
    readonly d7: string;
    readonly d30: string;
    readonly checkout: string;
    readonly failed: string;
    readonly notes: string;
    readonly noteTime: string;
    readonly onDevice: string;
  };
  /** Özet ölçülerinin kısa alt satırları. */
  readonly kpiSubs: {
    /** `{mau}`, `{ratio}`. */
    readonly wau: string;
    /** `{retained}`, `{eligible}`. */
    readonly retention: string;
    /** `{abandoned}`, `{started}`, `{recent}`, `{recentStarted}`. */
    readonly checkout: string;
    /** `{failed}`, `{meetings}`. */
    readonly failed: string;
    /** `{noted}`, `{ended}`. */
    readonly notes: string;
    /** `{noted}`. */
    readonly noteTime: string;
    /** `{onDevice}`, `{meetings}`. */
    readonly onDevice: string;
  };
  readonly tables: {
    readonly cohorts: string;
    readonly weeks: string;
    readonly steps: string;
    readonly trials: string;
    readonly failures: string;
    readonly outcomes: string;
    readonly costs: string;
    readonly payers: string;
    readonly crashes: string;
  };
  readonly columns: {
    readonly signupWeek: string;
    readonly signups: string;
    /** `{week}`. */
    readonly week: string;
    readonly calendarWeek: string;
    readonly activeUsers: string;
    readonly meetings: string;
    readonly perActiveUser: string;
    readonly step: string;
    readonly accounts: string;
    readonly median: string;
    readonly outcome: string;
    readonly share: string;
    readonly lastError: string;
    readonly measure: string;
    readonly month: string;
    readonly hours: string;
    readonly llm: string;
    readonly elevenLabs: string;
    readonly deepgram: string;
    readonly perMeeting: string;
    readonly perHour: string;
    readonly accountLlm: string;
    readonly payers: string;
    readonly costPerPayer: string;
    readonly listRevenue: string;
    readonly grossMargin: string;
    readonly version: string;
    readonly crashes: string;
    readonly recent: string;
    readonly latest: string;
  };
  readonly notes: {
    readonly cohorts: string;
    /** `{days}`. */
    readonly steps: string;
    readonly trials: string;
    /** `{baseline}`. */
    readonly outcomes: string;
    /** `{input}`, `{output}`, `{elevenLabs}`, `{deepgram}`. */
    readonly costs: string;
    /** `{monthly}`, `{yearly}`. */
    readonly payers: string;
    readonly crashes: string;
  };
  readonly empty: { readonly failures: string; readonly crashes: string };
  readonly steps: { readonly signupToFirstMeeting: string; readonly firstMeetingToFirstNote: string; readonly signupToFirstNote: string };
  readonly trialOutcomes: { readonly converted: string; readonly exhausted: string; readonly expired: string; readonly active: string; readonly started: string };
  readonly outcomes: {
    readonly ended: string;
    readonly noted: string;
    readonly superseded: string;
    readonly unended: string;
    readonly open: string;
    readonly budget: string;
    readonly deepgram: string;
    readonly reconnecting: string;
    readonly reconnects: string;
    readonly onDevice: string;
  };
  readonly charts: { readonly refusals: string; readonly providerErrors: string; readonly serverErrors: string; readonly spend: string };
  readonly legendTrial: string;
  readonly legendPaid: string;
  /** `{month}`: bu ayın kısmi satırı. */
  readonly partialMonth: string;
  readonly unknownVersion: string;
  /** Süre birimleri: `{value}`. */
  readonly durations: { readonly seconds: string; readonly minutes: string; readonly hours: string; readonly days: string };
}

/** Ürün görünümünün metinleri. */
export const adminProductCopy: AdminProductCopy = {
  kpis: {
    wau: "Weekly active",
    d7: "D7 retention",
    d30: "D30 retention",
    checkout: "Checkout abandoned",
    failed: "Meetings with errors",
    notes: "Notes finished",
    noteTime: "Median time to note",
    onDevice: "Live text on the Mac",
  },
  kpiHints: {
    wau: "Accounts that started a meeting in the last 7 days. WAU/MAU compares them with the last 30 days.",
    d7: "Share of sign-ups that started a meeting on days 7–13 after signing up.",
    d30: "Share of sign-ups that started a meeting on days 30–36 after signing up.",
    checkout: "Accounts that opened Stripe Checkout and never paid.",
    failed: "Meetings started in the last 30 days with at least one failed request.",
    notes: "Ended meetings in the last 30 days that got a finished note.",
    noteTime: "Median time from a meeting's end to its first finished note.",
    onDevice: "Meetings that got no Deepgram token, so live text ran on the Mac.",
  },
  kpiSubs: {
    wau: "{mau} in 30 days · WAU/MAU {ratio}",
    retention: "{retained} of {eligible} sign-ups",
    checkout: "{abandoned} of {started} · 30 days {recent} of {recentStarted}",
    failed: "{failed} of {meetings} meetings",
    notes: "{noted} of {ended} ended meetings",
    noteTime: "{noted} notes",
    onDevice: "{onDevice} of {meetings} meetings",
  },
  tables: {
    cohorts: "Sign-up cohorts",
    weeks: "Active accounts by week",
    steps: "Time to first steps",
    trials: "Trial outcomes",
    failures: "Errors by last error code",
    outcomes: "How meetings ended",
    costs: "Cost per meeting",
    payers: "Paying subscribers: cost and gross margin",
    crashes: "Crash reports by version",
  },
  columns: {
    signupWeek: "Sign-up week",
    signups: "Sign-ups",
    week: "Week {week}",
    calendarWeek: "Week of",
    activeUsers: "Active",
    meetings: "Meetings",
    perActiveUser: "Per active",
    step: "Step",
    accounts: "Accounts",
    median: "Median",
    outcome: "Outcome",
    share: "Share",
    lastError: "Last error",
    measure: "Measure",
    month: "Month",
    hours: "Hours",
    llm: "AI",
    elevenLabs: "ElevenLabs",
    deepgram: "Deepgram",
    perMeeting: "Per meeting",
    perHour: "Per hour",
    accountLlm: "AI outside meetings",
    payers: "Paying",
    costPerPayer: "Cost per payer",
    listRevenue: "List revenue",
    grossMargin: "Gross margin",
    version: "Version",
    crashes: "Stored",
    recent: "Last 30 days",
    latest: "Latest",
  },
  notes: {
    cohorts:
      "Accounts that started at least one meeting in their n-th week after signing up (days 7n to 7n+7), with the share of the cohort. — : that week hasn't started yet for anyone in the cohort; the newest cells are still filling.",
    steps: "Accounts created in the last {days} days. First note counts only meetings since note tracking began.",
    trials: "Accounts that started a trial; each is counted once, in this order. Deleted accounts are not counted.",
    outcomes:
      "Shares are of all meetings, except notes (of ended meetings) and reconnects (of Deepgram meetings). A Deepgram meeting normally takes {baseline} tokens (a check plus one per stream); more means it reconnected.",
    costs:
      "Lower-bound estimates: AI {input} / {output} per million input/output tokens (long-prompt rate ignored, tokens outside meetings split off by share), ElevenLabs {elevenLabs} per audio hour (keyterm surcharge ignored), Deepgram {deepgram} per stream minute. Totals per meeting cover every meeting started that month, trial or paid.",
    payers:
      "Approximate, list price. Today's paying subscribers (billed, access running, not in a free invite month), their usage cost in each month, against one month of list price ({monthly} a month, {yearly} a year counted as 1/12). No tax, discounts or Stripe fees.",
    crashes: "Crash reports are kept for 180 days. Only reports users chose to send.",
  },
  empty: { failures: "No meeting errors in the last 30 days.", crashes: "No crash reports stored." },
  steps: {
    signupToFirstMeeting: "Sign-up → first meeting",
    firstMeetingToFirstNote: "First meeting → first note",
    signupToFirstNote: "Sign-up → first note",
  },
  trialOutcomes: { converted: "Subscribed", exhausted: "Used all trial meetings", expired: "Trial period ran out", active: "Still in trial", started: "Started a trial" },
  outcomes: {
    ended: "Ended (or replaced)",
    noted: "Got a finished note",
    superseded: "Replaced by a new meeting",
    unended: "Never ended (timed out)",
    open: "Live now",
    budget: "AI budget ran out",
    deepgram: "Used Deepgram live text",
    reconnecting: "Deepgram reconnected",
    reconnects: "Extra Deepgram connections",
    onDevice: "Live text on the Mac",
  },
  charts: { refusals: "Refused requests", providerErrors: "Service failures", serverErrors: "Server errors (5xx)", spend: "Daily spend estimate" },
  legendTrial: "Trial",
  legendPaid: "Everything else",
  partialMonth: "{month} (so far)",
  unknownVersion: "Unknown version",
  durations: { seconds: "{value} s", minutes: "{value} min", hours: "{value} h", days: "{value} days" },
};
