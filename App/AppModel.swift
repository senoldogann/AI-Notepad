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
    /// Global kısayol kaydedilemediyse menüde gösterilen hata.
    var shortcutError: String?
    /// "Diğerleri" bölümlerinin Türkçesi.
    var translations: [SegmentID: String] = [:]
    var displayMode: DisplayMode
    /// Paneldeki "Ne kaçırdım?" / soru kartı.
    var assistantCard: AssistantCard?

    /// Çeviriler sırayla yapılır: her iş bir öncekini bekler.
    @ObservationIgnored private var translationTail: Task<Void, Never>?
    /// Anahtar yoksa ya da reddedildiyse bu kayıtta çeviri durur (her cümlede aynı hata çıkmasın).
    @ObservationIgnored private var translationDisabled: Bool = false
    /// Her kayıtta artar; önceki kaydın geç gelen çevirisi/kartı yeni kayda yazılmaz (bölüm numaraları her kayıtta 0'dan başlar).
    @ObservationIgnored private var recordingGeneration: Int = 0
    /// Kayıt başında bir kez okunan Anthropic anahtarı (her cümlede Keychain okunmasın).
    @ObservationIgnored private var anthropicKey: String?
    /// Kaydedilmiş toplantılar (yeniden eskiye) ve okunamayanlar.
    var meetings: [MeetingRecord] = []
    var meetingLoadFailures: [MeetingLoadFailure] = []
    /// İşlenmekte olan toplantıların kimlikleri.
    var processingMeetingIDs: Set<String> = []
    /// Süren kaydın klasörü, başlangıcı ve (bulut motorunda) ElevenLabs anahtarı.
    @ObservationIgnored private var currentSession: (directory: URL, startedAt: Date, elevenLabsKey: String?)?
    /// Süren "Ne kaçırdım?"/soru isteği; yenisi, kapatma ya da yeni kayıt eskisini iptal eder.
    @ObservationIgnored private var assistantTask: Task<Void, Never>?
    /// Kartı yazmaya yetkili son istek.
    @ObservationIgnored private var assistantRequestID: Int = 0

    @ObservationIgnored private var engine: WhisperKitEngine?
    @ObservationIgnored private let microphone: MicrophoneCapture = MicrophoneCapture()
    @ObservationIgnored private let systemAudio: SystemAudioCapture = SystemAudioCapture()
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var isStopping: Bool = false

    init(liveEngine: LiveEngine, displayMode: DisplayMode) {
        self.liveEngine = liveEngine
        self.displayMode = displayMode
    }

    /// Görünümü değiştirir ve kaydeder.
    func selectDisplayMode(mode: DisplayMode) {
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: displayModeKey)
    }

    /// Son 3 dakikanın Türkçe özeti (Claude Opus).
    func askWhatIMissed() {
        let segments: [LiveSegment] = suppressEchoes(transcript: transcript)
        let nowSec: Double = transcript.map(\.endSec).max() ?? 0
        guard let request = missedSummaryRequest(segments: segments, nowSec: nowSec, windowSec: 180) else {
            cancelAssistant()
            assistantCard = .summary(MissedSummary(topic: "Son 3 dakikada konuşma yok.", decisions: [], askedOfYou: []))
            return
        }
        runAssistant(request: request, title: "Ne kaçırdım?") { (text: String) throws -> AssistantCard in
            .summary(try parseMissedSummary(text: text))
        }
    }

    /// Toplantı hakkında Türkçe soru (Claude Opus).
    func ask(question: String) {
        let request: ClaudeRequest = questionRequest(segments: suppressEchoes(transcript: transcript), question: question)
        runAssistant(request: request, title: "Cevap hazırlanıyor") { (text: String) throws -> AssistantCard in
            .answer(question: question, text: text)
        }
    }

    /// Kartı kapatır ve süren isteği iptal eder.
    func closeAssistantCard() {
        cancelAssistant()
        assistantCard = nil
    }

    /// Önceki isteği iptal edip yenisini çalıştırır; sonucu yalnızca hâlâ en son istekse karta yazar.
    private func runAssistant(request: ClaudeRequest, title: String, makeCard: @escaping @MainActor (String) throws -> AssistantCard) {
        cancelAssistant()
        let requestID: Int = assistantRequestID
        assistantCard = .loading(title: title)
        assistantTask = Task { [weak self] in
            let card: AssistantCard
            do {
                let key: String = try readSecret(service: keychainService, account: .anthropic)
                card = try makeCard(try await sendClaude(apiKey: key, request: request))
            } catch {
                card = .failed(message: llmUserMessage(error: error))
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

    /// Kesinleşmiş "Diğerleri" bölümünü sıraya alıp Türkçeye çevirir (Claude Haiku).
    private func enqueueTranslation(segment: LiveSegment) {
        guard !translationDisabled, let key = anthropicKey else {
            return
        }
        let context: [String] = translationContext(transcript: transcript, before: segment.id, count: 3)
        let generation: Int = recordingGeneration
        let previous: Task<Void, Never>? = translationTail
        translationTail = Task { [weak self] in
            await previous?.value
            await self?.translate(segment: segment, context: context, key: key, generation: generation)
        }
    }

    private func translate(segment: LiveSegment, context: [String], key: String, generation: Int) async {
        guard !translationDisabled, generation == recordingGeneration else {
            return
        }
        do {
            let turkish: String = try await sendClaude(apiKey: key, request: translationRequest(sentence: segment.text, context: context))
            // Bu arada yeni kayıt başladıysa sonuç başka bir toplantının aynı numaralı bölümüne yazılmaz.
            guard generation == recordingGeneration else {
                return
            }
            translations[segment.id] = turkish
        } catch {
            guard generation == recordingGeneration else {
                return
            }
            if case LLMError.http(let status, _) = error, status == 401 || status == 403 {
                translationDisabled = true
            }
            Self.logger.error("Çeviri başarısız: \(String(describing: error), privacy: .public)")
            errorMessages = appendUnique(messages: errorMessages, message: "Çeviri: " + llmUserMessage(error: error))
        }
    }

    /// Kayıt başlatılabilir mi: Deepgram'da her zaman, WhisperKit'te model hazırsa.
    var isReadyToRecord: Bool {
        liveEngine == .deepgram || modelStatus == .ready
    }

    /// Ada ve panelin gösterdiği durum.
    var viewState: LiveViewState {
        makeLiveViewState(
            transcript: transcript,
            translations: translations,
            displayMode: displayMode,
            assistantCard: assistantCard,
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
        translations = [:]
        recordingGeneration += 1
        translationTail?.cancel()
        translationTail = nil
        closeAssistantCard()
        translationDisabled = false
        lockedLanguage = nil
        errorMessages = []
        isStopping = false
        // Çeviri anahtarı kayıt başında bir kez okunur; yoksa canlı metin yine akar, tek hata gösterilir.
        do {
            anthropicKey = try readSecret(service: keychainService, account: .anthropic)
        } catch {
            anthropicKey = nil
            translationDisabled = true
            errorMessages = appendUnique(messages: errorMessages, message: "Çeviri kapalı: " + llmUserMessage(error: error))
        }

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
        let startedAt: Date = Date()
        recordingStartedAt = startedAt
        currentSession = (directory, startedAt, cloudKeys?.elevenLabs)
        // Uygulama kayıt sırasında kapanırsa toplantı açılışta "yarıda kaldı" olarak bulunur.
        saveRecord(record: MeetingRecord(
            id: directory.lastPathComponent, title: "Toplantı", startedAt: startedAt, endedAt: nil, language: nil,
            status: .recording, failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:],
            speakerNames: [:], note: nil, audioDeleted: false
        ), directory: directory)
        Self.logger.info("Kayıt başladı: \(directory.path, privacy: .public), motor: \(self.liveEngine.rawValue, privacy: .public)")
        sessionTask = Task { [weak self] in
            for await event in events {
                self?.handle(event: event)
            }
            self?.sessionEnded()
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
        case .segment(let segment):
            if segment.id.speaker == .others, segment.isFinal, !segment.text.isEmpty {
                enqueueTranslation(segment: segment)
            }
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
        guard let session = currentSession else {
            return
        }
        currentSession = nil
        let record: MeetingRecord = MeetingRecord(
            id: session.directory.lastPathComponent, title: "Toplantı", startedAt: session.startedAt, endedAt: Date(),
            language: lockedLanguage, status: .processing, failureMessage: nil,
            liveSegments: storedSegments(transcript: transcript), finalSegments: [],
            translations: Dictionary(uniqueKeysWithValues: translations.map { (segmentKey(id: $0.key), $0.value) }),
            speakerNames: [:], note: nil, audioDeleted: false
        )
        process(record: record, directory: session.directory, elevenLabsKey: session.elevenLabsKey, anthropicKey: anthropicKey)
    }

    // MARK: Toplantı kayıtları

    /// Toplantıyı sonradan işler (son geçiş + not) ve kaydeder.
    private func process(record: MeetingRecord, directory: URL, elevenLabsKey: String?, anthropicKey: String?) {
        saveRecord(record: record, directory: directory)
        processingMeetingIDs.insert(record.id)
        let languageMode: LanguageMode = languageMode
        let userName: String = UserDefaults.standard.string(forKey: userNameKey) ?? ""
        Task {
            let result: MeetingRecord = await processMeeting(
                record: record, directory: directory, elevenLabsKey: elevenLabsKey, anthropicKey: anthropicKey,
                languageMode: languageMode, userName: userName
            )
            saveRecord(record: result, directory: directory)
            processingMeetingIDs.remove(record.id)
        }
    }

    /// "Tekrar işle": anahtarları şimdi okur (Ayarlar'dan sonradan eklenmiş olabilir).
    func reprocess(meetingID: String) {
        guard let record = meetings.first(where: { $0.id == meetingID }), !processingMeetingIDs.contains(meetingID) else {
            return
        }
        // Anahtar yoksa ilgili adım atlanır (ElevenLabs) ya da açık hatayla biter (Anthropic); okuma hatası yok sayılmaz.
        let elevenLabsKey: String? = optionalSecret(account: .elevenlabs)
        let anthropicKey: String? = optionalSecret(account: .anthropic)
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            process(record: record, directory: directory, elevenLabsKey: elevenLabsKey, anthropicKey: anthropicKey)
        }
    }

    /// "Konuşmacı 2 = Aino": adı kaydeder; boş ad etiketi geri getirir.
    func renameSpeaker(meetingID: String, person: Int, name: String) {
        guard let record = meetings.first(where: { $0.id == meetingID }) else {
            return
        }
        var names: [Int: String] = record.speakerNames
        names[person] = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            saveRecord(record: record.with(speakerNames: names), directory: directory)
        }
    }

    /// Kayıtlı değilse nil; Keychain başka bir hata verirse panelde gösterilir ve nil döner.
    private func optionalSecret(account: SecretAccount) -> String? {
        do {
            return try readSecret(service: keychainService, account: account)
        } catch KeychainError.notFound {
            return nil
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: "Anahtar okunamadı: \(error.localizedDescription)")
            return nil
        }
    }

    /// Ses dosyalarını siler; metin ve not kalır.
    func deleteAudio(meetingID: String) {
        guard let record = meetings.first(where: { $0.id == meetingID }) else {
            return
        }
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            deleteAudioFiles(directory: directory)
            saveRecord(record: record.withAudioDeleted(), directory: directory)
        }
    }

    /// Açılışta: kayıtları yükler, yarıda kalanları işaretler, saklama süresi dolan sesleri siler.
    func performStartupMaintenance() {
        reloadMeetings()
        for record in staleStatusesToInterrupt(records: meetings) {
            withSessionDirectory(id: record.id) { (directory: URL) -> Void in
                saveRecord(record: record, directory: directory)
            }
        }
        for id in audioToDelete(records: meetings, now: Date(), retentionDays: audioRetentionDays) {
            deleteAudio(meetingID: id)
        }
    }

    func reloadMeetings() {
        do {
            let result: MeetingLoadResult = loadMeetings(sessionsDirectory: try AppPaths.sessionsDirectory())
            meetings = result.meetings
            meetingLoadFailures = result.failures
        } catch {
            meetingLoadFailures = [MeetingLoadFailure(folder: "Sessions", reason: String(describing: error))]
        }
    }

    private func saveRecord(record: MeetingRecord, directory: URL) {
        do {
            try saveMeeting(record: record, directory: directory)
        } catch {
            Self.logger.error("Toplantı kaydedilemedi: \(directory.path, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            errorMessages = appendUnique(messages: errorMessages, message: "Toplantı kaydedilemedi: \(error.localizedDescription)")
        }
        reloadMeetings()
    }

    /// Toplantının klasörü (klasör adı toplantı kimliğidir).
    private func sessionDirectory(id: String) throws -> URL {
        try AppPaths.sessionsDirectory().appending(path: id, directoryHint: .isDirectory)
    }

    /// Klasör gerektiren bir eylemi çalıştırır; klasör alınamazsa hata panelde görünür.
    private func withSessionDirectory(id: String, action: (URL) -> Void) {
        do {
            action(try sessionDirectory(id: id))
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: "Toplantı klasörüne erişilemedi: \(error.localizedDescription)")
        }
    }
}

/// Hemen biten boş bir ses akışı (başlatılamayan kaynak yerine).
private func finishedStream() -> AsyncStream<[Float]> {
    let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    continuation.finish()
    return stream
}

/// Kullanıcı adı (not görevlerinde "benim" tespiti için) UserDefaults anahtarı.
let userNameKey: String = "userName"
/// Ses dosyalarının saklama süresi (gün).
let audioRetentionDays: Int = 30

/// Bir toplantının `.m4a`/`.caf` ses dosyalarını siler.
private func deleteAudioFiles(directory: URL) {
    for name in ["me.m4a", "others.m4a", "me.caf", "others.caf"] {
        let file: URL = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                Logger(subsystem: "com.senoldogan.AINotepad", category: "AppModel")
                    .error("Ses silinemedi: \(file.path, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// Görünüm ayarının UserDefaults anahtarı.
let displayModeKey: String = "displayMode"

/// Claude hatalarını kullanıcıya gösterilecek Türkçe metne çevirir (anahtar içermez).
func llmUserMessage(error: any Error) -> String {
    switch error {
    case KeychainError.notFound:
        return "Anthropic anahtarı kayıtlı değil. Menüden Ayarlar…'ı açıp ekle."
    case LLMError.http(let status, _) where status == 401 || status == 403:
        return "Anthropic anahtarı geçersiz (HTTP \(status)). Ayarlar'dan kontrol et."
    case LLMError.http(let status, _):
        return "Claude isteği başarısız (HTTP \(status))."
    case LLMError.refusal:
        return "Claude bu isteği yanıtlamadı (güvenlik denetimi)."
    case LLMError.malformed, LLMError.empty:
        return "Claude'dan beklenmeyen yanıt geldi."
    default:
        return "Claude'a ulaşılamadı: \(error.localizedDescription)"
    }
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
