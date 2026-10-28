// Sitenin Türkçe ve İngilizce metinleri (yasal metinler hariç: onlar src/legal/ altındaki bileşenlerde).
import type { Lang } from "./routes";

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
    readonly privacy: string;
    readonly terms: string;
  };
  readonly downloadCta: string;
  readonly languageLabel: string;
  readonly price: string;
  readonly perMonth: string;
  readonly offer: string;
  readonly requirementsShort: string;
  readonly taxNote: string;
  readonly footer: {
    readonly tagline: string;
    readonly product: string;
    readonly account: string;
    readonly legal: string;
    readonly sourceCode: string;
    readonly fontLicense: string;
    readonly copyright: string;
  };
  readonly draftBanner: string;
  readonly lastUpdated: string;
  /** Dile özgü olmayan adreslerin (kök, Stripe ve e-posta dönüşleri) dil seçimi. */
  readonly chooseLanguage: string;
}

/** Ana sayfa. */
export interface HomeCopy {
  readonly meta: PageMeta;
  readonly eyebrow: string;
  readonly title: string;
  readonly lead: string;
  readonly secondaryCta: string;
  readonly mock: {
    readonly listening: string;
    readonly meetingTitle: string;
    readonly meetingMeta: string;
    readonly tasksTitle: string;
    readonly tasks: readonly string[];
    readonly decisionsTitle: string;
    readonly decision: string;
  };
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
  readonly included: readonly string[];
  readonly startFree: string;
  readonly subscribe: string;
  readonly limitsTitle: string;
  readonly limits: readonly TitledText[];
  readonly taxTitle: string;
  readonly taxText: string;
  readonly faq: readonly Faq[];
}

/** İndirme sayfası. */
export interface DownloadCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly lead: string;
  readonly button: string;
  /** Sürüm etiketi ("Sürüm" + numara). */
  readonly versionLabel: string;
  readonly buttonNote: string;
  readonly requirementsTitle: string;
  readonly requirements: readonly TitledText[];
  readonly installTitle: string;
  readonly installSteps: readonly TitledText[];
  readonly updatesTitle: string;
  readonly updatesText: string;
  readonly releaseNotes: string;
  readonly developerTitle: string;
  readonly developerText: string;
}

/** Giriş sayfası ve e-posta bağlantısı sayfası. */
export interface SignInCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly lead: string;
  readonly apple: string;
  readonly or: string;
  readonly emailLabel: string;
  readonly emailPlaceholder: string;
  readonly emailSubmit: string;
  readonly emailHelp: string;
  readonly turnstileLabel: string;
  readonly sentTitle: string;
  readonly sentText: string;
  readonly sentAgain: string;
  readonly legal: string;
  readonly noScript: string;
  readonly linkMeta: PageMeta;
  readonly linkWorking: string;
  readonly linkFailedTitle: string;
  readonly linkRetry: string;
  /** Giriş sayfası uygulamadan açıldığında. */
  readonly appNote: string;
  /** E-posta bağlantısı uygulamaya iletilirken. */
  readonly linkApp: string;
  readonly linkAppHelp: string;
  readonly linkAppOpen: string;
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
  readonly backHome: string;
  readonly noScript: string;
}

/** 404 sayfası (iki dil birlikte gösterilir). */
export interface NotFoundCopy {
  readonly title: string;
  readonly text: string;
  readonly home: string;
}

/** Bir dilin tüm metinleri. */
export interface Copy {
  readonly common: CommonCopy;
  readonly home: HomeCopy;
  readonly pricing: PricingCopy;
  readonly download: DownloadCopy;
  readonly signIn: SignInCopy;
  readonly account: AccountCopy;
  readonly notFound: NotFoundCopy;
  readonly privacyMeta: PageMeta;
  readonly termsMeta: PageMeta;
}

const tr: Copy = {
  common: {
    skipLink: "İçeriğe geç",
    homeLabel: "AI-Notepad ana sayfa",
    navLabel: "Ana menü",
    nav: { features: "Özellikler", pricing: "Fiyat", download: "İndir", signIn: "Giriş yap", account: "Hesabım", privacy: "Gizlilik politikası", terms: "Kullanım şartları" },
    downloadCta: "Mac için indir",
    languageLabel: "Dil",
    price: "5,99 $",
    perMonth: "/ ay",
    offer: "3 toplantı ücretsiz, sonra aylık 5,99 $",
    requirementsShort: "macOS 26 · Apple silicon",
    taxNote: "KDV dahil değildir; vergiler ödeme sırasında hesaplanır.",
    footer: {
      tagline: "Toplantılarını dinler, notunu yazar.",
      product: "Ürün",
      account: "Hesap",
      legal: "Yasal",
      sourceCode: "Kaynak kod",
      fontLicense: "Inter yazı tipi lisansı",
      copyright: "© 2026 AI-Notepad. Açık kaynak, Apache 2.0.",
    },
    draftBanner: "Taslak — yayından önce hukuken gözden geçirilmeli",
    lastUpdated: "Son güncelleme",
    chooseLanguage: "Dil seç",
  },
  home: {
    meta: {
      title: "AI-Notepad — Toplantılarını dinler, notunu yazar",
      description:
        "Mac için toplantı not defteri: konuşmayı canlı yazıya döker, istersen çevirir, toplantı bitince önce senin görevlerinle başlayan notu yazar. 3 toplantı ücretsiz.",
    },
    eyebrow: "Mac için toplantı not defteri",
    title: "Toplantılarını dinler, notunu yazar.",
    lead: "AI-Notepad konuşmayı canlı yazıya döker, istersen anında çevirir ve toplantı biter bitmez notunu hazırlar: önce sana düşen görevler, sonra kararlar ve özet. Toplantıya bot katılmaz, anahtar gerekmez.",
    secondaryCta: "Fiyatı gör",
    mock: {
      listening: "Dinliyor",
      meetingTitle: "Ürün haftalığı",
      meetingMeta: "Bugün · 42 dk · 4 kişi",
      tasksTitle: "Senin görevlerin",
      tasks: ["Beta sürüm notlarını cumaya kadar yaz", "Ayşe'ye fiyat tablosunu gönder", "Destek ekibiyle çarşamba görüşmesi ayarla"],
      decisionsTitle: "Kararlar",
      decision: "Beta 14 Kasım'da açılıyor.",
    },
    library: {
      label: "Son toplantılar",
      meetings: [
        { title: "Müşteri görüşmesi · Nordia", meta: "Dün · 3 görev" },
        { title: "Tasarım incelemesi", meta: "Pazartesi · 5 görev" },
        { title: "Birebir: Elif", meta: "Geçen hafta · 2 görev" },
        { title: "Yatırımcı güncellemesi", meta: "Ekim · 4 görev" },
      ],
    },
    featuresEyebrow: "Özellikler",
    featuresTitle: "Sen konuşmaya odaklan, kaydı o tutsun.",
    featuresLead: "Toplantı sırasında yanında, toplantıdan sonra elinde: yapılacaklar, kararlar ve her şeyin aranabilir kaydı.",
    features: {
      live: {
        title: "Canlı metin ve çeviri",
        text: "Konuşulan her cümle birkaç saniye içinde ekranda. Toplantı başka bir dildeyse yanında kendi dilindeki çevirisi akar. Canlı metin Mac'inde üretilir.",
        original: "We should open the beta on the fourteenth.",
        translation: "Betayı on dördünde açmalıyız.",
      },
      tasks: {
        title: "Önce görevler",
        text: "Toplantı bitince not hazır. En üstte sana düşen işler ve kimin neyi ne zamana yapacağı; sonra kararlar, özet ve terimler. Görevleri işaretle ya da Anımsatıcılar'a gönder.",
        sample: ["Sürüm notlarını yaz · Cuma", "Fiyat tablosunu gönder · Bugün"],
      },
      missed: {
        title: "“Ne kaçırdım?”",
        text: "Bir an dalıp mı gittin? Tek tıkla son dakikaların kısa özeti gelir; toplantıyı bölmeden yetişirsin.",
        button: "Ne kaçırdım?",
        answer: "Son 5 dakikada: beta tarihi 14 Kasım'a çekildi, sürüm notları sende.",
      },
      ask: {
        title: "Toplantılarına sor",
        text: "Tüm notların ve metinlerin üzerinde soru sor. Yanıt, kaynak toplantıların bağlantılarıyla gelir.",
        question: "Bütçe hakkında ne karar verdik?",
        source: "Kaynak: Yatırımcı güncellemesi, Ürün haftalığı",
      },
      integrations: {
        title: "Entegrasyonlar",
        text: "Notu ve görevleri gittiği yere gönder: Notion, Slack, Microsoft Teams, Discord ve Zoom; görevler Linear ya da Jira'ya. Anahtar yapıştırmadan, resmi girişleriyle.",
      },
      privacy: {
        title: "Gizlilik",
        text: "Ses yalnızca yazıya dökülmek için işlenir, sunucularımızda saklanmaz. Notların ve kayıtların cihazında kalır. Toplantıya bot katılmaz.",
        badge: "Ses saklanmaz",
      },
    },
    stepsTitle: "Üç adımda",
    steps: [
      { title: "İndir ve giriş yap", text: "DMG'yi indir, AI-Notepad'i Uygulamalar'a sürükle, Apple ya da e-postanla giriş yap." },
      { title: "Dinlemeye başla", text: "Toplantı başlarken tek tık. Zoom, Meet, Teams ya da yüz yüze; senin sesin ve karşı tarafın sesi." },
      { title: "Notunu al", text: "Toplantı biter, not hazır: önce görevler, sonra kararlar ve özet. Paylaş ya da gönder." },
    ],
    pricingTitle: "Tek plan, sade fiyat.",
    pricingLead: "İlk 3 toplantı ücretsiz, kart gerekmez. Sonra aylık 5,99 $; istediğin an iptal.",
    pricingCta: "Fiyat ayrıntıları",
    faqTitle: "Sık sorulanlar",
    faq: [
      {
        question: "Ücretsiz deneme nasıl işliyor?",
        answer: "İlk 3 toplantı ücretsizdir ve kart gerekmez. Deneme toplantıları en çok 90 dakikadır. Sonrasında aylık 5,99 $ abonelikle devam edersin.",
      },
      {
        question: "Toplantıya bot katılıyor mu?",
        answer: "Hayır. AI-Notepad Mac'inin sesini ve mikrofonunu dinler; katılımcılar bir bot görmez. Kayda başlamadan önce katılımcılara haber vermeni hatırlatır.",
      },
      {
        question: "Sesim nereye gidiyor?",
        answer: "Canlı metin Mac'inde üretilir. Toplantı bitince ses, konuşmacıları ayırmak ve son metni çıkarmak için sunucumuz üzerinden ElevenLabs'e iletilir; not ve çeviri için metin Anthropic'in Claude modeline gider. Sunucumuz sesi ve metni saklamaz, yalnızca süreyi sayar.",
      },
      {
        question: "Hangi dilleri destekliyor?",
        answer: "Türkçe, İngilizce, Fince ve onlarca dilde yazıya döker. Notun ve çevirinin dilini sen seçersin.",
      },
      {
        question: "Aboneliği nasıl iptal ederim?",
        answer: "Hesap sayfasındaki “Aboneliği yönet” düğmesiyle, Stripe'ın güvenli portalından. İptal ettiğinde ödenmiş dönemin sonuna kadar kullanmaya devam edersin.",
      },
      {
        question: "Kendi API anahtarlarımı kullanabilir miyim?",
        answer: "Evet. Açık kaynak geliştirici sürümü kendi anahtarlarınla ve tüm motorlarla ücretsiz çalışır; kaynak kodu GitHub'dadır.",
      },
    ],
    finalTitle: "Bir sonraki toplantın notunu o yazsın.",
    finalLead: "3 toplantı ücretsiz. Kurulum bir dakika.",
  },
  pricing: {
    meta: {
      title: "Fiyat — AI-Notepad",
      description: "Tek plan: aylık 5,99 $. İlk 3 toplantı ücretsiz, ayda 10 saate kadar, toplantı başına en çok 4 saat, istediğin an iptal.",
    },
    title: "Tek plan, sade fiyat.",
    lead: "Önce 3 toplantıyı ücretsiz dene. Beğenirsen aylık 5,99 $ ile devam et.",
    planName: "AI-Notepad",
    planTagline: "Canlı metinden göreve kadar her şey.",
    included: [
      "İlk 3 toplantı ücretsiz, kart gerekmez",
      "Ayda 10 saate kadar toplantı (adil kullanım)",
      "Toplantı başına en çok 4 saat",
      "Canlı metin, canlı çeviri, “Ne kaçırdım?” ve Sor",
      "Toplantı sonu notu: görevler, kararlar, özet ve konuşmacı ayırma",
      "Notion, Slack, Linear, Jira ve daha fazlasına gönderme",
      "İstediğin an iptal",
    ],
    startFree: "Ücretsiz başla",
    subscribe: "Abone ol",
    limitsTitle: "Sınırlar, açıkça",
    limits: [
      { title: "Deneme", text: "3 toplantı, her biri en çok 90 dakika. Yeni hesap açmak deneme hakkını sıfırlamaz." },
      { title: "Aylık 10 saat", text: "Adil kullanım sınırı. Her ayın ilk günü (UTC) sıfırlanır. Sınıra gelince ay başına kadar yeni toplantı başlatılamaz; uygulama bunu açıkça söyler." },
      { title: "Toplantı başına 4 saat", text: "Uzun atölyeler ve dersler için yeterli; daha uzun toplantılar 4 saatte kapanır." },
      { title: "İptal", text: "Hesap sayfasından Stripe portalına geçip tek tıkla iptal edersin. Ödenmiş dönemin sonuna kadar kullanırsın." },
    ],
    taxTitle: "Vergiler",
    taxText:
      "Fiyatlar ABD doları cinsindendir ve KDV dahil değildir. AB'de KDV gibi vergiler bulunduğun ülkeye göre ödeme sırasında Stripe Tax ile hesaplanır ve ödemeden önce ödeme sayfasında ayrıca gösterilir. Kart bilgilerin Stripe'ta kalır, bize hiç gelmez.",
    faq: [
      {
        question: "Deneme bitince ne olur?",
        answer: "Uygulama sana haber verir. Abone olana kadar yeni toplantı başlatılamaz; eski notların ve kayıtların cihazında kalır ve okunabilir.",
      },
      {
        question: "Ödeme alınamazsa?",
        answer: "Stripe ödemeyi birkaç gün yeniden dener. Bu sürede kullanmaya devam edersin; kartını “Aboneliği yönet”ten güncelleyebilirsin.",
      },
      {
        question: "Kendi anahtarlarımla ücretsiz kullanabilir miyim?",
        answer: "Evet. Açık kaynak geliştirici sürümü kendi Deepgram, ElevenLabs ve Anthropic anahtarlarınla ya da tamamen cihaz üstü motorlarla çalışır.",
      },
    ],
  },
  download: {
    meta: {
      title: "İndir — AI-Notepad",
      description: "AI-Notepad'i Mac'ine indir: macOS 26 ve Apple silicon. İlk 3 toplantı ücretsiz.",
    },
    title: "AI-Notepad'i indir",
    lead: "Mac için. İlk 3 toplantı ücretsiz, kart gerekmez.",
    button: "DMG'yi indir",
    versionLabel: "Sürüm",
    buttonNote: "GitHub Releases'teki son sürüm. Developer ID ile imzalı ve Apple tarafından onaylanmış (notarized).",
    requirementsTitle: "Sistem gereksinimleri",
    requirements: [
      { title: "macOS 26", text: "ya da daha yenisi" },
      { title: "Apple silicon", text: "M1 ve sonrası işlemciler" },
      { title: "İnternet", text: "not, çeviri ve konuşmacı ayırma için" },
      { title: "~1 GB boş alan", text: "cihaz üstü konuşma modeli için" },
    ],
    installTitle: "Mac'e kurulum",
    installSteps: [
      { title: "DMG'yi aç", text: "İndirilen AI-Notepad DMG dosyasına çift tıkla." },
      { title: "Uygulamalar'a sürükle", text: "AI-Notepad simgesini Uygulamalar klasörüne sürükle, sonra DMG'yi çıkar." },
      { title: "Aç", text: "Uygulamalar'dan AI-Notepad'i aç. macOS internetten indirilen uygulamayı açmak istediğini sorarsa “Aç”ı seç." },
      { title: "İzinleri ver", text: "Kurulum sayfası mikrofon ve sistem sesi izinlerini ister. Sonradan Sistem Ayarları › Gizlilik ve Güvenlik'ten değiştirebilirsin." },
      { title: "Giriş yap", text: "Apple ya da e-postanla giriş yap ve ilk toplantını başlat. İlk 3 toplantı ücretsiz." },
    ],
    updatesTitle: "Güncellemeler",
    updatesText: "Yeni sürümler uygulamanın içinden gelir; onayınla indirilip kurulur.",
    releaseNotes: "Sürüm notları",
    developerTitle: "Kendi anahtarlarınla mı?",
    developerText: "Açık kaynak geliştirici sürümü kendi API anahtarlarınla ya da tamamen cihaz üstü motorlarla ücretsiz çalışır. Aynı sürüm sayfasında ayrı bir DMG olarak yer alır.",
  },
  signIn: {
    meta: { title: "Giriş yap — AI-Notepad", description: "AI-Notepad hesabına Apple ile ya da e-posta bağlantısıyla giriş yap." },
    title: "Giriş yap",
    lead: "Hesabını ve aboneliğini yönetmek için. Mac uygulamasında da aynı hesapla giriş yaparsın.",
    apple: "Apple ile giriş yap",
    or: "ya da",
    emailLabel: "E-posta adresi",
    emailPlaceholder: "ad@ornek.com",
    emailSubmit: "Giriş bağlantısı gönder",
    emailHelp: "Tek kullanımlık, 15 dakika geçerli bir bağlantı göndeririz. Parola yok.",
    turnstileLabel: "Güvenlik doğrulaması",
    sentTitle: "E-postanı kontrol et",
    sentText: "Bu adres kayıtlıysa ya da yeni bir hesap açılabiliyorsa giriş bağlantısı birazdan gelir. Bağlantı 15 dakika geçerlidir ve bir kez kullanılır.",
    sentAgain: "Başka bir adres dene",
    legal: "Giriş yaparak Kullanım şartlarını ve Gizlilik politikasını kabul etmiş olursun.",
    noScript: "Giriş için JavaScript gerekir.",
    linkMeta: { title: "Giriş yapılıyor — AI-Notepad", description: "E-posta bağlantısıyla giriş." },
    linkWorking: "Giriş yapılıyor…",
    linkFailedTitle: "Giriş yapılamadı",
    linkRetry: "Yeni bağlantı iste",
    appNote: "AI-Notepad uygulaması için giriş: e-postadaki bağlantıyı bu tarayıcıda açınca uygulama açılır ve girişi tamamlar.",
    linkApp: "Uygulamaya dönülüyor…",
    linkAppHelp: "AI-Notepad açılmadıysa aşağıdaki düğmeye bas.",
    linkAppOpen: "AI-Notepad'i aç",
  },
  account: {
    meta: { title: "Hesabım — AI-Notepad", description: "AI-Notepad hesabın: plan, deneme, aylık kullanım ve abonelik." },
    title: "Hesabın",
    loading: "Hesap bilgilerin yükleniyor…",
    paymentDone: "Ödemen alındı, teşekkürler. Aboneliğin birkaç saniye içinde burada görünür.",
    planLabel: "Plan",
    trialLabel: "Ücretsiz deneme",
    hoursLabel: "Bu ayki kullanım",
    hoursNote: "Her ayın ilk günü (UTC) sıfırlanır.",
    renewalLabel: "Abonelik",
    subscribe: "Abone ol",
    subscribeNote: "Aylık 5,99 $. KDV dahil değildir; vergiler ödeme sırasında hesaplanır.",
    manage: "Aboneliği yönet",
    signOut: "Çıkış yap",
    dangerTitle: "Hesabı sil",
    dangerText:
      "Hesabın, oturumların, cihaz kayıtların ve kullanım geçmişin kalıcı olarak silinir; bitmemiş aboneliğin hemen iptal edilir. Notların ve kayıtların cihazında kalır. Faturalar yasal zorunluluk nedeniyle Stripe'ta saklanır.",
    deleteButton: "Hesabı sil",
    dialogTitle: "Hesabın silinsin mi?",
    dialogText: "Bu işlem geri alınamaz. Aboneliğin varsa hemen iptal edilir ve kalan süre iade edilmez.",
    confirmWord: "SİL",
    confirmLabel: "Onaylamak için SİL yaz",
    cancel: "Vazgeç",
    confirmDelete: "Hesabımı kalıcı olarak sil",
    deletedTitle: "Hesabın silindi",
    deletedText: "Sunucumuzdaki hesap verilerin silindi. Mac'indeki notların ve kayıtların yerinde duruyor.",
    backHome: "Ana sayfaya dön",
    noScript: "Hesap sayfası için JavaScript gerekir.",
  },
  notFound: { title: "Bu sayfa yok.", text: "Adres yanlış yazılmış ya da sayfa taşınmış olabilir.", home: "Ana sayfa" },
  privacyMeta: {
    title: "Gizlilik politikası — AI-Notepad",
    description: "AI-Notepad hangi verileri neden işler, kimlerle paylaşır, ne kadar saklar ve haklarını nasıl kullanırsın.",
  },
  termsMeta: { title: "Kullanım şartları — AI-Notepad", description: "AI-Notepad abonelik sürümünün kullanım şartları." },
};

const en: Copy = {
  common: {
    skipLink: "Skip to content",
    homeLabel: "AI-Notepad home",
    navLabel: "Main menu",
    nav: { features: "Features", pricing: "Pricing", download: "Download", signIn: "Sign in", account: "Account", privacy: "Privacy policy", terms: "Terms of use" },
    downloadCta: "Download for Mac",
    languageLabel: "Language",
    price: "$5.99",
    perMonth: "/ month",
    offer: "3 meetings free, then $5.99 a month",
    requirementsShort: "macOS 26 · Apple silicon",
    taxNote: "Excludes VAT; taxes are calculated at checkout.",
    footer: {
      tagline: "Listens to your meetings, writes your notes.",
      product: "Product",
      account: "Account",
      legal: "Legal",
      sourceCode: "Source code",
      fontLicense: "Inter font licence",
      copyright: "© 2026 AI-Notepad. Open source, Apache 2.0.",
    },
    draftBanner: "Draft — must be legally reviewed before publication",
    lastUpdated: "Last updated",
    chooseLanguage: "Choose a language",
  },
  home: {
    meta: {
      title: "AI-Notepad — Listens to your meetings, writes your notes",
      description:
        "A meeting notepad for Mac: a live transcript, optional live translation, and a note that starts with your tasks the moment the meeting ends. 3 meetings free.",
    },
    eyebrow: "A meeting notepad for Mac",
    title: "Listens to your meetings, writes your notes.",
    lead: "AI-Notepad transcribes the conversation live, translates it if you like, and has your note ready when the meeting ends: your tasks first, then decisions and a summary. No bot joins the call, no API keys needed.",
    secondaryCta: "See pricing",
    mock: {
      listening: "Listening",
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
        text: "Send notes and tasks where they belong: Notion, Slack, Microsoft Teams, Discord and Zoom; tasks to Linear or Jira. Through their official sign-ins, no pasted keys.",
      },
      privacy: {
        title: "Privacy",
        text: "Audio is processed only to be transcribed and is not stored on our servers. Your notes and recordings stay on your devices. No bot joins the call.",
        badge: "Audio not stored",
      },
    },
    stepsTitle: "In three steps",
    steps: [
      { title: "Download and sign in", text: "Download the DMG, drag AI-Notepad to Applications and sign in with Apple or your email." },
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
        answer: "No. AI-Notepad listens to your Mac's audio and microphone; participants never see a bot. It reminds you to tell participants before you start recording.",
      },
      {
        question: "Where does my audio go?",
        answer: "The live transcript is produced on your Mac. When the meeting ends, the audio is passed through our server to ElevenLabs to separate speakers and produce the final transcript; for notes and translation the text goes to Anthropic's Claude model. Our server does not store audio or text; it only counts the duration.",
      },
      {
        question: "Which languages are supported?",
        answer: "English, Finnish, Turkish and dozens more. You choose the language of your notes and translations.",
      },
      {
        question: "How do I cancel?",
        answer: "With “Manage subscription” on your account page, in Stripe's secure portal. After cancelling you keep access until the end of the period you paid for.",
      },
      {
        question: "Can I use my own API keys?",
        answer: "Yes. The open-source developer edition runs free with your own keys and every engine; the source code is on GitHub.",
      },
    ],
    finalTitle: "Let it write the note for your next meeting.",
    finalLead: "3 meetings free. Set up in a minute.",
  },
  pricing: {
    meta: {
      title: "Pricing — AI-Notepad",
      description: "One plan: $5.99 a month. First 3 meetings free, up to 10 hours a month, up to 4 hours per meeting, cancel anytime.",
    },
    title: "One plan. Simple pricing.",
    lead: "Try 3 meetings for free. If you like it, continue for $5.99 a month.",
    planName: "AI-Notepad",
    planTagline: "Everything from live transcript to tasks.",
    included: [
      "First 3 meetings free, no card needed",
      "Up to 10 hours of meetings a month (fair use)",
      "Up to 4 hours per meeting",
      "Live transcript, live translation, “What did I miss?” and Ask",
      "Post-meeting note: tasks, decisions, summary and speaker separation",
      "Send to Notion, Slack, Linear, Jira and more",
      "Cancel anytime",
    ],
    startFree: "Start free",
    subscribe: "Subscribe",
    limitsTitle: "The limits, plainly",
    limits: [
      { title: "Trial", text: "3 meetings, each up to 90 minutes. Opening a new account does not reset the trial." },
      { title: "10 hours a month", text: "A fair-use limit that resets on the first day of each month (UTC). At the limit you can't start new meetings until the month resets; the app tells you clearly." },
      { title: "4 hours per meeting", text: "Enough for long workshops and lectures; longer meetings close at 4 hours." },
      { title: "Cancelling", text: "Go from your account page to Stripe's portal and cancel in one click. You keep access until the end of the paid period." },
    ],
    taxTitle: "Taxes",
    taxText:
      "Prices are in US dollars and exclude VAT. Taxes such as EU VAT are calculated at checkout by Stripe Tax based on your location and shown separately on the checkout page before you pay. Your card details stay with Stripe and never reach us.",
    faq: [
      {
        question: "What happens when the trial ends?",
        answer: "The app lets you know. You can't start new meetings until you subscribe; your existing notes and recordings stay on your devices and remain readable.",
      },
      {
        question: "What if a payment fails?",
        answer: "Stripe retries the payment over a few days. You keep access meanwhile and can update your card under “Manage subscription”.",
      },
      {
        question: "Can I use it free with my own keys?",
        answer: "Yes. The open-source developer edition works with your own Deepgram, ElevenLabs and Anthropic keys, or entirely with on-device engines.",
      },
    ],
  },
  download: {
    meta: {
      title: "Download — AI-Notepad",
      description: "Download AI-Notepad for your Mac: macOS 26 and Apple silicon. First 3 meetings free.",
    },
    title: "Download AI-Notepad",
    lead: "For Mac. Your first 3 meetings are free, no card needed.",
    button: "Download the DMG",
    versionLabel: "Version",
    buttonNote: "The latest release on GitHub Releases. Signed with a Developer ID and notarized by Apple.",
    requirementsTitle: "System requirements",
    requirements: [
      { title: "macOS 26", text: "or later" },
      { title: "Apple silicon", text: "M1 or later" },
      { title: "Internet", text: "for notes, translation and speaker separation" },
      { title: "~1 GB free space", text: "for the on-device speech model" },
    ],
    installTitle: "Installing on your Mac",
    installSteps: [
      { title: "Open the DMG", text: "Double-click the AI-Notepad DMG you downloaded." },
      { title: "Drag to Applications", text: "Drag the AI-Notepad icon into the Applications folder, then eject the DMG." },
      { title: "Open it", text: "Open AI-Notepad from Applications. If macOS asks whether to open an app downloaded from the internet, choose “Open”." },
      { title: "Grant permissions", text: "The setup page asks for microphone and system-audio permissions. You can change them later in System Settings › Privacy & Security." },
      { title: "Sign in", text: "Sign in with Apple or your email and start your first meeting. The first 3 are free." },
    ],
    updatesTitle: "Updates",
    updatesText: "New versions arrive inside the app and are installed with your approval.",
    releaseNotes: "Release notes",
    developerTitle: "Prefer your own keys?",
    developerText: "The open-source developer edition runs free with your own API keys or entirely with on-device engines. It is a separate DMG on the same release page.",
  },
  signIn: {
    meta: { title: "Sign in — AI-Notepad", description: "Sign in to your AI-Notepad account with Apple or an email link." },
    title: "Sign in",
    lead: "To manage your account and subscription. You use the same account in the Mac app.",
    apple: "Sign in with Apple",
    or: "or",
    emailLabel: "Email address",
    emailPlaceholder: "name@example.com",
    emailSubmit: "Email me a sign-in link",
    emailHelp: "We send a single-use link that is valid for 15 minutes. No password.",
    turnstileLabel: "Security check",
    sentTitle: "Check your email",
    sentText: "If this address can sign in, a link is on its way. It is valid for 15 minutes and works once.",
    sentAgain: "Use a different address",
    legal: "By signing in you accept the Terms of use and the Privacy policy.",
    noScript: "Signing in needs JavaScript.",
    linkMeta: { title: "Signing in — AI-Notepad", description: "Sign in with an email link." },
    linkWorking: "Signing you in…",
    linkFailedTitle: "Couldn't sign you in",
    linkRetry: "Request a new link",
    appNote: "Signing in to the AI-Notepad app: open the link from your email in this browser and the app opens and finishes signing in.",
    linkApp: "Returning to the app…",
    linkAppHelp: "If AI-Notepad didn't open, press the button below.",
    linkAppOpen: "Open AI-Notepad",
  },
  account: {
    meta: { title: "Account — AI-Notepad", description: "Your AI-Notepad account: plan, trial, monthly usage and subscription." },
    title: "Your account",
    loading: "Loading your account…",
    paymentDone: "Payment received, thank you. Your subscription will show up here within a few seconds.",
    planLabel: "Plan",
    trialLabel: "Free trial",
    hoursLabel: "Usage this month",
    hoursNote: "Resets on the first day of each month (UTC).",
    renewalLabel: "Subscription",
    subscribe: "Subscribe",
    subscribeNote: "$5.99 a month. Excludes VAT; taxes are calculated at checkout.",
    manage: "Manage subscription",
    signOut: "Sign out",
    dangerTitle: "Delete account",
    dangerText:
      "Your account, sessions, device registrations and usage history are permanently deleted, and any unfinished subscription is cancelled immediately. Your notes and recordings stay on your devices. Invoices are kept at Stripe as required by law.",
    deleteButton: "Delete account",
    dialogTitle: "Delete your account?",
    dialogText: "This can't be undone. If you have a subscription, it is cancelled immediately and the remaining time is not refunded.",
    confirmWord: "DELETE",
    confirmLabel: "Type DELETE to confirm",
    cancel: "Cancel",
    confirmDelete: "Permanently delete my account",
    deletedTitle: "Your account was deleted",
    deletedText: "Your account data on our server is gone. The notes and recordings on your Mac are still there.",
    backHome: "Back to the home page",
    noScript: "The account page needs JavaScript.",
  },
  notFound: { title: "This page doesn't exist.", text: "The address may be mistyped, or the page has moved.", home: "Home" },
  privacyMeta: {
    title: "Privacy policy — AI-Notepad",
    description: "What data AI-Notepad processes and why, who it is shared with, how long it is kept and how to use your rights.",
  },
  termsMeta: { title: "Terms of use — AI-Notepad", description: "Terms of use for the AI-Notepad subscription edition." },
};

/** Dile göre metinler. */
export const copy: Readonly<Record<Lang, Copy>> = { tr, en };
