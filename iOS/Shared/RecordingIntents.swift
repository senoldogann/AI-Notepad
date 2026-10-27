import ActivityKit
import AppIntents
import Foundation

// Uygulama ve widget eklentisinde ortak: canlı etkinliğin verisi ve kaydı başlatan/bitiren niyetler. Eklentide
// (`WIDGET_EXTENSION`) niyetlerin gövdesi boştur; sistem onları uygulamanın sürecinde çalıştırır.

/// Kaydın canlı etkinliği: kilit ekranı ve Dynamic Island'da süre ve son cümle.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Son kesinleşen cümle; henüz yoksa boş.
        var lastLine: String
        /// Cümlenin konuşmacısı ("Konuşmacı 2"); bilinmiyorsa boş.
        var speaker: String
        /// Mikrofon kapandı, son bölümler bitiriliyor.
        var isFinishing: Bool
    }

    let startedAt: Date
}

/// Toplantıyı kaydet (Kısayollar, Siri, Denetim Merkezi, Eylem düğmesi): uygulamayı açar ve kaydı başlatır.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Toplantıyı kaydet"
    static let description: IntentDescription = IntentDescription("AI-Notepad'i açar ve yüz yüze toplantıyı kaydetmeye başlar.")
    static let openAppWhenRun: Bool = true

    #if !WIDGET_EXTENSION
    @Dependency private var recorder: PhoneRecorder
    @Dependency private var router: PhoneRouter
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        router.tab = .record
        await recorder.start()
        #endif
        return .result()
    }
}

/// Kaydı bitir (Kısayollar, canlı etkinlikteki düğme): uygulamayı açmadan mikrofonu kapatır; toplantı işlenir.
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Kaydı bitir"
    static let description: IntentDescription = IntentDescription("Süren AI-Notepad kaydını bitirir; not hazırlanır.")

    #if !WIDGET_EXTENSION
    @Dependency private var recorder: PhoneRecorder
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        recorder.stop()
        #endif
        return .result()
    }
}
