// Sitenin sayfa metinleri (yasal metinler hariç: onlar src/pages/privacy.astro ve terms.astro içinde). Ürün adı ve
// işletme bilgisi tek yerden gelir (config.ts `productName`, legal/operator.ts).
import { cardStatementDescriptor, productName } from "./config";
import type { IconName } from "./lib/icons";
import { operator } from "./legal/operator";

/** Başlık ve açıklama (arama motorları ve paylaşım kartı). */
export interface PageMeta {
  readonly title: string;
  readonly description: string;
}

/** Soru ve yanıt. */
export interface Faq {
  readonly question: string;
  readonly answer: string;
}

/** Başlıklı kısa metin. */
export interface TitledText {
  readonly title: string;
  readonly text: string;
}

/** Simgeli, başlıklı kısa metin (kartlar). */
export interface IconText extends TitledText {
  readonly icon: IconName;
}

/** Simgeli liste öğesi. */
export interface IconItem {
  readonly icon: IconName;
  readonly text: string;
}

/** Ortak metinler: üst çubuk, alt bilgi, fiyat. */
export interface CommonCopy {
  readonly skipLink: string;
  readonly homeLabel: string;
  readonly navLabel: string;
  readonly nav: {
    readonly features: string;
    readonly pricing: string;
    readonly download: string;
    readonly signIn: string;
    readonly account: string;
    readonly contact: string;
    readonly privacy: string;
    readonly terms: string;
  };
  readonly downloadCta: string;
  readonly headerDownload: string;
  /** Tema düğmesinin erişilebilir adı (basılıysa koyu tema). */
  readonly darkMode: string;
  readonly price: string;
  readonly perMonth: string;
  readonly offer: string;
  readonly requirementsShort: string;
  readonly taxNote: string;
  readonly footer: {
    readonly tagline: string;
    readonly product: string;
    readonly account: string;
    readonly company: string;
    readonly fontLicense: string;
    readonly copyright: string;
  };
  readonly lastUpdated: string;
  readonly contents: string;
}

/** Ana sayfadaki canlı ürün gösterimi (kayıt, canlı metin, kendiliğinden yazılan not). */
export interface DemoCopy {
  readonly label: string;
  readonly listening: string;
  readonly writing: string;
  readonly done: string;
  /** Sayaç dakikası; saniye CSS ile sayılır (global değil, HeroDemo). */
  readonly timerMinutes: string;
  readonly transcriptTitle: string;
  /** Not yazılmadan önce not kartında görünen satır. */
  readonly notePending: string;
  readonly transcript: readonly { readonly speaker: string; readonly text: string; readonly translation: string | null }[];
  readonly meetingTitle: string;
  readonly meetingMeta: string;
  readonly tasksTitle: string;
  readonly tasks: readonly string[];
  readonly decisionsTitle: string;
  readonly decision: string;
}

/** Ana sayfa. */
export interface HomeCopy {
  readonly meta: PageMeta;
  readonly eyebrow: string;
  readonly title: string;
  readonly lead: string;
  readonly secondaryCta: string;
  readonly demo: DemoCopy;
  readonly library: {
    readonly label: string;
    readonly meetings: readonly { readonly title: string; readonly meta: string }[];
  };
  readonly featuresEyebrow: string;
  readonly featuresTitle: string;
  readonly featuresLead: string;
  readonly features: {
    readonly live: TitledText & { readonly original: string; readonly translation: string };
    readonly tasks: TitledText & { readonly sample: readonly string[] };
    readonly missed: TitledText & { readonly button: string; readonly answer: string };
    readonly ask: TitledText & { readonly question: string; readonly source: string };
    readonly integrations: TitledText;
    readonly privacy: TitledText & { readonly badge: string };
  };
  readonly stepsTitle: string;
  readonly steps: readonly TitledText[];
  readonly pricingTitle: string;
  readonly pricingLead: string;
  readonly pricingCta: string;
  readonly faqTitle: string;
  readonly faq: readonly Faq[];
  readonly finalTitle: string;
  readonly finalLead: string;
}

/** Fiyat sayfası. */
export interface PricingCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly lead: string;
  readonly planName: string;
  readonly planTagline: string;
  readonly included: readonly IconItem[];
  readonly startFree: string;
  readonly subscribe: string;
  readonly limitsTitle: string;
  readonly limits: readonly IconText[];
  readonly taxTitle: string;
  readonly taxText: string;
  readonly faqTitle: string;
  readonly faq: readonly Faq[];
}

/** İndirme sayfası. */
export interface DownloadCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly lead: string;
  /** Sürüm etiketi ("Version" + numara). */
  readonly versionLabel: string;
  readonly buttonNote: string;
  readonly requirementsTitle: string;
  readonly requirements: readonly IconText[];
  readonly installTitle: string;
  readonly installSteps: readonly TitledText[];
  readonly updatesTitle: string;
  readonly updatesText: string;
  readonly helpTitle: string;
  readonly helpText: string;
  readonly helpCta: string;
}

/** Giriş sayfası. */
export interface SignInCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly lead: string;
  readonly apple: string;
  /** "… the {Terms} and the {Privacy policy}." cümlesinin bağlantılar dışındaki parçaları. */
  readonly legalBefore: string;
  readonly legalBetween: string;
  readonly noScript: string;
  /** Mac uygulamasından açıldığında. */
  readonly appTitle: string;
  readonly appLead: string;
  readonly appReturning: string;
  readonly appReturningHelp: string;
  readonly appOpen: string;
}

/** İletişim sayfası. */
export interface ContactCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly lead: string;
  readonly emailLabel: string;
  readonly emailPlaceholder: string;
  readonly messageLabel: string;
  readonly messagePlaceholder: string;
  readonly turnstileLabel: string;
  readonly submit: string;
  readonly privacyNote: string;
  readonly sentTitle: string;
  readonly sentText: string;
  readonly sendAnother: string;
  readonly directTitle: string;
  readonly directText: string;
  readonly noScript: string;
}

/** Hesap sayfası. */
export interface AccountCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly loading: string;
  readonly paymentDone: string;
  readonly planLabel: string;
  readonly trialLabel: string;
  readonly hoursLabel: string;
  readonly hoursNote: string;
  readonly renewalLabel: string;
  readonly subscribe: string;
  readonly subscribeNote: string;
  readonly manage: string;
  readonly signOut: string;
  readonly dangerTitle: string;
  readonly dangerText: string;
  readonly deleteButton: string;
  readonly dialogTitle: string;
  readonly dialogText: string;
  readonly confirmWord: string;
  readonly confirmLabel: string;
  readonly cancel: string;
  readonly confirmDelete: string;
  readonly deletedTitle: string;
  readonly deletedText: string;
  readonly deletedRedirect: string;
  readonly backHome: string;
  readonly noScript: string;
}

/** Yönetim panelinin durgun metinleri (değerlere bağlı olanlar client/copy.ts'te). */
export interface AdminCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly refresh: string;
  readonly loading: string;
  readonly signedOutTitle: string;
  readonly signedOutText: string;
  readonly forbiddenTitle: string;
  readonly forbiddenText: string;
  readonly kpis: {
    readonly downloads: string;
    readonly users: string;
    readonly trials: string;
    readonly subscribers: string;
    readonly mrr: string;
    readonly spend: string;
    readonly hours: string;
    readonly tokens: string;
  };
  readonly chartsTitle: string;
  readonly charts: {
    readonly downloads: string;
    readonly users: string;
    readonly meetings: string;
    readonly spend: string;
  };
  readonly legendTrial: string;
  readonly legendSubscription: string;
  readonly inboxTitle: string;
  readonly tabs: { readonly feedback: string; readonly crash: string; readonly contact: string };
  readonly statusOpen: string;
  readonly statusDone: string;
  readonly empty: string;
  readonly loadMore: string;
  readonly detailEmpty: string;
  readonly fields: {
    readonly received: string;
    readonly email: string;
    readonly user: string;
    readonly app: string;
    readonly os: string;
  };
  readonly messageTitle: string;
  readonly payloadTitle: string;
  readonly markDone: string;
  readonly reopen: string;
  readonly noScript: string;
}

/** 404 sayfası. */
export interface NotFoundCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly text: string;
  readonly home: string;
}

/** Sitenin tüm metinleri. */
export interface Copy {
  readonly common: CommonCopy;
  readonly home: HomeCopy;
  readonly pricing: PricingCopy;
  readonly download: DownloadCopy;
  readonly signIn: SignInCopy;
  readonly contact: ContactCopy;
  readonly account: AccountCopy;
  readonly admin: AdminCopy;
  readonly notFound: NotFoundCopy;
  readonly privacyMeta: PageMeta;
  readonly termsMeta: PageMeta;
}

const tagline: string = "Listens to your meetings, writes your notes.";

/** Sitenin metinleri. */
export const copy: Copy = {
  common: {
    skipLink: "Skip to content",
    homeLabel: `${productName} home`,
    navLabel: "Main menu",
    nav: {
      features: "Features",
      pricing: "Pricing",
      download: "Download",
      signIn: "Sign in",
      account: "Account",
      contact: "Contact",
      privacy: "Privacy policy",
      terms: "Terms of service",
    },
    downloadCta: "Download for Mac",
    headerDownload: "Download",
    darkMode: "Dark mode",
    price: "$5.99",
    perMonth: "/ month",
    offer: "3 meetings free, then $5.99 a month",
    requirementsShort: "macOS 26 · Apple silicon",
    taxNote: "Plus applicable taxes, shown at checkout.",
    footer: {
      tagline,
      product: "Product",
      account: "Account",
      company: "Company",
      fontLicense: "Inter font licence",
      copyright: `© 2026 ${operator.name}`,
    },
    lastUpdated: "Last updated",
    contents: "On this page",
  },
  home: {
    meta: {
      title: `${productName} — ${tagline}`,
      description:
        "A meeting notepad for Mac: a live transcript, optional live translation, and a note that starts with your tasks the moment the meeting ends. 3 meetings free.",
    },
    eyebrow: "A meeting notepad for Mac",
    title: tagline,
    lead: `${productName} transcribes the conversation live, translates it if you like, and has your note ready when the meeting ends: your tasks first, then decisions and a summary. No bot joins the call, and there's nothing to set up.`,
    secondaryCta: "See pricing",
    demo: {
      label: `${productName} recording a meeting and writing the note`,
      listening: "Listening",
      writing: "Writing your note",
      done: "Note ready",
      timerMinutes: "42",
      transcriptTitle: "Live transcript",
      notePending: "Your note appears here when the meeting ends.",
      transcript: [
        { speaker: "Elif", text: "Let's open the beta on 14 November.", translation: null },
        { speaker: "You", text: "Works for me. I'll write the release notes by Friday.", translation: null },
        { speaker: "Mikko", text: "Voitko lähettää hinnaston Ayşelle?", translation: "Could you send Ayşe the pricing table?" },
      ],
      meetingTitle: "Product weekly",
      meetingMeta: "Today · 42 min · 4 people",
      tasksTitle: "Your tasks",
      tasks: ["Write the beta release notes by Friday", "Send Ayşe the pricing table", "Set up Wednesday's call with support"],
      decisionsTitle: "Decisions",
      decision: "The beta opens on 14 November.",
    },
    library: {
      label: "Recent meetings",
      meetings: [
        { title: "Client call · Nordia", meta: "Yesterday · 3 tasks" },
        { title: "Design review", meta: "Monday · 5 tasks" },
        { title: "One-on-one: Elif", meta: "Last week · 2 tasks" },
        { title: "Investor update", meta: "October · 4 tasks" },
      ],
    },
    featuresEyebrow: "Features",
    featuresTitle: "Stay in the conversation. It keeps the record.",
    featuresLead: "By your side during the meeting, in your hands after it: what to do, what was decided, and a searchable record of everything.",
    features: {
      live: {
        title: "Live transcript and translation",
        text: "Every sentence is on screen within seconds. If the meeting is in another language, a translation into yours runs alongside. The live transcript is produced on your Mac.",
        original: "Betayı on dördünde açmalıyız.",
        translation: "We should open the beta on the fourteenth.",
      },
      tasks: {
        title: "Tasks first",
        text: "When the meeting ends, the note is ready. Your tasks on top, with who does what by when; then decisions, a summary and a glossary. Tick tasks off or send them to Reminders.",
        sample: ["Write release notes · Friday", "Send pricing table · Today"],
      },
      missed: {
        title: "“What did I miss?”",
        text: "Drifted off for a moment? One click brings a short summary of the last few minutes, so you catch up without interrupting.",
        button: "What did I miss?",
        answer: "In the last 5 minutes: the beta moved to 14 November, and the release notes are yours.",
      },
      ask: {
        title: "Ask your meetings",
        text: "Ask questions across all your notes and transcripts. Answers come with links to the meetings they came from.",
        question: "What did we decide about the budget?",
        source: "Sources: Investor update, Product weekly",
      },
      integrations: {
        title: "Integrations",
        text: "Send notes and tasks where they belong: Notion, Slack, Microsoft Teams, Discord and Zoom; tasks to Linear, Jira or Reminders. Connected with their official sign-ins.",
      },
      privacy: {
        title: "Privacy",
        text: "Audio is processed only to be transcribed and is not stored on our servers. Your notes and recordings stay on your Mac. No bot joins the call.",
        badge: "Audio not stored",
      },
    },
    stepsTitle: "In three steps",
    steps: [
      { title: "Download and sign in", text: `Download the app, drag ${productName} to Applications and sign in with Apple or Google.` },
      { title: "Start listening", text: "One click as the meeting starts. Zoom, Meet, Teams or in person; your voice and the other side's." },
      { title: "Get your note", text: "The meeting ends, the note is ready: tasks first, then decisions and a summary. Share it or send it on." },
    ],
    pricingTitle: "One plan. Simple pricing.",
    pricingLead: "Your first 3 meetings are free, no card needed. Then $5.99 a month; cancel anytime.",
    pricingCta: "Pricing details",
    faqTitle: "Questions",
    faq: [
      {
        question: "How does the free trial work?",
        answer: "Your first 3 meetings are free and no card is needed. Trial meetings can be up to 90 minutes long. After that you continue with the $5.99 monthly subscription.",
      },
      {
        question: "Does a bot join my meetings?",
        answer: `No. ${productName} listens to your Mac's audio and microphone; participants never see a bot. It reminds you to tell participants before you start recording.`,
      },
      {
        question: "Where does my audio go?",
        answer:
          "The live transcript is produced on your Mac. When the meeting ends, the audio is passed through our server to ElevenLabs to separate speakers and produce the final transcript; for notes and translation the text goes to Anthropic's Claude model. Our server does not store audio or text; it only counts the duration.",
      },
      {
        question: "Where are my notes stored?",
        answer: "On your Mac. Notes, transcripts and recordings live in the app's folder on your Mac; our servers never keep a copy. You can export, share or delete them in the app.",
      },
      {
        question: "Which languages are supported?",
        answer: "English, Finnish, Turkish and dozens more. You choose the language of your notes and translations.",
      },
      {
        question: "How do I cancel?",
        answer: "With “Manage subscription” on your account page, or at link.com. After cancelling you keep access until the end of the period you paid for.",
      },
    ],
    finalTitle: "Let it write the note for your next meeting.",
    finalLead: "3 meetings free. Set up in a minute.",
  },
  pricing: {
    meta: {
      title: `Pricing — ${productName}`,
      description: "One plan: $5.99 a month. First 3 meetings free, up to 10 hours a month, up to 4 hours per meeting, cancel anytime.",
    },
    title: "One plan. Simple pricing.",
    lead: "Try 3 meetings for free. If you like it, continue for $5.99 a month.",
    planName: productName,
    planTagline: "Everything from live transcript to tasks.",
    included: [
      { icon: "gift", text: "First 3 meetings free, no card needed" },
      { icon: "calendar", text: "Up to 10 hours of meetings a month (fair use)" },
      { icon: "timer", text: "Up to 4 hours per meeting" },
      { icon: "waveform", text: "Live transcript, live translation, “What did I miss?” and Ask" },
      { icon: "note", text: "Post-meeting note: tasks, decisions, summary and speaker separation" },
      { icon: "plug", text: "Send to Notion, Slack, Linear, Jira and more" },
      { icon: "check-circle", text: "Cancel anytime" },
    ],
    startFree: "Start free",
    subscribe: "Subscribe",
    limitsTitle: "The limits, plainly",
    limits: [
      { icon: "gift", title: "Trial", text: "3 meetings, each up to 90 minutes. Opening a new account does not reset the trial." },
      {
        icon: "calendar",
        title: "10 hours a month",
        text: "A fair-use limit that resets on the first day of each month (UTC). At the limit you can't start new meetings until the month resets; the app tells you clearly.",
      },
      { icon: "timer", title: "4 hours per meeting", text: "Enough for long workshops and lectures; longer meetings close at 4 hours." },
      { icon: "card", title: "Cancelling", text: "Cancel in a click from your account page or at link.com. You keep access until the end of the paid period." },
    ],
    taxTitle: "Payments and taxes",
    taxText:
      `Checkout is hosted by Stripe, and your purchase is sold through Link, Stripe's payment service, as the merchant of record. Link calculates, collects and remits sales tax, VAT or GST for your location and shows it at checkout before you pay; you may see the price in your local currency. Receipts come from Link, and your card statement shows ${cardStatementDescriptor}. Your card details stay with Stripe and Link and never reach us. Purchases aren't available in some countries where Stripe can't sell, such as China, Cuba, Iran, North Korea, Russia and Syria.`,
    faqTitle: "Questions",
    faq: [
      {
        question: "What happens when the trial ends?",
        answer: "The app lets you know. You can't start new meetings until you subscribe; your existing notes and recordings stay on your Mac and remain readable.",
      },
      {
        question: "What if a payment fails?",
        answer: "The payment is retried over a few days. You keep access meanwhile and can update your card under “Manage subscription” or at link.com.",
      },
      {
        question: "Can I get a refund?",
        answer:
          "Refunds are handled by Link, which sells the subscription on our behalf. It applies statutory cooling-off rights where they apply — such as the 14-day withdrawal right for consumers in the EU — and may refund within 60 days in other cases. Contact Link support at support.link.com, or write to us and we'll help.",
      },
      {
        question: "Who will I see on my receipt and card statement?",
        answer: `Receipts and some subscription emails come from Link, Stripe's payment service. Your card statement shows ${cardStatementDescriptor}.`,
      },
    ],
  },
  download: {
    meta: {
      title: `Download — ${productName}`,
      description: `Download ${productName} for your Mac: macOS 26 and Apple silicon. First 3 meetings free.`,
    },
    title: `Download ${productName}`,
    lead: "For Mac. Your first 3 meetings are free, no card needed.",
    versionLabel: "Version",
    buttonNote: "Signed with an Apple Developer ID and notarized by Apple.",
    requirementsTitle: "System requirements",
    requirements: [
      { icon: "laptop", title: "macOS 26", text: "or later" },
      { icon: "chip", title: "Apple silicon", text: "M1 or later" },
      { icon: "globe", title: "Internet", text: "for notes, translation and speaker separation" },
      { icon: "disk", title: "~1 GB free space", text: "for the on-device speech model" },
    ],
    installTitle: "Installing on your Mac",
    installSteps: [
      { title: "Open the disk image", text: `Double-click the ${productName} disk image (.dmg) you downloaded.` },
      { title: "Drag to Applications", text: `Drag the ${productName} icon into the Applications folder, then eject the disk image.` },
      { title: "Open it", text: `Open ${productName} from Applications. If macOS asks whether to open an app downloaded from the internet, choose “Open”.` },
      { title: "Grant permissions", text: "The setup page asks for microphone and system-audio permissions. You can change them later in System Settings › Privacy & Security." },
      { title: "Sign in", text: "Sign in with Apple or Google and start your first meeting. The first 3 are free." },
    ],
    updatesTitle: "Updates",
    updatesText: "New versions arrive inside the app and are installed with your approval.",
    helpTitle: "Need a hand?",
    helpText: "Questions about installing, your account or your subscription? Send us a message and we'll get back to you by email.",
    helpCta: "Contact us",
  },
  signIn: {
    meta: { title: `Sign in — ${productName}`, description: `Sign in to your ${productName} account with Apple or Google.` },
    title: "Sign in",
    lead: "To manage your account and subscription. You use the same account in the Mac app.",
    apple: "Continue with Apple",
    legalBefore: "By continuing, you agree to the",
    legalBetween: "and confirm you have read the",
    noScript: "Signing in needs JavaScript.",
    appTitle: `Sign in to the ${productName} app`,
    appLead: "Continue with Google. When you're done, the app opens and finishes signing you in.",
    appReturning: "Returning to the app…",
    appReturningHelp: `If ${productName} didn't open, use the button below.`,
    appOpen: `Open ${productName}`,
  },
  contact: {
    meta: { title: `Contact — ${productName}`, description: `Questions about ${productName}, your account or your subscription? Send us a message.` },
    title: "Contact us",
    lead: "Questions about the app, your account or your subscription? Write to us and we'll reply by email.",
    emailLabel: "Your email",
    emailPlaceholder: "name@example.com",
    messageLabel: "Message",
    messagePlaceholder: "How can we help?",
    turnstileLabel: "Security check",
    submit: "Send message",
    privacyNote: "We use your email and message only to answer you, and delete them after 180 days.",
    sentTitle: "Message sent",
    sentText: "Thank you for writing. We'll reply to the address you gave as soon as we can.",
    sendAnother: "Send another message",
    directTitle: "Prefer email?",
    directText: "You can also write to us directly:",
    noScript: "The contact form needs JavaScript. You can also email us directly.",
  },
  account: {
    meta: { title: `Account — ${productName}`, description: `Your ${productName} account: plan, trial, monthly usage and subscription.` },
    title: "Your account",
    loading: "Loading your account…",
    paymentDone: "Payment received, thank you. Your subscription will show up here within a few seconds.",
    planLabel: "Plan",
    trialLabel: "Free trial",
    hoursLabel: "Usage this month",
    hoursNote: "Resets on the first day of each month (UTC).",
    renewalLabel: "Subscription",
    subscribe: "Subscribe",
    subscribeNote: "$5.99 a month plus applicable taxes, shown at checkout. Sold through Link, Stripe's payment service.",
    manage: "Manage subscription",
    signOut: "Sign out",
    dangerTitle: "Delete account",
    dangerText:
      "Your account, sessions, device registrations and usage history are permanently deleted, and any unfinished subscription is cancelled immediately. Your notes and recordings stay on your Mac. Receipts and payment records are kept by Stripe and Link as required by law. To prevent free-trial abuse, a pseudonymous record of how many free-trial meetings your sign-in has used is kept for up to 24 months, so signing in again with the same account continues the trial instead of restarting it.",
    deleteButton: "Delete account",
    dialogTitle: "Delete your account?",
    dialogText: "This can't be undone. If you have a subscription, it is cancelled immediately and ends with your account; the remaining time is not refunded automatically.",
    confirmWord: "DELETE",
    confirmLabel: "Type DELETE to confirm",
    cancel: "Cancel",
    confirmDelete: "Permanently delete my account",
    deletedTitle: "Your account was deleted",
    deletedText: "Your account data on our server is gone, apart from the pseudonymous free-trial record described in the privacy policy. The notes and recordings on your Mac are still there.",
    deletedRedirect: "Taking you to the home page…",
    backHome: "Back to the home page",
    noScript: "The account page needs JavaScript.",
  },
  admin: {
    meta: { title: `Dashboard — ${productName}`, description: "Operator dashboard." },
    title: "Dashboard",
    refresh: "Refresh",
    loading: "Loading the dashboard…",
    signedOutTitle: "Sign in first",
    signedOutText: "The dashboard needs an admin session in this tab. Sign in, then open the dashboard again.",
    forbiddenTitle: "Not authorized",
    forbiddenText: "This account isn't on the server's admin list. To grant access, add this identity to the allowlist:",
    kpis: {
      downloads: "Downloads",
      users: "Users",
      trials: "Trials",
      subscribers: "Subscribers",
      mrr: "MRR",
      spend: "AI spend today",
      hours: "Meeting hours this month",
      tokens: "Tokens this month",
    },
    chartsTitle: "Last 30 days",
    charts: {
      downloads: "Downloads per day",
      users: "New users per day",
      meetings: "Meetings per day",
      spend: "AI spend per day",
    },
    legendTrial: "Trial",
    legendSubscription: "Subscription",
    inboxTitle: "Inbox",
    tabs: { feedback: "Feedback", crash: "Crashes", contact: "Contact" },
    statusOpen: "Open",
    statusDone: "Done",
    empty: "Nothing here.",
    loadMore: "Load more",
    detailEmpty: "Select a report to read it.",
    fields: { received: "Received", email: "Email", user: "User", app: "App version", os: "OS" },
    messageTitle: "Message",
    payloadTitle: "Crash report",
    markDone: "Mark done",
    reopen: "Reopen",
    noScript: "The dashboard needs JavaScript.",
  },
  notFound: {
    meta: { title: `Page not found — ${productName}`, description: "The address may be mistyped, or the page has moved." },
    title: "This page doesn't exist.",
    text: "The address may be mistyped, or the page has moved.",
    home: "Back to the home page",
  },
  privacyMeta: {
    title: `Privacy policy — ${productName}`,
    description: `What data ${productName} processes and why, who it is shared with, how long it is kept and how to use your rights.`,
  },
  termsMeta: { title: `Terms of service — ${productName}`, description: `The terms for using ${productName} and its subscription.` },
};
