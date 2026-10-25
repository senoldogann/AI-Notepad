// Tasarımı gözle kontrol etmek için ada ve paneli örnek verilerle gerçek pencerelerde gösterir.
// Kullanım: swift run --package-path Packages/AINotepadCore AINotepadPreview <saniye>
// Pencere numaralarını yazdırır; `screencapture -l <numara>` ile görüntü alınır.
import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Örnek toplantı: Sen, iki kişi, kesinleşmemiş metin ve bir hata.
func sampleState() -> LiveViewState {
    func segment(_ speaker: Speaker, _ index: Int, _ start: Double, _ text: String, _ final: Bool, _ person: Int?) -> LiveSegment {
        LiveSegment(id: SegmentID(speaker: speaker, index: index), startSec: start, endSec: start + 3, text: text, isFinal: final, failureMessage: nil, person: person)
    }
    return makeLiveViewState(
        transcript: [
            segment(.others, 0, 0, "Hyvää huomenta kaikille, aloitetaan palaveri.", true, 1),
            segment(.others, 1, 4, "Seuraavalla viikolla meidän pitää palauttaa raportti.", true, 1),
            segment(.me, 0, 9, "Kiitos. Minulla on raportti melkein valmiina.", true, nil),
            segment(.others, 2, 14, "Hienoa. Kuka voisi ottaa vastuun esityksestä", true, 2),
            segment(.others, 3, 18, "perjantaina?", false, 2),
        ],
        isRecording: true,
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
    let panel: Int = showWindow(
        view: TranscriptPanel(state: sampleState(), onHide: {}),
        frame: NSRect(x: 120, y: 200, width: 380, height: 520)
    )
    print("panel \(panel)")
    // Çıktı bir dosyaya yönlendirildiğinde de hemen görünsün.
    fflush(stdout)
}
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    exit(0)
}
app.run()
