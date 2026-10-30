// Sitenin sayfa metinleri (yasal metinler hariç: onlar src/pages/privacy.astro ve terms.astro içinde). Ürün adı ve
// işletme bilgisi tek yerden gelir (config.ts `productName`, legal/operator.ts).
import { cardStatementDescriptor, productName } from "./config";
import type { IconName } from "./lib/icons";
import type { BillingPlan } from "./lib/plans";
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
    readonly compare: string;
    readonly blog: string;
    readonly mcp: string;
  };
  readonly downloadCta: string;
  readonly headerDownload: string;
  /** Tema düğmesinin erişilebilir adı (basılıysa koyu tema). */
  readonly darkMode: string;
  readonly price: string;
  readonly perMonth: string;
  /** Yıllık planın fiyatı (`$49`) ve dönemi. */
  readonly yearlyPrice: string;
  readonly perYear: string;
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
    /** Karşılaştırma, blog ve MCP bağlantılarının sütunu. */
    readonly learn: string;
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
  /** Kahramanın altındaki tanıtım videosu (public/video; kendiliğinden oynamaz). */
  readonly launchVideo: {
    readonly eyebrow: string;
    readonly title: string;
    readonly caption: string;
    /** Video oynatılamazsa görünen metin ve dosya bağlantısı. */
    readonly fallback: string;
    readonly fallbackLink: string;
  };
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
    /** Yapay zekâ kartından MCP sayfasına bağlantı. */
    readonly mcpLink: string;
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
  /** Fiyat bandından karşılaştırma sayfasına bağlantı. */
  readonly pricingCompare: string;
  readonly faqTitle: string;
  readonly faq: readonly Faq[];
  readonly finalTitle: string;
  readonly finalLead: string;
}

/** Fiyat sayfasında ve hesap sayfasının plan seçiminde bir plan. */
export interface PlanOptionCopy {
  readonly plan: BillingPlan;
  readonly name: string;
  readonly price: string;
  readonly per: string;
  /** Fiyatın altındaki kısa satır (ör. aylık karşılığı ve faturalama sıklığı). */
  readonly detail: string;
  /** Öne çıkan planın rozeti (ör. "Save 32%"); yoksa null. */
  readonly badge: string | null;
  /** Fiyat sayfasındaki düğme. */
  readonly cta: string;
}

/** Fiyat sayfası. */
export interface PricingCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly lead: string;
  /** Plan kartlarının başlığı (ekran okuyucular için). */
  readonly plansTitle: string;
  readonly plans: readonly PlanOptionCopy[];
  /** Plan kartlarının altındaki not: deneme ve davet kodu ("{invite}" bağlantının yeri). */
  readonly plansNote: string;
  readonly plansInviteLink: string;
  readonly includedTitle: string;
  readonly planTagline: string;
  readonly included: readonly IconItem[];
  readonly startFree: string;
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
  /** Ödeme uygulamadan açıldıysa tarayıcıda oturum yoktur: giriş sayfası yerine bu not görünür. */
  readonly paymentDoneSignedOut: { readonly title: string; readonly text: string; readonly signIn: string };
  readonly planLabel: string;
  readonly trialLabel: string;
  readonly hoursLabel: string;
  readonly hoursNote: string;
  readonly renewalLabel: string;
  readonly subscribe: string;
  /** Abone olmadan önce plan seçimi (seçenekler `copy.pricing.plans`'tan). */
  readonly planChoiceLegend: string;
  /** Davet kodu alanı (abone ol düğmesinin üstünde, varsayılan kapalı). */
  readonly invite: {
    readonly summary: string;
    readonly label: string;
    readonly placeholder: string;
    readonly apply: string;
    readonly remove: string;
  };
  /** Abone ol düğmesinin yanında: vergiler dahil, otomatik yenileme, iptal, satıcı. */
  readonly subscribeNote: string;
  readonly manage: string;
  /** Aboneliği yönet düğmesinin yanında (kart, iptal; makbuzlar Link'ten e-postayla, sipariş geçmişi link.com'da). */
  readonly manageNote: string;
  readonly signOut: string;
  /** Abonenin davet kartı ("bir ay ver, bir ay kazan"). */
  readonly referral: {
    readonly title: string;
    readonly text: string;
    readonly codeLabel: string;
    readonly copyLink: string;
    readonly copied: string;
    readonly howItWorks: string;
  };
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

/** Davet sayfası ("bir ay ver, bir ay kazan"). */
export interface InviteCopy {
  readonly meta: PageMeta;
  readonly eyebrow: string;
  readonly title: string;
  readonly lead: string;
  readonly stepsTitle: string;
  readonly steps: readonly IconText[];
  readonly rulesTitle: string;
  readonly rules: readonly string[];
  /** Adresteki `?code=` ile gelen kodun kutusu. */
  readonly codeLabel: string;
  readonly codeNote: string;
  readonly subscribeWithCode: string;
  /** Davet edenin kendi kodu: hesap sayfası ve uygulama. */
  readonly ownCodeTitle: string;
  readonly ownCodeText: string;
  readonly ownCodeLink: string;
  readonly termsNote: string;
  readonly termsLink: string;
}

/** Yönetim panelinin kullanıcılar görünümü. */
export interface AdminUsersCopy {
  readonly title: string;
  readonly searchLabel: string;
  readonly searchPlaceholder: string;
  readonly search: string;
  readonly segmentLabel: string;
  /** Kesim seçiminin grupları: plan ve bırakma kesimleri. */
  readonly segmentGroups: { readonly plan: string; readonly dropOff: string };
  readonly segments: {
    readonly all: string;
    readonly subscribed: string;
    readonly pastDue: string;
    readonly canceled: string;
    readonly trial: string;
    readonly free: string;
    readonly noMeeting: string;
    readonly trialEnded: string;
    readonly inactive: string;
    readonly failed: string;
  };
  readonly providerLabel: string;
  readonly providers: { readonly all: string; readonly apple: string; readonly google: string };
  readonly columns: {
    readonly user: string;
    readonly provider: string;
    readonly created: string;
    readonly plan: string;
    readonly trial: string;
    readonly subscription: string;
    readonly meetings: string;
    readonly hours: string;
    readonly lastActive: string;
    readonly problems: string;
  };
  readonly empty: string;
  readonly loadMore: string;
  readonly back: string;
  readonly fields: {
    readonly provider: string;
    readonly created: string;
    readonly lastActive: string;
    readonly stripeCustomer: string;
    readonly trialDevice: string;
    readonly subscription: string;
    readonly trial: string;
    readonly cancellation: string;
  };
  readonly usageTitle: string;
  readonly usage: { readonly hours: string; readonly tokens: string; readonly accountTokens: string; readonly audio: string };
  readonly timelineTitle: string;
  readonly timelineNote: string;
  readonly meetingsTitle: string;
  readonly meetingColumns: {
    readonly started: string;
    readonly kind: string;
    readonly state: string;
    readonly duration: string;
    readonly audio: string;
    readonly tokens: string;
    readonly notes: string;
    readonly problem: string;
  };
  readonly noMeetings: string;
  readonly reportsTitle: string;
  readonly noReports: string;
}

/** Yönetim panelinin işletim görünümü. */
export interface AdminOperationsCopy {
  readonly kpis: {
    readonly open: string;
    readonly unended: string;
    readonly reservations: string;
    readonly deepgram: string;
    readonly webhook: string;
    readonly reports: string;
  };
  readonly openTitle: string;
  readonly openColumns: { readonly user: string; readonly kind: string; readonly started: string; readonly endsBy: string; readonly notes: string };
  readonly noOpen: string;
  readonly stripeTitle: string;
  readonly stripeColumns: { readonly type: string; readonly count: string };
  readonly noStripe: string;
  readonly crashesTitle: string;
  readonly noCrashes: string;
}

/** Yönetim panelinin içgörüler görünümü (sorunlar, huni, indirme kaynakları, iptal nedenleri). */
export interface AdminInsightsCopy {
  readonly problemsTitle: string;
  readonly problemsColumns: { readonly problem: string; readonly last7: string; readonly last30: string };
  readonly noProblems: string;
  readonly funnelTitle: string;
  readonly funnelColumns: { readonly step: string; readonly count: string; readonly fromPrevious: string; readonly lost: string };
  readonly funnelNote: string;
  readonly sourcesTitle: string;
  readonly sourceColumns: { readonly source: string; readonly count: string };
  readonly referrersTitle: string;
  readonly referrerColumns: { readonly host: string; readonly count: string };
  readonly noDownloads: string;
  readonly downloadsNote: string;
  readonly cancellationsTitle: string;
  readonly cancellationColumns: { readonly reason: string; readonly count: string };
  readonly noCancellations: string;
  readonly recentCancellationsTitle: string;
}

/** Yönetim panelinin durgun metinleri (değerlere bağlı olanlar client/copy.ts'te). */
export interface AdminCopy {
  /** Nötr başlık ve açıklama: yönetici erişimi doğrulanmadan panelin varlığı belli olmaz. */
  readonly meta: PageMeta;
  /** Erişim doğrulanınca sekme başlığı. */
  readonly documentTitle: string;
  /** Sol menüde ürün adının yanındaki rozet. */
  readonly title: string;
  /** Sol menüden siteye dönüş bağlantısı. */
  readonly backToSite: string;
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
    readonly conversion: string;
    readonly churn: string;
    readonly payments: string;
    readonly meetings: string;
    readonly audio: string;
    readonly refusals: string;
  };
  /** Özet kutusu gruplarının başlıkları. */
  readonly groups: { readonly growth: string; readonly revenue: string; readonly usage: string; readonly costs: string };
  /** Panelin görünümleri (üstteki sekmeler). */
  readonly views: {
    readonly label: string;
    readonly overview: string;
    readonly insights: string;
    readonly users: string;
    readonly operations: string;
    readonly inbox: string;
  };
  readonly users: AdminUsersCopy;
  readonly operations: AdminOperationsCopy;
  readonly insights: AdminInsightsCopy;
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

/** Karşılaştırma tablosunun satırları (konular). */
export type ComparisonTopic =
  | "price"
  | "free"
  | "capture"
  | "platforms"
  | "limits"
  | "languages"
  | "notes"
  | "ask"
  | "integrations"
  | "storage"
  | "plans";

/** Karşılaştırılan ürünler. */
export type Competitor = "granola" | "otter";

/** "Kim hangisini seçmeli" kutusu: başlık ve maddeler. */
export interface PickCopy {
  readonly title: string;
  readonly points: readonly string[];
}

/**
 * Bir rakiple karşılaştırma sayfası. Rakibin değerleri yalnızca kendi fiyat sayfasında doğrulanmış gerçeklerdir; o
 * konuda doğrulanmış bilgi yoksa değer `null` olur ve tabloda tire görünür (özelliğin olmadığı anlamına gelmez).
 */
export interface CompetitorCopy {
  readonly meta: PageMeta;
  readonly name: string;
  readonly title: string;
  readonly lead: string;
  /** Karşılaştırma dizinindeki kartın kısa özeti. */
  readonly summary: string;
  readonly pricingUrl: string;
  readonly values: Readonly<Record<ComparisonTopic, string | null>>;
  /** Rakibin daha güçlü olduğu yerler (adil karşılaştırma). */
  readonly strengthsTitle: string;
  readonly strengths: readonly string[];
  readonly pickCompetitor: PickCopy;
  readonly pickUs: PickCopy;
}

/** Karşılaştırma sayfalarının ortak metinleri ve dizin sayfası. */
export interface CompareCopy {
  readonly meta: PageMeta;
  readonly eyebrow: string;
  readonly title: string;
  readonly lead: string;
  /** Dizindeki özet tablonun konuları. */
  readonly overviewTopics: readonly ComparisonTopic[];
  readonly overviewTitle: string;
  readonly topics: Readonly<Record<ComparisonTopic, string>>;
  /** Bizim değerlerimiz (copy.ts, fiyat sayfası ve sunucu sınırlarıyla aynı). */
  readonly us: Readonly<Record<ComparisonTopic, string>>;
  readonly topicColumn: string;
  readonly tableTitle: string;
  readonly checked: string;
  readonly source: string;
  readonly missingNote: string;
  /** Tirenin ekran okuyucudaki karşılığı. */
  readonly notChecked: string;
  readonly pickTitle: string;
  readonly readComparison: string;
  readonly trademarks: string;
  readonly ctaTitle: string;
  readonly ctaText: string;
  readonly competitors: Readonly<Record<Competitor, CompetitorCopy>>;
}

/** Blog dizini, yazı sayfası ve RSS akışı. */
export interface BlogCopy {
  readonly meta: PageMeta;
  readonly eyebrow: string;
  readonly title: string;
  readonly lead: string;
  readonly feedTitle: string;
  readonly feedLink: string;
  readonly byline: string;
  /** "6 min read" gibi okuma süresinin eki. */
  readonly minutesRead: string;
  readonly readPost: string;
  readonly backToBlog: string;
  readonly ctaTitle: string;
  readonly ctaText: string;
}

/** MCP aracının açıklaması (MCPServer.swift `mcpTools` ile aynı araçlar). */
export interface McpToolCopy {
  readonly name: string;
  readonly text: string;
  /** Girdileri (yoksa "No input"). */
  readonly input: string;
}

/** MCP istemcisinin yapılandırma dosyası (MCPClients.swift `configRelativePath`). */
export interface McpClientFileCopy {
  readonly client: string;
  readonly file: string;
}

/** MCP sayfası. */
export interface McpCopy {
  readonly meta: PageMeta;
  readonly eyebrow: string;
  readonly title: string;
  readonly lead: string;
  readonly toolsTitle: string;
  readonly toolsLead: string;
  readonly toolInputLabel: string;
  readonly tools: readonly McpToolCopy[];
  readonly setupTitle: string;
  readonly setupLead: string;
  readonly oneClick: PickCopy;
  readonly manual: PickCopy;
  readonly configLabel: string;
  readonly configNote: string;
  readonly filesTitle: string;
  readonly fileColumns: { readonly client: string; readonly file: string };
  readonly files: readonly McpClientFileCopy[];
  readonly filesNote: string;
  readonly questionsTitle: string;
  readonly questionsLead: string;
  readonly questions: readonly string[];
  readonly privacyTitle: string;
  readonly privacy: readonly TitledText[];
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
  readonly compare: CompareCopy;
  readonly blog: BlogCopy;
  readonly mcp: McpCopy;
  readonly signIn: SignInCopy;
  readonly contact: ContactCopy;
  readonly account: AccountCopy;
  readonly invite: InviteCopy;
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
      compare: "Compare",
      blog: "Blog",
      mcp: "MCP for AI apps",
    },
    downloadCta: "Download for Mac",
    headerDownload: "Download",
    darkMode: "Dark mode",
    price: "$5.99",
    perMonth: "/ month",
    yearlyPrice: "$49",
    perYear: "/ year",
    offer: "3 meetings or 7 days free, then $5.99 a month or $49 a year, taxes included",
    requirementsShort: "macOS 15 or later · Apple silicon",
    taxNote: "Taxes included.",
    renewalNote: "Renews automatically every month or year, depending on your plan, until you cancel. Cancel anytime.",
    ogImageAlt: `The ${productName} logo and the tagline “${tagline}” on a soft pastel gradient, above a small sound wave.`,
    footer: {
      tagline,
      product: "Product",
      learn: "Learn",
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
    lead: `${productName} transcribes the conversation live, translates it if you like, and has your note ready when the meeting ends: your tasks first, then decisions and a summary. No bot joins the call, and no one else in the meeting needs to install anything.`,
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
    launchVideo: {
      eyebrow: "In one minute",
      title: "See it at work.",
      caption:
        "A 66-second tour, with music: the live transcript and translation, your tasks on top of the note, asking across your meetings, and sending notes where your team works.",
      fallback: "Your browser can't play this video here.",
      fallbackLink: "Open the video file",
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
        { title: "Notes stay on your Mac", text: "Notes, transcripts and recordings live in the app on your Mac. Our servers don't keep your notes or recordings." },
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
      mcpLink: "How MCP works",
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
    pricingTitle: "Simple pricing, monthly or yearly.",
    pricingLead: "Free for 3 meetings or 7 days, whichever comes first, no card needed. Then $5.99 a month or $49 a year, taxes included. Cancel anytime.",
    pricingCta: "Pricing details",
    pricingCompare: "Compare with Granola and Otter",
    faqTitle: "Questions",
    faq: [
      {
        question: "How does the free trial work?",
        answer: "The trial is free and needs no card: 3 meetings or 7 days from your first meeting, whichever comes first. Meetings you haven't used by then expire. Trial meetings can be up to 90 minutes long. After that, the subscription is $5.99 a month or $49 a year, taxes included.",
      },
      {
        question: "Does a bot join my meetings?",
        answer: `No. ${productName} listens to your Mac's audio and microphone; participants never see a bot. It reminds you to tell participants before you start recording.`,
      },
      {
        question: "Where does my audio go?",
        answer:
          "While you record, the audio streams from your Mac to Deepgram for the live transcript; Deepgram is asked not to keep it or use it for training. If that isn't available, the live transcript is produced on your Mac instead. When the meeting ends, the audio is passed through our server to ElevenLabs to separate speakers and produce the final transcript; for notes and translation the text goes to Anthropic's Claude model. Our servers don't store audio or notes; they count the duration and hold the final transcript encrypted for up to 2 hours, only so it can be re-sent if the connection drops. ElevenLabs and Anthropic may keep what they process for a time under their own retention rules (Anthropic deletes it within 30 days); the privacy policy has the details.",
      },
      {
        question: "Where are my notes stored?",
        answer: "On your Mac. Notes, transcripts and recordings live in the app's folder on your Mac; our servers don't keep them (the final transcript is held encrypted for up to 2 hours so it can be re-sent, then deleted). You can export, share or delete them in the app.",
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
      description: "$5.99 a month or $49 a year, taxes included. 3 meetings or 7 days free, up to 10 hours a month, up to 4 hours per meeting, cancel anytime.",
    },
    title: "Simple pricing, monthly or yearly.",
    lead: "Try it free for 3 meetings or 7 days. If you like it, continue for $5.99 a month, or $49 a year and save 32%. Taxes included.",
    plansTitle: "Plans",
    plans: [
      {
        plan: "monthly",
        name: "Monthly",
        price: "$5.99",
        per: "/ month",
        detail: "Billed every month. Taxes included.",
        badge: null,
        cta: "Choose monthly",
      },
      {
        plan: "yearly",
        name: "Yearly",
        price: "$49",
        per: "/ year",
        detail: "About $4.08 a month, billed once a year. Taxes included.",
        badge: "Save 32%",
        cta: "Choose yearly",
      },
    ],
    plansNote: "Both plans include everything below and start with 3 meetings or 7 days free. Got an invite from a friend? {invite}",
    plansInviteLink: "How invites work",
    includedTitle: "Everything included",
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
      `Checkout is hosted by Stripe, and your purchase is sold through Link, Stripe's payment service, as the merchant of record. The price of $5.99 a month or $49 a year includes sales tax, VAT or GST: Link calculates and remits the tax for your location, and checkout shows the included tax before you pay. You may see the price in your local currency. Receipts come from Link, and your card statement shows ${cardStatementDescriptor}. Your card details stay with Stripe and Link and never reach us. Purchases aren't available in some countries where Stripe can't sell, such as China, Cuba, Iran, North Korea, Russia and Syria.`,
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
        question: "Can I switch between monthly and yearly?",
        answer:
          "Not with a single click yet. Cancel your current plan with “Manage subscription” on your account page; you keep access until the end of the period you paid for. When it has ended, subscribe again from your account page and choose the other plan.",
      },
      {
        question: "How do invites work?",
        answer:
          "Subscribers get a personal invite code in the app and on their account page. A friend who subscribes with it gets their first month free on the monthly plan, or $5.99 off their first year on the yearly plan. Once your friend's first payment has gone through and hasn't been refunded for 30 days, you get $5.99 off your next payment. You can earn up to 12 rewards a year.",
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
      description: `Download ${productName} for your Mac: macOS 15 or later on Apple silicon. 3 meetings or 7 days free.`,
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
  // Rakip değerleri yalnızca rakiplerin kendi fiyat sayfalarından (29 Ekim 2026'da denetlendi); bizimkiler bu dosyadaki
  // fiyat ve SSS metinleriyle ve sunucu sınırlarıyla (server/wrangler.jsonc) aynıdır. Yeni bir değer eklerken kaynağını
  // denetle; doğrulanmamış rakip bilgisi yazma (değer `null` kalır).
  compare: {
    meta: {
      title: `Compare ${productName} with Granola and Otter`,
      description: `How ${productName} compares with Granola and Otter.ai on price, free plans, how audio is captured, platforms and limits. Prices checked October 2026.`,
    },
    eyebrow: "Compare",
    title: `${productName} next to Granola and Otter`,
    lead: "Three meeting note apps that work in different ways. Here are the plain differences in price, how each one hears the meeting and where it runs, so you can pick the one that fits.",
    overviewTopics: ["price", "free", "capture", "platforms"],
    overviewTitle: "At a glance",
    topics: {
      price: "Price",
      free: "Free option",
      capture: "How it hears the meeting",
      platforms: "Platforms",
      limits: "Meeting limits",
      languages: "Languages",
      notes: "Notes",
      ask: "Questions across meetings",
      integrations: "Integrations",
      storage: "Where notes are kept",
      plans: "Plans for teams",
    },
    us: {
      price: "$5.99 a month or $49 a year, taxes included",
      free: "Free trial: 3 meetings or 7 days, whichever comes first; no card needed",
      capture: "No bot. Listens to your Mac's system audio and microphone",
      platforms: "Mac with Apple silicon, macOS 15 or later",
      limits: "Up to 10 meeting hours a month and up to 4 hours per meeting",
      languages: "30+ languages, with live translation during the meeting",
      notes: "The note starts with your own tasks, then decisions and a summary; templates for different kinds of meetings",
      ask: "Ask across all your meetings; answers link to the meetings they came from",
      integrations: "Slack, Microsoft Teams, Discord, Notion, Apple Notes, an Obsidian folder, webhooks and MCP",
      storage: "Notes, transcripts and recordings are saved on your Mac",
      plans: "One personal plan, billed monthly or yearly",
    },
    topicColumn: "Topic",
    tableTitle: "Side by side",
    checked: "Prices checked October 2026.",
    source: "Source",
    missingNote: "A dash means the point wasn't part of what we checked on the vendor's pricing page. It doesn't mean the feature is missing.",
    notChecked: "Not checked",
    pickTitle: "Who should pick which",
    readComparison: "Read the comparison",
    trademarks: `Granola and Otter.ai are trademarks of their owners. ${productName} isn't affiliated with either company. Plans and prices change; check the vendor's site before you buy.`,
    ctaTitle: `Try ${productName} on your next meeting`,
    ctaText: "3 meetings or 7 days free, no card needed. Then $5.99 a month or $49 a year, taxes included.",
    competitors: {
      granola: {
        meta: {
          title: `${productName} vs Granola: meeting notes without a bot`,
          description: `${productName} and Granola both take meeting notes without a bot. Compare price, free plans, platforms, languages and integrations. Prices checked October 2026.`,
        },
        name: "Granola",
        title: `${productName} vs Granola`,
        lead: "Both take notes without a bot joining the call. Granola runs on more devices and has team plans; Gistsmith is a Mac app with simple pricing, notes that start with your tasks and live translation.",
        summary: "Both work without a bot. Granola has a free plan, mobile apps and team plans; Gistsmith is Mac-only, with one personal plan.",
        pricingUrl: "https://www.granola.ai/pricing",
        values: {
          price: "Basic $0; Business $14 per user a month; Enterprise $35 per user a month",
          free: "Basic plan at $0, with 30 days of meeting history",
          capture: "No bot. Captures your device's audio",
          platforms: "Desktop, iOS, Android and Apple Watch",
          limits: null,
          languages: "Multi-language support",
          notes: "Note templates",
          ask: "AI chat across meetings",
          integrations: "Slack on all plans; Notion, HubSpot, Zapier, Attio, MCP and an API on Business",
          storage: null,
          plans: "Per-user Business and Enterprise plans",
        },
        strengthsTitle: "Where Granola is stronger",
        strengths: [
          "A free Basic plan, with 30 days of meeting history.",
          "Apps for iOS, Android and Apple Watch as well as the desktop.",
          "Per-user Business and Enterprise plans for teams.",
          "HubSpot, Attio and Zapier integrations and an API on the Business plan.",
        ],
        pickCompetitor: {
          title: "Pick Granola if",
          points: [
            "you want a free plan and 30 days of history is enough",
            "you also take notes on an Android phone, an iPhone or an Apple Watch",
            "your team wants one shared plan with per-user billing",
            "your notes need to reach HubSpot or Attio, or you want an API",
          ],
        },
        pickUs: {
          title: `Pick ${productName} if`,
          points: [
            "you work on a Mac and want simple pricing: $5.99 a month or $49 a year, taxes included",
            "you want every note to open with your own tasks",
            "your meetings are in another language and you want a live translation as people talk",
            "you want notes, transcripts and recordings saved on your own Mac",
          ],
        },
      },
      otter: {
        meta: {
          title: `${productName} vs Otter.ai: a Mac notepad without a meeting bot`,
          description: `Otter joins calls as a bot; ${productName} listens on your Mac. Compare price, free plans, minutes, meeting length and languages. Prices checked October 2026.`,
        },
        name: "Otter.ai",
        title: `${productName} vs Otter.ai`,
        lead: "Otter joins Zoom, Microsoft Teams and Google Meet as a bot to write notes. Gistsmith listens on your Mac instead, so nothing extra appears in the call. Otter has a free tier and team plans; Gistsmith has one personal plan.",
        summary: "Otter joins calls as a bot and has a free tier. Gistsmith listens on your Mac, with no bot in the call.",
        pricingUrl: "https://otter.ai/pricing",
        values: {
          price: "Basic free; Pro $16.99 per user a month billed monthly ($8.33 a month billed annually); Business $19.99 per user a month billed annually",
          free: "Basic plan: 300 transcription minutes a month and 3 file imports in total",
          capture: "Joins Zoom, Microsoft Teams and Google Meet as a bot to write notes",
          platforms: "Mobile apps available",
          limits: "Pro: 1,200 minutes a month, up to 90 minutes per meeting. Business: unlimited meetings, up to 4 hours per meeting",
          languages: "Automatic transcription in English, Spanish, French, German, Japanese and Chinese",
          notes: null,
          ask: null,
          integrations: null,
          storage: null,
          plans: "Per-user Pro and Business plans",
        },
        strengthsTitle: "Where Otter is stronger",
        strengths: [
          "A free Basic plan with 300 transcription minutes a month.",
          "Mobile apps.",
          "Per-user Pro and Business plans for teams.",
          "Unlimited meetings on the Business plan.",
        ],
        pickCompetitor: {
          title: "Pick Otter if",
          points: [
            "you want a free tier and 300 minutes a month covers you",
            "you'd like a note-taker to join the call as a participant",
            "you need mobile apps or team plans",
            "you want unlimited meetings on a business plan",
          ],
        },
        pickUs: {
          title: `Pick ${productName} if`,
          points: [
            "you'd rather no bot joins your calls",
            "you meet in a language beyond the six on Otter's pricing page, or you want a live translation",
            "you want every note to open with your own tasks",
            "you work on a Mac and want simple pricing: $5.99 a month or $49 a year, taxes included",
          ],
        },
      },
    },
  },
  blog: {
    meta: {
      title: `Blog — ${productName}`,
      description: "Practical guides on meeting notes, task lists and recording calls on a Mac, from the team behind Gistsmith.",
    },
    eyebrow: "Blog",
    title: "Notes on better meetings",
    lead: "Practical guides on meeting notes, follow-ups and recording calls on a Mac. Short, specific and useful whether or not you use our app.",
    feedTitle: `${productName} blog`,
    feedLink: "RSS feed",
    byline: "By",
    minutesRead: "min read",
    readPost: "Read the post",
    backToBlog: "All posts",
    ctaTitle: `Try ${productName}`,
    ctaText: "A meeting notepad for Mac. 3 meetings or 7 days free, then $5.99 a month or $49 a year, taxes included.",
  },
  mcp: {
    meta: {
      title: `MCP server — ${productName}`,
      description: `${productName} includes a local, read-only MCP server. Let Claude, Cursor, VS Code and other MCP apps list, search and read your meeting notes and tasks.`,
    },
    eyebrow: "MCP",
    title: "Ask your AI apps about your meetings.",
    lead: `${productName} includes a small MCP server. Claude, Cursor, Visual Studio Code and other MCP apps can use it to list, search and read your meetings and your open tasks. It only reads; it never changes anything.`,
    toolsTitle: "What it offers",
    toolsLead: "The server gives your AI app four tools. The app decides when to call them, usually starting with a list or a search and then opening a meeting.",
    toolInputLabel: "Input",
    tools: [
      {
        name: "list_meetings",
        text: "Lists your recorded meetings, newest first: ID, date, title, length and whether the note is ready.",
        input: "limit (optional; 20 if not given)",
      },
      {
        name: "search_meetings",
        text: "Searches your notes and transcripts by keyword and returns the matching passages, with the meeting and the moment in it.",
        input: "query (required)",
      },
      {
        name: "get_meeting",
        text: "Returns a meeting's note as Markdown: summary, decisions, tasks and glossary. Add the transcript when you need the exact words.",
        input: "id from list_meetings (required); include_transcript (optional)",
      },
      {
        name: "list_my_tasks",
        text: "Lists the tasks from your meeting notes that are yours and not yet done, with due dates and the meeting each one came from.",
        input: "No input",
      },
    ],
    setupTitle: "Connect it",
    setupLead: `Keep ${productName} in your Applications folder and sign in to the app first: the server reads the meetings of the account you're signed in with.`,
    oneClick: {
      title: "One click: Claude, Cursor and VS Code",
      points: [
        `In ${productName}, open Settings › Connections.`,
        "Under AI apps, click Connect on the Claude, Cursor or Visual Studio Code card. A card is dimmed if that app isn't in your Applications folder.",
        `Quit and reopen the AI app. ${productName} now appears among its tools.`,
      ],
    },
    manual: {
      title: "Any other MCP app",
      points: [
        "In Settings › Connections, open “Advanced: skills and manual MCP setup”.",
        "Under Other MCP clients, click Copy configuration.",
        "Paste it into your app's MCP settings. In Claude Desktop that's Settings › Developer › Edit Config.",
      ],
    },
    configLabel: "The configuration, for the app in your Applications folder",
    configNote: `The app copies this with the real location of ${productName} on your Mac. If you keep it somewhere else, use the copy from the app.`,
    filesTitle: "Where the one-click setup writes",
    fileColumns: { client: "App", file: "Configuration file" },
    files: [
      { client: "Claude", file: "~/Library/Application Support/Claude/claude_desktop_config.json" },
      { client: "Cursor", file: "~/.cursor/mcp.json" },
      { client: "Visual Studio Code", file: "~/Library/Application Support/Code/User/mcp.json" },
    ],
    filesNote: `Connect adds a single “${productName.toLowerCase()}” entry and leaves everything else in the file as it was. VS Code keeps its servers under “servers” with “type”: “stdio”; Connect writes that form for you. If the file contains comments, which VS Code allows, ${productName} won't overwrite it and tells you why.`,
    questionsTitle: "Questions to try",
    questionsLead: "Ask in your own words. A few that work well:",
    questions: [
      "What did I promise Nordia last week?",
      "List my open tasks from this week's meetings, grouped by due date.",
      "Find the meetings where we discussed the budget and summarise what we decided.",
    ],
    privacyTitle: "What it can and can't do",
    privacy: [
      { title: "Read only", text: "The tools list, search and read. Nothing can be edited, deleted or sent through them." },
      {
        title: "Runs on your Mac",
        text: `Your AI app starts ${productName} in the background and talks to it through standard input and output. The server doesn't open a network port.`,
      },
      {
        title: "Your AI app's provider sees what it reads",
        text: "Notes and transcripts your AI app reads go to that app's AI provider, such as Anthropic or OpenAI, under its own terms.",
      },
      {
        title: "Your signed-in account only",
        text: `If you sign out of ${productName}, the tools stop returning meetings until you sign in again. If you switch accounts, restart the AI app.`,
      },
      {
        title: "Meeting text is data, not instructions",
        text: "The server tells your AI app that notes and transcripts are what people said, and that it shouldn't follow requests found inside them.",
      },
    ],
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
    paymentDoneSignedOut: {
      title: "Payment received, thank you",
      text: `Go back to the ${productName} app: your subscription shows up there within a few seconds. You can close this tab.`,
      signIn: "Sign in to see your account here",
    },
    planLabel: "Plan",
    trialLabel: "Free trial",
    hoursLabel: "Usage this month",
    hoursNote: "Resets on the first day of each month (UTC).",
    renewalLabel: "Subscription",
    subscribe: "Subscribe",
    planChoiceLegend: "Choose a plan",
    invite: {
      summary: "Have an invite code?",
      label: "Invite code",
      placeholder: "For example K7M2QX9D",
      apply: "Apply",
      remove: "Remove",
    },
    subscribeNote: "Taxes included. Your plan renews automatically every month or year until you cancel. Cancel anytime. Sold through Link, Stripe's payment service.",
    manage: "Manage subscription",
    manageNote: "Update your card or cancel anytime. Receipts are emailed to you by Link, and your order history is at link.com. Your plan renews automatically until you cancel.",
    signOut: "Sign out",
    referral: {
      title: "Give a month, get a month",
      text: "Friends who subscribe with your code get their first month free. For each one who stays, you get a free month too: $5.99 off your next payment, up to 12 times a year.",
      codeLabel: "Your invite code",
      copyLink: "Copy invite link",
      copied: "Link copied",
      howItWorks: "How invites work",
    },
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
  invite: {
    meta: {
      title: `Invite a friend — ${productName}`,
      description: `Give a month, get a month: a friend who subscribes to ${productName} with your invite code gets their first month free, and you get $5.99 off your next payment.`,
    },
    eyebrow: "Invite a friend",
    title: "Give a month, get a month.",
    lead: `Share ${productName} with a friend. They get their first month free, and when they stay, you get a month too.`,
    stepsTitle: "How it works",
    steps: [
      {
        icon: "gift",
        title: "Share your code",
        text: "Every subscriber gets a personal invite code, shown in the app under Settings › Account and on your account page. Send the code or your invite link to a friend.",
      },
      {
        icon: "card",
        title: "Your friend subscribes with it",
        text: "On the monthly plan their first month is free; on the yearly plan they get $5.99 off their first year. Invites are for people who haven't subscribed before.",
      },
      {
        icon: "check-circle",
        title: "You get a month",
        text: "Once your friend's first payment has gone through and hasn't been refunded for 30 days, $5.99 is taken off your next payment. On the monthly plan that is a free month; on the yearly plan it comes off your next renewal.",
      },
    ],
    rulesTitle: "The rules, plainly",
    rules: [
      "Up to 12 rewards per person in any 12 months.",
      "One reward for each new paying account. Your own account, or another account of yours, doesn't count.",
      "A reward is cancelled if your friend's first payment is refunded or disputed.",
      "Rewards are credit on your next payments, not cash, and can't be exchanged or transferred.",
      "We may change or end the invite programme; rewards already earned stay yours.",
    ],
    codeLabel: "Your invite code",
    codeNote: "We've saved it in this browser. Subscribe here, or sign in to the Mac app and enter it when you subscribe.",
    subscribeWithCode: "Subscribe with this code",
    ownCodeTitle: "Looking for your own code?",
    ownCodeText: "Subscribers find it in the app under Settings › Account and on their account page.",
    ownCodeLink: "Go to your account",
    termsNote: "The full rules are in the",
    termsLink: "terms of service",
  },
  admin: {
    meta: { title: productName, description: tagline },
    documentTitle: `Dashboard — ${productName}`,
    title: "Admin",
    backToSite: "Back to site",
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
      conversion: "Trial to paid",
      churn: "Cancellations, 30 days",
      payments: "Payment issues",
      meetings: "Meetings this month",
      audio: "Transcribed audio this month",
      refusals: "Trials refused, 30 days",
    },
    groups: { growth: "Growth", revenue: "Revenue", usage: "Usage", costs: "Costs & capacity" },
    views: { label: "Dashboard sections", overview: "Overview", insights: "Insights", users: "Users", operations: "Operations", inbox: "Inbox" },
    users: {
      title: "Users",
      searchLabel: "Account ID",
      searchPlaceholder: "Search by account ID prefix",
      search: "Search",
      segmentLabel: "Segment",
      segmentGroups: { plan: "Plan", dropOff: "Drop-off" },
      segments: {
        all: "All",
        subscribed: "Subscribed",
        pastDue: "Payment due",
        canceled: "Cancelled",
        trial: "Trial",
        free: "No plan",
        noMeeting: "Signed in, no meeting",
        trialEnded: "Trial ended, not subscribed",
        inactive: "Inactive for 7+ days",
        failed: "Meetings with errors",
      },
      providerLabel: "Sign-in",
      providers: { all: "Any", apple: "Apple", google: "Google" },
      columns: {
        user: "Account",
        provider: "Sign-in",
        created: "Joined",
        plan: "Plan",
        trial: "Trial",
        subscription: "Subscription",
        meetings: "Meetings",
        hours: "Hours, month",
        lastActive: "Last active",
        problems: "Problems",
      },
      empty: "No accounts match.",
      loadMore: "Load more",
      back: "All users",
      fields: {
        provider: "Sign-in",
        created: "Joined",
        lastActive: "Last active",
        stripeCustomer: "Stripe customer",
        trialDevice: "Trial tied to a Mac",
        subscription: "Subscription",
        trial: "Trial",
        cancellation: "Why they cancelled",
      },
      usageTitle: "This month",
      usage: { hours: "Meeting hours", tokens: "AI tokens", accountTokens: "AI outside meetings", audio: "Transcribed audio" },
      timelineTitle: "Timeline",
      timelineNote: "Built from the account's current dates; past subscription changes aren't stored.",
      meetingsTitle: "Meetings",
      meetingColumns: {
        started: "Started",
        kind: "Plan",
        state: "Status",
        duration: "Length",
        audio: "Audio",
        tokens: "Tokens",
        notes: "Notes",
        problem: "What went wrong",
      },
      noMeetings: "No meetings yet.",
      reportsTitle: "Reports from this account",
      noReports: "No reports.",
    },
    operations: {
      kpis: {
        open: "Meetings live now",
        unended: "Never ended, 7 days",
        reservations: "Usage reservations",
        deepgram: "Unsettled live transcripts",
        webhook: "Stripe webhook",
        reports: "Reports, 7 days",
      },
      openTitle: "Live meetings",
      openColumns: { user: "Account", kind: "Plan", started: "Started", endsBy: "Ends by", notes: "Notes" },
      noOpen: "No meetings are live right now.",
      stripeTitle: "Stripe events, 7 days",
      stripeColumns: { type: "Event", count: "Count" },
      noStripe: "No Stripe events in the last 7 days.",
      crashesTitle: "Latest crash reports",
      noCrashes: "No crash reports.",
    },
    insights: {
      problemsTitle: "Problems",
      problemsColumns: { problem: "Problem", last7: "7 days", last30: "30 days" },
      noProblems: "No refusals, service errors or server errors in the last 30 days.",
      funnelTitle: "Funnel, last 30 days",
      funnelColumns: { step: "Step", count: "People", fromPrevious: "Of previous step", lost: "Lost" },
      funnelNote:
        "Downloads count each network once a day. The other steps follow the accounts created in the last 30 days and aren't nested: someone can subscribe without a meeting. “First note” counts only meetings held since the server began tracking finished notes.",
      sourcesTitle: "Downloads by button, 30 days",
      sourceColumns: { source: "Button", count: "Downloads" },
      referrersTitle: "Downloads by referring site, 30 days",
      referrerColumns: { host: "Site", count: "Downloads" },
      noDownloads: "No downloads with a source yet.",
      downloadsNote: "Visitors to the website itself are in Cloudflare Web Analytics.",
      cancellationsTitle: "Why people cancel",
      cancellationColumns: { reason: "Reason", count: "Cancellations" },
      noCancellations: "No cancellation reasons yet. They appear once the cancellation reason form is on in Stripe's customer portal.",
      recentCancellationsTitle: "Latest cancellations",
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
