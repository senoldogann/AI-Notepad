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

/** Ürün gerçekleri kartı: büyük değer ve kısa açıklama. */
export interface FactCopy {
  readonly value: string;
  readonly label: string;
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
  /** Fiyatın vergiler dahil olduğu (fiyatın hemen altında). */
  readonly taxNote: string;
  /** Otomatik yenileme ve iptal (Abone ol düğmesinin yanında). */
  readonly renewalNote: string;
  /** Paylaşım kartı görselinin (public/og.png) metin karşılığı. */
  readonly ogImageAlt: string;
  readonly footer: {
    readonly tagline: string;
    readonly product: string;
    readonly account: string;
    readonly company: string;
    readonly fontLicense: string;
    readonly cookies: string;
    /** Sayfa sonundaki çekmede görünen kısa teşekkür (PullReveal.astro). */
    readonly pullThanks: string;
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
  /** Duraklat/oynat düğmesinin erişilebilir adları (oynarken, duraklatılmışken, gösterim bitmişken). */
  readonly pause: string;
  readonly play: string;
  readonly replay: string;
}

/** Ana sayfadaki uygulama ekran görüntülerinden biri: kartın altındaki etiket ve başlık, görselin metin karşılığı. */
export interface ShowcaseShot {
  /** Toplantının hangi anı (ör. "During the meeting"). */
  readonly label: string;
  readonly title: string;
  readonly alt: string;
}

/** Ana sayfa. */
export interface HomeCopy {
  readonly meta: PageMeta;
  readonly eyebrow: string;
  readonly title: string;
  readonly lead: string;
  readonly secondaryCta: string;
  /** Kahraman düğmelerinin altındaki kısa güvenceler (engel kaldıranlar). */
  readonly assurances: readonly string[];
  readonly demo: DemoCopy;
  readonly library: {
    readonly label: string;
    readonly meetings: readonly { readonly title: string; readonly meta: string }[];
  };
  /** Uygulamanın gerçek ekranları (örnek toplantılarla; bkz. scripts/make-screenshots.sh). */
  readonly showcase: {
    readonly eyebrow: string;
    readonly title: string;
    readonly lead: string;
    readonly note: ShowcaseShot;
    readonly live: ShowcaseShot;
    readonly ask: ShowcaseShot;
    readonly home: ShowcaseShot;
  };
  /** Doğrulanabilir ürün gerçekleri kartları (uydurma kullanıcı sayısı yok); her kartın küçük bir örnek görseli var. */
  readonly facts: {
    readonly label: string;
    readonly noBot: FactCopy & { readonly people: readonly string[]; readonly note: string };
    readonly live: FactCopy & { readonly status: string; readonly line: string };
    readonly languages: FactCopy & { readonly sample: readonly string[] };
    readonly tasks: FactCopy & { readonly sample: readonly string[] };
  };
  readonly featuresEyebrow: string;
  readonly featuresTitle: string;
  readonly featuresLead: string;
  readonly features: {
    readonly live: TitledText & { readonly original: string; readonly translation: string };
    readonly tasks: TitledText & { readonly sample: readonly string[] };
    readonly missed: TitledText & { readonly button: string; readonly answer: string };
    readonly ask: TitledText & { readonly question: string; readonly source: string };
    readonly followUp: TitledText & { readonly recipe: string; readonly subject: string; readonly lines: readonly string[] };
    readonly templates: TitledText & { readonly sample: readonly string[] };
  };
  /** Kayan entegrasyon şeridinin etiketi. */
  readonly marqueeLabel: string;
  /** Not ekranındaki açıklama balonları (ekran görüntüsüne göre konumlar Home'da). */
  readonly noteCallouts: {
    readonly dueDate: string;
    readonly transcript: string;
  };
  /** Entegrasyonlar: notların ve görevlerin gittiği yerler, MCP ile yapay zekâ uygulamaları, dosyalar ve takvim. */
  readonly integrations: {
    readonly eyebrow: string;
    readonly title: string;
    readonly lead: string;
    readonly notes: TitledText;
    readonly tasks: TitledText;
    readonly ai: TitledText;
    readonly files: TitledText;
    /** Claude'da toplantılar üstüne bir soru örneği (MCP). */
    readonly mcpDemo: {
      readonly label: string;
      readonly question: string;
      readonly tool: string;
      readonly answerLead: string;
      readonly answer: readonly string[];
      readonly source: string;
    };
  };
  /** Gizlilik ve güven ızgarası. */
  readonly trust: {
    readonly eyebrow: string;
    readonly title: string;
    readonly lead: string;
    readonly items: readonly TitledText[];
    readonly link: string;
  };
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
  /** Sürüm etiketi ("Version" + sunucudan okunan numara). */
  readonly versionLabel: string;
  readonly installTitle: string;
  readonly installSteps: readonly TitledText[];
  /** Sayfanın sonundaki tek satır: güncellemeler ve yardım bağlantısı. */
  readonly footnote: string;
  readonly helpCta: string;
}

/** Giriş sayfası. */
export interface SignInCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly lead: string;
  readonly apple: string;
  /** Uygulama adına girişte Google düğmesi (yönlendirmeli; sitede Google'ın kendi düğmesi çizilir). */
  readonly google: string;
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
  /** İşletme bilgisi kutusu: başlık ve işletme kimliğinin etiketi. */
  readonly companyTitle: string;
  readonly businessIdLabel: string;
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
  /** Abone ol düğmesinin yanında: fiyat (vergiler dahil), otomatik yenileme, iptal, satıcı. */
  readonly subscribeNote: string;
  readonly manage: string;
  /** Aboneliği yönet düğmesinin yanında (Link'te kart, makbuz, iptal). */
  readonly manageNote: string;
  readonly signOut: string;
  /** "Uygulamayı indir" kartı. */
  readonly appTitle: string;
  readonly appText: string;
  /** Yardım satırı. */
  readonly helpTitle: string;
  readonly helpContact: string;
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
  /** Nötr başlık ve açıklama: yönetici erişimi doğrulanmadan panelin varlığı belli olmaz. */
  readonly meta: PageMeta;
  /** Erişim doğrulanınca sekme başlığı. */
  readonly documentTitle: string;
  readonly title: string;
  readonly refresh: string;
  /** Nötr yükleme satırı. */
  readonly loading: string;
  readonly kpis: {
    readonly downloads: string;
    readonly users: string;
    readonly trials: string;
    readonly subscribers: string;
    readonly mrr: string;
    readonly spend: string;
    readonly hours: string;
    readonly tokens: string;
    readonly elevenLabs: string;
    readonly deepgram: string;
  };
  /** Özet kutusu gruplarının başlıkları. */
  readonly groups: { readonly growth: string; readonly revenue: string; readonly costs: string };
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
    offer: "3 meetings or 7 days free, then $5.99 a month, taxes included",
    requirementsShort: "macOS 26 · Apple silicon",
    taxNote: "Taxes included.",
    renewalNote: "Renews automatically every month until you cancel. Cancel anytime.",
    ogImageAlt: `The ${productName} logo and the tagline “${tagline}” on a soft pastel gradient, above a small sound wave.`,
    footer: {
      tagline,
      product: "Product",
      account: "Account",
      company: "Company",
      fontLicense: "Inter font licence",
      cookies: "Cookies",
      pullThanks: "Thanks for listening.",
      copyright: `© 2026 ${operator.name}`,
    },
    lastUpdated: "Last updated",
    contents: "On this page",
  },
  home: {
    meta: {
      title: `${productName} — ${tagline}`,
      description:
        "A meeting notepad for Mac: a live transcript, optional live translation, and a note that starts with your tasks the moment the meeting ends. 3 meetings or 7 days free.",
    },
    eyebrow: "A meeting notepad for Mac",
    title: tagline,
    lead: `${productName} transcribes the conversation live, translates it if you like, and has your note ready when the meeting ends: your tasks first, then decisions and a summary. No bot joins the call, and there's nothing to set up.`,
    secondaryCta: "See pricing",
    assurances: ["3 meetings or 7 days free", "No credit card", "No bot joins your call"],
    facts: {
      label: "At a glance",
      noBot: {
        value: "No bot",
        label: `Nothing joins your call. ${productName} listens on your Mac.`,
        people: ["E", "M", "A", "Y"],
        note: "4 people · no bots",
      },
      live: {
        value: "Live",
        label: "Transcript and translation appear while people talk.",
        status: "Listening · 23:20",
        line: "So the beta opens on the fourteenth?",
      },
      languages: {
        value: "30+",
        label: "Languages for your meetings, notes and translations.",
        sample: ["English", "Suomi", "Türkçe", "Deutsch", "Español", "日本語"],
      },
      tasks: {
        value: "Tasks first",
        label: "Every note opens with who does what, by when.",
        sample: ["Release notes · Fri", "Pricing table · Today"],
      },
    },
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
      pause: "Pause the demo",
      play: "Play the demo",
      replay: "Replay the demo",
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
    showcase: {
      eyebrow: "Inside the app",
      title: "Quiet while you talk. Organised when you're done.",
      lead: "One window for all your meetings, and a small panel that stays out of the way while you record.",
      note: {
        label: "After the meeting",
        title: "Your note, tasks first",
        alt: `The Product weekly note in the ${productName} app: a list of recent meetings on the left and, under the meeting cover and a who-spoke-when timeline, your three tasks with due dates: write the beta release notes by Friday, send Ayşe the pricing table today, set up a weekly call with support on Wednesday.`,
      },
      live: {
        label: "During the meeting",
        title: "Live transcript and translation",
        alt: `The ${productName} live panel while recording a Finnish meeting: each speaker's Finnish sentences with the English translation underneath, your own lines in English, and a “What did I miss?” button at the bottom.`,
      },
      ask: {
        label: "Any time later",
        title: "Answers with sources",
        alt: `The Ask page in ${productName}: the question “What did we decide about the budget?” answered in two bullet points with numbered citations, and a row showing 3 sources from 2 meetings.`,
      },
      home: {
        label: "Before the meeting",
        title: "One click to start",
        alt: `The ${productName} home screen: “Good morning, Alex”, a large Start listening button with options for language, your voice and live translation, shortcuts, and your open tasks from recent meetings.`,
      },
    },
    featuresEyebrow: "Features",
    featuresTitle: "Stay in the conversation. It keeps the record.",
    featuresLead: "By your side during the meeting, in your hands after it: what to do, what was decided, and a searchable record of everything.",
    features: {
      live: {
        title: "Live transcript and translation",
        text: "Every sentence is on screen within seconds. If the meeting is in another language, a translation into yours runs alongside.",
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
      followUp: {
        title: "Follow-up in one click",
        text: "Recipes turn a meeting into the next step: a follow-up email, a project plan, risks and open questions. Save your own for the questions you ask every week.",
        recipe: "Follow-up email",
        subject: "Subject: Product weekly, next steps",
        lines: ["Beta opens on 14 November.", "Alex: release notes by Friday."],
      },
      templates: {
        title: "Meeting templates",
        text: "Client calls, one-on-ones, interviews and lectures each get a note that puts the right things first. Or write your own.",
        sample: ["Client call", "One-on-one", "Interview", "Lecture", "Your own"],
      },
    },
    trust: {
      eyebrow: "Privacy",
      title: "Your meetings stay yours.",
      lead: "Built for conversations you'd rather keep private, by a small company in Finland.",
      items: [
        { title: "No bot in your call", text: "Gistsmith listens on your Mac. Nobody sees an extra participant, and you don't have to ask anyone to let it in." },
        { title: "Notes stay on your Mac", text: "Notes, transcripts and recordings live in the app on your Mac. Our servers never keep a copy." },
        { title: "Audio isn't kept by us", text: "Audio is sent only to be transcribed. Our servers don't store it, and your recordings stay on your Mac." },
        { title: "Not used to train AI", text: "Your meetings aren't used to train our providers' models. We've opted out wherever that's a setting." },
        { title: "EU company, GDPR", text: "Gistsmith is run from Finland under EU data protection law. Our account database is hosted in the EU." },
        { title: "Delete any time", text: "Delete your account from the website whenever you like; your account is removed and any subscription ends." },
      ],
      link: "Read the privacy policy",
    },
    marqueeLabel: "Works with the tools you already use",
    noteCallouts: {
      dueDate: "Owner and due date",
      transcript: "Full transcript, by speaker",
    },
    integrations: {
      eyebrow: "Integrations",
      title: "Your meetings, where your work happens.",
      lead: "Send the note where your team works, put tasks in your tracker, and let your AI apps read your meetings.",
      notes: {
        title: "Notes to your team",
        text: "Send the finished note to Notion, Apple Notes or a channel in Slack, Microsoft Teams, Discord or Zoom Team Chat; anything else through a webhook (Zapier, Make, n8n).",
      },
      tasks: {
        title: "Tasks to your tracker",
        text: "Turn your tasks into Linear or Jira issues, or into Apple Reminders.",
      },
      ai: {
        title: "Your AI apps, through MCP",
        text: "Claude, Cursor and VS Code can search and read your meetings. Connect them with one click in Settings; they can only read, never change anything.",
      },
      files: {
        title: "Your files and calendar",
        text: "Save every note as Markdown to a folder, such as your Obsidian vault or iCloud Drive. Your calendar shows what's next and can start recording when a meeting begins.",
      },
      mcpDemo: {
        label: "In Claude",
        question: "What did I promise Nordia last week?",
        tool: "Searched your meetings",
        answerLead: "In the client call on 27 October you said you'd:",
        answer: ["Send the revised quote by Friday", "Share the onboarding checklist"],
        source: "Client call · Nordia",
      },
    },
    pricingTitle: "One plan. Simple pricing.",
    pricingLead: "Free for 3 meetings or 7 days, whichever comes first, no card needed. Then $5.99 a month, taxes included. Cancel anytime.",
    pricingCta: "Pricing details",
    faqTitle: "Questions",
    faq: [
      {
        question: "How does the free trial work?",
        answer: "The trial is free and needs no card: 3 meetings or 7 days from your first meeting, whichever comes first. Meetings you haven't used by then expire. Trial meetings can be up to 90 minutes long. After that, the subscription is $5.99 a month, taxes included.",
      },
      {
        question: "Does a bot join my meetings?",
        answer: `No. ${productName} listens to your Mac's audio and microphone; participants never see a bot. It reminds you to tell participants before you start recording.`,
      },
      {
        question: "Where does my audio go?",
        answer:
          "While you record, the audio streams from your Mac to Deepgram for the live transcript; Deepgram is asked not to keep it or use it for training. If that isn't available, the live transcript is produced on your Mac instead. When the meeting ends, the audio is passed through our server to ElevenLabs to separate speakers and produce the final transcript; for notes and translation the text goes to Anthropic's Claude model. Our servers don't store audio or text; they only count the duration. ElevenLabs and Anthropic may keep what they process for a time under their own retention rules (Anthropic deletes it within 30 days); the privacy policy has the details.",
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
    finalLead: "3 meetings or 7 days free. Set up in a minute.",
  },
  pricing: {
    meta: {
      title: `Pricing — ${productName}`,
      description: "One plan: $5.99 a month, taxes included. 3 meetings or 7 days free, up to 10 hours a month, up to 4 hours per meeting, cancel anytime.",
    },
    title: "One plan. Simple pricing.",
    lead: "Try it free for 3 meetings or 7 days. If you like it, continue for $5.99 a month, taxes included.",
    planName: productName,
    planTagline: "Everything from live transcript to tasks.",
    included: [
      { icon: "gift", text: "3 meetings or 7 days free, no card needed" },
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
      { icon: "gift", title: "Trial", text: "3 meetings or 7 days from your first meeting, whichever comes first; each meeting up to 90 minutes. Opening a new account does not reset the trial." },
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
      `Checkout is hosted by Stripe, and your purchase is sold through Link, Stripe's payment service, as the merchant of record. The price of $5.99 a month includes sales tax, VAT or GST: Link calculates and remits the tax for your location, and checkout shows the included tax before you pay. You may see the price in your local currency. Receipts come from Link, and your card statement shows ${cardStatementDescriptor}. Your card details stay with Stripe and Link and never reach us. Purchases aren't available in some countries where Stripe can't sell, such as China, Cuba, Iran, North Korea, Russia and Syria.`,
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
          "Refunds are handled by Link, the merchant of record for the subscription. Under Link's terms, consumers in the EU can cancel within 14 days of getting access by contacting Link support and giving “cooling off period” as the reason; Link may also refund within 60 days in certain other cases, such as a duplicate charge. Contact Link support at support.link.com, or write to us and we'll help. The details are in the terms of service.",
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
      description: `Download ${productName} for your Mac: macOS 26 and Apple silicon. 3 meetings or 7 days free.`,
    },
    title: `Download ${productName}`,
    lead: "For Mac. Free for 3 meetings or 7 days, no card needed.",
    versionLabel: "Version",
    installTitle: "Three steps to your first meeting",
    installSteps: [
      { title: "Install", text: `Open the disk image and drag ${productName} into Applications.` },
      { title: "Allow audio", text: "Open the app and allow the microphone and system audio, so it hears both sides of the call." },
      { title: "Sign in", text: "Sign in with Apple or Google and start listening. Your first 3 meetings or 7 days are free." },
    ],
    footnote: "Updates arrive automatically inside the app.",
    helpCta: "Questions? Contact us",
  },
  signIn: {
    meta: { title: `Sign in — ${productName}`, description: `Sign in to your ${productName} account with Apple or Google.` },
    title: "Sign in",
    lead: "To manage your account and subscription. You use the same account in the Mac app.",
    apple: "Continue with Apple",
    google: "Continue with Google",
    legalBefore: "By continuing, you agree to the",
    legalBetween: "and confirm you have read the",
    noScript: "Signing in needs JavaScript.",
    appTitle: `Sign in to the ${productName} app`,
    appLead: "Continue with Apple or Google. When you're done, the app opens and finishes signing you in.",
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
    companyTitle: "Company details",
    businessIdLabel: "Business ID (Y-tunnus)",
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
    subscribeNote: "$5.99 a month, taxes included. Renews automatically every month until you cancel. Cancel anytime. Sold through Link, Stripe's payment service.",
    manage: "Manage subscription",
    manageNote: "Update your card, see receipts or cancel anytime at Link. Renews automatically every month until you cancel.",
    signOut: "Sign out",
    appTitle: "Get the app",
    appText: `${productName} runs on your Mac. Sign in there with the same Apple or Google account.`,
    helpTitle: "Need help?",
    helpContact: "Contact support",
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
    meta: { title: productName, description: tagline },
    documentTitle: `Dashboard — ${productName}`,
    title: "Dashboard",
    refresh: "Refresh",
    loading: "Loading…",
    kpis: {
      downloads: "Downloads",
      users: "Users",
      trials: "Trials",
      subscribers: "Subscribers",
      mrr: "MRR",
      spend: "AI spend today",
      hours: "Meeting hours this month",
      tokens: "Tokens this month",
      elevenLabs: "Transcription capacity",
      deepgram: "Live transcript budget",
    },
    groups: { growth: "Growth", revenue: "Revenue", costs: "Costs & capacity" },
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
