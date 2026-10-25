import AINotepadCore
import Foundation
import Observation
import os

/// Konuşma tanıma modelinin yüklenme durumu.
enum ModelStatus: Equatable {
    case loading
    case ready
    case failed(String)
}

/// Uygulamanın arayüz durumu ve kayıt yaşam döngüsü.
@MainActor
@Observable
final class AppModel {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AppModel")

    var modelStatus: ModelStatus = .loading
    var isRecording: Bool = false
    /// İzin pencereleri açıkken ikinci bir başlatmayı engeller.
    var isStarting: Bool = false
    var languageMode: LanguageMode = .automatic
    var lockedLanguage: MeetingLanguage?
    var transcript: [LiveSegment] = []
    var errorMessages: [String] = []
    var recordingStartedAt: Date?

    @ObservationIgnored private var engine: WhisperKitEngine?
    @ObservationIgnored private let microphone: MicrophoneCapture = MicrophoneCapture()
    @ObservationIgnored private let systemAudio: SystemAudioCapture = SystemAudioCapture()
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var isStopping: Bool = false

    /// Modeli (ilk seferde indirerek) yükler.
    func loadModel() async {
        modelStatus = .loading
        do {
            engine = try await WhisperKitEngine.load(modelName: liveWhisperModel, modelsDirectory: AppPaths.modelsDirectory())
            modelStatus = .ready
        } catch {
            Self.logger.error("Model yüklenemedi: \(String(describing: error), privacy: .public)")
            modelStatus = .failed(userMessage(error: error))
        }
    }

    /// İki ses akışını başlatır ve canlı oturumu çalıştırır.
    /// Akışlardan biri başlatılamazsa hata gösterilir, diğeriyle devam edilir.
    func startRecording() async {
        guard let engine, !isRecording, !isStarting else {
            return
        }
        isStarting = true
        defer { isStarting = false }
        transcript = []
        lockedLanguage = nil
        errorMessages = []
        isStopping = false

        let directory: URL
        do {
            directory = try AppPaths.newSessionDirectory(startedAt: Date())
        } catch {
            errorMessages.append("Kayıt klasörü oluşturulamadı: \(userMessage(error: error))")
            return
        }

        var startedStreams: Int = 0
        let meAudio: AsyncStream<[Float]>
        do {
            meAudio = try await microphone.start()
            startedStreams += 1
        } catch {
            errorMessages.append(userMessage(error: error))
            meAudio = finishedStream()
        }
        let othersAudio: AsyncStream<[Float]>
        do {
            othersAudio = try await systemAudio.start()
            startedStreams += 1
        } catch {
            errorMessages.append(userMessage(error: error))
            othersAudio = finishedStream()
        }
        guard startedStreams > 0 else {
            return
        }

        isRecording = true
        recordingStartedAt = Date()
        let config: LiveSessionConfig = LiveSessionConfig(
            languageMode: languageMode,
            segmenter: .live,
            recordingDirectory: directory,
            partialIntervalSec: 1.5,
            minPartialSpeechSec: 1.0,
            languageLockAfterSec: 30
        )
        let events: AsyncStream<LiveSessionEvent> = runLiveSession(
            config: config,
            engine: engine,
            meAudio: meAudio,
            othersAudio: othersAudio
        )
        Self.logger.info("Kayıt başladı: \(directory.path, privacy: .public)")
        sessionTask = Task { [weak self] in
            for await event in events {
                self?.handle(event: event)
            }
            self?.sessionEnded()
        }
    }

    /// Yakalamayı durdurur; oturum kalan bölümleri işleyip kendiliğinden biter.
    func stopRecording() {
        guard isRecording else {
            return
        }
        isStopping = true
        microphone.stop()
        systemAudio.stop()
    }

    private func handle(event: LiveSessionEvent) {
        transcript = applyEvent(transcript: transcript, event: event)
        switch event {
        case .segment:
            break
        case .languageLocked(let language):
            lockedLanguage = language
        case .captureEnded(let speaker):
            if !isStopping {
                errorMessages.append("\(speakerLabel(speaker: speaker)) ses akışı beklenmedik şekilde durdu.")
            }
        case .recordingFailed(let speaker, let message):
            errorMessages.append("\(speakerLabel(speaker: speaker)) sesi diske yazılamadı: \(message)")
        }
    }

    private func sessionEnded() {
        isRecording = false
        recordingStartedAt = nil
        sessionTask = nil
        Self.logger.info("Kayıt bitti")
    }
}

/// Konuşmacının arayüzdeki adı.
func speakerLabel(speaker: Speaker) -> String {
    switch speaker {
    case .me: "Sen"
    case .others: "Diğerleri"
    }
}

/// Hemen biten boş bir ses akışı (başlatılamayan kaynak yerine).
private func finishedStream() -> AsyncStream<[Float]> {
    let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    continuation.finish()
    return stream
}

/// Hataları kullanıcıya gösterilecek Türkçe metne çevirir.
private func userMessage(error: any Error) -> String {
    switch error {
    case AudioCaptureError.microphonePermissionDenied:
        return "Mikrofon izni yok. Sistem Ayarları › Gizlilik ve Güvenlik › Mikrofon'dan AI-Notepad'e izin ver."
    case AudioCaptureError.systemAudioPermissionDenied:
        return "Sistem sesi kaydı izni yok. Sistem Ayarları › Gizlilik ve Güvenlik › Ekran ve Sistem Sesi Kaydı'ndan AI-Notepad'e izin ver."
    case AudioCaptureError.coreAudio(let operation, let status):
        return "Sistem sesi yakalanamadı (\(operation), kod \(status))."
    case TranscriptionError.modelLoadFailed(let model, let reason):
        return "Konuşma tanıma modeli (\(model)) yüklenemedi: \(reason)"
    default:
        return String(describing: error)
    }
}
