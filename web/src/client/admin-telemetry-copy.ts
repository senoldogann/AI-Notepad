// Yönetim panelinin telemetri verisinin metinleri (İngilizce; yalnızca yönetici görür) ve sunucunun telemetri
// listeleri (yapay zekâ çağrısının amacı, istemci olay türleri, özellik adları, entegrasyon türleri, dışa aktarma
// biçimleri). Listeler sunucuyla birebir aynıdır (`server/src/llm/purpose.ts`, `server/src/telemetry.ts`). Sayfa
// (admin.astro) ve betik (admin-telemetry.ts) aynı nesneyi kullanır; DOM'a dokunmaz.

/** Yapay zekâ çağrısının amacı (`x-llm-purpose`); `unattributed` başlığı göndermeyen eski uygulama sürümleridir. */
export const llmPurposes = [
  "live_translation",
  "missed_summary",
  "live_question",
  "note",
  "note_chunk",
  "note_overview",
  "speaker_review",
  "note_edit",
  "shared_note_translation",
  "ask_search_terms",
  "ask_answer",
  "task_agent",
  "connection_test",
  "unattributed",
] as const;
export type LlmPurpose = (typeof llmPurposes)[number];

/** Sayılan istemci olayları. */
export const countEventKinds = ["deepgram_socket_drop", "deepgram_reconnect", "final_pass_give_up", "note_generation_failed", "recording_overrun"] as const;
export type CountEventKind = (typeof countEventKinds)[number];

/** Süresi ölçülen istemci olayları. */
export const durationEventKinds = ["final_pass_duration", "note_generation_duration"] as const;
export type DurationEventKind = (typeof durationEventKinds)[number];

/** Günlük özellik raporundaki özellik adları (`report`: raporu gönderen kullanıcı-günü, oranların paydası). */
export const featureNames = ["report", "live_translation", "translation_language", "ask", "integration", "export", "mcp", "on_device_live"] as const;
export type FeatureName = (typeof featureNames)[number];

/** Değeri olmayan (evet/hayır) özellikler; tabloda bu sırayla görünür. */
export const flagFeatures = ["live_translation", "ask", "mcp", "on_device_live"] as const;
export type FlagFeature = (typeof flagFeatures)[number];

/** Telemetri görünümünün metinleri. `{ad}` yer tutucuları değerlerle doldurulur. */
export interface AdminTelemetryCopy {
  /** `{days}`. */
  readonly windowNote: string;
  readonly versionsTitle: string;
  /** `{users}`, `{days}`. */
  readonly activeUsers: string;
  readonly appVersionsTitle: string;
  readonly osVersionsTitle: string;
  readonly versionColumns: { readonly version: string; readonly users: string; readonly share: string };
  readonly noVersions: string;
  readonly purposesTitle: string;
  readonly purposeColumns: { readonly purpose: string; readonly calls: string; readonly input: string; readonly output: string; readonly share: string };
  readonly noPurposes: string;
  readonly purposesDailyTitle: string;
  readonly dailyTokenColumns: { readonly day: string; readonly calls: string; readonly tokens: string; readonly trend: string };
  readonly purposes: Readonly<Record<LlmPurpose, string>>;
  readonly reliabilityTitle: string;
  readonly reliabilityColumns: { readonly event: string; readonly total: string; readonly versions: string };
  readonly noEvents: string;
  readonly reliabilityDailyTitle: string;
  readonly dayColumn: string;
  readonly countKinds: Readonly<Record<CountEventKind, string>>;
  /** Günlük olay tablosunun kısa sütun başlıkları. */
  readonly countKindsShort: Readonly<Record<CountEventKind, string>>;
  readonly durationKinds: Readonly<Record<DurationEventKind, string>>;
  readonly durationColumns: { readonly bucket: string; readonly runs: string; readonly share: string };
  /** `{runs}`, `{mean}`. */
  readonly durationSummary: string;
  readonly noDurations: string;
  /** `≤{value}`. */
  readonly bucketAtMost: string;
  /** `>{value}`. */
  readonly bucketOver: string;
  /** `{value}` saniye. */
  readonly seconds: string;
  /** `{value}` dakika. */
  readonly minutes: string;
  readonly featuresTitle: string;
  /** `{reports}`, `{days}`. */
  readonly featureReports: string;
  readonly featureColumns: { readonly feature: string; readonly userDays: string; readonly share: string; readonly uses: string };
  readonly noFeatures: string;
  readonly flagFeatures: Readonly<Record<FlagFeature, string>>;
  readonly languagesTitle: string;
  readonly integrationsTitle: string;
  readonly exportsTitle: string;
  readonly valueColumn: string;
  readonly integrations: Readonly<Record<string, string>>;
  readonly exports: Readonly<Record<string, string>>;
  readonly featuresNote: string;
}

/** Telemetri görünümünün metinleri. */
export const adminTelemetryCopy: AdminTelemetryCopy = {
  windowNote: "Last {days} days. Counts are daily totals that are not linked to accounts, except app and macOS versions, which are the latest values per account.",
  versionsTitle: "Version adoption",
  activeUsers: "Accounts that checked in from the Mac app in the last {days} days: {users}",
  appVersionsTitle: "App versions (active accounts)",
  osVersionsTitle: "macOS versions (active accounts)",
  versionColumns: { version: "Version", users: "Accounts", share: "Share" },
  noVersions: "No app has reported its version yet.",
  purposesTitle: "AI tokens by purpose",
  purposeColumns: { purpose: "Purpose", calls: "Calls", input: "Input tokens", output: "Output tokens", share: "Share of tokens" },
  noPurposes: "No AI calls in this window.",
  purposesDailyTitle: "AI tokens per day",
  dailyTokenColumns: { day: "Day", calls: "Calls", tokens: "Tokens", trend: "Trend" },
  purposes: {
    live_translation: "Live translation",
    missed_summary: "“What did I miss?”",
    live_question: "Question during the meeting",
    note: "Meeting note",
    note_chunk: "Long-meeting note: section",
    note_overview: "Long-meeting note: overview",
    speaker_review: "Speaker review",
    note_edit: "Note edit or rewrite",
    shared_note_translation: "Shared note translation",
    ask_search_terms: "Ask: search terms",
    ask_answer: "Ask: answer",
    task_agent: "Task tracker agent",
    connection_test: "Connection test",
    unattributed: "Older app versions (no purpose header)",
  },
  reliabilityTitle: "Client reliability",
  reliabilityColumns: { event: "Event", total: "Total", versions: "By app version" },
  noEvents: "No reliability events in this window.",
  reliabilityDailyTitle: "Reliability events per day",
  dayColumn: "Day",
  countKinds: {
    deepgram_socket_drop: "Live transcript connection drops",
    deepgram_reconnect: "Live transcript reconnects",
    final_pass_give_up: "Final transcription gave up",
    note_generation_failed: "Note generation failed",
    recording_overrun: "Recording hit the time limit",
  },
  countKindsShort: {
    deepgram_socket_drop: "Drops",
    deepgram_reconnect: "Reconnects",
    final_pass_give_up: "Final pass gave up",
    note_generation_failed: "Note failed",
    recording_overrun: "Time limit",
  },
  durationKinds: {
    final_pass_duration: "Final transcription duration",
    note_generation_duration: "Note generation duration",
  },
  durationColumns: { bucket: "Duration", runs: "Runs", share: "Share" },
  durationSummary: "{runs} runs · mean {mean}",
  noDurations: "No measurements in this window.",
  bucketAtMost: "≤{value}",
  bucketOver: ">{value}",
  seconds: "{value} s",
  minutes: "{value} min",
  featuresTitle: "Feature usage",
  featureReports: "{reports} daily reports (account-days) in the last {days} days. Shares are of these reports.",
  featureColumns: { feature: "Feature", userDays: "Account-days", share: "Share", uses: "Uses" },
  noFeatures: "No feature reports in this window.",
  flagFeatures: {
    live_translation: "Live translation",
    ask: "Ask",
    mcp: "Archive used over MCP",
    on_device_live: "Live transcript ran on the Mac",
  },
  languagesTitle: "Live translation target language",
  integrationsTitle: "Integrations by type",
  exportsTitle: "Exports by format",
  valueColumn: "Type",
  integrations: {
    slack: "Slack",
    teams: "Microsoft Teams",
    discord: "Discord",
    webhook: "Webhook",
    notion: "Notion",
    apple_notes: "Apple Notes",
    markdown_folder: "Markdown folder",
    tracker_linear: "Linear (tasks)",
    tracker_jira: "Jira (tasks)",
    tracker_notion: "Notion (tasks)",
  },
  exports: {
    pdf: "PDF",
    html: "HTML",
    markdown: "Markdown",
    docx: "Word (DOCX)",
    transcript_text: "Transcript (TXT)",
    srt: "Subtitles (SRT)",
    copy_markdown: "Copy as Markdown",
    email: "Email",
    pdf_share: "Share PDF",
    link_share: "Share link",
    audio_clip: "Audio clip",
  },
  featuresNote: "Opt-out statistics: only Mac apps with “Share anonymous usage statistics” on send these.",
};
