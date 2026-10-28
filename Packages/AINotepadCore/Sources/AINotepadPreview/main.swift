// Önizleme aracı AppKit pencereleri açar: yalnızca macOS'ta çalışır (iOS derlemesinde boş).
#if os(macOS)
// Tasarımı gözle kontrol etmek için ada ve paneli örnek verilerle gerçek pencerelerde gösterir.
// Kullanım: swift run --package-path Packages/AINotepadCore AINotepadPreview <saniye>
// Pencere numaralarını yazdırır; `screencapture -l <numara>` ile görüntü alınır.
import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Örnek toplantı: Sen, iki kişi, kesinleşmemiş metin ve bir hata.
func sampleState(phase: RecordingPhase) -> LiveViewState {
    func segment(_ speaker: Speaker, _ index: Int, _ start: Double, _ text: String, _ final: Bool, _ person: Int?) -> LiveSegment {
        LiveSegment(id: SegmentID(speaker: speaker, index: index), startSec: start, endSec: start + 3, text: text, isFinal: final, failureMessage: nil, person: person)
    }
    let transcript: [LiveSegment] = [
            segment(.others, 0, 0, "Hyvää huomenta kaikille, aloitetaan palaveri.", true, 1),
            segment(.others, 1, 4, "Seuraavalla viikolla meidän pitää palauttaa raportti.", true, 1),
            segment(.me, 0, 9, "Kiitos. Minulla on raportti melkein valmiina.", true, nil),
            segment(.others, 2, 14, "Hienoa. Kuka voisi ottaa vastuun esityksestä", true, 2),
            segment(.others, 3, 18, "perjantaina? Ja sitten vielä pitää sopia, kuka tekee diat ja kuka harjoittelee esityksen ennen torstain tapaamista kirjastossa.", false, 2),
    ]
    let turkish: [String] = [
        "Herkese günaydın, toplantıya başlayalım.",
        "Gelecek hafta raporu teslim etmemiz gerekiyor.",
        "",
        "Harika. Sunumun sorumluluğunu kim üstlenebilir",
    ]
    var translations: [SegmentID: String] = [:]
    for (segment, text) in zip(transcript, turkish) where !text.isEmpty {
        translations[segment.id] = text
    }
    return makeLiveViewState(
        transcript: transcript,
        translations: translations,
        displayMode: .bilingual,
        failedTranslations: [transcript[1].id],
        assistantCard: .summary(MissedSummary(
            topic: "Gelecek haftaki rapor ve cuma günkü sunum konuşuluyor.",
            decisions: ["Rapor gelecek hafta teslim edilecek."],
            askedOfYou: ["Sunum slaytlarını hazırlaman isteniyor."]
        )),
        phase: phase,
        newPersonNumber: 3,
        isPaused: false,
        isMicMuted: false, canToggleMic: true,
        isInPerson: false,
        canStart: true,
        startedAt: Date(timeIntervalSinceNow: -754),
        statusText: "Hazır · Deepgram",
        languageText: "🇫🇮 Fince",
        errors: ["Konuşmacı ayırma başarısız: ElevenLabs isteği başarısız (HTTP 503)."]
    )
}

/// Kenarlıksız, saydam bir pencerede SwiftUI görünümü açar ve pencere numarasını döndürür.
@MainActor
func showWindow(view: some View, frame: NSRect) -> Int {
    let window: NSPanel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.level = .floating
    window.contentView = NSHostingView(rootView: view)
    window.orderFrontRegardless()
    return window.windowNumber
}

let seconds: Double = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 6
let app: NSApplication = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let actions: PanelActions = PanelActions(onHide: {}, onStart: {}, onTogglePause: {}, onToggleMic: {}, onStop: {}, onOpenMeetings: {}, onOpenSettings: {}, onMissed: {}, onAsk: { _ in }, onCloseCard: {}, onRetryTranslations: { _ in }, onSetLanguage: { _ in }, onChooseLanguageMode: { _ in }, onReassignBlock: { _, _ in }, onMergePerson: { _, _ in }, onBookmark: {})
    let panel: Int = showWindow(view: TranscriptPanel(state: sampleState(phase: .recording), actions: actions, levels: AudioLevels(count: 14, interval: 0.1), myNotes: .constant("")).panelSurface(), frame: NSRect(x: 120, y: 100, width: 400, height: 720))
    // Dar panel: başlık düğmeleri "⋯" menüsüne toplanmalı, "Ne kaçırdım?" simgeye dönmeli.
    let narrow: Int = showWindow(view: TranscriptPanel(state: sampleState(phase: .recording), actions: actions, levels: AudioLevels(count: 14, interval: 0.1), myNotes: .constant("")).panelSurface(), frame: NSRect(x: 560, y: 100, width: 340, height: 560))
    let narrowIdle: Int = showWindow(view: TranscriptPanel(state: sampleState(phase: .idle), actions: actions, levels: AudioLevels(count: 14, interval: 0.1), myNotes: .constant("")).panelSurface(), frame: NSRect(x: 940, y: 100, width: 340, height: 560))
    print("panel-narrow \(narrow)")
    print("panel-narrow-idle \(narrowIdle)")
    print("panel \(panel)")
    // Çentikli 14" ekran benzeri düzen; pencereler önizleme için ekranın ortasına konur.
    let notchScreen: ScreenGeometry = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 660, height: 32),
        auxiliaryTopRight: CGRect(x: 852, y: 950, width: 660, height: 32)
    )
    let layout: IslandLayout = islandLayout(screen: notchScreen, wing: islandWing, expansion: islandExpansion, pillHeight: 32, pillWidth: 360, pillGap: 8)
    // Örnek ses seviyeleri: konuşma sürüyor gibi.
    let levels: AudioLevels = AudioLevels(count: 14, interval: 0)
    levels.start()
    for (index, level) in [0.2, 0.6, 0.35, 0.8, 0.5, 0.9, 0.4, 0.7, 0.3, 0.65, 0.45, 0.85, 0.55, 0.75].enumerated() {
        levels.record(level: Float(level), at: Date().addingTimeInterval(Double(index)))
    }
    for (name, expanded, y) in [("island-collapsed", false, 600.0), ("island-expanded", true, 460.0)] {
        let number: Int = showWindow(
            view: IslandView(state: sampleState(phase: .recording), levels: levels, layout: layout, isExpanded: expanded, onTap: {}, onHover: { _ in }, onStop: {}, onSetLanguage: { _ in }),
            frame: NSRect(x: 600, y: y, width: layout.frame.width, height: layout.frame.height)
        )
        print("\(name) \(number)")
    }
    // Boş sayfa sahneleri (Kişiler, tüm görevler bitti) açık ve koyu.
    for (name, scheme, y) in [("empty-light", ColorScheme.light, 120.0), ("empty-dark", ColorScheme.dark, 120.0)] {
        let number: Int = showWindow(
            view: EmptyStateHero(
                symbol: "person.2.fill", title: "Henüz kimse yok",
                message: "Konuşmacıya bir kez ad ver; kişi burada görünür, toplantıları, konuşma payı ve görevleriyle.",
                palette: .sunset,
                steps: [
                    EmptyStateStep(symbol: "doc.text", title: "Toplantının transkriptini aç"),
                    EmptyStateStep(symbol: "character.cursor.ibeam", title: "Konuşmacıya ad ver"),
                    EmptyStateStep(symbol: "person.crop.circle.badge.checkmark", title: "Kişi burada toplanır"),
                ]
            ) {
                Button("Kişi ekle", systemImage: "person.badge.plus") {}
                    .buttonStyle(.pillPrimary)
            }
            .frame(width: 760, height: 600)
            .background(Theme.background)
            .environment(\.colorScheme, scheme),
            frame: NSRect(x: scheme == .light ? 40 : 820, y: y, width: 760, height: 600)
        )
        print("\(name) \(number)")
    }
    // Kayıt ekranının ortasındaki büyük ses ölçer.
    let largeMeter: Int = showWindow(
        view: LargeLevelMeter(levels: levels).padding(30).background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 20)),
        frame: NSRect(x: 200, y: 300, width: 260, height: 160)
    )
    print("large-meter \(largeMeter)")
    let confetti: Int = showWindow(
        view: EmptyStateHero(symbol: "party.popper.fill", title: "Açık görevin kalmadı", message: "Hepsi tamamlandı.", palette: .sunset, steps: []) {
            EmptyView()
        }
        .overlay { ConfettiBurst(palette: .sunset) }
        .frame(width: 760, height: 480)
        .background(Theme.background),
        frame: NSRect(x: 400, y: 80, width: 760, height: 480)
    )
    print("confetti \(confetti)")
    let recipes: Int = showWindow(
        view: RecipeSuggestions(
            recipes: builtInRecipes() + [recipeFromQuestion(question: "Satış ekibinin bu çeyrekteki hedefleri ve engelleri neler?", id: "r1")],
            highlighted: 0, onPick: { _ in }, onDelete: { _ in }
        )
        .padding(16)
        .frame(width: 520, height: 420)
        .background(Theme.background),
        frame: NSRect(x: 1000, y: 300, width: 520, height: 420)
    )
    print("recipes \(recipes)")
    for (name, scheme, x) in [("notes-light", ColorScheme.light, 40.0), ("notes-dark", ColorScheme.dark, 520.0)] {
        let number: Int = showWindow(
            view: VStack(spacing: 10) {
                MyNotesEditor(text: .constant("## Bana önemli\n- bütçe cuma yönetime\n- park yeri azalıyor → kiralık yer sor")) {}
                MyNotesEditor(text: .constant("")) {}
            }
            .padding(16)
            .frame(width: 420, height: 380)
            .background(Theme.background)
            .environment(\.colorScheme, scheme),
            frame: NSRect(x: x, y: 300, width: 420, height: 380)
        )
        print("\(name) \(number)")
    }
    // Sor sayfasının örnek soru kartları (açık ve koyu).
    for (name, scheme, x) in [("cards-light", ColorScheme.light, 40.0), ("cards-dark", ColorScheme.dark, 820.0)] {
        let number: Int = showWindow(
            view: VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ExampleQuestionCard(symbol: "checklist", question: "Bana hangi görevler verildi?", hint: "Tüm toplantılarında arar", palette: .sunset) {}
                    ExampleQuestionCard(symbol: "checkmark.seal", question: "Son toplantılarda alınan kararlar neler?", hint: "Tüm toplantılarında arar", palette: .sunset) {}
                }
                HStack(spacing: 12) {
                    ExampleQuestionCard(symbol: "eurosign.circle", question: "Bütçe hakkında neler konuşuldu?", hint: "Tüm toplantılarında arar", palette: .rose) {}
                    ExampleQuestionCard(symbol: "person.2", question: "Bu hafta kimlerle neler konuştum?", hint: "Tüm toplantılarında arar", palette: .sunset) {}
                }
                EmptyStateHero(symbol: "checkmark.circle", title: "Tamamlanan görev yok", message: "Bir görevin dairesine tıklayınca buraya taşınır; bitirdiklerin burada birikir.", palette: .sunset, steps: []) {
                    EmptyView()
                }
            }
            .padding(24)
            .frame(width: 760, height: 640)
            .background(Theme.background)
            .environment(\.colorScheme, scheme),
            frame: NSRect(x: x, y: 60, width: 760, height: 640)
        )
        print("\(name) \(number)")
    }
    // Çıktı bir dosyaya yönlendirildiğinde de hemen görünsün.
    fflush(stdout)
}
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    exit(0)
}
app.run()
#endif
