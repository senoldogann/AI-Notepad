import AINotepadCore
import AINotepadUI
import Foundation
import Observation
import os

/// Canlı metin motoru. Seçim UserDefaults'ta `liveEngineKey` ile saklanır.
enum LiveEngine: String, CaseIterable {
    case deepgram
    case whisperKit
}

let liveEngineKey: String = "liveEngine"

/// Konuşma tanıma modelinin (WhisperKit) yüklenme durumu.
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
    var liveEngine: LiveEngine
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

    init(liveEngine: LiveEngine) {
        self.liveEngine = liveEngine
    }

    /// Kayıt başlatılabilir mi: Deepgram'da her zaman, WhisperKit'te model hazırsa.
    var isReadyToRecord: Bool {
        liveEngine == .deepgram || modelStatus == .ready
    }

    /// Ada ve panelin gösterdiği durum.
    var viewState: LiveViewState {
        makeLiveViewState(
            transcript: transcript,
            isRecording: isRecording,
            startedAt: recordingStartedAt,
            statusText: statusText,
            languageText: languageText(locked: lockedLanguage, mode: languageMode, isRecording: isRecording),
            errors: errorMessages
        )
    }

    /// Kayıt yokken gösterilen durum metni.
    private var statusText: String {
        switch (liveEngine, modelStatus) {
        case (.deepgram, _): "Hazır · Deepgram"
        case (.whisperKit, .loading): "Model hazırlanıyor…"
        case (.whisperKit, .ready): "Hazır · Mac'te"
        case (.whisperKit, .failed(let message)): message
        }
    }

    /// Motoru değiştirir ve kaydeder; WhisperKit seçilirse model (henüz yoksa) yüklenir.
    func selectEngine(engine: LiveEngine) async {
        liveEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: liveEngineKey)
        if engine == .whisperKit, self.engine == nil {
            await loadModel()
        }
    }

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
        guard !isRecording, !isStarting, isReadyToRecord else {
            return
        }
        isStarting = true
        defer { isStarting = false }
        transcript = []
        lockedLanguage = nil
        errorMessages = []
        isStopping = false

        // Bulut anahtarları yakalama başlamadan önce okunur: eksikse hiçbir şey başlatılmaz.
        let cloudKeys: (deepgram: String, elevenLabs: String)?
        switch liveEngine {
        case .deepgram:
            do {
                cloudKeys = (
                    try readSecret(service: keychainService, account: .deepgram),
                    try readSecret(service: keychainService, account: .elevenlabs)
                )
            } catch {
                errorMessages = appendUnique(messages: errorMessages, message: userMessage(error: error))
                return
            }
        case .whisperKit:
            cloudKeys = nil
        }

        let directory: URL
        do {
            directory = try AppPaths.newSessionDirectory(startedAt: Date())
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: "Kayıt klasörü oluşturulamadı: \(userMessage(error: error))")
            return
        }

        var startedStreams: Int = 0
        let meAudio: AsyncStream<[Float]>
        do {
            meAudio = try await microphone.start()
            startedStreams += 1
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userMessage(error: error))
            meAudio = finishedStream()
        }
        let othersAudio: AsyncStream<[Float]>
        do {
            othersAudio = try await systemAudio.start()
            startedStreams += 1
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userMessage(error: error))
            othersAudio = finishedStream()
        }
        guard startedStreams > 0 else {
            return
        }

        let events: AsyncStream<LiveSessionEvent>
        if let cloudKeys {
            events = runCloudLiveSession(
                config: CloudSessionConfig(
                    languageMode: languageMode,
                    recordingDirectory: directory,
                    deepgramKey: cloudKeys.deepgram,
                    elevenLabsKey: cloudKeys.elevenLabs,
                    firstDiarizationAfterSec: 15,
                    diarizationIntervalSec: 60,
                    diarizationWindowSec: 120,
                    minDiarizationAudioSec: 5,
                    languageConfidence: 0.8
                ),
                meAudio: meAudio,
                othersAudio: othersAudio
            )
        } else if let engine {
            events = runLiveSession(
                config: LiveSessionConfig(
                    languageMode: languageMode,
                    segmenter: .live,
                    recordingDirectory: directory,
                    partialIntervalSec: 1.5,
                    minPartialSpeechSec: 1.0,
                    languageLockAfterSec: 30
                ),
                engine: engine,
                meAudio: meAudio,
                othersAudio: othersAudio
            )
        } else {
            // isReadyToRecord WhisperKit'te motoru garanti eder; buraya gelinmesi programlama hatasıdır.
            errorMessages = appendUnique(messages: errorMessages, message: "Konuşma tanıma modeli hazır değil.")
            microphone.stop()
            systemAudio.stop()
            return
        }
        isRecording = true
        recordingStartedAt = Date()
        Self.logger.info("Kayıt başladı: \(directory.path, privacy: .public), motor: \(self.liveEngine.rawValue, privacy: .public)")
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
                errorMessages = appendUnique(messages: errorMessages, message: "\(speakerLabel(speaker: speaker, person: nil)) ses akışı beklenmedik şekilde durdu.")
            }
        case .recordingFailed(let speaker, let message):
            errorMessages = appendUnique(messages: errorMessages, message: "\(speakerLabel(speaker: speaker, person: nil)) sesi diske yazılamadı: \(message)")
        case .speakersAssigned:
            break
        case .streamFailed(let speaker, let message):
            errorMessages = appendUnique(messages: errorMessages, message: "\(speakerLabel(speaker: speaker, person: nil)) metin akışı durdu: \(message)")
        case .diarizationFailed(let message):
            errorMessages = appendUnique(messages: errorMessages, message: "Konuşmacı ayırma başarısız: \(message)")
        }
    }

    private func sessionEnded() {
        isRecording = false
        recordingStartedAt = nil
        sessionTask = nil
        Self.logger.info("Kayıt bitti")
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
    case KeychainError.notFound(_, let account):
        let service: String = account == SecretAccount.deepgram.rawValue ? "Deepgram" : "ElevenLabs"
        return "\(service) anahtarı kayıtlı değil. Menüden Ayarlar…'ı açıp ekle."
    case KeychainError.unexpectedStatus(let operation, let status):
        return "Anahtar Keychain'den okunamadı (\(operation), kod \(status))."
    case TranscriptionError.modelLoadFailed(let model, let reason):
        return "Konuşma tanıma modeli (\(model)) yüklenemedi: \(reason)"
    default:
        return String(describing: error)
    }
}
