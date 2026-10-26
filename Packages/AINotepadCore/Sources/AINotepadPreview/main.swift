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
    let actions: PanelActions = PanelActions(onHide: {}, onStart: {}, onTogglePause: {}, onToggleMic: {}, onStop: {}, onOpenMeetings: {}, onOpenSettings: {}, onMissed: {}, onAsk: { _ in }, onCloseCard: {}, onRetryTranslations: { _ in }, onSetLanguage: { _ in }, onReassignBlock: { _, _ in }, onMergePerson: { _, _ in })
    let panel: Int = showWindow(view: TranscriptPanel(state: sampleState(phase: .recording), actions: actions).panelSurface(), frame: NSRect(x: 120, y: 100, width: 400, height: 720))
    // Dar panel: başlık düğmeleri "⋯" menüsüne toplanmalı, "Ne kaçırdım?" simgeye dönmeli.
    let narrow: Int = showWindow(view: TranscriptPanel(state: sampleState(phase: .recording), actions: actions).panelSurface(), frame: NSRect(x: 560, y: 100, width: 340, height: 560))
    let narrowIdle: Int = showWindow(view: TranscriptPanel(state: sampleState(phase: .idle), actions: actions).panelSurface(), frame: NSRect(x: 940, y: 100, width: 340, height: 560))
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
    for (name, expanded, y) in [("island-collapsed", false, 600.0), ("island-expanded", true, 460.0)] {
        let number: Int = showWindow(
            view: IslandView(state: sampleState(phase: .recording), layout: layout, isExpanded: expanded, onTap: {}, onHover: { _ in }, onStop: {}, onSetLanguage: { _ in }),
            frame: NSRect(x: 600, y: y, width: layout.frame.width, height: layout.frame.height)
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
