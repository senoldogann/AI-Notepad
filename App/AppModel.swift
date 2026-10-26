import AINotepadCore
import AINotepadUI
import AVFoundation
import Foundation
import Observation
import os

/// Konuşma tanıma modelinin (WhisperKit) yüklenme durumu.
enum ModelStatus: Equatable {
    case loading
    case ready
    case failed(String)
}

/// Toplantı sayfasındaki "Konuşmacıları gözden geçir" kartı.
enum SpeakerReviewState: Equatable {
    case loading
    /// `applied`: kabul edilen öneri sayısı; sıfırdan büyükse not eski adlarla yazılmıştır ("Notu yenile").
    case ready(review: SpeakerReview, applied: Int)
    case failed(String)
}

/// Görünüm durumunu üreten girdiler; değişmedikçe görünüm durumu yeniden hesaplanmaz.
private struct ViewStateInputs: Equatable {
    let transcript: [LiveSegment]
    let translations: [SegmentID: String]
    let failedTranslations: Set<SegmentID>
    let displayMode: DisplayMode
    let assistantCard: AssistantCard?
    let phase: RecordingPhase
    let newPersonNumber: Int
    let isPaused: Bool
    let isMicMuted: Bool
    let canToggleMic: Bool
    let canStart: Bool
    let startedAt: Date?
    let statusText: String
    let languageText: String
    let errors: [String]
}

/// Süren kaydın bilgileri.
private struct RecordingSession {
    let directory: URL
    let startedAt: Date
    let engine: LiveEngine
    let handle: LiveSessionHandle
    /// Duraklatınca iki akış, mikrofon kapatılınca "Sen" sessizliğe çevrilir.
    let pauseGate: AudioGate
    let micGate: AudioGate
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
    /// Durduruldu; kalan metin, çeviriler ve son konuşmacı ayırma bitiyor.
    var isFinishing: Bool = false
    /// Kayıt duraklatıldı (ses sessizlikle değiştiriliyor).
    var isPaused: Bool = false
    /// "Sen" kapalı: hoparlörle dinlerken yankı olmasın. Ayar olarak saklanır.
    var isMicMuted: Bool = UserDefaults.standard.bool(forKey: SettingsKey.micMuted)
    /// Bu kayıtta mikrofon açıldı mı: mikrofon kapalıyken başlayan kayıt yalnızca bilgisayardan gelen sesi alır, mikrofonu
    /// hiç açmaz (menü çubuğunda mikrofon göstergesi yanmaz, Deepgram'a sessizlik gönderilip ücretlendirilmez).
    var micOpenedForRecording: Bool = false
    /// Son biten kaydın toplantısı: panel bitince bu toplantının sayfasını açar.
    var lastFinishedMeetingID: String?
    /// Yerel konuşmacı ayırma modeli hazır değil (menüde uyarı; canlı kayıt engellenmez).
    var localDiarizationWarning: String?
    /// Bir sonraki kaydın dil modu (kayıt sırasında dil `setLanguage` ile değişir).
    var languageMode: LanguageMode = .automatic
    var lockedLanguage: MeetingLanguage?
    var transcript: [LiveSegment] = []
    /// Kullanıcının kayıt sırasında yaptığı konuşmacı düzeltmeleri (otomatik ayırmanın üstüne uygulanır).
    var speakerCorrections: SpeakerCorrections = .none
    var errorMessages: [String] = []
    var recordingStartedAt: Date?
    /// Global kısayol kaydedilemediyse menüde gösterilen hata.
    var shortcutError: String?
    /// Eksik anahtar/ayar (menüde kırmızı; kayıt başlamadan görünür).
    var setupProblems: [String] = []
    /// "Diğerleri" bölümlerinin Türkçesi.
    var translations: [SegmentID: String] = [:]
    /// Çevirisi başarısız bölümler (panelde "Tekrar dene").
    var failedTranslations: Set<SegmentID> = []
    var displayMode: DisplayMode
    /// Paneldeki "Ne kaçırdım?" / soru kartı.
    var assistantCard: AssistantCard?
    /// Kaydedilmiş toplantılar (yeniden eskiye) ve okunamayanlar.
    var meetings: [MeetingRecord] = []
    var meetingLoadFailures: [MeetingLoadFailure] = []
    /// İşlenmekte olan toplantıların kimlikleri.
    var processingMeetingIDs: Set<String> = []
    /// İşlenen toplantının şu anki adımı (panelde ilerleme kartı).
    var processingSteps: [String: ProcessingStep] = [:]
    /// Kayıttaki toplantının kimliği: bu toplantı için tekrar işle / ses sil / ad verme kilitli.
    var activeMeetingID: String?
    /// Toplantı → konuşmacı incelemesi kartı.
    var speakerReviews: [String: SpeakerReviewState] = [:]

    /// Çeviriler sırayla yapılır: her iş bir öncekini bekler.
    @ObservationIgnored private var translationTail: Task<Void, Never>?
    /// Anahtar reddedildiyse bu kayıtta çeviri durur (her cümlede aynı hata çıkmasın); anahtar değişince açılır.
    @ObservationIgnored private var translationDisabled: Bool = false
    /// Her kayıtta artar; önceki kaydın geç gelen çevirisi/kartı yeni kayda yazılmaz (bölüm numaraları her kayıtta 0'dan başlar).
    @ObservationIgnored private var recordingGeneration: Int = 0
    /// Kayıt başında bir kez çözülen LLM sağlayıcısı (her cümlede Keychain okunmasın).
    @ObservationIgnored private var llmProvider: LLMProvider?
    /// Kayıt sırasında transkripti periyodik saklayan görev (çökmede metin kaybolmasın).
    @ObservationIgnored private var checkpointTask: Task<Void, Never>?
    @ObservationIgnored private var session: RecordingSession?
    /// Başarıyla başlayan ses akışları: başlamayan akış için "beklenmedik şekilde durdu" gösterilmez.
    @ObservationIgnored private var startedSpeakers: Set<Speaker> = []
    /// Süren "Ne kaçırdım?"/soru isteği; yenisi, kapatma ya da yeni kayıt eskisini iptal eder.
    @ObservationIgnored private var assistantTask: Task<Void, Never>?
    /// Kartı yazmaya yetkili son istek.
    @ObservationIgnored private var assistantRequestID: Int = 0
    /// Bu kayıtta "Sen"in canlı metin akışı koptu mu (toplantı sonunda "Sen" kaydı da son geçişten geçer).
    @ObservationIgnored private var meStreamFailed: Bool = false
    /// Kayıt ve işleme sürerken Mac boşta uykuya geçmesin (uyku kaydı ve son geçiş yüklemesini keser); toplantı başına.
    @ObservationIgnored private var sleepActivities: [String: any NSObjectProtocol] = [:]
    /// Süren konuşmacı incelemeleri; yenisi ya da kartı kapatmak eskisini iptal eder.
    @ObservationIgnored private var speakerReviewTasks: [String: Task<Void, Never>] = [:]
    /// Ses saklama süresini günde bir uygulayan görev.
    @ObservationIgnored private var retentionTask: Task<Void, Never>?
    @ObservationIgnored private var viewStateCache: (inputs: ViewStateInputs, state: LiveViewState)?

    @ObservationIgnored private var engine: WhisperKitEngine?
    @ObservationIgnored private let microphone: MicrophoneCapture = MicrophoneCapture()
    @ObservationIgnored private let systemAudio: SystemAudioCapture = SystemAudioCapture()
    @ObservationIgnored private var sessionTask: Task<Void, Never>?

    init(liveEngine: LiveEngine, displayMode: DisplayMode) {
        self.liveEngine = liveEngine
        self.displayMode = displayMode
    }

    // MARK: Görünüm

    var phase: RecordingPhase {
        isFinishing ? .finishing : (isRecording ? .recording : .idle)
    }

    /// Kayıt başlatılabilir mi: önceki kayıt bitmiş olmalı; Deepgram'da her zaman, WhisperKit'te model hazırsa.
    var isReadyToRecord: Bool {
        !isFinishing && (liveEngine == .deepgram || modelStatus == .ready)
    }

    /// Ada ve panelin gösterdiği durum; girdiler değişmedikçe önbellekten (ada ve panel aynı değişiklikte iki kez okur).
    var viewState: LiveViewState {
        let inputs: ViewStateInputs = ViewStateInputs(
            transcript: correctedTranscript, translations: translations, failedTranslations: failedTranslations, displayMode: displayMode,
            assistantCard: assistantCard, phase: phase,
            newPersonNumber: nextFreePerson(transcript: transcript, corrections: speakerCorrections), isPaused: isPaused, isMicMuted: isMicMuted, canToggleMic: !isRecording || micOpenedForRecording, canStart: isReadyToRecord && !isStarting,
            startedAt: recordingStartedAt, statusText: statusText,
            languageText: languageText(locked: lockedLanguage, mode: languageMode, isRecording: isRecording), errors: errorMessages
        )
        if let cache = viewStateCache, cache.inputs == inputs {
            return cache.state
        }
        let state: LiveViewState = makeLiveViewState(
            transcript: inputs.transcript, translations: inputs.translations, displayMode: inputs.displayMode,
            failedTranslations: inputs.failedTranslations, assistantCard: inputs.assistantCard, phase: inputs.phase,
            newPersonNumber: inputs.newPersonNumber, isPaused: inputs.isPaused, isMicMuted: inputs.isMicMuted, canToggleMic: inputs.canToggleMic, canStart: inputs.canStart, startedAt: inputs.startedAt, statusText: inputs.statusText, languageText: inputs.languageText, errors: inputs.errors
        )
        viewStateCache = (inputs, state)
        return state
    }

    /// Kayıt yokken gösterilen durum metni.
    private var statusText: String {
        switch (liveEngine, modelStatus) {
        case (.deepgram, _): String(localized: "Hazır · Deepgram")
        case (.whisperKit, .loading): String(localized: "Model hazırlanıyor…")
        case (.whisperKit, .ready): String(localized: "Hazır · Mac'te")
        case (.whisperKit, .failed(let message)): message
        }
    }

    /// Konuşmacı düzeltmeleri uygulanmış transkript (görünüm, asistan ve kaydedilen toplantı bunu kullanır).
    var correctedTranscript: [LiveSegment] {
        applyCorrections(transcript: transcript, corrections: speakerCorrections)
    }

    /// Bir bloğu başka konuşmacıya atar (otomatik ayırma yanıldıysa); sonraki ayırma pencereleri bunu ezmez.
    func reassignBlock(segments: [SegmentID], person: Int) {
        speakerCorrections = speakerCorrections.assigning(segments: segments, to: person)
    }

    /// Bir konuşmacının tüm bölümlerini (geçmiş ve gelecek) diğeriyle birleştirir.
    func mergeLivePersons(from: Int, into: Int) {
        speakerCorrections = speakerCorrections.merging(person: from, into: into)
    }

    /// Kaydedilmiş toplantıda iki konuşmacıyı birleştirir (ör. son geçiş aynı kişiyi ikiye böldüyse).
    func mergeSpeakers(meetingID: String, from: Int, into: Int) {
        guard let record = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return
        }
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            saveRecord(record: mergingPersons(record: record, from: from, into: into), directory: directory)
        }
    }

    /// Görünümü değiştirir ve kaydeder.
    func selectDisplayMode(mode: DisplayMode) {
        let resumesTranslation: Bool = mode.needsLiveTranslation && !displayMode.needsLiveTranslation
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: SettingsKey.displayMode)
        // "Sadece orijinal"den dönünce o sırada çevrilmeyen cümleler de çevrilir (toplantıda Türkçesi eksik kalmasın).
        if resumesTranslation, isRecording {
            for segment in transcript where segment.id.speaker == .others && segment.isFinal && !segment.text.isEmpty
                && translations[segment.id] == nil && !failedTranslations.contains(segment.id) {
                enqueueTranslation(segment: segment)
            }
        }
    }

    // MARK: Asistan

    /// Son N dakikanın (Ayarlar) Türkçe özeti.
    func askWhatIMissed() {
        let minutes: Int = clampedSetting(key: SettingsKey.missedWindowMinutes, range: SettingsRange.missedWindowMinutes)
        let segments: [LiveSegment] = suppressEchoes(transcript: correctedTranscript)
        let nowSec: Double = transcript.map(\.endSec).max() ?? 0
        guard let request = missedSummaryRequest(segments: segments, nowSec: nowSec, windowSec: Double(minutes * 60)) else {
            cancelAssistant()
            assistantCard = .summary(MissedSummary(topic: String(localized: "Son \(minutes) dakikada konuşma yok."), decisions: [], askedOfYou: []))
            return
        }
        runAssistant(request: request, title: String(localized: "Ne kaçırdım?")) { (text: String) throws -> AssistantCard in
            .summary(try parseMissedSummary(text: text))
        }
    }

    /// Toplantı hakkında Türkçe soru; henüz konuşma yoksa istek atılmaz.
    func ask(question: String) {
        guard let request = questionRequest(segments: suppressEchoes(transcript: correctedTranscript), question: question) else {
            cancelAssistant()
            assistantCard = .answer(question: question, text: String(localized: "Henüz konuşma yok; sorular toplantıda konuşulanlara göre cevaplanır."))
            return
        }
        runAssistant(request: request, title: String(localized: "Cevap hazırlanıyor")) { (text: String) throws -> AssistantCard in
            .answer(question: question, text: text)
        }
    }

    /// Kartı kapatır ve süren isteği iptal eder.
    func closeAssistantCard() {
        cancelAssistant()
        assistantCard = nil
    }

    /// Önceki isteği iptal edip yenisini çalıştırır; sonucu yalnızca hâlâ en son istekse karta yazar.
    private func runAssistant(request: LLMRequest, title: String, makeCard: @escaping @Sendable (String) throws -> AssistantCard) {
        cancelAssistant()
        let requestID: Int = assistantRequestID
        assistantCard = .loading(title: title)
        assistantTask = Task { [weak self] in
            let card: AssistantCard
            do {
                let provider: LLMProvider = try await resolveLLMProvider()
                card = try await requestStructured(provider: provider, request: request, parse: makeCard)
            } catch {
                card = .failed(message: userFacingMessage(error: error))
            }
            guard let self, requestID == self.assistantRequestID, !Task.isCancelled else {
                return
            }
            self.assistantCard = card
        }
    }

    private func cancelAssistant() {
        assistantRequestID += 1
        assistantTask?.cancel()
        assistantTask = nil
    }

    // MARK: Çeviri

    /// Kesinleşmiş "Diğerleri" bölümünü sıraya alıp Türkçeye çevirir (hızlı model).
    private func enqueueTranslation(segment: LiveSegment) {
        // "Sadece orijinal" görünümünde canlı çeviri yapılmaz (maliyet); toplantı sonu Türkçe not yine üretilir.
        guard displayMode.needsLiveTranslation, !translationDisabled, let provider = llmProvider else {
            return
        }
        let context: [String] = translationContext(transcript: transcript, before: segment.id, count: 3)
        let generation: Int = recordingGeneration
        let previous: Task<Void, Never>? = translationTail
        translationTail = Task { [weak self] in
            await previous?.value
            await self?.translate(segment: segment, context: context, provider: provider, generation: generation)
        }
    }

    private func translate(segment: LiveSegment, context: [String], provider: LLMProvider, generation: Int) async {
        guard !translationDisabled, generation == recordingGeneration else {
            return
        }
        do {
            let turkish: String = try await sendLLM(provider: provider, request: translationRequest(sentence: segment.text, context: context))
            // Bu arada yeni kayıt başladıysa sonuç başka bir toplantının aynı numaralı bölümüne yazılmaz.
            guard generation == recordingGeneration else {
                return
            }
            translations[segment.id] = turkish
            failedTranslations.remove(segment.id)
        } catch {
            guard generation == recordingGeneration else {
                return
            }
            if case LLMError.http(let status, _, _, _) = error, status == 401 || status == 403 {
                translationDisabled = true
            }
            failedTranslations.insert(segment.id)
            Self.logger.error("Çeviri başarısız, bölüm: \(segmentKey(id: segment.id), privacy: .public), hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Çeviri: \(userFacingMessage(error: error))"))
        }
    }

    /// Başarısız çevirileri yeniden dener; anahtar sonradan düzeltilmiş olabileceği için sağlayıcı yeniden çözülür.
    func retryTranslations(ids: [SegmentID]) {
        Task {
            guard await refreshLLMProvider() else {
                return
            }
            for id in ids {
                guard let segment = transcript.first(where: { $0.id == id && $0.isFinal && !$0.text.isEmpty }) else {
                    continue
                }
                failedTranslations.remove(id)
                enqueueTranslation(segment: segment)
            }
        }
    }

    /// Kayıt sırasında sağlayıcıyı yeniden çözer ve çeviriyi açar; başarısızsa hata panelde görünür.
    private func refreshLLMProvider() async -> Bool {
        do {
            llmProvider = try await resolveLLMProvider()
            translationDisabled = false
            return true
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Çeviri kapalı: \(userFacingMessage(error: error))"))
            return false
        }
    }

    /// Ayarlar'da anahtar ya da LLM ayarı değişti: eksik listesi güncellenir; kayıttaysa çeviri yeni ayarla sürer.
    func settingsChanged() {
        Task {
            await refreshSetupProblems()
            if isRecording, !isFinishing, translationDisabled || llmProvider == nil {
                _ = await refreshLLMProvider()
            }
        }
    }

    /// Seçili motor ve LLM için eksik anahtar/ayarları bulur (değer okunmaz, izin penceresi açılmaz).
    func refreshSetupProblems() async {
        var required: [SecretAccount] = []
        if liveEngine == .deepgram {
            required += [.deepgram, .elevenlabs]
        }
        let kind: LLMProviderKind = selectedLLMProviderKind()
        if kind == .anthropic {
            required.append(.anthropic)
        }
        var problems: [String] = []
        for account in required {
            do {
                let exists: Bool = try await Task.detached { try secretExists(service: keychainService, account: account) }.value
                if !exists {
                    problems.append(userFacingMessage(error: KeychainError.notFound(service: keychainService, account: account.rawValue)))
                }
            } catch {
                problems.append(userFacingMessage(error: error))
            }
        }
        if kind == .openAICompatible {
            do {
                _ = try storedOpenAIConfig(apiKey: nil)
            } catch {
                problems.append(userFacingMessage(error: error))
            }
        }
        setupProblems = problems
    }

    // MARK: Motor

    /// Motoru değiştirir ve kaydeder; WhisperKit seçilirse model (henüz yoksa) yüklenir.
    func selectEngine(engine: LiveEngine) async {
        liveEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: SettingsKey.liveEngine)
        await refreshSetupProblems()
        if engine == .whisperKit, self.engine == nil {
            await loadModel()
        }
    }

    /// Modeli (ilk seferde indirerek) yükler.
    func loadModel() async {
        modelStatus = .loading
        do {
            let modelsDirectory: URL = try AppPaths.modelsDirectory()
            engine = try await WhisperKitEngine.load(modelName: liveWhisperModel, modelsDirectory: modelsDirectory)
            modelStatus = .ready
        } catch {
            Self.logger.error("Model yüklenemedi, hata: \(String(describing: error), privacy: .public)")
            modelStatus = .failed(userFacingMessage(error: error))
            return
        }
        // Konuşmacı ayırma modeli de şimdi indirilir: ilk yerel toplantının son geçişi internetsiz çalışsın.
        // İndirilemezse canlı kayıt engellenmez; uyarı menüde görünür, son geçiş metni tek konuşmacı saklar.
        do {
            try await prepareLocalDiarization(modelsDirectory: try AppPaths.modelsDirectory())
            localDiarizationWarning = nil
        } catch {
            Self.logger.error("Konuşmacı ayırma modeli indirilemedi, hata: \(String(describing: error), privacy: .public)")
            localDiarizationWarning = String(localized: "Konuşmacı ayırma modeli indirilemedi; internete bağlanıp \"Modeli yeniden yükle\"ye bas.")
        }
    }

    // MARK: Kayıt

    /// İki ses akışını başlatır ve canlı oturumu çalıştırır.
    /// Akışlardan biri başlatılamazsa hata gösterilir, diğeriyle devam edilir.
    func startRecording() async {
        guard !isRecording, !isStarting, isReadyToRecord else {
            return
        }
        isStarting = true
        defer { isStarting = false }
        transcript = []
        speakerCorrections = .none
        meStreamFailed = false
        translations = [:]
        failedTranslations = []
        recordingGeneration += 1
        translationTail?.cancel()
        translationTail = nil
        closeAssistantCard()
        translationDisabled = false
        lockedLanguage = nil
        errorMessages = []
        startedSpeakers = []
        isPaused = false
        // Çeviri sağlayıcısı kayıt başında bir kez çözülür; yoksa canlı metin yine akar, tek hata gösterilir.
        if !(await refreshLLMProvider()) {
            llmProvider = nil
            translationDisabled = true
        }

        // Bulut anahtarları yakalama başlamadan önce okunur: eksikse hiçbir şey başlatılmaz; eksiklerin hepsi bildirilir.
        let cloudKeys: (deepgram: String, elevenLabs: String)?
        switch liveEngine {
        case .deepgram:
            let deepgram: Result<String, any Error> = await secretResult(account: .deepgram)
            let elevenLabs: Result<String, any Error> = await secretResult(account: .elevenlabs)
            guard case .success(let deepgramKey) = deepgram, case .success(let elevenLabsKey) = elevenLabs else {
                for case .failure(let error) in [deepgram, elevenLabs] {
                    errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
                }
                return
            }
            cloudKeys = (deepgramKey, elevenLabsKey)
        case .whisperKit:
            cloudKeys = nil
        }

        let directory: URL
        do {
            directory = try AppPaths.newSessionDirectory(startedAt: Date())
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Kayıt klasörü oluşturulamadı: \(userFacingMessage(error: error))"))
            return
        }

        // İki akış aynı zaman çizgisine hizalanır: geç başlayan akış ve yeniden kurma boşlukları sessizlikle dolar.
        let origin: ContinuousClock.Instant = .now
        let startedAt: Date = Date()
        let pauseGate: AudioGate = AudioGate(isOpen: true)
        let micGate: AudioGate = AudioGate(isOpen: !isMicMuted)
        let meAudio: AsyncStream<[Float]>
        if isMicMuted {
            // Yalnızca karşı taraf: mikrofon hiç açılmaz.
            meAudio = finishedStream()
            micOpenedForRecording = false
        } else {
            do {
                let aligned: AsyncStream<[Float]> = clockAlignedStream(audio: try await microphone.start(), origin: origin, sampleRate: 16000, thresholdSec: 0.5)
                meAudio = gatedStream(audio: gatedStream(audio: aligned, gate: micGate), gate: pauseGate)
                startedSpeakers.insert(.me)
                micOpenedForRecording = true
            } catch {
                errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
                meAudio = finishedStream()
                micOpenedForRecording = false
            }
        }
        let othersAudio: AsyncStream<[Float]>
        do {
            let aligned: AsyncStream<[Float]> = clockAlignedStream(audio: try await systemAudio.start(), origin: origin, sampleRate: 16000, thresholdSec: 0.5)
            othersAudio = gatedStream(audio: aligned, gate: pauseGate)
            startedSpeakers.insert(.others)
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            othersAudio = finishedStream()
        }
        guard !startedSpeakers.isEmpty else {
            return
        }

        let handle: LiveSessionHandle
        if let cloudKeys {
            handle = runCloudLiveSession(
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
            handle = runLiveSession(
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
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Konuşma tanıma modeli hazır değil."))
            microphone.stop()
            systemAudio.stop()
            return
        }
        isRecording = true
        recordingStartedAt = startedAt
        session = RecordingSession(directory: directory, startedAt: startedAt, engine: liveEngine, handle: handle, pauseGate: pauseGate, micGate: micGate)
        activeMeetingID = directory.lastPathComponent
        keepAwake(meetingID: directory.lastPathComponent)
        startCheckpoints(directory: directory, startedAt: startedAt)
        // Uygulama kayıt sırasında kapanırsa toplantı açılışta "yarıda kaldı" olarak bulunur.
        saveRecord(record: liveRecord(directory: directory, startedAt: startedAt, status: .recording, endedAt: nil), directory: directory)
        Self.logger.info("Kayıt başladı, klasör: \(directory.lastPathComponent, privacy: .public), motor: \(self.liveEngine.rawValue, privacy: .public)")
        sessionTask = Task { [weak self] in
            for await event in handle.events {
                self?.handle(event: event)
            }
            await self?.sessionEnded()
        }
    }

    /// Anahtarı arka planda okur; sonucu hata dahil döndürür (birden çok eksik birlikte bildirilsin diye).
    private func secretResult(account: SecretAccount) async -> Result<String, any Error> {
        do {
            return .success(try await readSecretInBackground(service: keychainService, account: account))
        } catch {
            return .failure(error)
        }
    }

    /// Kayıttaysa durdurur, değilse başlatır (kısayol için).
    func toggleRecording() async {
        if isRecording {
            stopRecording()
        } else {
            await startRecording()
        }
    }

    /// Yakalamayı durdurur; oturum kalan bölümleri işleyip kendiliğinden biter ("Bitiriliyor…").
    func stopRecording() {
        guard isRecording, !isFinishing else {
            return
        }
        isFinishing = true
        microphone.stop()
        systemAudio.stop()
    }

    /// Kaydı duraklatır ya da sürdürür. Duraklatılınca ses sessizlikle değiştirilir: kayıt sürer, metin üretilmez,
    /// zaman çizgisi bozulmaz.
    func togglePause() {
        guard isRecording, !isFinishing, let session else {
            return
        }
        isPaused.toggle()
        session.pauseGate.set(isOpen: !isPaused)
    }

    /// "Sen"i (mikrofon) kapatır/açar; tercih saklanır. Hoparlörle dinlerken yankıyı kökten önler.
    func toggleMicrophone() {
        // Mikrofonsuz başlayan kayıtta mikrofon açılamaz (akış kayıt başında kurulur); düğme de kapalıdır.
        guard !isRecording || micOpenedForRecording else {
            return
        }
        isMicMuted.toggle()
        UserDefaults.standard.set(isMicMuted, forKey: SettingsKey.micMuted)
        session?.micGate.set(isOpen: !isMicMuted)
    }

    /// Kayıt sırasında toplantı dilini değiştirir; o andan sonraki metin yeni dille yazılır.
    func setLanguage(language: MeetingLanguage) {
        guard isRecording, !isFinishing, let handle = session?.handle else {
            return
        }
        Task {
            await handle.setLanguage(language)
        }
    }

    private func handle(event: LiveSessionEvent) {
        transcript = applyEvent(transcript: transcript, event: event)
        switch event {
        case .segment(let segment):
            if segment.id.speaker == .others, segment.isFinal, !segment.text.isEmpty {
                enqueueTranslation(segment: segment)
            }
        case .languageLocked(let language):
            lockedLanguage = language
        case .captureEnded(let speaker):
            // Başlatılamamış akışın hatası başlangıçta zaten gösterildi.
            if !isFinishing, startedSpeakers.contains(speaker) {
                errorMessages = appendUnique(messages: errorMessages, message: String(localized: "\(speakerLabel(speaker: speaker, person: nil)) ses akışı beklenmedik şekilde durdu. Cihazı kontrol edip kaydı yeniden başlat."))
            }
        case .recordingFailed(let speaker, let message):
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "\(speakerLabel(speaker: speaker, person: nil)) sesi diske yazılamadı: \(message)"))
        case .speakersAssigned:
            break
        case .streamFailed(let speaker, let message):
            // "Sen"in metni bu kayıtta eksik kalır; toplantı sonunda "Sen" kaydı da yazıya dökülür.
            meStreamFailed = meStreamFailed || speaker == .me
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "\(speakerLabel(speaker: speaker, person: nil)) metin akışı durdu: \(message)"))
        case .diarizationFailed(let message):
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Konuşmacı ayırma başarısız: \(message)"))
        }
    }

    /// Oturum bitti: bekleyen çeviriler (en fazla 10 sn) beklenir, toplantı kaydedilip işlenir.
    private func sessionEnded() async {
        await waitForPendingTranslations(timeoutSec: 10)
        isRecording = false
        isFinishing = false
        recordingStartedAt = nil
        sessionTask = nil
        checkpointTask?.cancel()
        checkpointTask = nil
        Self.logger.info("Kayıt bitti")
        isPaused = false
        guard let finished = session else {
            return
        }
        session = nil
        activeMeetingID = nil
        let record: MeetingRecord = liveRecord(directory: finished.directory, startedAt: finished.startedAt, status: .processing, endedAt: Date())
        process(record: record, directory: finished.directory)
        lastFinishedMeetingID = record.id
    }

    /// Kuyruktaki çevirileri en fazla `timeoutSec` bekler; süre dolarsa kalan çeviriler durdurulur (kaydedilmez, loglanır).
    private func waitForPendingTranslations(timeoutSec: Double) async {
        guard let tail = translationTail else {
            return
        }
        let completed: Bool = await finishesWithin(seconds: timeoutSec) {
            await tail.value
        }
        if !completed {
            // Sıradaki işler başlarken bunu görüp çıkar; süren istek iptal edilir.
            translationDisabled = true
            tail.cancel()
            Self.logger.warning("Kayıt sonunda bekleyen çeviriler süre içinde bitmedi, süre: \(timeoutSec, privacy: .public)")
        }
    }

    /// Canlı transkript ve çevirilerden toplantı kaydı.
    private func liveRecord(directory: URL, startedAt: Date, status: MeetingStatus, endedAt: Date?) -> MeetingRecord {
        MeetingRecord(
            id: directory.lastPathComponent, title: String(localized: "Toplantı"), startedAt: startedAt, endedAt: endedAt,
            language: lockedLanguage, status: status, failureMessage: nil,
            liveSegments: storedSegments(transcript: correctedTranscript), finalSegments: [],
            translations: Dictionary(uniqueKeysWithValues: translations.map { (segmentKey(id: $0.key), $0.value) }),
            speakerNames: [:], note: nil, audioDeleted: false,
            engine: session?.engine.recordingEngine ?? liveEngine.recordingEngine, notice: nil,
            meNeedsFinalPass: meStreamFailed ? true : nil
        )
    }

    /// Kayıt sürerken her 30 sn'de transkripti saklar: uygulama çökerse metin "Yarıda kaldı" toplantısında durur.
    private func startCheckpoints(directory: URL, startedAt: Date) {
        checkpointTask?.cancel()
        checkpointTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    // İptal: kayıt bitti.
                    return
                }
                guard let self, self.isRecording else {
                    return
                }
                self.saveRecord(record: self.liveRecord(directory: directory, startedAt: startedAt, status: .recording, endedAt: nil), directory: directory)
            }
        }
    }

    // MARK: Toplantı kayıtları

    /// Bu toplantı üzerinde değişiklik yapılabilir mi (kayıtta ya da işlemede değil).
    func isLocked(meetingID: String) -> Bool {
        activeMeetingID == meetingID || processingMeetingIDs.contains(meetingID)
    }

    /// Toplantıyı sonradan işler (son geçiş + not) ve kaydeder. Son geçiş kaydın motoruna göre yapılır
    /// (yerel toplantı buluta gönderilmez); dil kaydın kilitlenmiş dilidir.
    private func process(record: MeetingRecord, directory: URL) {
        saveRecord(record: record, directory: directory)
        processingMeetingIDs.insert(record.id)
        keepAwake(meetingID: record.id)
        // İlerleme kartı yalnızca kayıt sonrası işleme (adımlı) için; "Notu yenile" adım bildirmez, kart açmaz.
        processingSteps[record.id] = .convertingAudio
        let userName: String = UserDefaults.standard.string(forKey: SettingsKey.userName) ?? ""
        let languageMode: LanguageMode = record.language.map { LanguageMode.fixed($0) } ?? .automatic
        Task {
            let plan: FinalPassPlan = await finalPassPlan(record: record)
            let llm: LLMProvider? = await optionalLLMProvider()
            let result: MeetingRecord = await processMeeting(
                record: record, directory: directory, finalPass: plan, llm: llm, languageMode: languageMode, userName: userName
            ) { (step: ProcessingStep) async -> Void in
                self.processingSteps[record.id] = step
            }
            saveRecord(record: result, directory: directory)
            processingMeetingIDs.remove(record.id)
            processingSteps[record.id] = nil
            allowSleep(meetingID: record.id)
        }
    }

    /// Toplantının kaydı ya da işlenmesi sürerken boşta uykuyu engeller (kapak kapatma yine uyutur).
    private func keepAwake(meetingID: String) {
        guard sleepActivities[meetingID] == nil else {
            return
        }
        sleepActivities[meetingID] = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "AI-Notepad toplantı kaydediyor ya da işliyor"
        )
    }

    private func allowSleep(meetingID: String) {
        if let activity = sleepActivities.removeValue(forKey: meetingID) {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    /// Kaydın motoruna göre son geçiş; eski toplantılar (motor bilgisi yok) bulut sayılır.
    private func finalPassPlan(record: MeetingRecord) async -> FinalPassPlan {
        switch record.engine ?? .cloud {
        case .local:
            do {
                return .run(LocalFinalTranscriber(modelsDirectory: try AppPaths.modelsDirectory(), modelName: liveWhisperModel))
            } catch {
                return .skip(reason: userFacingMessage(error: error))
            }
        case .cloud:
            do {
                guard let key = try await optionalSecretInBackground(service: keychainService, account: .elevenlabs) else {
                    return .skip(reason: String(localized: "ElevenLabs anahtarı kayıtlı değil."))
                }
                return .run(ElevenLabsFinalTranscriber(apiKey: key))
            } catch {
                return .skip(reason: userFacingMessage(error: error))
            }
        }
    }

    /// LLM sağlayıcısı; anahtar ya da ayar yoksa nil (not adımı bunu açıkça bildirir), diğer hatalar panelde.
    private func optionalLLMProvider() async -> LLMProvider? {
        do {
            return try await resolveLLMProvider()
        } catch KeychainError.notFound, LLMError.notConfigured {
            return nil
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "LLM ayarı okunamadı: \(userFacingMessage(error: error))"))
            return nil
        }
    }

    /// "Tekrar işle": anahtarlar şimdi okunur (Ayarlar'dan sonradan eklenmiş olabilir).
    func reprocess(meetingID: String) {
        guard let record = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return
        }
        // Son geçiş konuşmacıları yeniden numaralar; eski öneriler başka kişileri gösterirdi.
        closeSpeakerReview(meetingID: meetingID)
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            process(record: record, directory: directory)
        }
    }

    /// Yalnızca notu yeniden üretir (ad verdikten sonra notta da adlar görünsün); ses gerekmez.
    func regenerateNote(meetingID: String) {
        guard let record = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return
        }
        let userName: String = UserDefaults.standard.string(forKey: SettingsKey.userName) ?? ""
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            processingMeetingIDs.insert(meetingID)
            // Kabul edilen öneriler artık notta; bekleyen öneri yoksa inceleme kartı kapanır.
            if case .ready(let review, _) = speakerReviews[meetingID] {
                speakerReviews[meetingID] = review.hasPendingSuggestions || !review.suspicious.isEmpty
                    ? .ready(review: review, applied: 0)
                    : nil
            }
            Task {
                let llm: LLMProvider? = await optionalLLMProvider()
                let result: MeetingRecord = await AINotepadCore.regenerateNote(record: record, llm: llm, userName: userName)
                saveRecord(record: result, directory: directory)
                processingMeetingIDs.remove(meetingID)
            }
        }
    }

    /// "Konuşmacı 2 = Aino": adı kaydeder; boş ad etiketi geri getirir.
    func renameSpeaker(meetingID: String, person: Int, name: String) {
        // İşleme bitince kayıt bütünüyle yazıldığı için bu sırada verilen ad kaybolurdu.
        guard let record = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return
        }
        var names: [Int: String] = record.speakerNames
        names[person] = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            saveRecord(record: record.with(speakerNames: names), directory: directory)
        }
    }

    // MARK: Konuşmacı incelemesi

    /// Akıllı model transkriptin tamamını okuyup ad, birleştirme ve şüpheli an önerir; öneriler kartta tek tek
    /// kabul ya da reddedilir (yanlış bir öneri sessizce notu bozmasın diye otomatik uygulanmaz).
    func reviewSpeakers(meetingID: String) {
        guard let record = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return
        }
        let segments: [StoredSegment] = meetingSegments(record: record)
        let userName: String = UserDefaults.standard.string(forKey: SettingsKey.userName) ?? ""
        guard let request = speakerReviewRequest(segments: segments, speakerNames: record.speakerNames, userName: userName) else {
            return
        }
        let persons: Set<Int> = Set(segments.compactMap(\.person))
        speakerReviewTasks[meetingID]?.cancel()
        speakerReviews[meetingID] = .loading
        speakerReviewTasks[meetingID] = Task { [weak self] in
            let state: SpeakerReviewState
            do {
                let provider: LLMProvider = try await resolveLLMProvider()
                let names: [Int: String] = record.speakerNames
                let review: SpeakerReview = try await requestStructured(provider: provider, request: request) { (text: String) throws -> SpeakerReview in
                    try parseSpeakerReview(text: text, persons: persons, speakerNames: names)
                }
                state = .ready(review: review, applied: 0)
            } catch {
                // Hata gövdesi toplantı metni içerebilir: yalnızca özel (private) loglanır.
                Self.logger.error("Konuşmacı incelemesi başarısız, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                state = .failed(userFacingMessage(error: error))
            }
            // Kart kapatıldıysa ya da yeni inceleme başladıysa sonuç yazılmaz.
            guard let self, !Task.isCancelled else {
                return
            }
            self.speakerReviews[meetingID] = state
            self.speakerReviewTasks[meetingID] = nil
        }
    }

    /// Kartı kapatır ve süren incelemeyi iptal eder.
    func closeSpeakerReview(meetingID: String) {
        speakerReviewTasks[meetingID]?.cancel()
        speakerReviewTasks[meetingID] = nil
        speakerReviews[meetingID] = nil
    }

    /// Ad önerisini uygular.
    func acceptNameSuggestion(meetingID: String, suggestion: SpeakerNameSuggestion) {
        guard case .ready(let review, let applied) = speakerReviews[meetingID], !isLocked(meetingID: meetingID) else {
            return
        }
        // Bu arada elle birleştirilen kişiye ad verilmez; öneri yalnızca düşer.
        guard currentPersons(meetingID: meetingID).contains(suggestion.person) else {
            speakerReviews[meetingID] = .ready(review: review.removingName(person: suggestion.person), applied: applied)
            return
        }
        renameSpeaker(meetingID: meetingID, person: suggestion.person, name: suggestion.name)
        speakerReviews[meetingID] = .ready(review: review.removingName(person: suggestion.person), applied: applied + 1)
    }

    func dismissNameSuggestion(meetingID: String, suggestion: SpeakerNameSuggestion) {
        guard case .ready(let review, let applied) = speakerReviews[meetingID] else {
            return
        }
        speakerReviews[meetingID] = .ready(review: review.removingName(person: suggestion.person), applied: applied)
    }

    /// Birleştirme önerisini uygular; kalan öneriler yeni numaralara taşınır.
    func acceptMergeSuggestion(meetingID: String, suggestion: SpeakerMergeSuggestion) {
        guard case .ready(let review, let applied) = speakerReviews[meetingID], !isLocked(meetingID: meetingID) else {
            return
        }
        guard currentPersons(meetingID: meetingID).isSuperset(of: [suggestion.from, suggestion.into]) else {
            speakerReviews[meetingID] = .ready(review: review.removingMerge(from: suggestion.from, into: suggestion.into), applied: applied)
            return
        }
        mergeSpeakers(meetingID: meetingID, from: suggestion.from, into: suggestion.into)
        speakerReviews[meetingID] = .ready(review: review.afterMerge(from: suggestion.from, into: suggestion.into), applied: applied + 1)
    }

    func dismissMergeSuggestion(meetingID: String, suggestion: SpeakerMergeSuggestion) {
        guard case .ready(let review, let applied) = speakerReviews[meetingID] else {
            return
        }
        speakerReviews[meetingID] = .ready(review: review.removingMerge(from: suggestion.from, into: suggestion.into), applied: applied)
    }

    /// Toplantının şu anki kişi numaraları (gösterilen bölümlerden).
    private func currentPersons(meetingID: String) -> Set<Int> {
        guard let record = meetings.first(where: { $0.id == meetingID }) else {
            return []
        }
        return Set(meetingSegments(record: record).compactMap(\.person))
    }

    /// Ses dosyalarını siler; metin ve not kalır.
    /// Toplantıyı (metin, not ve ses) Çöp Sepeti'ne taşır ve listeden çıkarır; kayıttaki ya da işlenen toplantı silinmez.
    /// Hata, işlemin yapıldığı sayfada gösterilmek üzere döner.
    func deleteMeeting(meetingID: String) -> String? {
        guard meetings.contains(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return String(localized: "Kayıttaki ya da işlenen toplantı silinemez.")
        }
        do {
            try trashMeetingDirectory(directory: try sessionDirectory(id: meetingID))
        } catch {
            Self.logger.error("Toplantı silinemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            return String(localized: "Toplantı silinemedi: \(userFacingMessage(error: error))")
        }
        closeSpeakerReview(meetingID: meetingID)
        meetings.removeAll { $0.id == meetingID }
        if lastFinishedMeetingID == meetingID {
            lastFinishedMeetingID = nil
        }
        return nil
    }

    func deleteAudio(meetingID: String) {
        // Kayıttaki toplantının sesi silinirse kayıt yazılmaya devam ederken dosyalar kaybolur.
        guard let record = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return
        }
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            do {
                try deleteAudioFiles(directory: directory)
                saveRecord(record: record.withAudioDeleted(), directory: directory)
            } catch {
                // Silinemediyse "silindi" işaretlenmez; saklama süresi bir sonraki denemede yeniden dener.
                Self.logger.error("Ses silinemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .public)")
                errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            }
        }
    }

    /// Açılışta: kayıtları yükler, yarıda kalanları işaretler, saklama süresini uygular ve günlük uygulamayı başlatır.
    func performStartupMaintenance() {
        reloadMeetings()
        for record in staleStatusesToInterrupt(records: meetings) {
            withSessionDirectory(id: record.id) { (directory: URL) -> Void in
                saveRecord(record: record, directory: directory)
            }
        }
        applyRetention()
        startRetentionTimer()
        Task { await refreshSetupProblems() }
    }

    /// Saklama süresi (Ayarlar) dolan toplantıların sesini siler; kilitli toplantılar atlanır.
    func applyRetention() {
        let days: Int = clampedSetting(key: SettingsKey.audioRetentionDays, range: SettingsRange.audioRetentionDays)
        for id in audioToDelete(records: meetings, now: Date(), retentionDays: days) where !isLocked(meetingID: id) {
            deleteAudio(meetingID: id)
        }
    }

    /// Uygulama günlerce açık kalabilir: saklama süresi saatte bir denetlenir.
    private func startRetentionTimer() {
        retentionTask?.cancel()
        retentionTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3600))
                } catch {
                    return
                }
                self?.applyRetention()
            }
        }
    }

    func reloadMeetings() {
        do {
            let result: MeetingLoadResult = loadMeetings(sessionsDirectory: try AppPaths.sessionsDirectory())
            meetings = result.meetings
            meetingLoadFailures = result.failures
            for failure in result.failures {
                Self.logger.error("Toplantı okunamadı, klasör: \(failure.folder, privacy: .public), neden: \(failure.reason, privacy: .private)")
            }
        } catch {
            meetingLoadFailures = [MeetingLoadFailure(folder: "Sessions", reason: userFacingMessage(error: error))]
        }
    }

    /// Kaydı diske yazar ve bellekteki listeyi günceller (her kayıtta tüm toplantılar yeniden okunmaz).
    private func saveRecord(record: MeetingRecord, directory: URL) {
        do {
            try saveMeeting(record: record, directory: directory)
            meetings = upsertMeeting(records: meetings, record: record)
        } catch {
            Self.logger.error("Toplantı kaydedilemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Toplantı kaydedilemedi: \(userFacingMessage(error: error))"))
        }
    }

    /// Toplantının klasörü (klasör adı toplantı kimliğidir).
    func sessionDirectory(id: String) throws -> URL {
        try AppPaths.sessionsDirectory().appending(path: id, directoryHint: .isDirectory)
    }

    /// Klasör gerektiren bir eylemi çalıştırır; klasör alınamazsa hata panelde görünür.
    private func withSessionDirectory(id: String, action: (URL) -> Void) {
        do {
            action(try sessionDirectory(id: id))
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Toplantı klasörüne erişilemedi: \(userFacingMessage(error: error))"))
        }
    }

    // MARK: İzinler (karşılama ekranı)

    /// Mikrofon izninin durumu.
    var microphonePermission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    /// Mikrofon iznini ister.
    func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Sistem sesi yakalamayı 2 sn deneyerek macOS izin penceresini açtırır. macOS bu iznin durumunu
    /// sorgulatmadığı için yalnızca yakalamanın başlayıp başlamadığı bilinir; başlamazsa hata fırlar.
    func probeSystemAudio() async throws {
        guard !isRecording, !isStarting else {
            throw AudioCaptureError.alreadyRunning(source: "SystemAudioCapture")
        }
        let probe: SystemAudioCapture = SystemAudioCapture()
        let stream: AsyncStream<[Float]> = try await probe.start()
        let reader: Task<Void, Never> = Task {
            for await _ in stream {}
        }
        do {
            try await Task.sleep(for: .seconds(2))
        } catch {
            // İptal: deneme erken biter.
        }
        probe.stop()
        await reader.value
    }
}

/// Hemen biten boş bir ses akışı (başlatılamayan kaynak yerine).
private func finishedStream() -> AsyncStream<[Float]> {
    let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    continuation.finish()
    return stream
}
