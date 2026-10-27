import AINotepadCore
import AINotepadUI
import AVFoundation
import AppKit
import Foundation
import UniformTypeIdentifiers
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
    let isInPerson: Bool
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
    /// Yüz yüze toplantı modu (bkz. `SettingsKey.inPersonMode`); kayıt başında okunur.
    var isInPerson: Bool = UserDefaults.standard.bool(forKey: SettingsKey.inPersonMode)
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
    /// Adı verilmiş kişilerin ses izleri (sesinden tanıma; `Voices.json`).
    var registeredVoices: [RegisteredVoice] = []
    /// Kayıtlı sesler okunamadı ya da yazılamadı (Ayarlar'da gösterilir).
    var voiceRegistryError: String?
    /// Kayıt başında panelde "katılımcılara haber ver" hatırlatması gösteriliyor.
    var consentReminderVisible: Bool = false
    /// Takvim ve Anımsatıcılar.
    @ObservationIgnored let eventKit: EventKitConnector = EventKitConnector()
    @ObservationIgnored private let notifier: MeetingNotifier = MeetingNotifier()
    @ObservationIgnored private let micMonitor: MicrophoneActivityMonitor = MicrophoneActivityMonitor()
    /// Kaydı panel ve adayla birlikte başlatır (uygulama bağlar; kendiliğinden kayıtta kullanılır).
    @ObservationIgnored var onAutoRecord: (@MainActor () async -> Void)?
    /// Kendiliğinden kayıtta bağlanacak etkinlik (çakışan etkinliklerde doğru olan kayda geçsin).
    @ObservationIgnored private var pendingAutoMeeting: CalendarMeeting?
    @ObservationIgnored private var calendarTask: Task<Void, Never>?
    @ObservationIgnored private var calendarChangesTask: Task<Void, Never>?
    @ObservationIgnored private var lastMicSuggestion: Date = .distantPast
    /// Önümüzdeki 24 saatin toplantıları (takvim açıksa).
    var upcomingMeetings: [CalendarMeeting] = []
    /// Takvim ya da bildirim hatası (Ayarlar ve Ana sayfada gösterilir).
    var calendarError: String?
    /// Bildirim izni yok: toplantı hatırlatmaları kapalı (takvim yine çalışır); Ayarlar'da görünür.
    var notificationProblem: String?
    /// Bu kaydın bağlandığı takvim toplantısı.
    @ObservationIgnored private var linkedMeeting: CalendarMeeting?
    var transcript: [LiveSegment] = []
    /// Kullanıcının kayıt sırasında yaptığı konuşmacı düzeltmeleri (otomatik ayırmanın üstüne uygulanır).
    var speakerCorrections: SpeakerCorrections = .none
    var errorMessages: [String] = []

    /// Hata şeridini kapatır (ana pencere ve panel aynı listeyi gösterir).
    func dismissErrors() {
        errorMessages = []
    }
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
    /// Kullanıcının kaydettiği tarifler (bkz. `recipes`).
    private(set) var userRecipes: [Recipe] = []
    /// iCloud eşitlemesi (Ayarlar › Genel › iCloud ile eşitle).
    let cloud: CloudSyncController = CloudSyncController()
    /// iCloud'dan henüz inmemiş toplantı sayısı.
    private(set) var cloudDownloadingCount: Int = 0
    /// Anahtarların iCloud Anahtar Zinciri kopyası (iPhone için) yazılıyor ya da başarısız oldu.
    private(set) var keySync: SyncWorkState = .idle
    /// Eşitlenen kopyası olan anahtarlar.
    private(set) var sharedKeyAccounts: [SecretAccount] = []
    /// İşlenmekte olan toplantıların kimlikleri.
    var processingMeetingIDs: Set<String> = []
    /// İşlenen toplantının şu anki adımı (panelde ilerleme kartı).
    var processingSteps: [String: ProcessingStep] = [:]
    /// Kayıttaki toplantının kimliği: bu toplantı için tekrar işle / ses sil / ad verme kilitli.
    var activeMeetingID: String?
    /// "Arka planda devam et" ile kapatılan hazırlanma kartları (panel ve ana pencere ortak).
    var dismissedProgressIDs: Set<String> = []
    /// Kayıt bitirilirken kart kapatıldı; yeni kayıtta sıfırlanır.
    var finishingCardDismissed: Bool = false
    /// Toplantı → konuşmacı incelemesi kartı.
    var speakerReviews: [String: SpeakerReviewState] = [:]

    /// Sırası gelmemiş çeviriler (gelme sırasıyla).
    @ObservationIgnored private var translationQueue: [TranslationJob] = []
    /// Süren çeviriler: en fazla `maxParallelTranslations` aynı anda. Tek tek sırayla yapılınca hızlı konuşmada her
    /// cümle bir öncekini beklediği için Türkçe giderek geride kalıyordu; sonuçlar bölüm kimliğiyle yazıldığı için
    /// sıra bozulmaz.
    @ObservationIgnored private var translationsInFlight: [UUID: Task<Void, Never>] = [:]
    /// Son gecikme uyarısı (log seli olmasın).
    @ObservationIgnored private var lastLagWarning: Date = .distantPast
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

    init(liveEngine: LiveEngine, displayMode: DisplayMode, player: MeetingAudioPlayer) {
        self.liveEngine = liveEngine
        self.displayMode = displayMode
        self.player = player
    }

    /// Uygulamanın tek oynatıcısı: kayıt başlarken durdurulur (çalan ses mikrofona girip yeni kayda karışmasın).
    @ObservationIgnored private let player: MeetingAudioPlayer

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
            newPersonNumber: nextFreePerson(transcript: transcript, corrections: speakerCorrections), isPaused: isPaused, isMicMuted: isMicMuted, canToggleMic: !isRecording || micOpenedForRecording, isInPerson: isRecording && recordingInPerson, canStart: isReadyToRecord && !isStarting,
            startedAt: recordingStartedAt, statusText: statusText,
            languageText: languageText(locked: lockedLanguage, mode: languageMode, isRecording: isRecording), errors: errorMessages
        )
        if let cache = viewStateCache, cache.inputs == inputs {
            return cache.state
        }
        let state: LiveViewState = makeLiveViewState(
            transcript: inputs.transcript, translations: inputs.translations, displayMode: inputs.displayMode,
            failedTranslations: inputs.failedTranslations, assistantCard: inputs.assistantCard, phase: inputs.phase,
            newPersonNumber: inputs.newPersonNumber, isPaused: inputs.isPaused, isMicMuted: inputs.isMicMuted, canToggleMic: inputs.canToggleMic, isInPerson: inputs.isInPerson, canStart: inputs.canStart, startedAt: inputs.startedAt, statusText: inputs.statusText, languageText: inputs.languageText, errors: inputs.errors
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
        guard displayMode.needsLiveTranslation else {
            return
        }
        // Türkçe toplantıda çeviri gerekmez: cümle olduğu gibi Türkçesidir (LLM'e gitmez, maliyet yok).
        if (lockedLanguage ?? fixedLanguage(mode: languageMode)) == .turkish {
            translations[segment.id] = segment.text
            return
        }
        guard !translationDisabled, let provider = llmProvider else {
            // Çeviri şu an yapılamıyor (anahtar reddedildi ya da sağlayıcı yok): cümle kaybolmasın, "Tekrar dene"de kalsın.
            failedTranslations.insert(segment.id)
            return
        }
        let context: [String] = translationContext(transcript: transcript, before: segment.id, count: 3)
        translationQueue.append(TranslationJob(segment: segment, context: context, provider: provider, generation: recordingGeneration))
        startQueuedTranslations()
    }

    /// Süren çevirilerden biri; yoksa nil.
    private func anyTranslationInFlight() -> Task<Void, Never>? {
        translationsInFlight.values.first
    }

    /// Boş yer oldukça sıradaki çevirileri başlatır; biten her çeviri sıradakini başlatır.
    private func startQueuedTranslations() {
        while translationsInFlight.count < maxParallelTranslations, !translationQueue.isEmpty {
            let job: TranslationJob = translationQueue.removeFirst()
            let id: UUID = UUID()
            translationsInFlight[id] = Task { [weak self] in
                await self?.translate(segment: job.segment, context: job.context, provider: job.provider, generation: job.generation)
                self?.translationsInFlight[id] = nil
                self?.startQueuedTranslations()
            }
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
            // Kayıt sonunda süre dolunca iptal edilen çeviri hata değildir (panelde "Çeviri: …" hatası çıkmasın).
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                failedTranslations.insert(segment.id)
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
        // Kayıt bittikten sonra çevrilen cümle toplantıya yazılmaz (kayıt çoktan saklandı ve işlendi): yalnızca kayıtta.
        guard isRecording, !isFinishing else {
            return
        }
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
            // Kayıt sürerken sağlayıcı her ayar değişiminde yeniden çözülür (model ya da anahtar değişimi hemen geçerli
            // olsun); çevrilemeyen cümleler yeni sağlayıcıyla yeniden sıraya alınır.
            if isRecording, !isFinishing, await refreshLLMProvider() {
                retryTranslations(ids: Array(failedTranslations))
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
        player.stop()
        transcript = []
        speakerCorrections = .none
        meStreamFailed = false
        translations = [:]
        failedTranslations = []
        recordingGeneration += 1
        translationQueue = []
        translationsInFlight.values.forEach { $0.cancel() }
        translationsInFlight = [:]
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

        // Takvimde şu anki toplantı: başlık ve katılımcı adları kayda geçer, adlar tanımaya yardım eder.
        linkedMeeting = pendingAutoMeeting ?? (UserDefaults.standard.bool(forKey: SettingsKey.calendarEnabled)
            ? currentMeeting(meetings: upcomingMeetings, now: Date())
            : nil)
        pendingAutoMeeting = nil
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
        let othersAudio: AsyncStream<[Float]>
        recordingInPerson = isInPerson
        if isInPerson, linkedMeeting?.joinURL != nil {
            // Çevrimiçi görüşmede yüz yüze modu karşı tarafı kaydetmez: açıkça uyarılır.
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Yüz yüze modu açık: çevrimiçi görüşmenin karşı tarafı kaydedilmiyor. Ana sayfadaki \"Yüz yüze\"yi kapatıp kaydı yeniden başlat."))
        }
        if isInPerson {
            // Yüz yüze: odadaki herkes mikrofondan gelir; "Diğerleri" akışı olarak konuşmacılara ayrılır (kullanıcı da
            // onlardan biri). Sistem sesi dinlenmez.
            meAudio = finishedStream()
            micOpenedForRecording = false
            do {
                let aligned: AsyncStream<[Float]> = clockAlignedStream(audio: try await microphone.start(), origin: origin, sampleRate: 16000, thresholdSec: 0.5)
                othersAudio = gatedStream(audio: aligned, gate: pauseGate)
                startedSpeakers.insert(.others)
            } catch {
                errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
                othersAudio = finishedStream()
            }
        } else {
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
        do {
            let aligned: AsyncStream<[Float]> = clockAlignedStream(audio: try await systemAudio.start(), origin: origin, sampleRate: 16000, thresholdSec: 0.5)
            othersAudio = gatedStream(audio: aligned, gate: pauseGate)
            startedSpeakers.insert(.others)
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            othersAudio = finishedStream()
        }
        }
        guard !startedSpeakers.isEmpty else {
            return
        }

        // Ses seviyesi panelde görünür (sesin geldiği anlaşılsın); iki akışın en yükseği çubuğa düşer.
        audioLevels.start()
        let levels: AudioLevels = audioLevels
        let onLevel: @Sendable (Float) -> Void = { (level: Float) -> Void in
            let now: Date = Date()
            Task { @MainActor in levels.record(level: level, at: now) }
        }
        let meteredMe: AsyncStream<[Float]> = meteredStream(audio: meAudio, onLevel: onLevel)
        let meteredOthers: AsyncStream<[Float]> = meteredStream(audio: othersAudio, onLevel: onLevel)
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
                    languageConfidence: 0.8,
                    keyterms: keytermsWithAttendees(attendees: linkedMeeting?.attendees ?? [], keyterms: recognitionKeyterms, limit: 30),
                    voiceEmbedder: voiceEmbedderIfEnabled(),
                    automaticStartLanguage: primaryMeetingLanguage()
                ),
                meAudio: meteredMe,
                othersAudio: meteredOthers
            )
        } else if let engine {
            handle = runLiveSession(
                config: LiveSessionConfig(
                    languageMode: languageMode,
                    segmenter: .live,
                    recordingDirectory: directory,
                    partialIntervalSec: 1.5,
                    minPartialSpeechSec: 1.0,
                    languageLockAfterSec: 30,
                    candidateLanguages: automaticCandidates(primary: primaryMeetingLanguage())
                ),
                engine: engine,
                meAudio: meteredMe,
                othersAudio: meteredOthers
            )
        } else {
            // isReadyToRecord WhisperKit'te motoru garanti eder; buraya gelinmesi programlama hatasıdır.
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Konuşma tanıma modeli hazır değil."))
            microphone.stop()
            systemAudio.stop()
            return
        }
        isRecording = true
        liveHighlights = []
        liveMyNotes = ""
        recordingTemplate = defaultNoteTemplate()
        consentReminderVisible = UserDefaults.standard.bool(forKey: SettingsKey.consentReminder)
        // Yeni bitirme için hazırlanma kartı yeniden gösterilir.
        finishingCardDismissed = false
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
        consentReminderVisible = false
        audioLevels.stop()
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
            logLiveLagIfHigh(segment: segment)
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

    /// Canlı metin konuşmanın 2 sn'den fazla gerisindeyse (yarım dakikada en fazla bir kez) uyarı loglanır: gecikme
    /// şikâyetinde nerede biriktiği görülsün. Doldurulan boşluklar (geç gelmeleri doğaldır) sayılmaz.
    private func logLiveLagIfHigh(segment: LiveSegment) {
        guard let startedAt = recordingStartedAt, !segment.text.isEmpty, segment.id.index < 1_000_000 else {
            return
        }
        let lag: Double = Date().timeIntervalSince(startedAt) - segment.endSec
        guard lag > 2, Date().timeIntervalSince(lastLagWarning) > 30 else {
            return
        }
        lastLagWarning = Date()
        Self.logger.warning("Canlı metin gecikiyor, gecikme: \(lag, privacy: .public), kesin: \(segment.isFinal, privacy: .public), konuşmacı: \(segment.id.speaker.rawValue, privacy: .public)")
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
        // Oturum kendiliğinden de bitebilir (ör. ses akışı koptu): yakalama, ses çubukları ve rıza hatırlatması burada da
        // kapanır; yoksa sonraki kayıt "zaten çalışıyor" hatası alıp karşı tarafı kaydedemezdi. İkinci kez çağrılması
        // zararsızdır.
        microphone.stop()
        systemAudio.stop()
        audioLevels.stop()
        consentReminderVisible = false
        guard let finished = session else {
            return
        }
        // Kayıt, oturum temizlenmeden yazılır: motoru (yerel ya da bulut) kaydın gerçek motorudur, şimdiki ayar değil.
        let record: MeetingRecord = liveRecord(directory: finished.directory, startedAt: finished.startedAt, status: .processing, endedAt: Date())
        session = nil
        activeMeetingID = nil
        process(record: record, directory: finished.directory)
        lastFinishedMeetingID = record.id
    }

    /// Kuyruktaki çevirileri en fazla `timeoutSec` bekler; süre dolarsa kalan çeviriler durdurulur (kaydedilmez, loglanır).
    private func waitForPendingTranslations(timeoutSec: Double) async {
        let completed: Bool = await finishesWithin(seconds: timeoutSec) { [weak self] in
            // Biten çeviri sıradakini başlatır: kuyruk ve süren işler bitene dek beklenir.
            while let next = await self?.anyTranslationInFlight() {
                await next.value
            }
        }
        if !completed {
            // Sıradaki işler başlamaz; süren istekler iptal edilir.
            translationDisabled = true
            translationQueue = []
            translationsInFlight.values.forEach { $0.cancel() }
            Self.logger.warning("Kayıt sonunda bekleyen çeviriler süre içinde bitmedi, süre: \(timeoutSec, privacy: .public)")
        }
    }

    /// Canlı transkript ve çevirilerden toplantı kaydı.
    private func liveRecord(directory: URL, startedAt: Date, status: MeetingStatus, endedAt: Date?) -> MeetingRecord {
        let base: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: linkedMeeting?.title ?? String(localized: "Toplantı"), startedAt: startedAt, endedAt: endedAt,
            language: lockedLanguage, status: status, failureMessage: nil,
            liveSegments: storedSegments(transcript: correctedTranscript), finalSegments: [],
            translations: Dictionary(uniqueKeysWithValues: translations.map { (segmentKey(id: $0.key), $0.value) }),
            speakerNames: [:], note: nil, audioDeleted: false,
            engine: session?.engine.recordingEngine ?? liveEngine.recordingEngine, notice: nil,
            meNeedsFinalPass: meStreamFailed ? true : nil
        )
        // Not, kayıt başladığında seçili şablonla yazılır; kayıtta işaretlenen anlar öne çıkar.
        .with(template: recordingTemplate)
        .with(highlights: liveHighlights)
        .with(myNotes: liveMyNotes)
        return linkedMeeting.map { base.with(attendees: $0.attendees).with(calendarEventID: $0.id) } ?? base
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
                record: record, directory: directory, finalPass: plan, llm: llm, languageMode: languageMode, userName: userName,
                voiceEmbedder: voiceEmbedderIfEnabled(), registry: registeredVoices
            ) { (step: ProcessingStep) async -> Void in
                self.processingSteps[record.id] = step
            }
            // Tekrar işlemede eski not geçmişe girer (ilk işlemede not yoktur).
            let versioned: MeetingRecord = withNoteVersion(updated: result, previous: record, reason: String(localized: "Tekrar işlendi"), savedAt: Date())
            let saved: MeetingRecord = applyingPendingReminders(record: versioned)
            saveRecord(record: saved, directory: directory)
            processingMeetingIDs.remove(record.id)
            processingSteps[record.id] = nil
            allowSleep(meetingID: record.id)
            autoSendToDestinations(record: saved)
            if saved.status == .done {
                await cloud.moveFinishedMeetings(excluding: cloudMoveExclusions) { [weak self] in self?.reloadMeetings() }
            }
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

    /// Bu kayıt yüz yüze başladı (mod kayıt sırasında değişmez).
    @ObservationIgnored private var recordingInPerson: Bool = false

    /// Bu kaydın not şablonu: kayıt başlarken Ayarlar'daki varsayılan.
    @ObservationIgnored private var recordingTemplate: NoteTemplate = .general

    /// Konuşma tanımaya verilen adlar ve terimler: kullanıcının adı, son toplantıların konuşmacı adları ve sözlük
    /// terimleri (en fazla 30; ElevenLabs'ta %20 ek ücret, sınırlı tutulur).
    private var recognitionKeyterms: [String] {
        // Kullanıcının adı ve sözlüğü öne; sınırda (30) önce toplantılardan gelenler düşer.
        let userName: String = UserDefaults.standard.string(forKey: SettingsKey.userName) ?? ""
        return keytermsWithAttendees(
            attendees: [userName] + customVocabulary(text: UserDefaults.standard.string(forKey: SettingsKey.customVocabulary) ?? "")
                + peopleBook.saved.map(\.name),
            keyterms: meetingKeyterms(records: Array(meetings.prefix(20)), userName: userName, limit: 30),
            limit: 30
        )
    }

    /// Kaydın motoruna göre son geçiş; eski toplantılar (motor bilgisi yok) bulut sayılır.
    private func finalPassPlan(record: MeetingRecord) async -> FinalPassPlan {
        switch record.engine ?? .cloud {
        case .local:
            do {
                return .run(LocalFinalTranscriber(
                    modelsDirectory: try AppPaths.modelsDirectory(), modelName: liveWhisperModel,
                    candidateLanguages: automaticCandidates(primary: primaryMeetingLanguage())
                ))
            } catch {
                return .skip(reason: userFacingMessage(error: error))
            }
        case .cloud:
            do {
                guard let key = try await optionalSecretInBackground(service: keychainService, account: .elevenlabs) else {
                    return .skip(reason: String(localized: "ElevenLabs anahtarı kayıtlı değil."))
                }
                return .run(ElevenLabsFinalTranscriber(apiKey: key, keyterms: recognitionKeyterms))
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
        rewriteNote(record: record, reason: String(localized: "Not yenilendi"))
    }

    /// Notu kullanıcının isteğine göre düzenler ("özeti kısalt", "görevlere tarih ekle"); düzenlenirken toplantı kilitli,
    /// hata olursa not değişmez ve neden gösterilir.
    func editNote(meetingID: String, instruction: String) {
        let trimmed: String = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let record = meetings.first(where: { $0.id == meetingID }), record.note != nil, !isLocked(meetingID: meetingID) else {
            return
        }
        let userName: String = UserDefaults.standard.string(forKey: SettingsKey.userName) ?? ""
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            processingMeetingIDs.insert(meetingID)
            Task {
                defer { processingMeetingIDs.remove(meetingID) }
                guard let llm = await optionalLLMProvider() else {
                    errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Not düzenlenemedi: LLM anahtarı ya da ayarı yok."))
                    return
                }
                do {
                    let edited: MeetingRecord = try await editMeetingNote(record: record, instruction: trimmed, llm: llm, userName: userName)
                    // Eski not geçmişe girer ("Geri al"); düzenleme sürerken Anımsatıcılar'a eklenenler kaybolmasın.
                    let versioned: MeetingRecord = withNoteVersion(
                        updated: edited, previous: record, reason: String(localized: "Düzenlendi: \(trimmed)"), savedAt: Date()
                    )
                    saveRecord(record: applyingPendingReminders(record: versioned), directory: directory)
                    refreshFolderCopy(meetingID: meetingID)
                } catch {
                    Self.logger.error("Not düzenlenemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                    errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Not düzenlenemedi: \(userFacingMessage(error: error))"))
                }
            }
        }
    }

    /// Kendi notlarını saklar ve notu onlarla yeniden yazar.
    func saveMyNotes(meetingID: String, text: String) {
        guard let record = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return
        }
        rewriteNote(record: record.with(myNotes: text), reason: String(localized: "Kendi notlarınla yeniden yazıldı"))
    }

    /// Notu başka bir şablonla yeniden yazar (şablon toplantıda saklanır).
    func regenerateNote(meetingID: String, template: NoteTemplate) {
        guard let record = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return
        }
        rewriteNote(record: record.with(template: template), reason: String(localized: "Şablonla yeniden yazıldı"))
    }

    /// Notu paylaşım diline çevirir ve saklar; hata varsa kullanıcı metni döner.
    func generateSharedNote(meetingID: String, language: ShareLanguage) async -> String? {
        guard let record = meetings.first(where: { $0.id == meetingID }), let note = record.note else {
            return nil
        }
        let userName: String = UserDefaults.standard.string(forKey: SettingsKey.userName) ?? ""
        do {
            let provider: LLMProvider = try await resolveLLMProvider()
            let shared: MeetingNote = try await requestStructured(provider: provider, request: sharedNoteRequest(note: note, language: language, userName: userName)) { (text: String) throws -> MeetingNote in
                try parseSharedNote(text: text, original: note)
            }
            // Çeviri sürerken not yeniden yazıldıysa eski notun çevirisi saklanmaz.
            guard let current = meetings.first(where: { $0.id == meetingID }), current.note == note, !isLocked(meetingID: meetingID) else {
                return nil
            }
            withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
                saveRecord(record: current.with(sharedNotes: (current.sharedNotes ?? [:]).merging([language.rawValue: shared]) { $1 }), directory: directory)
            }
            return nil
        } catch is CancellationError {
            // Görünüm kapandı ya da dil değişti: hata değil.
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            Self.logger.error("Paylaşım notu yazılamadı, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            return userFacingMessage(error: error)
        }
    }

    /// Notu verilen kayıtla (adlar, şablon) yeniden yazıp kaydeder; eski not `reason` ile geçmişe girer.
    private func rewriteNote(record: MeetingRecord, reason: String) {
        let meetingID: String = record.id
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
                let result: MeetingRecord = await AINotepadCore.regenerateNote(record: record, directory: directory, llm: llm, userName: userName)
                let versioned: MeetingRecord = withNoteVersion(updated: result, previous: record, reason: reason, savedAt: Date())
                saveRecord(record: applyingPendingReminders(record: versioned), directory: directory)
                processingMeetingIDs.remove(meetingID)
                refreshFolderCopy(meetingID: meetingID)
            }
        }
    }

    /// Notun önceki sürümünü geri yükler (`index`: geçmişte yeniden eskiye sıra); şimdiki not geçmişe girer, geri yükleme
    /// de geri alınabilir.
    func restoreNoteVersion(meetingID: String, index: Int) {
        guard let record = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return
        }
        do {
            let restored: MeetingRecord = try restoringNoteVersion(
                record: record, index: index, reason: String(localized: "Önceki sürüm geri yüklendi"), savedAt: Date()
            )
            withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
                saveRecord(record: restored, directory: directory)
            }
            refreshFolderCopy(meetingID: meetingID)
        } catch {
            Self.logger.error("Not sürümü geri yüklenemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Not sürümü geri yüklenemedi: \(userFacingMessage(error: error))"))
        }
    }

    /// Toplantının adını değiştirir (not başlığı da); boş ad yok sayılır.
    func renameMeeting(meetingID: String, title: String) {
        let trimmed: String = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let record = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return
        }
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            saveRecord(record: record.with(title: trimmed), directory: directory)
        }
        refreshFolderCopy(meetingID: meetingID)
    }

    /// "Konuşmacı 2 = Aino": adı kaydeder; boş ad etiketi geri getirir.
    func renameSpeaker(meetingID: String, person: Int, name: String) {
        // İşleme bitince kayıt bütünüyle yazıldığı için bu sırada verilen ad kaybolurdu.
        guard let record = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return
        }
        var names: [Int: String] = record.speakerNames
        let trimmed: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous: String? = names[person]
        names[person] = trimmed.isEmpty ? nil : trimmed
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            saveRecord(record: record.with(speakerNames: names), directory: directory)
        }
        refreshFolderCopy(meetingID: meetingID)
        let source: String = voiceSource(meetingID: meetingID, person: person)
        // Ad düzeltildiyse bu kişinin sesi eski addan geri alınır (yoksa sonraki toplantılarda yanlış adla tanınırdı).
        var voices: [RegisteredVoice] = registeredVoices
        if let previous, previous.caseInsensitiveCompare(trimmed) != .orderedSame {
            voices = unregistering(voices: voices, name: previous, source: source, now: Date())
        }
        // Adı verilen kişinin sesi hatırlanır: sonraki toplantılarda (ve "Tekrar işle"de) ad kendiliğinden gelir.
        if !trimmed.isEmpty, UserDefaults.standard.bool(forKey: SettingsKey.voiceRecognition), let voice = record.voiceprints?[person] {
            voices = registering(voices: voices, name: trimmed, voiceprint: voice, source: source, now: Date())
        }
        if voices != registeredVoices {
            storeVoices(voices: voices)
        }
    }

    /// Yüz yüze modunu değiştirir (kayıt yokken).
    func toggleInPerson() {
        guard !isRecording else {
            return
        }
        isInPerson.toggle()
        UserDefaults.standard.set(isInPerson, forKey: SettingsKey.inPersonMode)
    }

    // MARK: Klasörler

    /// Oluşturulan klasörler (toplantısız olanlar dahil).
    var savedFolders: [String] = UserDefaults.standard.stringArray(forKey: SettingsKey.folders) ?? []

    /// Klasörler ve toplantı sayıları.
    var folders: [FolderSummary] {
        meetingFolders(records: meetings, saved: savedFolders)
    }

    /// Yeni klasör oluşturur (aynı ad varsa bir şey yapmaz).
    func createFolder(name: String) {
        let trimmed: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !folders.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return
        }
        savedFolders.append(trimmed)
        UserDefaults.standard.set(savedFolders, forKey: SettingsKey.folders)
    }

    /// Klasörü siler: toplantılar silinmez, klasörsüz kalır.
    func deleteFolder(name: String) {
        savedFolders.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        UserDefaults.standard.set(savedFolders, forKey: SettingsKey.folders)
        moveMeetings(ids: Set(meetingsInFolder(records: meetings, folder: name).map(\.id)), to: nil)
    }

    /// Klasör silinebilir mi: içindeki toplantılardan biri kayıtta ya da işlemedeyse hayır (o toplantı klasörden
    /// çıkarılamaz, klasör yeniden belirirdi).
    func canDeleteFolder(name: String) -> Bool {
        !meetingsInFolder(records: meetings, folder: name).contains { isLocked(meetingID: $0.id) }
    }

    /// Toplantıları klasöre taşır (nil: klasörden çıkarır); kilitli (kayıtta/işlemede) olanlar atlanır.
    func moveMeetings(ids: Set<String>, to folder: String?) {
        for record in meetings where ids.contains(record.id) && !isLocked(meetingID: record.id) {
            withSessionDirectory(id: record.id) { (directory: URL) -> Void in
                saveRecord(record: record.with(folder: folder), directory: directory)
            }
        }
    }

    // MARK: İşaretler

    /// Kayıt sırasında canlı ses seviyesi (panelde çubuklar).
    @ObservationIgnored let audioLevels: AudioLevels = AudioLevels(count: 14, interval: 0.1)

    /// Bu kayıtta işaretlenen anlar.
    @ObservationIgnored private var liveHighlights: [Highlight] = []
    /// Kullanıcının kayıt sırasında yazdığı notlar (panelde "Notlarım"); kayıtla saklanır.
    var liveMyNotes: String = ""

    /// Kayıtta şu anı işaretler (notta öne çıkar).
    func bookmarkNow() {
        guard isRecording, let startedAt = recordingStartedAt else {
            return
        }
        liveHighlights.append(Highlight(startSec: Date().timeIntervalSince(startedAt), endSec: nil))
    }

    /// Kaydedilmiş toplantıda bir paragrafın işaretini açar/kapatır.
    func toggleHighlight(meetingID: String, paragraph: TranscriptParagraph) {
        guard let record = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return
        }
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            let highlights: [Highlight] = togglingHighlight(highlights: record.highlights ?? [], paragraphs: transcriptParagraphs(record: record), paragraph: paragraph)
            saveRecord(record: record.with(highlights: highlights), directory: directory)
        }
    }

    // MARK: Dosya içe aktarma

    /// İçe aktarılmakta olan dosya sayısı (dönüştürme sürerken).
    var importingCount: Int = 0
    /// Kayıt, işleme ya da içe aktarma sürüyor mu (çıkış ve dil değişikliği bunu bekler).
    var isBusy: Bool { phase != .idle || !processingMeetingIDs.isEmpty || importingCount > 0 }
    /// Son içe aktarma hatası (Toplantılar listesinde gösterilir).
    var importError: String?

    /// Ses/video dosyalarını toplantı olarak içe aktarır: ses izi `others.m4a` olur, sonra kayıt gibi son geçiş
    /// (konuşmacılar, sesinden tanıma) ve not. Motor ve şablon şu anki ayarlardır.
    func importMedia(urls: [URL]) {
        importError = nil
        importingCount += urls.count
        // Dosyalar sırayla dönüştürülür: çok dosya bırakılınca açık kayıt ve diğer işler yavaşlamasın.
        Task {
            for url in urls {
                await importOne(url: url)
                importingCount -= 1
            }
        }
    }

    /// Tek dosyayı içe aktarır; başarısızsa yarım klasör silinir ve hata listede gösterilir.
    private func importOne(url: URL) async {
        var created: URL?
        do {
            let session: (url: URL, startedAt: Date) = try AppPaths.newExclusiveSessionDirectory(startedAt: Date())
            created = session.url
            let accessed: Bool = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let duration: Double = try await importMediaAudio(source: url, destination: session.url.appending(path: "others.m4a"))
            let record: MeetingRecord = importedMeetingRecord(
                id: session.url.lastPathComponent, source: url, startedAt: session.startedAt, durationSec: duration,
                engine: liveEngine.recordingEngine, template: defaultNoteTemplate()
            )
            Self.logger.info("Dosya içe aktarıldı, toplantı: \(record.id, privacy: .public), süre: \(Int(duration), privacy: .public)")
            process(record: record, directory: session.url)
        } catch {
            Self.logger.error("Dosya içe aktarılamadı, hata: \(String(describing: error), privacy: .private)")
            importError = String(localized: "\(url.lastPathComponent) içe aktarılamadı: \(mediaImportMessage(error: error))")
            if let created {
                do {
                    try FileManager.default.removeItem(at: created)
                } catch {
                    Self.logger.error("Yarım içe aktarma klasörü silinemedi, hata: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }

    // MARK: Takvim

    /// Takvim açıksa toplantıları 5 dk'da bir ve takvim değişince yeniler, hatırlatmaları kurar; görüşme önerisi açıksa
    /// mikrofonu izler. Ayar değişince yeniden çağrılır.
    func startCalendarServices() {
        calendarTask?.cancel()
        calendarChangesTask?.cancel()
        micMonitor.stop()
        guard UserDefaults.standard.bool(forKey: SettingsKey.calendarEnabled) else {
            // Hata burada silinmez: izin reddedilince ayar kapanır ve neden görünür kalmalı.
            upcomingMeetings = []
            // Kapatılınca kurulu hatırlatmalar kaldırılır.
            Task {
                do {
                    try await notifier.scheduleReminders(meetings: [])
                } catch {
                    Self.logger.error("Toplantı hatırlatmaları kaldırılamadı, hata: \(String(describing: error), privacy: .public)")
                }
            }
            return
        }
        let changes: NotificationCenter.Notifications = eventKit.changes
        calendarTask = Task { [weak self] in
            await self?.refreshCalendar()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(300))
                } catch {
                    return
                }
                await self?.refreshCalendar()
            }
        }
        calendarChangesTask = Task { [weak self] in
            for await _ in changes {
                await self?.refreshCalendar()
            }
        }
        if UserDefaults.standard.bool(forKey: SettingsKey.micSuggestions) || UserDefaults.standard.bool(forKey: SettingsKey.autoRecord) {
            micMonitor.start { [weak self] in self?.microphoneStartedElsewhere() }
        }
    }

    /// Takvimi kapatır (kullanıcı); önceki hata da kalkar.
    func disableCalendar() {
        UserDefaults.standard.set(false, forKey: SettingsKey.calendarEnabled)
        calendarError = nil
        startCalendarServices()
    }

    /// Takvimi açar: takvim ve bildirim izni ister, servisleri başlatır. İzin yoksa ayar kapalı kalır, hata gösterilir.
    func enableCalendar() async {
        do {
            try await eventKit.requestCalendarAccess()
            UserDefaults.standard.set(true, forKey: SettingsKey.calendarEnabled)
            calendarError = nil
        } catch {
            UserDefaults.standard.set(false, forKey: SettingsKey.calendarEnabled)
            calendarError = eventKitMessage(error: error)
            startCalendarServices()
            return
        }
        // Bildirim izni yalnızca hatırlatmalar için gerekir: reddedilse de takvim (bugünün toplantıları, brifing,
        // kendiliğinden kayıt) açık kalır; hatırlatmalar kapanır ve neden görünür.
        do {
            try await notifier.requestAuthorization()
            notificationProblem = nil
        } catch {
            UserDefaults.standard.set(false, forKey: SettingsKey.meetingReminders)
            notificationProblem = notificationMessage(error: error)
        }
        startCalendarServices()
    }

    /// Bugünün (biteni de: notu takvimden açılır) ve önümüzdeki 24 saatin toplantılarını okur, 3 saat içindekiler için
    /// hatırlatma kurar.
    private func refreshCalendar() async {
        do {
            let now: Date = Date()
            let dayStart: Date = Calendar.current.startOfDay(for: now)
            upcomingMeetings = try eventKit.meetings(from: dayStart, hours: now.timeIntervalSince(dayStart) / 3600 + 24)
            let remind: [CalendarMeeting] = UserDefaults.standard.bool(forKey: SettingsKey.meetingReminders)
                // Son bir dakikaya girmiş toplantı yeniden kurulmaz (hatırlatması zaten gösterildi; çift bildirim olmasın).
                ? meetingsToRemind(meetings: upcomingMeetings, now: Date().addingTimeInterval(60), horizonSec: 3 * 3600)
                : []
            try await notifier.scheduleReminders(meetings: remind)
            calendarError = nil
        } catch {
            Self.logger.error("Takvim okunamadı, hata: \(String(describing: error), privacy: .public)")
            calendarError = error is NotificationError ? notificationMessage(error: error) : eventKitMessage(error: error)
        }
    }

    /// Başka bir uygulama mikrofonu açtı (kayıt yokken). Takvimde süren çevrim içi görüşme varsa ve kendiliğinden başlatma
    /// açıksa kayıt başlar ve bildirilir; değilse (10 dk'da en fazla bir) "dinlemeye başla" önerisi.
    private func microphoneStartedElsewhere() {
        guard !isRecording, !isStarting else {
            return
        }
        if UserDefaults.standard.bool(forKey: SettingsKey.autoRecord),
           let meeting = meetingToAutoRecord(meetings: upcomingMeetings, records: meetings, now: Date()),
           let onAutoRecord {
            Self.logger.info("Görüşme kendiliğinden kaydediliyor, etkinlik: \(meeting.id, privacy: .private)")
            pendingAutoMeeting = meeting
            Task {
                await onAutoRecord()
                // Başlatma sessizce bitmiş olabilir (anahtar ya da model yok): bildirim gerçeği söylesin.
                pendingAutoMeeting = nil
                do {
                    if isRecording {
                        try await notifier.announceAutoRecording(title: meeting.title)
                    } else {
                        Self.logger.error("Kendiliğinden kayıt başlamadı, etkinlik: \(meeting.id, privacy: .private)")
                        try await notifier.announceAutoRecordingFailed(title: meeting.title)
                    }
                } catch {
                    Self.logger.error("Kendiliğinden kayıt bildirilemedi, hata: \(String(describing: error), privacy: .public)")
                }
            }
            return
        }
        guard UserDefaults.standard.bool(forKey: SettingsKey.micSuggestions), Date().timeIntervalSince(lastMicSuggestion) > 600 else {
            return
        }
        lastMicSuggestion = Date()
        Task {
            do {
                try await notifier.suggestRecording()
            } catch {
                Self.logger.error("Görüşme önerisi gösterilemedi, hata: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Toplantılarıma sor

    /// Açık sohbetin soruları ve cevapları.
    var archiveExchanges: [ArchiveExchange] = []
    /// Saklanan sohbetler (yeniden eskiye; en fazla `askHistoryLimit`).
    var askConversations: [AskConversation] = []
    /// Açık sohbetin kimliği: ilk cevap saklanınca atanır, "Yeni sohbet"te nil.
    var currentConversationID: UUID?
    /// Cevaplanan soru (durdurulabilir).
    @ObservationIgnored private var archiveTask: Task<Void, Never>?

    /// Bir soru cevaplanıyor (yenisi sorulamaz, durdurulabilir).
    var isAnsweringArchive: Bool {
        archiveExchanges.last.map { [.understanding, .searching, .writing].contains($0.phase) } ?? false
    }

    /// Tüm toplantılara soru sorar; ajanın adımları (terimler, okunan parçalar) ve akan cevap listede güncellenir.
    /// Önceki cevaplar devam soruları için bağlamdır.
    /// Arşive sorar; `meetingIDs` boş değilse soru yalnız o toplantılara sorulur (`@` ile etiketlenenler).
    func askArchive(question: String, meetingIDs: [String], recipeTitle: String?) {
        let trimmed: String = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnsweringArchive else {
            return
        }
        let history: [ArchiveTurn] = archiveHistory(exchanges: archiveExchanges)
        let id: UUID = UUID()
        let scoped: [MeetingRecord] = meetings.filter { meetingIDs.contains($0.id) }
        archiveExchanges.append(ArchiveExchange(
            id: id, question: trimmed, scopeMeetingIDs: scoped.map(\.id), scopeTitles: scoped.map { $0.note?.title ?? $0.title }, recipeTitle: recipeTitle, startedAt: Date(), phase: .understanding,
            terms: [], passages: [], answer: ArchiveAnswer(text: "", sources: []), finishedAt: nil, modelName: nil
        ))
        let records: [MeetingRecord] = meetings
        let userName: String = UserDefaults.standard.string(forKey: SettingsKey.userName) ?? ""
        archiveTask = Task { [weak self] in
            do {
                let provider: LLMProvider = try await resolveLLMProvider()
                self?.updateExchange(id: id) { $0.modelName = llmModelDisplayName(provider: provider, tier: .smart) }
                let onProgress: ArchiveProgressHandler = { [weak self] (progress: ArchiveProgress) -> Void in
                    await self?.apply(progress: progress, id: id)
                }
                if scoped.isEmpty {
                    _ = try await AINotepadCore.askArchive(
                        question: trimmed, history: history, records: records, userName: userName, llm: provider, maxChars: 60_000, now: Date(),
                        onProgress: onProgress
                    )
                } else {
                    _ = try await askAboutMeetings(
                        question: trimmed, history: history, records: scoped, userName: userName, llm: provider, maxChars: 60_000, now: Date(),
                        onProgress: onProgress
                    )
                }
                self?.updateExchange(id: id) {
                    $0.phase = .done
                    $0.finishedAt = Date()
                }
                self?.saveConversation(exchangeID: id)
            } catch is CancellationError {
                self?.updateExchange(id: id) {
                    $0.phase = .stopped
                    $0.finishedAt = Date()
                }
            } catch let error as URLError where error.code == .cancelled {
                self?.updateExchange(id: id) {
                    $0.phase = .stopped
                    $0.finishedAt = Date()
                }
            } catch {
                Self.logger.error("Arşiv sorusu cevaplanamadı, hata: \(String(describing: error), privacy: .private)")
                self?.updateExchange(id: id) {
                    $0.phase = .failed(userFacingMessage(error: error))
                    $0.finishedAt = Date()
                }
            }
        }
    }

    /// Tarifler: yerleşikler ve kullanıcının kaydettikleri.
    var recipes: [Recipe] {
        builtInRecipes() + userRecipes
    }

    /// Soruyu tarif olarak kaydeder ("/" ile yeniden sorulur).
    func saveRecipe(question: String) {
        storeUserRecipes(userRecipes + [recipeFromQuestion(question: question, id: UUID().uuidString)])
    }

    /// Agent Skill dosyalarını (`SKILL.md`) tarif olarak ekler; okunamayanların nedeni döner.
    func importSkills(files: [URL]) -> [String] {
        var imported: [Recipe] = []
        var failures: [String] = []
        for file in files {
            do {
                let text: String = try String(contentsOf: file, encoding: .utf8)
                imported.append(try recipeFromSkill(text: text, file: file.lastPathComponent, id: UUID().uuidString))
            } catch {
                failures.append("\(file.lastPathComponent): \(userFacingMessage(error: error))")
            }
        }
        if !imported.isEmpty {
            storeUserRecipes(userRecipes + imported)
        }
        return failures
    }

    /// Kullanıcı tarifini siler.
    func deleteRecipe(id: String) {
        storeUserRecipes(userRecipes.filter { $0.id != id })
    }

    private func storeUserRecipes(_ recipes: [Recipe]) {
        do {
            try saveUserRecipes(recipes: recipes, defaults: .standard)
            userRecipes = recipes
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Kayıtlı kullanıcı tariflerini okur (açılışta); okunamazsa neden gösterilir, yerleşikler çalışır.
    func loadRecipes() {
        do {
            userRecipes = try loadUserRecipes(defaults: .standard)
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Akan cevabı durdurur; o ana kadar yazılan kalır.
    func stopArchiveAnswer() {
        archiveTask?.cancel()
    }

    /// Sohbeti temizler (yeni konu: önceki cevaplar bağlam olmaz); önceki sohbet geçmişte kalır.
    func clearArchiveConversation() {
        archiveTask?.cancel()
        archiveExchanges = []
        currentConversationID = nil
    }

    /// Saklanan sohbeti açar; devam soruları onun cevaplarını bağlam alır. Süren cevap durdurulur.
    func openConversation(id: UUID) {
        guard let conversation = askConversations.first(where: { $0.id == id }) else {
            return
        }
        archiveTask?.cancel()
        archiveExchanges = conversation.turns.map { (turn: AskConversationTurn) -> ArchiveExchange in archiveExchange(turn: turn) }
        currentConversationID = id
    }

    /// Sohbeti geçmişten siler; açık sohbetse sayfa boşalır.
    func deleteConversation(id: UUID) {
        do {
            try deleteAskConversation(id: id, directory: try AppPaths.askHistoryDirectory())
            askConversations.removeAll { $0.id == id }
            if currentConversationID == id {
                clearArchiveConversation()
            }
        } catch {
            Self.logger.error("Sohbet silinemedi, sohbet: \(id.uuidString, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Sohbet silinemedi: \(userFacingMessage(error: error))"))
        }
    }

    /// Saklanan sohbetleri okur (açılışta, arka planda); okunamayan dosyalar loglanır ve sayısı gösterilir.
    func loadAskHistory() {
        Task {
            do {
                let result: AskHistoryLoadResult = try await Task.detached(priority: .utility) { () throws -> AskHistoryLoadResult in
                    try loadAskConversations(directory: try AppPaths.askHistoryDirectory())
                }.value
                askConversations = result.conversations
                for failure in result.failures {
                    Self.logger.error("Sohbet okunamadı, dosya: \(failure.file, privacy: .public), neden: \(failure.reason, privacy: .public)")
                }
                if !result.failures.isEmpty {
                    errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Sohbet geçmişinden \(result.failures.count) sohbet okunamadı."))
                }
            } catch {
                Self.logger.error("Sohbet geçmişi okunamadı, hata: \(String(describing: error), privacy: .public)")
                errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Sohbet geçmişi okunamadı: \(userFacingMessage(error: error))"))
            }
        }
    }

    /// Bitmiş soruyla açık sohbeti saklar (ilk cevapta yeni sohbet olur); sınırı aşan en eski sohbetler silinir.
    private func saveConversation(exchangeID: UUID) {
        // Sohbet bu arada değiştiyse (yeni sohbet, başka sohbet açıldı) cevap bu sohbete ait değildir.
        guard archiveExchanges.contains(where: { $0.id == exchangeID && $0.phase == .done }) else {
            return
        }
        let id: UUID = currentConversationID ?? UUID()
        let turns: [AskConversationTurn] = archiveExchanges.compactMap { (exchange: ArchiveExchange) -> AskConversationTurn? in askTurn(exchange: exchange) }
        let conversation: AskConversation = askConversation(existing: askConversations.first { $0.id == id }, id: id, turns: turns, now: Date())
        do {
            let directory: URL = try AppPaths.askHistoryDirectory()
            try saveAskConversation(conversation: conversation, directory: directory)
            currentConversationID = id
            askConversations = upsertAskConversation(conversations: askConversations, conversation: conversation)
            for old in askConversationsBeyondLimit(conversations: askConversations, limit: askHistoryLimit) {
                try deleteAskConversation(id: old.id, directory: directory)
                askConversations.removeAll { $0.id == old.id }
            }
        } catch {
            Self.logger.error("Sohbet saklanamadı, sohbet: \(id.uuidString, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Sohbet saklanamadı: \(userFacingMessage(error: error))"))
        }
    }

    /// Ajanın adımını soruya yazar.
    private func apply(progress: ArchiveProgress, id: UUID) {
        updateExchange(id: id) { (exchange: inout ArchiveExchange) -> Void in
            switch progress {
            case .searchTerms(let terms):
                exchange.terms = terms
                exchange.phase = .searching
            case .passages(let passages):
                exchange.passages = passages
                exchange.phase = .writing
            case .answer(let answer):
                exchange.answer = answer
            }
        }
    }

    private func updateExchange(id: UUID, change: (inout ArchiveExchange) -> Void) {
        guard let index = archiveExchanges.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&archiveExchanges[index])
    }

    // MARK: Görevler

    /// Görevin tamamlandı işaretini değiştirir (kilitli toplantıda değil: işleme bitince kayıt bütünüyle yazılır).
    func toggleTask(meetingID: String, task: NoteTask) {
        guard let record = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return
        }
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            saveRecord(record: togglingTask(record: record, task: task), directory: directory)
        }
    }

    /// Görevi Apple Anımsatıcılar'a ekler; hata varsa kullanıcı metni döner.
    func addToReminders(meetingID: String, task: NoteTask) async -> String? {
        guard let record = meetings.first(where: { $0.id == meetingID }) else {
            return nil
        }
        do {
            try await eventKit.addReminder(draft: reminderDraft(record: record, task: task, calendar: Calendar.current))
        } catch {
            Self.logger.error("Anımsatıcı eklenemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            return eventKitMessage(error: error)
        }
        // Ekleme sürerken kayıt değişmiş olabilir: güncel kayıt işaretlenir. Toplantı bu arada işlenmeye başladıysa işaret
        // işleme bitince yazılır (yoksa "Anımsatıcılara ekle" yeniden görünür ve görev iki kez eklenirdi).
        if let current = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) {
            withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
                saveRecord(record: markingReminded(record: current, task: task), directory: directory)
            }
        } else {
            pendingReminded[meetingID, default: []].append(task)
        }
        return nil
    }

    // MARK: Not hedefleri (kanallar, webhook, Notion)

    /// Toplantı başına gönderimin durumu (toplantı sayfasında görünür).
    var webhookStates: [String: WebhookSendState] = [:]
    /// Bağlı not hedefleri (Ayarlar › Bağlantılar); birden çok olabilir.
    private(set) var destinations: [NoteDestination] = []
    /// Görev araçları (Linear, Jira).
    private(set) var taskTrackers: [TaskTracker] = []
    /// Toplantı başına görev gönderiminin durumu.
    var trackerStates: [String: WebhookSendState] = [:]

    /// Hedeflerin deposu: hesap jetonlarını hedef başına tek seferde yeniler.
    @ObservationIgnored let destinationVault: DestinationVault = DestinationVault(service: keychainService, account: .destinations) {
        (connection: ChannelConnection) async throws -> ChannelConnection in
        try await refreshConnectionTokens(connection: connection)
    }
    /// Kendiliğinden gönderim sürüyor: açılış, saatlik denetim ve işleme sonu aynı anda ikinci tur başlatmasın.
    @ObservationIgnored private var autoSendRunning: Bool = false

    /// Hedefleri ve görev araçlarını yükler; eski sürümün tek bağlantısı (hesap ya da webhook) bir kez hedeflere taşınır.
    func loadDestinations() async {
        do {
            try await migrateLegacyChannelIfNeeded()
            destinations = try await destinationVault.all()
            taskTrackers = try await Task.detached { try loadTaskTrackers(service: keychainService) }.value
        } catch {
            Self.logger.error("Hedefler okunamadı, hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Bağlantılar okunamadı: \(userFacingMessage(error: error))"))
        }
    }

    private func migrateLegacyChannelIfNeeded() async throws {
        guard try await destinationVault.all().isEmpty else {
            return
        }
        let connection: ChannelConnection? = try await optionalSecretInBackground(service: keychainService, account: .channel)
            .map { (text: String) throws -> ChannelConnection in try decodeChannelConnection(text: text) }
        let webhook: URL? = try await optionalSecretInBackground(service: keychainService, account: .webhook).flatMap { URL(string: $0) }
        let migrated: [NoteDestination] = migratedDestinations(
            connection: connection, webhook: webhook, autoSend: UserDefaults.standard.bool(forKey: SettingsKey.webhookAutoSend), now: Date()
        ) { UUID().uuidString }
        guard !migrated.isEmpty else {
            return
        }
        for destination in migrated {
            try await destinationVault.upsert(destination)
        }
        try deleteSecret(service: keychainService, account: .channel)
        try deleteSecret(service: keychainService, account: .webhook)
        Self.logger.info("Eski kanal bağlantısı hedeflere taşındı, sayı: \(migrated.count, privacy: .public)")
    }

    /// Yeni hedef ekler (kendiliğinden gönderim kapalı başlar; kullanıcı açar).
    @discardableResult
    func addDestination(target: DestinationTarget) async throws -> NoteDestination {
        let destination: NoteDestination = NoteDestination(id: UUID().uuidString, target: target, autoSend: false, createdAt: Date(), needsReconnect: false)
        try await destinationVault.upsert(destination)
        destinations = try await destinationVault.all()
        return destination
    }

    /// Hedefin bağlantısını değiştirir (kanalı değiştir, yeniden bağlan); kimliği ve ayarı korunur.
    func replaceDestinationTarget(id: String, target: DestinationTarget) async throws {
        guard let current = destinations.first(where: { $0.id == id }) else {
            throw DestinationError.notFound(id: id)
        }
        try await destinationVault.upsert(current.with(target: target).with(needsReconnect: false))
        destinations = try await destinationVault.all()
    }

    func setAutoSend(destinationID: String, enabled: Bool) async {
        guard let current = destinations.first(where: { $0.id == destinationID }) else {
            return
        }
        do {
            try await destinationVault.upsert(current.with(autoSend: enabled))
            destinations = try await destinationVault.all()
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Hedefi kaldırır; servis tarafında da kapatılır (Slack jetonu geri alınır, Discord webhook'u silinir). Servis
    /// tarafı kapatılamazsa hedef yine kaldırılır, neden gösterilir.
    func removeDestination(id: String) async {
        do {
            let removed: NoteDestination = try await destinationVault.remove(id: id)
            destinations = try await destinationVault.all()
            do {
                try await revokeDestination(destination: removed)
            } catch {
                Self.logger.warning("Hedef servis tarafında kapatılamadı, hata: \(String(describing: error), privacy: .private)")
                errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Eski bağlantı servis tarafında kapatılamadı: \(userFacingMessage(error: error))"))
            }
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Hesap hedefinin kanallarını yeniden listeler (yeniden giriş yapmadan kanal değiştirmek için).
    func channelOptions(destinationID: String) async throws -> (signIn: ChannelSignIn, options: [ChannelOption]) {
        let connection: ChannelConnection = try await destinationVault.connection(id: destinationID, force: false)
        let signIn: ChannelSignIn = ChannelSignIn(service: connection.service, tokens: connection.tokens, workspace: connection.workspace)
        return (signIn, try await listChannels(signIn: signIn))
    }

    /// Notu bir hedefe gönderir; başarılıysa toplantıya işlenir (kendiliğinden gönderim yinelemez). Hata metni döner.
    func sendNote(meetingID: String, destinationID: String) async -> String? {
        guard let record = meetings.first(where: { $0.id == meetingID }), let note = record.note,
              let destination = destinations.first(where: { $0.id == destinationID }) else {
            return nil
        }
        do {
            try await deliverNote(vault: destinationVault, destination: destination, record: record, note: note)
            markSent(meetingID: meetingID, destinationID: destinationID)
            Self.logger.info("Not hedefe gönderildi, toplantı: \(meetingID, privacy: .public), hedef: \(destinationName(destination: destination), privacy: .public)")
            return nil
        } catch {
            Self.logger.error("Not hedefe gönderilemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            return String(localized: "\(destinationName(destination: destination)): \(userFacingMessage(error: error))")
        }
    }

    /// Notu verilen hedeflere sırayla gönderir; toplantı sayfasındaki durum güncellenir.
    func sendNote(meetingID: String, destinationIDs: [String]) async {
        webhookStates[meetingID] = .sending
        var failures: [String] = []
        for id in destinationIDs {
            if let failure = await sendNote(meetingID: meetingID, destinationID: id) {
                failures.append(failure)
            }
        }
        await refreshDestinationList()
        webhookStates[meetingID] = failures.isEmpty ? .sent : .failed(failures.joined(separator: "\n"))
    }

    /// Ayarlardaki "Dene": örnek notu hedefe gönderir.
    func sendTestNote(destinationID: String) async -> String? {
        guard let destination = destinations.first(where: { $0.id == destinationID }) else {
            return nil
        }
        let sample: MeetingRecord = MeetingRecord(
            id: "deneme", title: "AI-Notepad", startedAt: Date(), endedAt: Date(), language: nil, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud,
            notice: nil, meNeedsFinalPass: nil
        )
        let note: MeetingNote = MeetingNote(
            title: String(localized: "AI-Notepad bağlantı denemesi"),
            summary: String(localized: "Bu bir deneme mesajıdır: toplantı notların buraya böyle gelecek."),
            decisions: [], tasks: [], glossary: []
        )
        do {
            try await deliverNote(vault: destinationVault, destination: destination, record: sample, note: note)
            await refreshDestinationList()
            return nil
        } catch {
            Self.logger.error("Hedef denemesi başarısız, hata: \(String(describing: error), privacy: .private)")
            await refreshDestinationList()
            return userFacingMessage(error: error)
        }
    }

    private func refreshDestinationList() async {
        do {
            destinations = try await destinationVault.all()
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Gönderildi işareti: toplantı kilitliyse (işleniyor) işleme bitince uygulanır.
    private func markSent(meetingID: String, destinationID: String) {
        guard let current = meetings.first(where: { $0.id == meetingID }) else {
            return
        }
        guard !isLocked(meetingID: meetingID) else {
            pendingSentMarks[meetingID, default: []].insert(destinationID)
            return
        }
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            saveRecord(record: current.markingSent(destinationID: destinationID), directory: directory)
        }
    }

    /// İşleme sürerken gönderilen hedefler; işleme bitince kayda işlenir.
    @ObservationIgnored private var pendingSentMarks: [String: Set<String>] = [:]

    /// Bekleyen kendiliğinden gönderimleri yapar: işleme bitince, açılışta ve saatte bir. Ağ yokken kaçanlar böylece
    /// sonra gider; her (toplantı, hedef) bir kez gönderilir.
    func processPendingAutoSends() async {
        guard !autoSendRunning else {
            return
        }
        autoSendRunning = true
        defer { autoSendRunning = false }
        await refreshDestinationList()
        let pending: [(meetingID: String, destinationID: String)] = pendingAutoSends(records: meetings, destinations: destinations, now: Date())
            .filter { !(pendingSentMarks[$0.meetingID] ?? []).contains($0.destinationID) && !isLocked(meetingID: $0.meetingID) }
        for item in pending {
            if let failure = await sendNote(meetingID: item.meetingID, destinationID: item.destinationID) {
                errorMessages = appendUnique(messages: errorMessages, message: failure)
            }
        }
        if !pending.isEmpty {
            await refreshDestinationList()
        }
    }

    /// Notion'a tek tıkla bağlanır (tarayıcıda izin) ve hedef olarak ekler.
    func connectNotion() async throws {
        let connection: MCPConnection = try await signInToMCP(service: .notion) { (url: URL) async -> Void in
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
        try await addDestination(target: .notion(NotionTarget(connection: connection, pageTitle: String(localized: "Özel sayfalar"))))
    }

    // MARK: Görev araçları (Linear, Jira)

    /// Linear ya da Jira'ya tek tıkla bağlanır (tarayıcıda izin; uygulama kaydı ya da API anahtarı gerekmez).
    func connectTracker(service: MCPService) async throws {
        let connection: MCPConnection = try await signInToMCP(service: service) { (url: URL) async -> Void in
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
        let tracker: TaskTracker = TaskTracker(id: UUID().uuidString, service: service, connection: connection, target: "")
        try saveTrackers(taskTrackers.filter { $0.service != service } + [tracker])
    }

    func removeTracker(id: String) {
        do {
            try saveTrackers(taskTrackers.filter { $0.id != id })
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    func setTrackerTarget(id: String, target: String) {
        do {
            try saveTrackers(taskTrackers.map { $0.id == id ? $0.with(target: target.trimmingCharacters(in: .whitespacesAndNewlines)) : $0 })
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    private func saveTrackers(_ trackers: [TaskTracker]) throws {
        try saveTaskTrackers(trackers: trackers, service: keychainService)
        taskTrackers = trackers
    }

    /// Toplantının görevlerini araçta iş olarak açar (`onlyMine`: yalnız sana düşenler); daha önce gönderilenler
    /// yinelenmez. Sonuç özeti ya da hata toplantı sayfasında görünür.
    func sendTasks(meetingID: String, trackerID: String, onlyMine: Bool) async {
        guard let record = meetings.first(where: { $0.id == meetingID }), let note = record.note,
              let tracker = taskTrackers.first(where: { $0.id == trackerID }) else {
            return
        }
        let sent: [String] = record.sentTaskKeys?[trackerID] ?? []
        let tasks: [NoteTask] = note.tasks.filter { (onlyMine ? $0.isMine : true) && !sent.contains(taskKey(task: $0)) && !isTaskDone(record: record, task: $0) }
        guard !tasks.isEmpty else {
            trackerStates[meetingID] = .failed(String(localized: "Gönderilecek açık görev yok (hepsi gönderilmiş ya da tamamlanmış)."))
            return
        }
        trackerStates[meetingID] = .sending
        do {
            let llm: LLMProvider = try await resolveLLMProvider()
            let result: (summary: String, connection: MCPConnection) = try await sendTasksToTracker(tracker: tracker, tasks: tasks, meetingTitle: note.title, llm: llm)
            if result.connection != tracker.connection {
                try saveTrackers(taskTrackers.map { $0.id == trackerID ? $0.with(connection: result.connection) : $0 })
            }
            if let current = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) {
                let marked: MeetingRecord = tasks.reduce(current) { (result: MeetingRecord, task: NoteTask) -> MeetingRecord in
                    result.markingTaskSent(trackerID: trackerID, task: task)
                }
                withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
                    saveRecord(record: marked, directory: directory)
                }
            }
            trackerStates[meetingID] = .done(result.summary)
        } catch {
            Self.logger.error("Görevler araca gönderilemedi, araç: \(tracker.service.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            trackerStates[meetingID] = .failed(String(localized: "\(tracker.service.displayName): \(userFacingMessage(error: error))"))
        }
    }

    // MARK: Apple Notlar ve klasör

    /// Notu Apple Notlar'da "AI-Notepad" klasörüne yazar (ilk seferde macOS izin sorar); hata varsa kullanıcı metni döner.
    func sendToAppleNotes(meetingID: String) async -> String? {
        guard let record = meetings.first(where: { $0.id == meetingID }), let note = record.note else {
            return nil
        }
        let source: String = appleNotesScript(html: notesHTML(record: record, note: note))
        // NSAppleScript yalnızca ana iş parçacığında güvenli.
        let failure: String? = runAppleScript(source: source)
        if let failure {
            Self.logger.error("Not Apple Notlar'a yazılamadı, toplantı: \(meetingID, privacy: .public), hata: \(failure, privacy: .public)")
            return String(localized: "Apple Notlar'a yazılamadı: \(failure). Sistem Ayarları › Gizlilik ve Güvenlik › Otomasyon'da AI-Notepad için Notlar'a izin ver.")
        }
        Self.logger.info("Not Apple Notlar'a yazıldı, toplantı: \(meetingID, privacy: .public)")
        return nil
    }

    /// Notu seçili klasöre Markdown olarak yazar (aynı toplantı aynı dosyaya); klasör seçilmediyse ya da yazılamazsa
    /// kullanıcı metni döner.
    func exportToFolder(meetingID: String) -> String? {
        guard let record = meetings.first(where: { $0.id == meetingID }) else {
            return nil
        }
        let path: String = UserDefaults.standard.string(forKey: SettingsKey.markdownFolder) ?? ""
        guard !path.isEmpty else {
            return String(localized: "Önce Ayarlar › Bağlantılar'dan bir klasör seç.")
        }
        do {
            let file: URL = try exportMarkdown(record: record, folder: URL(fileURLWithPath: path, isDirectory: true))
            Self.logger.info("Not klasöre yazıldı, dosya: \(file.lastPathComponent, privacy: .private)")
            return nil
        } catch {
            return userFacingMessage(error: error)
        }
    }

    /// Not değişince (düzenleme, yeniden yazma, konuşmacı adı) klasördeki Markdown kopyası güncellenir.
    private func refreshFolderCopy(meetingID: String) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.markdownAutoExport), let error = exportToFolder(meetingID: meetingID) else {
            return
        }
        errorMessages = appendUnique(messages: errorMessages, message: error)
    }

    /// İşleme bitince açık olan hedeflere kendiliğinden gönderir: webhook, Apple Notlar (bir kez) ve klasör (her
    /// seferinde güncellenir). Hata panelde görünür; gönderilenler toplantıya işlenir.
    private func autoSendToDestinations(record: MeetingRecord) {
        Task { await processPendingAutoSends() }
        guard record.note != nil else {
            return
        }
        if UserDefaults.standard.bool(forKey: SettingsKey.markdownAutoExport), let error = exportToFolder(meetingID: record.id) {
            errorMessages = appendUnique(messages: errorMessages, message: error)
        }
        guard UserDefaults.standard.bool(forKey: SettingsKey.appleNotesAutoSend), record.notesSentAt == nil else {
            return
        }
        Task {
            if let error = await sendToAppleNotes(meetingID: record.id) {
                errorMessages = appendUnique(messages: errorMessages, message: error)
                return
            }
            guard let current = meetings.first(where: { $0.id == record.id }), !isLocked(meetingID: record.id) else {
                return
            }
            withSessionDirectory(id: record.id) { (directory: URL) -> Void in
                saveRecord(record: current.with(notesSentAt: Date()), directory: directory)
            }
        }
    }

    /// İşleme sürerken Anımsatıcılar'a eklenen görevler; işleme bitince kayda işlenir.
    @ObservationIgnored private var pendingReminded: [String: [NoteTask]] = [:]

    /// İşleme sonucuna bekleyen Anımsatıcılar işaretlerini uygular ve bekleyenleri temizler.
    private func applyingPendingReminders(record: MeetingRecord) -> MeetingRecord {
        let tasks: [NoteTask] = pendingReminded.removeValue(forKey: record.id) ?? []
        let sent: Set<String> = pendingSentMarks.removeValue(forKey: record.id) ?? []
        let withSent: MeetingRecord = sent.sorted().reduce(record) { (result: MeetingRecord, id: String) -> MeetingRecord in result.markingSent(destinationID: id) }
        return tasks.reduce(withSent) { (result: MeetingRecord, task: NoteTask) -> MeetingRecord in markingReminded(record: result, task: task) }
    }

    // MARK: Sesinden tanıma

    /// Ses izi servisi; Ayarlar'da kapalıysa ya da model klasörü yoksa nil (kayıt ve işleme izsiz sürer).
    private func voiceEmbedderIfEnabled() -> (any VoiceEmbedder)? {
        guard UserDefaults.standard.bool(forKey: SettingsKey.voiceRecognition) else {
            return nil
        }
        do {
            return SpeakerKitVoiceEmbedder(modelsDirectory: try AppPaths.modelsDirectory())
        } catch {
            Self.logger.error("Ses izi için model klasörü alınamadı, hata: \(String(describing: error), privacy: .public)")
            voiceRegistryError = userFacingMessage(error: error)
            return nil
        }
    }

    private func loadVoices() {
        do {
            registeredVoices = try loadRegisteredVoices(url: try voicesFileURL())
            voiceRegistryError = nil
        } catch {
            Self.logger.error("Kayıtlı sesler okunamadı, hata: \(String(describing: error), privacy: .public)")
            voiceRegistryError = userFacingMessage(error: error)
        }
    }

    private func storeVoices(voices: [RegisteredVoice]) {
        do {
            try saveRegisteredVoices(voices: voices, url: try voicesFileURL())
            registeredVoices = voices
            voiceRegistryError = nil
        } catch {
            Self.logger.error("Kayıtlı sesler yazılamadı, hata: \(String(describing: error), privacy: .public)")
            voiceRegistryError = userFacingMessage(error: error)
        }
    }

    // MARK: Kişiler

    /// Elle eklenen ve kaldırılan kişiler (`People.json`).
    var peopleBook: PeopleBook = .empty
    /// Kişiler defteri okunamadı ya da yazılamadı.
    var peopleBookError: String?
    /// Defter okundu: okunamadıysa üzerine yazılmaz (boş defterle eski kişiler silinmesin).
    @ObservationIgnored private var peopleBookLoaded: Bool = false

    private func loadPeople() {
        do {
            peopleBook = try loadPeopleBook(url: try peopleFileURL())
            peopleBookLoaded = true
            peopleBookError = nil
        } catch {
            Self.logger.error("Kişiler defteri okunamadı, hata: \(String(describing: error), privacy: .public)")
            peopleBookError = userFacingMessage(error: error)
        }
    }

    private func storePeople(book: PeopleBook) {
        guard peopleBookLoaded else {
            peopleBookError = String(localized: "Kişiler defteri okunamadığı için değişiklik kaydedilmedi; People.json dosyasını denetle ve uygulamayı yeniden aç.")
            return
        }
        do {
            try savePeopleBook(book: book, url: try peopleFileURL())
            peopleBook = book
            peopleBookError = nil
        } catch {
            Self.logger.error("Kişiler defteri yazılamadı, hata: \(String(describing: error), privacy: .public)")
            peopleBookError = userFacingMessage(error: error)
        }
    }

    /// Kişi ekler ya da bilgilerini günceller (adı tanımaya da verilir).
    func savePerson(name: String, role: String, email: String) {
        storePeople(book: addingPerson(book: peopleBook, person: SavedPerson(name: name, role: role, email: email, addedAt: Date())))
    }

    /// Elle eklenen kişinin adını ve bilgilerini değiştirir; kayıtlı sesi yeni ada taşınır.
    func renamePerson(oldName: String, name: String, role: String, email: String) {
        storePeople(book: renamingPerson(book: peopleBook, oldName: oldName, person: SavedPerson(name: name, role: role, email: email, addedAt: Date())))
        let trimmed: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard peopleBookError == nil, !trimmed.isEmpty else {
            return
        }
        storeVoices(voices: registeredVoices.map { (voice: RegisteredVoice) -> RegisteredVoice in
            voice.name.caseInsensitiveCompare(oldName) == .orderedSame
                ? RegisteredVoice(name: trimmed, voiceprint: voice.voiceprint, updatedAt: voice.updatedAt, contributions: voice.contributions)
                : voice
        })
    }

    /// Kişiyi Kişiler'den kaldırır ve sesini unutur; toplantılardaki adı ve görevleri kalır.
    func removePerson(name: String) {
        storePeople(book: removingPerson(book: peopleBook, name: name, now: Date()))
        guard peopleBookError == nil else {
            return
        }
        storeVoices(voices: registeredVoices.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame })
    }

    /// Kayıtlı sesi unutur (bu kişi bundan sonra sesinden tanınmaz; verilmiş adlar toplantılarda kalır).
    func forgetVoice(name: String) {
        storeVoices(voices: registeredVoices.filter { $0.name != name })
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
        guard let request = speakerReviewRequest(segments: segments, speakerNames: record.speakerNames, userName: userName, attendees: record.attendees ?? []) else {
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
        // Bu toplantıdan öğrenilen ses izleri de geri alınır (biyometrik veri toplantıdan uzun yaşamasın).
        let voices: [RegisteredVoice] = forgettingMeeting(voices: registeredVoices, meetingID: meetingID, now: Date())
        if voices != registeredVoices {
            storeVoices(voices: voices)
        }
        if lastFinishedMeetingID == meetingID {
            lastFinishedMeetingID = nil
        }
        return nil
    }

    /// Seçilen toplantıları Çöp Sepeti'ne taşır; silinemeyenlerin hataları (tekilleştirilmiş) döner, silinenler listeden
    /// çıkar.
    func deleteMeetings(meetingIDs: Set<String>) -> [String] {
        meetingIDs.sorted().reduce(into: [String]()) { (errors: inout [String], id: String) -> Void in
            if let error = deleteMeeting(meetingID: id), !errors.contains(error) {
                errors.append(error)
            }
        }
    }

    func deleteAudio(meetingID: String) {
        // Kayıttaki toplantının sesi silinirse kayıt yazılmaya devam ederken dosyalar kaybolur.
        guard let record = meetings.first(where: { $0.id == meetingID }), !isLocked(meetingID: meetingID) else {
            return
        }
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            do {
                try deleteAudioFiles(directory: directory)
                // Ses gidince toplantıdaki ses izleri de gider (ad verilmiş kişilerin kayıtlı sesi Ayarlar'da kalır).
                saveRecord(record: record.withAudioDeleted().with(voiceprints: nil), directory: directory)
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
        Task {
            await loadDestinations()
            await processPendingAutoSends()
        }
        loadVoices()
        loadPeople()
        loadRecipes()
        loadAskHistory()
        startCalendarServices()
        // Yalnızca bu cihazdaki toplantılar: iCloud'daki başka cihazın işlediği toplantı "yarıda kaldı" sayılmaz.
        let local: Set<String> = localMeetingIDsReportingFailure()
        for record in staleStatusesToInterrupt(records: meetings.filter { local.contains($0.id) }) {
            withSessionDirectory(id: record.id) { (directory: URL) -> Void in
                saveRecord(record: record, directory: directory)
            }
        }
        applyRetention()
        startRetentionTimer()
        startCloudSyncIfEnabled()
        Task { await refreshSetupProblems() }
        Task { await refreshSharedKeys() }
    }

    /// Yerel toplantı kimlikleri; okunamazsa boş (o turda hiçbir toplantıya dokunulmaz) ve neden gösterilir.
    private func localMeetingIDsReportingFailure() -> Set<String> {
        do {
            return try AppPaths.localMeetingIDs()
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            return []
        }
    }

    /// Saklama süresi (Ayarlar) dolan toplantıların sesini siler; kilitli toplantılar atlanır.
    func applyRetention() {
        let days: Int = clampedSetting(key: SettingsKey.audioRetentionDays, range: SettingsRange.audioRetentionDays)
        // iCloud'daki toplantılar da: eşitleme açıkken biten her toplantı iCloud'a taşınır, yalnız yerelde silinseydi
        // hiçbir cihaz sesi silmezdi. Çalan toplantının sesi kalır.
        for id in audioToDelete(records: meetings.filter { $0.id != player.meetingID }, now: Date(), retentionDays: days) where !isLocked(meetingID: id) {
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
                await self?.processPendingAutoSends()
            }
        }
    }

    func reloadMeetings() {
        do {
            let result: MeetingLoadResult = loadMeetings(directories: try AppPaths.meetingDirectories(location: activeStorageLocation))
            meetings = result.meetings
            meetingLoadFailures = result.failures
            cloudDownloadingCount = result.downloading.count
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
        try AppPaths.meetingDirectory(id: id, location: activeStorageLocation)
    }

    // MARK: iCloud eşitlemesi

    /// Okuma ve klasör çözümünde kullanılan yer (iCloud hazır olana dek yerel).
    private var activeStorageLocation: StorageLocation {
        cloud.activeLocation
    }

    /// Açılışta iCloud seçiliyse eşitlemeyi başlatır; iCloud kullanılamıyorsa neden listede de görünür.
    func startCloudSyncIfEnabled() {
        Task {
            await cloud.start(excluding: cloudMoveExclusions) { [weak self] in self?.reloadMeetings() }
            if case .failed(let message) = cloud.state {
                meetingLoadFailures.append(MeetingLoadFailure(folder: "iCloud", reason: message))
            }
        }
    }

    /// iCloud eşitlemesini açar ya da kapatır (bkz. `CloudSyncController.setEnabled`).
    func setCloudSync(enabled: Bool) async {
        await cloud.setEnabled(enabled, excluding: cloudMoveExclusions) { [weak self] in self?.reloadMeetings() }
    }

    /// iCloud'a taşınmayacak toplantılar: kayıtta, işlenen ya da düzenlenen ve çalınan (dosyaları kullanımda).
    private var cloudMoveExclusions: Set<String> {
        processingMeetingIDs.union([activeMeetingID, player.meetingID].compactMap { $0 })
    }

    // MARK: Anahtar eşitleme

    /// Kayıtlı anahtarların iCloud Anahtar Zinciri'ne eşitlenen kopyasını yazar (iPhone uygulaması okur); yerel
    /// öğelere dokunulmaz. Yalnızca bu Mac'te kayıtlı olan anahtarlar kopyalanır.
    func shareKeysWithIPhone() async {
        keySync = .working
        do {
            for account in [SecretAccount.deepgram, .elevenlabs, .anthropic, .openai] {
                guard let value = try await optionalSecretInBackground(service: keychainService, account: account) else {
                    // Bu Mac'te artık olmayan anahtarın iPhone kopyası da kalkar.
                    try await Task.detached { try deleteSyncedSecret(service: keychainService, account: account) }.value
                    continue
                }
                try await Task.detached { try saveSyncedSecret(service: keychainService, account: account, value: value) }.value
            }
            keySync = .idle
        } catch {
            Self.logger.error("Anahtarlar iCloud'a kopyalanamadı, hata: \(String(describing: error), privacy: .public)")
            keySync = .failed(userFacingMessage(error: error))
        }
        await refreshSharedKeys()
    }

    /// Eşitlenen kopyaları siler (iPhone'daki uygulama da artık göremez).
    func stopSharingKeys() async {
        keySync = .working
        do {
            for account in SecretAccount.allCases {
                try await Task.detached { try deleteSyncedSecret(service: keychainService, account: account) }.value
            }
            keySync = .idle
        } catch {
            keySync = .failed(userFacingMessage(error: error))
        }
        await refreshSharedKeys()
    }

    /// Hangi anahtarların eşitlenen kopyası var.
    func refreshSharedKeys() async {
        do {
            var shared: [SecretAccount] = []
            for account in SecretAccount.allCases where try await Task.detached(operation: { try syncedSecretExists(service: keychainService, account: account) }).value {
                shared.append(account)
            }
            sharedKeyAccounts = shared
        } catch {
            keySync = .failed(userFacingMessage(error: error))
        }
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

/// Sabit dil seçiliyse o dil; otomatikte nil. Saf fonksiyondur.
private func fixedLanguage(mode: LanguageMode) -> MeetingLanguage? {
    guard case .fixed(let language) = mode else {
        return nil
    }
    return language
}

/// Webhook gönderiminin durumu.
enum WebhookSendState: Equatable {
    case sending
    case sent
    /// Bitti, kısa özetle (ör. açılan Linear işleri).
    case done(String)
    case failed(String)
}

/// Sırası bekleyen canlı çeviri.
private struct TranslationJob {
    let segment: LiveSegment
    let context: [String]
    let provider: LLMProvider
    let generation: Int
}

/// Aynı anda en fazla bu kadar canlı çeviri isteği.
private let maxParallelTranslations: Int = 4

/// İçe aktarma hatasının kullanıcı metni. Saf fonksiyondur.
func mediaImportMessage(error: any Error) -> String {
    switch error {
    case MediaImportError.noAudioTrack:
        String(localized: "dosyada ses yok")
    case MediaImportError.readFailed(_, let reason):
        String(localized: "okunamadı (\(reason))")
    case MediaImportError.writeFailed(_, let reason):
        String(localized: "kaydedilemedi (\(reason))")
    default:
        userFacingMessage(error: error)
    }
}

/// Ses/video dosyası seçtirir (birden çok); seçilenleri içe aktarır.
@MainActor
func chooseMediaToImport(model: AppModel) {
    let panel: NSOpenPanel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
    panel.message = String(localized: "Toplantı kaydı seç (ses ya da video); yazıya dökülür ve notu çıkarılır.")
    guard panel.runModal() == .OK, !panel.urls.isEmpty else {
        return
    }
    model.importMedia(urls: panel.urls)
}


/// AppleScript'i çalıştırır; başarılıysa nil, değilse hata metni (numarasıyla). NSAppleScript ana iş parçacığı içindir.
@MainActor
private func runAppleScript(source: String) -> String? {
    guard let script = NSAppleScript(source: source) else {
        return "AppleScript derlenemedi"
    }
    var error: NSDictionary?
    script.executeAndReturnError(&error)
    guard let error else {
        return nil
    }
    let number: Int = (error[NSAppleScript.errorNumber] as? Int) ?? 0
    let message: String = (error[NSAppleScript.errorMessage] as? String) ?? ""
    return "\(message) (\(number))"
}
