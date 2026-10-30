// Fince tanıtım sayfasının (`/fi`) metinleri. İngilizce metnin birebir çevirisi değildir: Finlandiya pazarına göre
// yazılmıştır (Teams/Zoom, suomi, EU-tietosuoja, ALV). Tip `HomeCopy`/`CommonCopy` olduğundan eksik metin derlemeyi
// durdurur. Ürün adı ve işletme bilgisi yine tek kaynaktan gelir (config.ts, legal/operator.ts).
import { cardStatementDescriptor, productName } from "./config";
import type { CommonCopy, HomeCopy } from "./copy";
import { operator } from "./legal/operator";

/** Sayfanın başlığındaki tek satır (paylaşım kartı ve alt bilgi de kullanır). */
const tagline: string = "Kuuntelee kokouksesi, kirjoittaa muistiinpanosi.";

/** Fince arayüz metinleri: üst çubuk, alt bilgi ve ana sayfanın ortak düğmeleri. */
export const commonFi: CommonCopy = {
  skipLink: "Siirry sisältöön",
  homeLabel: `${productName} etusivu`,
  navLabel: "Päävalikko",
  nav: {
    features: "Ominaisuudet",
    pricing: "Hinnat",
    download: "Lataa",
    signIn: "Kirjaudu",
    account: "Tili",
    contact: "Ota yhteyttä",
    privacy: "Tietosuoja",
    terms: "Käyttöehdot",
    compare: "Vertailu",
    blog: "Blogi",
    mcp: "MCP tekoälysovelluksille",
  },
  downloadCta: "Lataa Macille",
  headerDownload: "Lataa",
  darkMode: "Tumma tila",
  // Hinta pysyy dollarina (checkout veloittaa dollareina); structured-data.ts tämän muodon lukee.
  price: "$5.99",
  perMonth: "/ kk",
  yearlyPrice: "$49",
  offer: "3 kokousta tai 7 päivää ilmaiseksi, sitten 5,99 $ kuussa tai 49 $ vuodessa, verot sisältyvät",
  requirementsShort: "macOS 15 tai uudempi · Apple silicon",
  renewalNote: "Jatkuu automaattisesti kuukausittain tai vuosittain, kunnes peruutat. Voit peruuttaa milloin tahansa.",
  ogImageAlt: `${productName}-logo ja tunnuslause ”${tagline}” pehmeällä pastelligradientilla pienen ääniaallon yläpuolella.`,
  footer: {
    tagline,
    product: "Tuote",
    learn: "Lue lisää",
    account: "Tili",
    company: "Yritys",
    fontLicense: "Inter-fontin lisenssi",
    cookies: "Evästeet",
    pullThanks: "Kiitos, kun kuuntelit.",
    copyright: `© 2026 ${operator.name}`,
  },
  lastUpdated: "Päivitetty",
  contents: "Tällä sivulla",
};

/** Kokousmuistiinpanoista kertova Fince sivu. */
export const homeFi: HomeCopy = {
  meta: {
    title: `${productName} — kokousmuistiinpanot Macilla, ilman bottia`,
    description:
      "Kokousmuistiinpanot Macille: reaaliaikainen litterointi, käännös ja valmis muistiinpano heti kokouksen päätyttyä – tehtävät ensimmäisenä. Kokoukseen ei liity bottia. 3 kokousta tai 7 päivää ilmaiseksi.",
  },
  eyebrow: "Kokousmuistiinpanot Macille",
  title: tagline,
  lead: `Kokous on Teamsissa, Zoomissa tai neuvotteluhuoneessa: ${productName} litteroi puheen reaaliajassa, kääntää vieraskieliset puheenvuorot suomeksi ja kirjoittaa kokouksen päätyttyä muistiinpanon, jossa omat tehtäväsi ovat ensimmäisenä. Kokoukseen ei liity bottia, eikä kenenkään muun tarvitse asentaa mitään.`,
  secondaryCta: "Katso hinnat",
  assurances: ["3 kokousta tai 7 päivää ilmaiseksi", "Ei korttitietoja"],
  demo: {
    label: `${productName} tallentaa kokousta ja kirjoittaa muistiinpanoa`,
    listening: "Kuuntelee",
    writing: "Kirjoittaa muistiinpanoa",
    done: "Muistiinpano valmis",
    timerMinutes: "42",
    transcriptTitle: "Litterointi",
    notePending: "Muistiinpanosi ilmestyy tähän, kun kokous päättyy.",
    transcript: [
      { speaker: "Mikko", text: "Avataan beta 14. marraskuuta.", translation: null },
      { speaker: "Sinä", text: "Sopii. Kirjoitan julkaisumuistiinpanot perjantaihin mennessä.", translation: null },
      { speaker: "Alex", text: "Can you send the pricing table to Ayşe?", translation: "Voitko lähettää hinnaston Ayşelle?" },
    ],
    meetingTitle: "Tuotepalaveri",
    meetingMeta: "Tänään · 42 min · 4 henkeä",
    tasksTitle: "Sinun tehtäväsi",
    tasks: ["Kirjoita beta-julkaisun muistiinpanot perjantaihin mennessä", "Lähetä hinnasto Ayşelle", "Sovi keskiviikon puhelu asiakastuen kanssa"],
    decisionsTitle: "Päätökset",
    decision: "Beta avataan 14. marraskuuta.",
    pause: "Keskeytä esittely",
    play: "Toista esittely",
    replay: "Toista esittely alusta",
  },
  launchVideo: {
    eyebrow: "Yhdessä minuutissa",
    title: "Katso se työssä.",
    description: `Minuutin kierros ${productName}-sovelluksessa: litterointi ja käännös kokouksen aikana, muistiinpano jossa tehtävät ovat päällimmäisenä, kysyminen kaikista kokouksista ja muistiinpanojen lähettäminen sinne, missä tiimi työskentelee.`,
    fallback: "Selaimesi ei voi toistaa tätä videota tässä.",
    fallbackLink: "Avaa videotiedosto",
  },
  library: {
    label: "Viimeisimmät kokoukset",
    meetings: [
      { title: "Asiakaspuhelu · Nordia", meta: "Eilen · 3 tehtävää" },
      { title: "Designkatselmus", meta: "Maanantaina · 5 tehtävää" },
      { title: "Kahden kesken: Elif", meta: "Viime viikolla · 2 tehtävää" },
      { title: "Sijoittajapäivitys", meta: "Lokakuu · 4 tehtävää" },
    ],
  },
  showcase: {
    eyebrow: "Sovelluksen sisällä",
    title: "Hiljaa, kun puhut. Järjestyksessä, kun lopetat.",
    lead: "Oikeita kuvakaappauksia sovelluksesta: yksi ikkuna kaikkiin kokouksiisi ja pieni paneeli tallennuksen ajaksi.",
    note: {
      label: "Kokouksen jälkeen",
      title: "Valmis, kun suljet puhelun",
      alt: `Tuotepalaverin muistiinpano ${productName}-sovelluksessa: vasemmalla luettelo viimeisimmistä kokouksista ja kokousotsikon sekä puhumisjärjestyksen alla kolme tehtävää määräaikoineen: julkaisumuistiinpanot perjantaihin mennessä, hinnasto Ayşelle tänään, viikoittainen puhelu asiakastuen kanssa keskiviikkona.`,
    },
    live: {
      label: "Kokouksen aikana",
      title: "Jokainen lause heti, kun se sanotaan",
      alt: `Kuvakaappaus ${productName}-sovelluksen reaaliaikaisesta paneelista suomenkielisen kokouksen aikana: puhujien lauseet ja oma englanninkielinen puheenvuoro litteroituna, sekä painike ”What did I miss?” paneelin alareunassa.`,
    },
    ask: {
      label: "Milloin tahansa myöhemmin",
      title: "Hae kaikista kokouksista",
      alt: `Kysy-sivu ${productName}-sovelluksessa: kysymys ”What did we decide about the budget?” ja vastaus kahdella ranskalaisella viivalla ja numeroiduilla lähteillä, sekä rivi joka kertoo 3 lähteestä kahdessa kokouksessa.`,
    },
    home: {
      label: "Ennen kokousta",
      title: "Yhdellä napsautuksella käyntiin",
      alt: `Kuvakaappaus ${productName}-etusivusta: tervehdys, iso ”Start listening” -painike kielen, oman äänen ja reaaliaikaisen käännöksen valinnoilla, pikavalinnat ja avoimet tehtävät viimeisistä kokouksista.`,
    },
  },
  featuresEyebrow: "Ominaisuudet",
  featuresTitle: "Pysy keskustelussa. Muistiinpanot hoituvat siinä sivussa.",
  featuresLead: "Kokouksen aikana vierelläsi, kokouksen jälkeen käsissäsi: mitä pitää tehdä, mitä päätettiin ja koko keskustelu haettavana.",
  features: {
    live: {
      title: "Litterointi ja käännös livenä",
      text: "Jokainen lause on ruudulla sekunneissa. Jos kokous käydään englanniksi tai ruotsiksi, suomenkielinen käännös kulkee rinnalla – samoin kuin työkaverin puheenvuoro, jonka haluat ymmärtää tarkalleen.",
      original: "Let's open the beta on 14 November.",
      translation: "Avataan beta 14. marraskuuta.",
    },
    tasks: {
      title: "Tehtävät ensin",
      text: "Kun kokous päättyy, muistiinpano on valmis. Tehtäväsi ovat päällimmäisenä: kuka tekee ja mihin mennessä. Sen jälkeen päätökset, yhteenveto ja sanasto. Rastita tehtävä valmiiksi tai lähetä se Remindersiin.",
      sample: ["Julkaisumuistiinpanot · perjantai", "Hinnasto asiakkaalle · tänään"],
    },
    missed: {
      title: "”Mitä minulta meni ohi?”",
      text: "Ajatus katkesi hetkeksi? Yksi napsautus kertoo viimeisten minuuttien olennaiset asiat, eikä kenenkään tarvitse toistaa itseään.",
      button: "Mitä minulta meni ohi?",
      answer: "Viimeisen 5 minuutin aikana: beta siirtyi 14. marraskuuta ja julkaisumuistiinpanot ovat sinulla.",
    },
    ask: {
      title: "Kysy kokouksiltasi",
      text: "Kysy mitä tahansa kaikista muistiinpanoistasi ja litteroinneista. Vastaus tulee lähteiden kanssa, joten näet aina mistä kokouksesta se on peräisin.",
      question: "Mitä sovimme budjetista?",
      source: "Lähteet: Sijoittajapäivitys, Tuotepalaveri",
    },
    followUp: {
      title: "Jatko yhdellä napsautuksella",
      text: "Valmiit ohjeet muuttavat kokouksen seuraavaksi askeleeksi: jatkoviesti, projektisuunnitelma, riskit ja avoimet kysymykset. Tallenna omat ohjeesi niille kysymyksille, jotka toistuvat joka viikko.",
      recipe: "Jatkoviesti",
      subject: "Aihe: Tuotepalaveri, seuraavat askeleet",
      lines: ["Beta avataan 14. marraskuuta.", "Alex: julkaisumuistiinpanot perjantaihin mennessä."],
    },
    templates: {
      title: "Kokousmallit",
      text: "Asiakaspuhelu, kahden kesken, työhaastattelu ja luento saavat kukin muistiinpanon, jossa oikeat asiat ovat ensimmäisenä. Tai kirjoita oma pohjasi.",
      sample: ["Asiakaspuhelu", "Kahden kesken", "Työhaastattelu", "Luento", "Oma pohja"],
    },
  },
  trust: {
    eyebrow: "Tietosuoja",
    title: "Kokouksesi pysyvät sinun.",
    lead: "Tehty keskusteluille, jotka haluat pitää omana tietonasi – suomalaisessa pienyrityksessä, EU:n tietosuojalainsäädännön alla.",
    items: [
      {
        icon: "laptop",
        title: "Tiedot Macillasi",
        text: "Muistiinpanot, litteroinnit ja tallenteet ovat sovelluksessa omalla Macillasi. Ääni lähetetään vain litterointia varten, eivätkä palvelimemme tallenna ääntäsi tai muistiinpanojasi.",
      },
      { icon: "sparkle", title: "Ei tekoälyn koulutusmateriaalina", text: "Kokouksiasi ei käytetä palveluntarjoajiemme mallien kouluttamiseen. Olemme kieltäneet sen kaikkialla, missä se on asetuksissa mahdollista." },
      { icon: "globe", title: "EU-yritys, GDPR", text: `${productName} toimii Suomesta käsin EU:n tietosuojalainsäädännön alla, ja tilitietokantamme sijaitsee EU:ssa.` },
      { icon: "check-circle", title: "Poista milloin haluat", text: "Voit poistaa tilisi verkkosivuilta milloin tahansa: tili poistetaan ja tilaus päättyy samalla." },
    ],
    link: "Lue tietosuojaseloste",
  },
  marqueeLabel: "Toimii niiden työkalujen kanssa, joita jo käytät",
  noteCallouts: {
    dueDate: "Tekijä ja määräaika",
    transcript: "Koko litterointi puhujittain",
  },
  integrations: {
    eyebrow: "Integraatiot",
    title: "Kokouksesi siellä, missä työ tapahtuu.",
    lead: "Lähetä muistiinpano sinne, missä tiimi työskentelee, siirrä tehtävät omaan työkaluusi ja anna tekoälysovellustesi lukea kokouksiasi.",
    notes: {
      title: "Muistiinpanot tiimille",
      text: "Lähetä valmis muistiinpano Notioniin, Apple Notesiin tai kanavalle Slackissa, Microsoft Teamsissa, Discordissa tai Zoomin Team Chatissa; kaikkeen muuhun webhookilla (Zapier, Make, n8n).",
    },
    tasks: {
      title: "Tehtävät omaan työkaluun",
      text: "Muunna tehtäväsi Linear- tai Jira-tiketeiksi tai Apple Remindersiin.",
    },
    ai: {
      title: "Tekoälysovelluksesi MCP:n kautta",
      text: "Claude, Cursor ja VS Code voivat hakea ja lukea kokouksiasi. Yhdistä ne asetuksista yhdellä napsautuksella; ne voivat vain lukea, eivät muuttaa mitään.",
    },
    mcpLink: "Miten MCP toimii",
    files: {
      title: "Tiedostosi ja kalenterisi",
      text: "Tallenna jokainen muistiinpano Markdownina kansioon, esimerkiksi Obsidian-holviin tai iCloud Driveen. Kalenterisi näyttää seuraavan kokouksen ja voi aloittaa tallennuksen, kun kokous alkaa.",
    },
    mcpDemo: {
      label: "Claudessa",
      question: "Mitä lupasin Nordialle viime viikolla?",
      tool: "Haki kokouksistasi",
      answerLead: "27. lokakuun asiakaspuhelussa lupasit:",
      answer: ["Lähettää päivitetyn tarjouksen perjantaihin mennessä", "Jakaa käyttöönoton tarkistuslistan"],
      source: "Asiakaspuhelu · Nordia",
    },
  },
  pricingTitle: "Yksi hinta, kuukausittain tai vuosittain.",
  pricingLead: "Yksi paketti, jossa on kaikki, laskutetaan kuukausittain tai vuosittain. Kokeile omilla kokouksillasi ennen kuin maksat.",
  pricingCta: "Hintatiedot",
  pricingCompare: "Vertaa Granolaan ja Otteriin",
  faqTitle: "Kysymyksiä",
  faq: [
    {
      question: "Miten ilmainen kokeilu toimii?",
      answer:
        "Kokeilu on maksuton eikä vaadi korttia: 3 kokousta tai 7 päivää ensimmäisestä kokouksesta, kumpi täyttyy ensin. Yksi kokeilukokous voi kestää enintään 90 minuuttia. Sen jälkeen tilaus maksaa 5,99 $ kuussa tai 49 $ vuodessa, verot sisältyvät hintaan.",
    },
    {
      question: "Liittyykö kokoukseeni botti?",
      answer: `Ei. ${productName} kuuntelee Macisi ääntä ja mikrofonia, eivätkä osallistujat näe kokouksessa mitään bottia. Sovellus muistuttaa kertomaan osallistujille ennen kuin aloitat tallennuksen.`,
    },
    {
      question: "Minne ääneni menee?",
      answer:
        "Tallennuksen aikana ääni siirtyy Maciltasi Deepgramille reaaliaikaista litterointia varten; Deepgramia on pyydetty olemaan säilyttämättä ääntä ja käyttämättä sitä kouluttamiseen. Jos tämä ei ole käytettävissä, litterointi tehdään Macillasi. Kokouksen päätyttyä ääni kulkee palvelimemme kautta ElevenLabsille, joka erottelee puhujat ja tuottaa lopullisen litteroinnin; muistiinpanoja ja käännöstä varten teksti menee Anthropicin Claude-mallille. Palvelimemme eivät tallenna ääntä eivätkä muistiinpanoja: ne laskevat keston ja pitävät lopullisen litteroinnin salattuna enintään 2 tuntia, jotta se voidaan lähettää uudelleen, jos yhteys katkeaa. ElevenLabs ja Anthropic voivat säilyttää käsittelemänsä aineiston oman käytäntönsä mukaisen ajan (Anthropic poistaa sen 30 päivän kuluessa); tietosuojaselosteessa on yksityiskohdat.",
    },
    {
      question: "Mitä kieliä tuetaan?",
      answer: "Yli 30 kieltä, muun muassa suomi, englanti ja ruotsi. Valitset itse muistiinpanojen ja käännösten kielen.",
    },
    {
      question: "Miten maksu ja verot toimivat Suomessa?",
      answer: `Maksun hoitaa Stripe ja myynnin Link, Stripen maksupalvelu. Hinta 5,99 $ kuussa tai 49 $ vuodessa sisältää arvonlisäveron: Link laskee sijaintisi mukaisen veron ja tilittää sen puolestamme, ja kassa näyttää sisältyvän veron ennen maksua. Veloitus näkyy tiliotteellasi nimellä ${cardStatementDescriptor}, ja kuitti tulee Linkiltä sähköpostiisi. Korttitietosi jäävät Stripelle ja Linkille eivätkä koskaan tule meille.`,
    },
  ],
  finalTitle: "Anna sen kirjoittaa muistiinpano seuraavasta kokouksestasi.",
  finalLead: "Käyttöönotto vie minuutin, sen jälkeen riittää että aloitat kuuntelemisen.",
};
