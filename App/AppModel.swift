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
    /// Abonelik: model henüz gerekmedi (canlı metin bulutta); gerekince (Mac'e geçişte) indirilir.
    case notLoaded
    case loading
    case ready
    case failed(String)
}

/// Kayıt kartındaki konuşma modeli durumu (bkz. `AppModel.localModelNotice`).
enum LocalModelNotice: Equatable {
    /// İndiriliyor (0…1) ya da yükleniyor (nil).
    case preparing(progress: Double?)
    case failed(message: String)
}

/// Model hazırlanırken gösterilen metin: indirme yüzdesi ya da "hazırlanıyor". Saf fonksiyondur.
func localModelNoticeText(progress: Double?) -> String {
    progress.map { String(localized: "Konuşma modeli indiriliyor… \($0.formatted(.percent.precision(.fractionLength(0))))") }
        ?? String(localized: "Konuşma modeli hazırlanıyor…")
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
    let noteLanguageText: String
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

    #if HOSTED_EDITION
    var modelStatus: ModelStatus = .notLoaded
    /// Abonelik: canlı metnin motoru ve nedeni (son kaydın başında seçilen, Mac'e geçişte güncellenen); bu açılışta
    /// kayıt yapılmadıysa nil (tanılama sunucunun önerisini gösterir).
    var hostedLiveStatus: HostedLiveStatus?
    #else
    var modelStatus: ModelStatus = .loading
    #endif
    /// Süren model yüklemesi: aynı anda gelen istekler (açılış, Mac'e geçiş) tek yüklemeyi bekler.
    @ObservationIgnored private var modelLoad: Task<Void, Never>?
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
    /// Kayıt şu an başlatılamıyor mu (giriş yok, deneme bitti, sınır…; uygulama bağlar): öyleyse görüşme önerisi ve
    /// takvimle kendiliğinden kayıt mikrofon ve sistem sesine dokunmaz.
    @ObservationIgnored var isStartBlocked: @MainActor () -> Bool = { false }
    /// Kendiliğinden kayıtta bağlanacak etkinlik (çakışan etkinliklerde doğru olan kayda geçsin).
    @ObservationIgnored private var pendingAutoMeeting: CalendarMeeting?
    @ObservationIgnored private var calendarTask: Task<Void, Never>?
    @ObservationIgnored private var calendarChangesTask: Task<Void, Never>?
    /// Toplantı listesini arka planda okur; art arda gelen istekleri birleştirir.
    @ObservationIgnored private let meetingReloader: MeetingReloader = MeetingReloader()
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
    /// "Diğerleri" bölümlerinin not dilindeki çevirisi.
    var translations: [SegmentID: String] = [:]
    /// Çevirisi başarısız bölümler (panelde "Tekrar dene").
    var failedTranslations: Set<SegmentID> = []
    var displayMode: DisplayMode
    /// Paneldeki "Ne kaçırdım?" / soru kartı.
    var assistantCard: AssistantCard?
    /// Kaydedilmiş toplantılar (yeniden eskiye) ve okunamayanlar.
    var meetings: [MeetingRecord] = []
    var meetingLoadFailures: [MeetingLoadFailure] = []
    /// Toplantılar listesinde gösterilen okuma hataları: okunamayan toplantılar ve iCloud eşitlemesi başarısızsa nedeni.
    /// iCloud durumu eşitlemeden okunur; toplantılar yeniden okununca silinmez.
    var visibleLoadFailures: [MeetingLoadFailure] {
        guard case .failed(let message) = cloud.state else {
            return meetingLoadFailures
        }
        return meetingLoadFailures + [MeetingLoadFailure(folder: "iCloud", reason: message)]
    }
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
    /// Biten kayıt işlemeye devrediliyor (sunucu oturumu kapatılıyor, kayıt yazılıyor): bu arada yeni kayıt, kuyruk,
    /// çıkış ve güncellemeyle yeniden başlatma beklenir (bkz. `isBusy`, `isReadyToRecord`).
    private(set) var handingOffMeetingID: String?
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
    #if HOSTED_EDITION
    /// Abonelik: toplantının süre sınırını izleyen görev (bkz. `watchRecordingLimit`).
    @ObservationIgnored private var recordingLimitTask: Task<Void, Never>?
    /// Olağandan kısa toplantının bitiş anı (aylık sınıra az kaldı); kayıt panelinde kalan dakika gösterilir. Kısa
    /// değilse ya da kayıt yoksa nil.
    private(set) var shortMeetingDeadline: Date?
    #endif

    @ObservationIgnored private var engine: WhisperKitEngine?
    /// Cihaz içi konuşma tanıma (Apple); model indirildiyse hazır.
    @ObservationIgnored private var speechEngine: AppleSpeechEngine?
    /// Cihaz içi konuşma modelinin indirme ilerlemesi (0…1); indirme yoksa nil.
    var speechModelProgress: Double?
    /// WhisperKit modelinin (~630 MB) indirme ilerlemesi (0…1); indirme yoksa (ya da model diskte) nil.
    var whisperModelProgress: Double?
    @ObservationIgnored private let microphone: MicrophoneCapture = MicrophoneCapture()
    @ObservationIgnored private let systemAudio: SystemAudioCapture = SystemAudioCapture()
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    /// Uyku ve çıkış bildirimlerinin gözlemcileri (uygulama boyunca yaşar).
    @ObservationIgnored private var systemObservers: [any NSObjectProtocol] = []

    init(liveEngine: LiveEngine, displayMode: DisplayMode, player: MeetingAudioPlayer) {
        self.liveEngine = liveEngine
        self.displayMode = displayMode
        self.player = player
        observeSleepAndTermination()
    }

    /// Uygulamanın tek oynatıcısı: kayıt başlarken durdurulur (çalan ses mikrofona girip yeni kayda karışmasın).
    @ObservationIgnored private let player: MeetingAudioPlayer

    // MARK: Görünüm

    var phase: RecordingPhase {
        isFinishing ? .finishing : (isRecording ? .recording : .idle)
    }

    /// Kayıt başlatılabilir mi: önceki kayıt bitmiş olmalı; Deepgram'da her zaman, yerel motorlarda model hazırsa.
    var isReadyToRecord: Bool {
        #if HOSTED_EDITION
        // Abonelik: canlı motor kayıt başında seçilir; Mac modeli gerekirse kayıt sürerken hazırlanır.
        !isFinishing && handingOffMeetingID == nil
        #else
        !isFinishing && handingOffMeetingID == nil && (liveEngine == .deepgram || modelStatus == .ready)
        #endif
    }

    /// Ada ve panelin gösterdiği durum; girdiler değişmedikçe önbellekten (ada ve panel aynı değişiklikte iki kez okur).
    var viewState: LiveViewState {
        let inputs: ViewStateInputs = ViewStateInputs(
            transcript: correctedTranscript, translations: translations, failedTranslations: failedTranslations, displayMode: displayMode,
            assistantCard: assistantCard, phase: phase,
            newPersonNumber: nextFreePerson(transcript: transcript, corrections: speakerCorrections), isPaused: isPaused, isMicMuted: isMicMuted, canToggleMic: !isRecording || micOpenedForRecording, isInPerson: isRecording && recordingInPerson, canStart: isReadyToRecord && !isStarting,
            startedAt: recordingStartedAt, statusText: statusText,
            // Algılanan dil yalnızca kayıt sürerken anlamlı: bittikten sonra seçili mod (ör. "Otomatik") görünür.
            languageText: languageText(locked: isRecording ? lockedLanguage : nil, mode: languageMode, isRecording: isRecording),
            noteLanguageText: selectedNoteLanguage().interfaceName,
            // Çözülmüş hatalar (ör. abone olduktan sonra "deneme bitti") panelde de kalmaz.
            errors: visibleErrorMessages(errors: errorMessages, shownElsewhere: [], resolved: resolvedErrorMessages())
        )
        if let cache = viewStateCache, cache.inputs == inputs {
            return cache.state
        }
        let state: LiveViewState = makeLiveViewState(
            transcript: inputs.transcript, translations: inputs.translations, displayMode: inputs.displayMode,
            failedTranslations: inputs.failedTranslations, assistantCard: inputs.assistantCard, phase: inputs.phase,
            newPersonNumber: inputs.newPersonNumber, isPaused: inputs.isPaused, isMicMuted: inputs.isMicMuted, canToggleMic: inputs.canToggleMic, isInPerson: inputs.isInPerson, canStart: inputs.canStart, startedAt: inputs.startedAt, statusText: inputs.statusText, languageText: inputs.languageText, noteLanguageText: inputs.noteLanguageText, errors: inputs.errors
        )
        viewStateCache = (inputs, state)
        return state
    }

    /// Panelde kayıt yokken gösterilen durum: hazırken boş (gereksiz yazı yok), yalnızca model hazırlanırken ya da
    /// hata varken dolu.
    private var statusText: String {
        switch (liveEngine, modelStatus) {
        case (.deepgram, _), (.whisperKit, .ready), (_, .notLoaded): ""
        case (.whisperKit, .loading): localModelNoticeText(progress: whisperModelProgress)
        case (.whisperKit, .failed(let message)): message
        case (.appleSpeech, .loading): localModelNoticeText(progress: speechModelProgress)
        case (.appleSpeech, .ready): String(localized: "Hazır · Cihaz içi")
        case (.appleSpeech, .failed(let message)): message
        }
    }

    /// Kayıt kartında gösterilen konuşma modeli durumu: model hazırlanıyor (ilerlemeyle) ya da hazırlanamadı. Model
    /// gerekmiyorsa ya da hazırsa nil. Geliştirici sürümünde model hazır olmadan kayıt başlamaz (kart nedenini söyler);
    /// abonelikte model yalnızca gerekince yüklenir ve kayıt beklemez (canlı metin model hazır olunca başlar).
    var localModelNotice: LocalModelNotice? {
        let progress: Double?
        switch liveEngine {
        case .deepgram:
            return nil
        case .whisperKit:
            progress = whisperModelProgress
        case .appleSpeech:
            progress = speechModelProgress
        }
        switch modelStatus {
        case .notLoaded, .ready:
            return nil
        case .loading:
            return .preparing(progress: progress)
        case .failed(let message):
            return .failed(message: message)
        }
    }

    /// Hazırlanamayan konuşma modelini yeniden dener (kayıt kartındaki düğme).
    func retryLocalModel() async {
        switch liveEngine {
        case .deepgram:
            return
        case .whisperKit:
            await loadModel()
        case .appleSpeech:
            await prepareSpeechModel()
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
        // "Sadece orijinal"den dönünce o sırada çevrilmeyen cümleler de çevrilir (toplantıda çevirisi eksik kalmasın).
        if resumesTranslation, isRecording {
            for segment in transcript where segment.id.speaker == .others && segment.isFinal && !segment.text.isEmpty
                && translations[segment.id] == nil && !failedTranslations.contains(segment.id) {
                enqueueTranslation(segment: segment)
            }
        }
    }

    // MARK: Asistan

    /// Son N dakikanın (Ayarlar) not dilinde özeti.
    func askWhatIMissed() {
        let minutes: Int = clampedSetting(key: SettingsKey.missedWindowMinutes, range: SettingsRange.missedWindowMinutes)
        let segments: [LiveSegment] = suppressEchoes(transcript: correctedTranscript)
        let nowSec: Double = transcript.map(\.endSec).max() ?? 0
        guard let request = missedSummaryRequest(segments: segments, nowSec: nowSec, windowSec: Double(minutes * 60), language: selectedNoteLanguage()) else {
            cancelAssistant()
            assistantCard = .summary(MissedSummary(topic: String(localized: "Son \(minutes) dakikada konuşma yok."), decisions: [], askedOfYou: []))
            return
        }
        runAssistant(request: request, title: String(localized: "Ne kaçırdım?")) { (text: String) throws -> AssistantCard in
            .summary(try parseMissedSummary(text: text))
        }
    }

    /// Toplantı hakkında soru (cevap not dilinde); henüz konuşma yoksa istek atılmaz.
    func ask(question: String) {
        guard let request = questionRequest(segments: suppressEchoes(transcript: correctedTranscript), question: question, language: selectedNoteLanguage()) else {
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
        let languages: [MeetingLanguage] = liveMeetingLanguages()
        let noteLanguage: ShareLanguage = selectedNoteLanguage()
        assistantTask = Task { [weak self] in
            let card: AssistantCard
            do {
                let provider: LLMProvider = try await resolveLiveLLMProvider()
                try requireOnDeviceLanguages(provider: provider, meetingLanguages: languages, outputLanguage: noteLanguage)
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

    /// Süren kaydın bilinen dili (kilitlenen ya da sabit seçilen); otomatik modda kilitlenmeden önce boş.
    private func liveMeetingLanguages() -> [MeetingLanguage] {
        (lockedLanguage ?? fixedLanguage(mode: languageMode)).map { [$0] } ?? []
    }

    /// Kesinleşmiş "Diğerleri" bölümünü sıraya alıp not diline çevirir (hızlı model).
    private func enqueueTranslation(segment: LiveSegment) {
        // "Sadece orijinal" görünümünde canlı çeviri yapılmaz (maliyet); toplantı sonu not yine üretilir.
        guard displayMode.needsLiveTranslation else {
            return
        }
        // Toplantı not dilindeyse aynı dile çeviri yapılmaz: orijinal tek başına görünür (LLM'e gitmez, maliyet yok).
        guard needsLiveTranslation(spoken: lockedLanguage ?? fixedLanguage(mode: languageMode), noteLanguage: selectedNoteLanguage()) else {
            return
        }
        guard !translationDisabled, let provider = llmProvider else {
            // Çeviri şu an yapılamıyor (anahtar reddedildi ya da sağlayıcı yok): cümle kaybolmasın, "Tekrar dene"de kalsın.
            failedTranslations.insert(segment.id)
            return
        }
        do {
            try requireOnDeviceLanguages(provider: provider, meetingLanguages: liveMeetingLanguages(), outputLanguage: selectedNoteLanguage())
        } catch {
            // Cihaz içi model bu dili anlamıyor: bozuk çeviri yerine açık mesaj; sağlayıcı değişince "Tekrar dene"de çevrilir.
            failedTranslations.insert(segment.id)
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Çeviri: \(userFacingMessage(error: error))"))
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
        guard generation == recordingGeneration else {
            return
        }
        guard !translationDisabled else {
            // Anahtar reddedildi (401/403) ya da kayıt sonu süresi doldu: sıradaki cümle kaybolmasın, "Tekrar dene"de kalsın.
            failedTranslations.insert(segment.id)
            return
        }
        do {
            let translated: String = try await sendLLM(provider: provider, request: translationRequest(sentence: segment.text, context: context, language: selectedNoteLanguage()))
            // Bu arada yeni kayıt başladıysa sonuç başka bir toplantının aynı numaralı bölümüne yazılmaz.
            guard generation == recordingGeneration else {
                return
            }
            // Cümle zaten not dilindeyse (model aynen döndürdü) çeviri saklanmaz: aynı cümle iki kez görünmesin.
            if isDistinctTranslation(original: segment.text, translated: translated) {
                translations[segment.id] = translated
            }
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
            if stopsLiveTranslation(error: error) {
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
            llmProvider = try await resolveLiveLLMProvider()
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
        #if DEBUG
        // Tanıtım modu sunucuya ve Anahtar Zinciri'ne bakmaz: kurulum eksiksiz görünür (bkz. App/DemoData.swift).
        if isDemoMode {
            setupProblems = []
            return
        }
        #endif
        #if HOSTED_EDITION
        // Abonelik sürümünde anahtar yok: eksik yalnızca giriş (ya da sunucu adresi).
        setupProblems = await hostedSetupProblems()
        #else
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
                let exists: Bool = try await Task.detached { try secretExists(service: appKeychainService, account: account) }.value
                if !exists {
                    problems.append(userFacingMessage(error: KeychainError.notFound(service: appKeychainService, account: account.rawValue)))
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
        if kind == .onDevice {
            do {
                let config: OnDeviceConfig = try onDeviceConfig()
                if let warning = onDeviceModeWarning(config: config, primaryLanguage: primaryMeetingLanguage(), outputLanguage: selectedNoteLanguage()) {
                    problems.append(warning)
                }
            } catch {
                problems.append(userFacingMessage(error: error))
            }
        }
        setupProblems = problems
        #endif
    }

    // MARK: Motor

    /// Motoru değiştirir ve kaydeder; WhisperKit seçilirse model (henüz yoksa) yüklenir.
    func selectEngine(engine: LiveEngine) async {
        liveEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: SettingsKey.liveEngine)
        await refreshSetupProblems()
        switch engine {
        case .deepgram:
            break
        case .whisperKit:
            if self.engine == nil {
                await loadModel()
            } else {
                modelStatus = .ready
            }
        case .appleSpeech:
            await prepareSpeechModel()
        }
    }

    /// Ana toplantı dili değişti: uyarılar yenilenir; cihaz içi tanımada yeni dilin modeli kayıttan önce hazırlanır
    /// (yoksa ilk bölüm indirmeyi beklerdi).
    func primaryLanguageChanged() {
        Task {
            await refreshSetupProblems()
            if liveEngine == .appleSpeech, !isRecording, !isStarting {
                await prepareSpeechModel()
            }
        }
    }

    /// Cihaz içi konuşma modelini ana toplantı dili için hazırlar (yüklü değilse indirir, ilerleme durumda görünür).
    func prepareSpeechModel() async {
        modelStatus = .loading
        speechModelProgress = nil
        do {
            _ = try await prepareAppleSpeech(language: primaryMeetingLanguage()) { [weak self] (fraction: Double) -> Void in
                Task { @MainActor in
                    self?.speechModelProgress = fraction < 1 ? fraction : nil
                }
            }
            speechEngine = speechEngine ?? AppleSpeechEngine()
            speechModelProgress = nil
            modelStatus = .ready
        } catch {
            Self.logger.error("Cihaz içi konuşma modeli hazırlanamadı, hata: \(String(describing: error), privacy: .private)")
            speechModelProgress = nil
            modelStatus = .failed(userFacingMessage(error: error))
        }
    }

    /// Modeli (ilk seferde indirerek) yükler; yükleme sürüyorsa onu bekler.
    func loadModel() async {
        if let modelLoad {
            await modelLoad.value
            return
        }
        let task: Task<Void, Never> = Task { await self.performModelLoad() }
        modelLoad = task
        await task.value
        modelLoad = nil
    }

    #if HOSTED_EDITION
    /// Abonelik: Mac'teki motor (hibrit oturum Mac'e geçerken ya da Mac'te başlarken çağırır); yüklü değilse model
    /// indirilip yüklenir (ilerleme menüde ve panelde görünür). Yüklenemezse `TranscriptionError.modelLoadFailed`.
    func requireLocalEngine() async throws -> WhisperKitEngine {
        if let engine {
            return engine
        }
        await loadModel()
        if let engine {
            return engine
        }
        let reason: String
        if case .failed(let message) = modelStatus {
            reason = message
        } else {
            reason = "model yüklenmedi"
        }
        throw TranscriptionError.modelLoadFailed(model: liveWhisperModel, reason: reason)
    }
    #endif

    private func performModelLoad() async {
        modelStatus = .loading
        whisperModelProgress = nil
        do {
            let modelsDirectory: URL = try AppPaths.modelsDirectory()
            engine = try await WhisperKitEngine.load(modelName: liveWhisperModel, modelsDirectory: modelsDirectory) { [weak self] (fraction: Double) -> Void in
                Task { @MainActor in
                    // İndirme bitince (ya da model zaten indiyse) yükleme sürer: yüzde yerine "hazırlanıyor".
                    self?.whisperModelProgress = fraction < 1 ? fraction : nil
                }
            }
            whisperModelProgress = nil
            modelStatus = .ready
        } catch {
            Self.logger.error("Model yüklenemedi, hata: \(String(describing: error), privacy: .private)")
            whisperModelProgress = nil
            modelStatus = .failed(userFacingMessage(error: error))
            return
        }
        #if !HOSTED_EDITION
        // Konuşmacı ayırma modeli de şimdi indirilir: ilk yerel toplantının son geçişi internetsiz çalışsın.
        // İndirilemezse canlı kayıt engellenmez; uyarı menüde görünür, son geçiş metni tek konuşmacı saklar.
        // (Abonelik sürümünde konuşmacılar sunucunun son geçişinde ayrılır: ~40 MB model indirilmez.)
        do {
            try await prepareLocalDiarization(modelsDirectory: try AppPaths.modelsDirectory())
            localDiarizationWarning = nil
        } catch {
            Self.logger.error("Konuşmacı ayırma modeli indirilemedi, hata: \(String(describing: error), privacy: .private)")
            localDiarizationWarning = String(localized: "Konuşmacı ayırma modeli indirilemedi; internete bağlanıp \"Modeli yeniden yükle\"ye bas.")
        }
        #endif
    }

    // MARK: Kayıt

    /// İki ses akışını başlatır ve canlı oturumu çalıştırır.
    /// Akışlardan biri başlatılamazsa hata gösterilir, diğeriyle devam edilir.
    func startRecording() async {
        guard !isRecording, !isStarting, isReadyToRecord else {
            return
        }
        #if HOSTED_EDITION
        // Giriş kapısı (ikinci savunma; kayıt yolları `toggleRecordingFlow`'da da kapılı): oturum yoksa kayıt başlamaz.
        guard !HostedAccount.shared.requiresSignIn else {
            Self.logger.info("Giriş yapılmadan kayıt istendi, başlatılmadı")
            return
        }
        #endif
        isStarting = true
        defer { isStarting = false }
        // Motor bir kez okunur: izin pencereleri açıkken ayar değişse de bulut/yerel kararı ile kaydın motoru aynı kalır
        // (yerel toplantı bulut sayılıp son geçişte buluta gönderilmesin).
        let engineAtStart: LiveEngine = liveEngine
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

        #if !HOSTED_EDITION
        // Bulut anahtarları yakalama başlamadan önce okunur: eksikse hiçbir şey başlatılmaz; eksiklerin hepsi bildirilir.
        // (Abonelik sürümünde anahtar yoktur; canlı motor toplantı oturumu açıldıktan sonra seçilir.)
        let cloudKeys: (deepgram: String, elevenLabs: String)?
        switch engineAtStart {
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
        case .whisperKit, .appleSpeech:
            cloudKeys = nil
        }
        #endif

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
        // Ses seviyesi panelde görünür (sesin geldiği anlaşılsın); iki akışın en yükseği çubuğa düşer. En yüksek değer
        // kilitli kutuda birikir, ana aktöre çubuk aralığının yarısında bir geçilir (her parça için ayrı görev
        // açılmaz; bkz. `levelThrottleInterval`).
        audioLevels.start()
        let levels: AudioLevels = audioLevels
        let throttle: LevelThrottle = LevelThrottle(intervalSec: levelThrottleInterval(barInterval: levels.interval))
        let onLevel: @Sendable (Float) -> Void = { (level: Float) -> Void in
            guard let peak = throttle.add(level: level) else {
                return
            }
            Task { @MainActor in levels.record(level: peak) }
        }
        let meteredMe: AsyncStream<[Float]> = meteredStream(audio: meAudio, onLevel: onLevel)
        let meteredOthers: AsyncStream<[Float]> = meteredStream(audio: othersAudio, onLevel: onLevel)
        #if HOSTED_EDITION
        // Ses hemen diske yazılır: toplantı oturumu açılırken ve canlı motor seçilirken (ağ beklenirken) gelen ses de
        // dosyada durur (uygulama bu arada kapansa bile).
        let hybridRecording: HybridRecording = startHybridRecording(directory: directory, meAudio: meteredMe, othersAudio: meteredOthers)
        // Abonelik: toplantı oturumu ses akışları başladıktan sonra açılır (yakalama başarısızsa deneme hakkı yanmasın);
        // sunucu reddederse (deneme bitti, aylık sınır, harcama tavanı…) kayıt başlamaz, yazılan ses silinir ve nedeni
        // panelde görünür.
        let meetingDeadline: Date
        do {
            let requestedAt: Date = Date()
            switch try await HostedAccount.shared.startMeeting(recordID: directory.lastPathComponent) {
            case .online(let started):
                meetingDeadline = hostedRecordingDeadline(requestedAt: requestedAt, maxDurationMinutes: started.maxDurationMinutes, serverEndsAt: started.expiresAt)
                // Aylık sınıra az kaldıysa toplantı olağandan kısadır: kalan dakika kayıt panelinde görünür.
                shortMeetingDeadline = isShortenedHostedMeeting(started: started) ? meetingDeadline : nil
            case .offline(let maxMinutes):
                // Sunucuya ulaşılamadı: kayıt sürer (canlı metin Mac'te), süre son bilinen hak durumuyla sınırlı; toplantı
                // bağlantı gelince işlenir (bkz. `runOfflineQueue`).
                meetingDeadline = requestedAt.addingTimeInterval(Double(maxMinutes) * 60)
                shortMeetingDeadline = nil
            }
        } catch {
            Self.logger.error("Toplantı oturumu açılamadı, kayıt başlatılmadı, hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            // Ret aylık sınırdan ya da denemenin bitmesinden olabilir: göstergeler ve bildirim güncellensin.
            Task { await HostedAccount.shared.refresh() }
            microphone.stop()
            systemAudio.stop()
            audioLevels.stop()
            discardRefusedRecording(directory: directory)
            return
        }
        #endif

        let handle: LiveSessionHandle
        #if HOSTED_EDITION
        // Abonelik: sunucu izin veriyorsa canlı metin Deepgram'la, değilse (ya da akış durursa) Mac'te; kayıt kesintisiz.
        // Deepgram akışı dil algılamaz: cihaz içi tanımadaki kural (sabit dil ya da ana toplantı dili).
        let liveLanguage: MeetingLanguage = appleSpeechLanguage(mode: languageMode, primary: primaryMeetingLanguage())
        let choice: HostedLiveChoice = await hostedLiveChoice(
            language: liveLanguage, keyterms: keytermsWithAttendees(attendees: linkedMeeting?.attendees ?? [], keyterms: recognitionKeyterms, limit: 30)
        )
        hostedLiveStatus = choice.status
        Self.logger.info("Canlı motor seçildi, motor: \(choice.status.engine.rawValue, privacy: .public)")
        handle = runHybridLiveSession(
            config: HybridLiveSessionConfig(
                speakers: startedSpeakers,
                local: LiveSessionConfig(
                    languageMode: languageMode,
                    segmenter: .live,
                    recordingDirectory: directory,
                    partialIntervalSec: 1.5,
                    minPartialSpeechSec: 1.0,
                    languageLockAfterSec: 30,
                    candidateLanguages: automaticCandidates(primary: primaryMeetingLanguage())
                ),
                maxPendingAudioSec: 600
            ),
            start: choice.start,
            localEngine: { [weak self] () async throws -> any TranscriptionEngine in
                guard let self else {
                    throw CancellationError()
                }
                return try await self.requireLocalEngine()
            },
            recording: hybridRecording
        )
        #else
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
        } else if liveEngine == .appleSpeech, let speechEngine {
            // Cihaz içi tanıma dil algılamaz: otomatikte ana toplantı diliyle başlar; dil panelden değiştirilebilir.
            let language: MeetingLanguage = appleSpeechLanguage(mode: languageMode, primary: primaryMeetingLanguage())
            handle = runLiveSession(
                config: LiveSessionConfig(
                    languageMode: .fixed(language),
                    segmenter: .live,
                    recordingDirectory: directory,
                    partialIntervalSec: 1.5,
                    minPartialSpeechSec: 1.0,
                    languageLockAfterSec: 30,
                    candidateLanguages: [language]
                ),
                engine: speechEngine,
                meAudio: meteredMe,
                othersAudio: meteredOthers
            )
            // Panelde dil görünsün (sabit dilde oturum kilit olayı yayınlamaz).
            await handle.setLanguage(language)
        } else if liveEngine == .whisperKit, let engine {
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
            // isReadyToRecord yerel motorlarda motoru garanti eder; buraya gelinmesi programlama hatasıdır.
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Konuşma tanıma modeli hazır değil."))
            microphone.stop()
            systemAudio.stop()
            return
        }
        #endif
        isRecording = true
        #if HOSTED_EDITION
        watchRecordingLimit(deadline: meetingDeadline)
        #endif
        liveHighlights = []
        liveMyNotes = ""
        recordingTemplate = defaultNoteTemplate()
        consentReminderVisible = UserDefaults.standard.bool(forKey: SettingsKey.consentReminder)
        // Yeni bitirme için hazırlanma kartı yeniden gösterilir.
        finishingCardDismissed = false
        recordingStartedAt = startedAt
        session = RecordingSession(directory: directory, startedAt: startedAt, engine: engineAtStart, handle: handle, pauseGate: pauseGate, micGate: micGate)
        activeMeetingID = directory.lastPathComponent
        keepAwake(meetingID: directory.lastPathComponent)
        startCheckpoints(directory: directory, startedAt: startedAt, engine: engineAtStart)
        // Uygulama kayıt sırasında kapanırsa toplantı açılışta "yarıda kaldı" olarak bulunur.
        saveRecord(record: liveRecord(directory: directory, startedAt: startedAt, engine: engineAtStart, status: .recording, endedAt: nil), directory: directory)
        Self.logger.info("Kayıt başladı, klasör: \(directory.lastPathComponent, privacy: .public), motor: \(engineAtStart.rawValue, privacy: .public)")
        sessionTask = Task { [weak self] in
            for await event in handle.events {
                self?.handle(event: event)
            }
            await self?.sessionEnded()
        }
    }

    #if HOSTED_EDITION
    /// Abonelik: toplantının süre sınırından 5 dk önce panelde ve adada uyarı, sınırda kayıt "Bitir"e basılmış gibi
    /// bitirilir ve normal işlenir. Kayıt bitince (ya da yenisi başlayınca) görev kendiliğinden sona erer.
    private func watchRecordingLimit(deadline: Date) {
        recordingLimitTask?.cancel()
        let generation: Int = recordingGeneration
        recordingLimitTask = Task { [weak self] in
            var warned: Bool = false
            while !Task.isCancelled {
                guard let self, self.isRecording, !self.isFinishing, generation == self.recordingGeneration else {
                    return
                }
                switch hostedRecordingLimitState(now: Date(), deadline: deadline, warningLeadSec: hostedLimitWarningLeadSec) {
                case .running:
                    break
                case .warning:
                    if !warned {
                        warned = true
                        let time: String = deadline.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale()))
                        Self.logger.info("Toplantının süre sınırı yaklaşıyor, uyarı gösterildi")
                        self.errorMessages = appendUnique(messages: self.errorMessages, message: String(localized: "Bu toplantının süre sınırına 5 dakika kaldı; kayıt \(time) itibarıyla bitirilecek."))
                    }
                case .reached:
                    Self.logger.info("Toplantının süre sınırına ulaşıldı, kayıt bitiriliyor")
                    self.errorMessages = appendUnique(messages: self.errorMessages, message: String(localized: "Bu toplantının süre sınırına ulaşıldı; kayıt bitirildi."))
                    self.stopRecording()
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    // İptal: kayıt bitti.
                    return
                }
            }
        }
    }
    #endif

    /// Anahtarı arka planda okur; sonucu hata dahil döndürür (birden çok eksik birlikte bildirilsin diye).
    private func secretResult(account: SecretAccount) async -> Result<String, any Error> {
        do {
            return .success(try await readSecretInBackground(service: appKeychainService, account: account))
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
        case .streamIncomplete(let speaker, let untranscribedSec):
            // Kapanışta sesin sonu yazıya dökülemedi: kayıp anlamlıysa "Sen" kaydı toplantı sonunda yazıya dökülür
            // (kullanıcıya hata gösterilmez; metin son geçişte tamamlanır). Durdurma tıkına denk gelen birkaç yüz ms için
            // tüm kayıt yeniden yazıya dökülmez. "Diğerleri" son geçişten zaten geçer.
            meStreamFailed = meStreamFailed || (speaker == .me && untranscribedSec >= incompleteTailFinalPassSec)
            Self.logger.warning("Canlı metnin sonu eksik, konuşmacı: \(speaker.rawValue, privacy: .public), süre: \(untranscribedSec, privacy: .public)")
        case .liveEngineFellBack(let message):
            // Bulut canlı metni durdu, Mac'e geçildi: geçişte kesinleşmemiş "Sen" metni toplantı sonunda kayıttan
            // yazıya dökülür ("Diğerleri" son geçişten zaten geçer). Ses kaydı kesilmedi.
            meStreamFailed = meStreamFailed || startedSpeakers.contains(.me)
            #if HOSTED_EDITION
            hostedLiveStatus = HostedLiveStatus(engine: .whisperKit, reason: String(localized: "Bulut canlı metni kayıt sırasında durdu: \(message)"))
            #endif
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Bulut canlı metni durdu; canlı metin bu Mac'te sürüyor, kayıt kesilmedi. (\(message))"))
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
        // Biten kayıt ilk beklemeden önce oturumdan alınır ve "devrediliyor" sayılır: sunucu oturumu kapatılırken yeni
        // kayıt bu kaydın `session`ını ezemez, kuyruk ve çıkış/güncelleme beklenir (isBusy), kayıt düzenlenemez.
        let finished: RecordingSession? = session
        session = nil
        handingOffMeetingID = finished?.directory.lastPathComponent
        activeMeetingID = nil
        defer { handingOffMeetingID = nil }
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
        #if HOSTED_EDITION
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        shortMeetingDeadline = nil
        let recordedOffline: Bool = HostedAccount.shared.isOfflineRecording
        // Kapatılacak oturum beklemeden önce alınır: geç dönen kapatma yeni kaydın oturumuna dokunmaz.
        let serverMeetingID: String? = HostedAccount.shared.currentMeeting?.meetingId
        // Abonelik: toplantı oturumu kapanır; not ve son geçiş sunucunun ek süresinde aynı oturumla sürer.
        do {
            try await HostedAccount.shared.endMeeting(meetingID: serverMeetingID)
        } catch {
            Self.logger.error("Toplantı oturumu kapatılamadı, hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Toplantı oturumu kapatılamadı: \(userFacingMessage(error: error))"))
        }
        #endif
        guard let finished else {
            return
        }
        // Kaydın motoru kaydın gerçek motorudur (oturumdan), şimdiki ayar değil.
        let record: MeetingRecord = liveRecord(directory: finished.directory, startedAt: finished.startedAt, engine: finished.engine, status: .processing, endedAt: Date())
        #if HOSTED_EDITION
        if recordedOffline {
            // Çevrimdışı kayıt: ses ve canlı metin bu Mac'te; son geçiş ve not bağlantı gelince (kayıt silinmez).
            saveRecord(record: record.with(status: .queued, failureMessage: nil).with(notice: String(localized: "Çevrimdışı kaydedildi; bağlantı gelince konuşmacılar ve not hazırlanır.")), directory: finished.directory)
            // Uyku engeli kayıtla biter: kuyruktaki kayıt sunucu kabul edene dek (belki hiç) işlenmeyebilir; işlenirken
            // `process` yeniden alır.
            allowSleep(meetingID: record.id)
            reloadMeetings()
            lastFinishedMeetingID = record.id
            return
        }
        #endif
        // Kaydın hemen ardından not, toplantının sağlayıcısıyla (abonelikte o kaydın sunucu oturumunun bütçesi).
        let recordID: String = record.id
        process(record: record, directory: finished.directory) { [weak self] () async -> LLMProvider? in
            await self?.optionalProvider { try await resolveRecordedMeetingLLMProvider(recordID: recordID) }
        }
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
    /// `engine`: kaydın başladığı motor (o anki ayar değil; bitirilen oturumun motoru).
    private func liveRecord(directory: URL, startedAt: Date, engine: LiveEngine, status: MeetingStatus, endedAt: Date?) -> MeetingRecord {
        let base: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: linkedMeeting?.title ?? String(localized: "Toplantı"), startedAt: startedAt, endedAt: endedAt,
            language: lockedLanguage, status: status, failureMessage: nil,
            liveSegments: storedSegments(transcript: correctedTranscript), finalSegments: [],
            translations: Dictionary(uniqueKeysWithValues: translations.map { (segmentKey(id: $0.key), $0.value) }),
            speakerNames: [:], note: nil, audioDeleted: false,
            engine: engine.recordingEngine, notice: nil,
            meNeedsFinalPass: meStreamFailed ? true : nil
        )
        // Not, kayıt başladığında seçili şablonla yazılır; kayıtta işaretlenen anlar öne çıkar.
        .with(template: recordingTemplate)
        .with(highlights: liveHighlights)
        .with(myNotes: liveMyNotes)
        return linkedMeeting.map { base.with(attendees: $0.attendees).with(calendarEventID: $0.id) } ?? base
    }

    /// Kayıt sürerken her 30 sn'de transkripti saklar: uygulama çökerse metin "Yarıda kaldı" toplantısında durur.
    private func startCheckpoints(directory: URL, startedAt: Date, engine: LiveEngine) {
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
                self.saveRecord(record: self.liveRecord(directory: directory, startedAt: startedAt, engine: engine, status: .recording, endedAt: nil), directory: directory)
            }
        }
    }

    // MARK: Toplantı kayıtları

    #if HOSTED_EDITION
    /// Sunucu toplantıyı reddetti (deneme bitti, sınır…): kayıt başlamadı, o ana dek diske yazılan ses ve klasör silinir.
    private func discardRefusedRecording(directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Self.logger.error("Reddedilen kaydın klasörü silinemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }
    #endif

    /// Bu toplantı üzerinde değişiklik yapılabilir mi (kayıtta ya da işlemede değil).
    func isLocked(meetingID: String) -> Bool {
        activeMeetingID == meetingID || handingOffMeetingID == meetingID || processingMeetingIDs.contains(meetingID)
    }

    /// Toplantıyı sonradan işler (son geçiş + not) ve kaydeder. Son geçiş kaydın motoruna göre yapılır
    /// (yerel toplantı buluta gönderilmez); dil kaydın kilitlenmiş dilidir.
    private func process(record: MeetingRecord, directory: URL, llmProvider resolveLLM: @escaping @MainActor () async -> LLMProvider?) {
        saveRecord(record: record, directory: directory)
        processingMeetingIDs.insert(record.id)
        keepAwake(meetingID: record.id)
        // İlerleme kartı yalnızca kayıt sonrası işleme (adımlı) için; "Notu yenile" adım bildirmez, kart açmaz.
        processingSteps[record.id] = .convertingAudio
        let userName: String = UserDefaults.standard.string(forKey: SettingsKey.userName) ?? ""
        let languageMode: LanguageMode = record.language.map { LanguageMode.fixed($0) } ?? .automatic
        Task {
            let plan: FinalPassPlan = await finalPassPlan(record: record)
            let llm: LLMProvider? = await resolveLLM()
            let result: MeetingRecord = await processMeeting(
                record: record, directory: directory, finalPass: plan, llm: llm, languageMode: languageMode, userName: userName,
                noteLanguage: selectedNoteLanguage(), voiceEmbedder: voiceEmbedderIfEnabled(), registry: registeredVoices
            ) { (step: ProcessingStep) async -> Void in
                self.processingSteps[record.id] = step
            }
            // Tekrar işlemede eski not geçmişe girer (ilk işlemede not yoktur).
            let versioned: MeetingRecord = withNoteVersion(updated: result, previous: record, reason: String(localized: "Tekrar işlendi"), savedAt: Date())
            let saved: MeetingRecord = withLatestMarks(result: versioned, start: record, directory: directory)
            saveRecord(record: saved, directory: directory)
            processingMeetingIDs.remove(record.id)
            processingSteps[record.id] = nil
            allowSleep(meetingID: record.id)
            #if HOSTED_EDITION
            // Son geçişin ses süresi aylık kullanıma sayılır: işleme bitince göstergeler yenilenir. Not hazırsa denemedeki
            // kullanıcıya zamanı geldiyse abone olma teklifi açılır.
            if saved.status == .done && saved.note != nil {
                Task { await HostedAccount.shared.meetingNoteReady() }
            } else {
                Task { await HostedAccount.shared.refresh() }
            }
            #endif
            autoSendToDestinations(record: saved)
            if saved.status == .done {
                await cloud.moveFinishedMeetings(excluding: cloudMoveExclusions) { [weak self] in self?.reloadMeetings() }
            }
        }
    }

    /// Mac uykuya geçerken kaydı bitirir; uygulama kapanırken süren kaydın son halini saklar.
    private func observeSleepAndTermination() {
        let sleep: any NSObjectProtocol = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.finishRecordingBeforeSleep()
            }
        }
        let terminate: any NSObjectProtocol = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.saveCheckpointBeforeQuit()
            }
        }
        systemObservers = [sleep, terminate]
    }

    /// Kapak kapandı ya da Mac uyuyor: kayıt temiz biçimde bitirilir. Uykuda saat ilerlediği için sürdürülen kayıt
    /// uyanınca uyku süresi kadar sessizlik (saatlik uykuda yüzlerce MB) üretip buluta yüklerdi.
    private func finishRecordingBeforeSleep() {
        guard isRecording, !isFinishing else {
            return
        }
        Self.logger.info("Mac uykuya geçiyor, kayıt bitiriliyor")
        stopRecording()
        errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Mac uykuya geçtiği için kayıt bitirildi; not hazırlanıyor."))
    }

    /// "Yine de çık": süren kaydın son transkripti saklanır (son kontrol noktasından sonraki metin kaybolmasın);
    /// toplantı açılışta "Yarıda kaldı" olarak bulunur.
    private func saveCheckpointBeforeQuit() {
        guard isRecording, let session else {
            return
        }
        Self.logger.info("Kayıt sürerken uygulama kapanıyor, son durum saklanıyor, klasör: \(session.directory.lastPathComponent, privacy: .public)")
        saveRecord(record: liveRecord(directory: session.directory, startedAt: session.startedAt, engine: session.engine, status: .recording, endedAt: nil), directory: session.directory)
    }

    /// Toplantının kaydı ya da işlenmesi sürerken boşta uykuyu engeller (kapak kapatma yine uyutur).
    private func keepAwake(meetingID: String) {
        guard sleepActivities[meetingID] == nil else {
            return
        }
        sleepActivities[meetingID] = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "\(appName) toplantı kaydediyor ya da işliyor"
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

    /// Bu motorla tanınan kaydın son geçişi bu Mac'te mi (WhisperKit + SpeakerKit; konuşmacılar Mac'te ayrılır).
    /// `finalPassPlan` ile aynı karar: abonelikte son geçiş hep sunucuda; kendi anahtarlı sürümde Mac'te tanınan kayıt,
    /// cihaz içi mod dışında (Apple konuşma tanıma konuşmacı ayırmaz).
    func finalPassRunsOnThisMac(engine: RecordingEngine?) -> Bool {
        #if HOSTED_EDITION
        false
        #else
        engine == .local && liveEngine != .appleSpeech
        #endif
    }

    /// Kaydın motoruna göre son geçiş; eski toplantılar (motor bilgisi yok) bulut sayılır.
    private func finalPassPlan(record: MeetingRecord) async -> FinalPassPlan {
        #if HOSTED_EDITION
        // Abonelik: kaydın motoru ne olursa olsun son geçiş sunucuda (konuşmacılar ayrılır).
        return await hostedFinalPassPlan(keyterms: recognitionKeyterms, recordID: record.id)
        #else
        switch record.engine ?? .cloud {
        case .local where liveEngine == .appleSpeech:
            // Cihaz içi modda WhisperKit (~630 MB) indirilmez: kayıt Apple'ın konuşma tanımasıyla yeniden yazılır.
            return .run(AppleSpeechFinalTranscriber(primaryLanguage: primaryMeetingLanguage()))
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
                guard let key = try await optionalSecretInBackground(service: appKeychainService, account: .elevenlabs) else {
                    return .skip(reason: String(localized: "ElevenLabs anahtarı kayıtlı değil."))
                }
                return .run(ElevenLabsFinalTranscriber(apiKey: key, keyterms: recognitionKeyterms))
            } catch {
                return .skip(reason: userFacingMessage(error: error))
            }
        }
        #endif
    }

    /// LLM sağlayıcısı; anahtar ya da ayar yoksa nil (not adımı bunu açıkça bildirir), diğer hatalar panelde.
    private func optionalLLMProvider() async -> LLMProvider? {
        await optionalProvider(resolve: resolveLLMProvider)
    }

    /// Verilen çözücüyle sağlayıcı; anahtar ya da ayar yoksa nil, diğer hatalar panelde.
    private func optionalProvider(resolve: () async throws -> LLMProvider) async -> LLMProvider? {
        do {
            return try await resolve()
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
        #if HOSTED_EDITION
        // Bekleyen (çevrimdışı) kayıt önce sunucu oturumunu almalı: kuyruktan işlenir.
        if record.status == .queued {
            Task { await runOfflineQueue() }
            return
        }
        #endif
        // Son geçiş konuşmacıları yeniden numaralar; eski öneriler başka kişileri gösterirdi.
        closeSpeakerReview(meetingID: meetingID)
        // Not, toplantının sağlayıcısıyla yazılır: abonelikte son geçişin yeniden açtığı oturum bütçesi (hakkı bitmiş
        // kullanıcı da sunucunun izin verdiği sürede yeniden işleyebilir), kendi anahtarlı sürümde Ayarlar'daki sağlayıcı.
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            process(record: record, directory: directory) { [weak self] () async -> LLMProvider? in
                await self?.optionalProvider { try await resolveRecordedMeetingLLMProvider(recordID: meetingID) }
            }
        }
    }

    #if HOSTED_EDITION
    /// Bekleyen ilk toplantıyı (çevrimdışı kaydedilmiş ya da içe aktarılmış) işler: kayıt ya da işleme yokken sunucu oturumu hazırlanır
    /// (bkz. `HostedAccount.prepareQueuedMeeting`), sonra son geçiş ve not o oturumla üretilir. Sunucuya hâlâ
    /// ulaşılamıyorsa bekler; sunucu şimdilik işlemiyorsa (deneme bitti, sınır) kayıt bekleyen kalır ve nedeni toplantıda
    /// görünür. Ağ gelince, hak durumu okununca, uygulama öne gelince ve her işleme bitince tetiklenir; birer birer işler.
    @ObservationIgnored private var isRunningQueue: Bool = false
    /// Sunucunun reddettiği bekleyen kayıtlar ve reddin anı (bkz. `hostedQueueCandidates`).
    @ObservationIgnored private var queueRejections: [String: Date] = [:]

    func runOfflineQueue() async {
        guard !isBusy, !isStarting, !isRunningQueue else {
            return
        }
        // İlk beklemeden önce açılır: eşzamanlı tetiklemeler kuyruğu ikinci kez çalıştırmasın.
        isRunningQueue = true
        defer { isRunningQueue = false }
        let userID: String
        do {
            guard let signedIn = try await HostedAccount.shared.signedInUserID() else {
                return
            }
            userID = signedIn
        } catch {
            Self.logger.error("Kuyruk: oturum okunamadı, hata: \(String(describing: error), privacy: .private)")
            return
        }
        // Yüklü toplantılar giriş yapan hesabın değilse (başka hesapla giriş yapıldı, uygulama yeniden başlamayı
        // bekliyor) hiçbiri işlenmez: kayıtlar sahiplerinin klasöründe bekler, başka hesaba faturalanmaz.
        guard AppPaths.activeAccountKey() == accountDataKey(userId: userID) else {
            Self.logger.info("Kuyruk: yüklü toplantılar giriş yapan hesabın değil, işlenmedi")
            return
        }
        let queued: HostedQueuedRecords = hostedQueuedRecords(records: meetings, owners: loadHostedRecordOwners(), userId: userID)
        for record in queued.foreign {
            noteQueued(recordID: record.id, notice: String(localized: "Bu kayıt başka bir hesapla yapıldı; o hesapla giriş yapınca işlenir."))
        }
        // Tetikleme başına en çok bir sunucu reddi: reddedilen kayıt nedeniyle işaretlenir, bir süre denenmez ve kuyruk
        // durur (başlatma hız sınırı dolup canlı kayıt 429 almasın); sonraki tetiklemede sıradaki kayıt denenir. Hak
        // durumundan (istek atmadan) engellenen kayıtlar sonrakileri bekletmez. İlk hazır olan işlenir, kalanlar işleme
        // bitince yeniden tetiklenir.
        for record in hostedQueueCandidates(records: queued.own, rejections: queueRejections, now: Date(), cooldownSec: hostedQueueRejectionCooldownSec) {
            let recordID: String = record.id
            switch await HostedAccount.shared.prepareQueuedMeeting(recordID: recordID) {
            case .waitingForNetwork:
                return
            case .blocked(let reason):
                noteQueued(recordID: recordID, notice: reason)
            case .rejected(let reason):
                queueRejections[recordID] = Date()
                noteQueued(recordID: recordID, notice: reason)
                return
            case .ready:
                // Hazırlık sürerken kayıt başlamış ya da toplantı silinmiş olabilir.
                guard !isBusy, let current = meetings.first(where: { $0.id == recordID }), current.status == .queued else {
                    return
                }
                Self.logger.info("Çevrimdışı kayıt işleniyor, toplantı: \(recordID, privacy: .public)")
                withSessionDirectory(id: recordID) { (directory: URL) -> Void in
                    process(record: current.with(notice: nil), directory: directory) { [weak self] () async -> LLMProvider? in
                        await self?.optionalProvider { try await resolveRecordedMeetingLLMProvider(recordID: recordID) }
                    }
                }
                return
            }
        }
    }

    /// Bekleyen kaydın işlenememe nedenini toplantıya yazar (değişmediyse dokunmaz).
    private func noteQueued(recordID: String, notice: String) {
        guard let current = meetings.first(where: { $0.id == recordID }), current.status == .queued, current.notice != notice else {
            return
        }
        withSessionDirectory(id: recordID) { (directory: URL) -> Void in
            saveRecord(record: current.with(notice: notice), directory: directory)
        }
        reloadMeetings()
    }
    #endif

    /// Abonelik: hakkı yoksa (deneme bitti, abonelik sona erdi) yapay zekâ isteği gönderilmez, abone olma teklifi hemen
    /// açılır ve true döner; toplantının durumu ve notu değişmez. Kendi anahtarlı sürümde her zaman false.
    private func isAIBlockedBySubscription() -> Bool {
        #if HOSTED_EDITION
        guard HostedAccount.shared.requiresSubscription else {
            return false
        }
        HostedAccount.shared.requestSubscription()
        return true
        #else
        return false
        #endif
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
        guard !isAIBlockedBySubscription() else {
            return
        }
        let userName: String = UserDefaults.standard.string(forKey: SettingsKey.userName) ?? ""
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            processingMeetingIDs.insert(meetingID)
            Task {
                defer { processingMeetingIDs.remove(meetingID) }
                guard let llm = await optionalLLMProvider() else {
                    savePendingMarks(meetingID: meetingID)
                    errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Not düzenlenemedi: LLM anahtarı ya da ayarı yok."))
                    return
                }
                do {
                    let edited: MeetingRecord = try await editMeetingNote(record: record, instruction: trimmed, llm: llm, userName: userName)
                    // Eski not geçmişe girer ("Geri al"); düzenleme sürerken konan işaretler kaybolmasın.
                    let versioned: MeetingRecord = withNoteVersion(
                        updated: edited, previous: record, reason: String(localized: "Düzenlendi: \(trimmed)"), savedAt: Date()
                    )
                    saveRecord(record: withLatestMarks(result: versioned, start: record, directory: directory), directory: directory)
                    refreshFolderCopy(meetingID: meetingID)
                } catch {
                    Self.logger.error("Not düzenlenemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                    savePendingMarks(meetingID: meetingID)
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
        let withNotes: MeetingRecord = record.with(myNotes: text)
        guard !isAIBlockedBySubscription() else {
            // Not yeniden yazılamaz ama kullanıcının yazdığı notlar kaybolmaz: toplantıda saklanır.
            withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
                saveRecord(record: withNotes, directory: directory)
            }
            return
        }
        rewriteNote(record: withNotes, reason: String(localized: "Kendi notlarınla yeniden yazıldı"))
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
            // Not kendi dilinde okunur, paylaşım dilinde yazılır: ikisi de cihaz içi modelde olmalı.
            try requireOnDeviceLanguages(
                provider: provider, meetingLanguages: note.writtenLanguage.meetingLanguage.map { [$0] } ?? [], outputLanguage: language
            )
            let shared: MeetingNote = try await requestStructured(provider: provider, request: sharedNoteRequest(note: note, language: language, userName: userName)) { (text: String) throws -> MeetingNote in
                try parseSharedNote(text: text, original: note).with(language: language)
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
        guard !isAIBlockedBySubscription() else {
            return
        }
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
                let result: MeetingRecord = await AINotepadCore.regenerateNote(record: record, directory: directory, llm: llm, userName: userName, language: selectedNoteLanguage())
                let versioned: MeetingRecord = withNoteVersion(updated: result, previous: record, reason: reason, savedAt: Date())
                saveRecord(record: withLatestMarks(result: versioned, start: record, directory: directory), directory: directory)
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
            Self.logger.error("Not sürümü geri yüklenemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
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

    #if HOSTED_EDITION
    /// Oluşturulan klasörler (toplantısız olanlar dahil); abonelikte hesabın ayar alanından, hesap verisi yüklenince
    /// okunur (bkz. `loadFolders`).
    var savedFolders: [String] = []
    #else
    /// Oluşturulan klasörler (toplantısız olanlar dahil).
    var savedFolders: [String] = UserDefaults.standard.stringArray(forKey: SettingsKey.folders) ?? []
    #endif

    /// Kayıtlı klasörleri okur (açılışta; abonelikte hesap verisi yüklenince). Okunamazsa neden gösterilir.
    func loadFolders() {
        do {
            savedFolders = try userContentDefaults().stringArray(forKey: SettingsKey.folders) ?? []
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Klasör listesini saklar; saklanamazsa neden gösterilir.
    private func storeFolders(folders: [String]) {
        do {
            try userContentDefaults().set(folders, forKey: SettingsKey.folders)
            savedFolders = folders
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

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
        storeFolders(folders: savedFolders + [trimmed])
    }

    /// Klasörü siler: toplantılar silinmez, klasörsüz kalır.
    func deleteFolder(name: String) {
        storeFolders(folders: savedFolders.filter { $0.caseInsensitiveCompare(name) != .orderedSame })
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
    var isBusy: Bool {
        isRecorderBusy(
            isRecording: isRecording, isFinishing: isFinishing, isHandingOff: handingOffMeetingID != nil,
            processingCount: processingMeetingIDs.count, importingCount: importingCount
        )
    }
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
            #if HOSTED_EDITION
            // Toplantının ses hakkını aşan dosya kuyruğa alınmaz: son geçiş yarıda kalır ve bekleyen kayıt hiç
            // bitmezdi. Hak durumu okunamadıysa sunucu son geçişte denetler (yazıya dökülen parçalar korunur).
            if case .signedIn(let entitlements) = HostedAccount.shared.state {
                try requireHostedImportFits(durationSec: duration, entitlements: entitlements)
            }
            #endif
            Self.logger.info("Dosya içe aktarıldı, toplantı: \(record.id, privacy: .public), süre: \(Int(duration), privacy: .public)")
            #if HOSTED_EDITION
            // Abonelik: içe aktarılan dosya da kayıt gibi kendi sunucu oturumuyla işlenir (haklar, deneme ve aylık süre
            // sunucuda denetlenir; süre sesin gerçek uzunluğundan sayılır). Kuyruğa girer: içe aktarma bitince
            // `runOfflineQueue` oturumu `clientRef` ile açar, son geçiş ve not o oturumla yapılır; sunucu reddederse
            // ses silinmez, neden toplantıda yazar.
            try await HostedAccount.shared.claimQueuedRecord(recordID: record.id)
            saveRecord(record: record.with(status: .queued, failureMessage: nil).with(notice: String(localized: "İçe aktarıldı; sunucuda işlenmeyi bekliyor.")), directory: session.url)
            reloadMeetings()
            #else
            process(record: record, directory: session.url) { [weak self] () async -> LLMProvider? in
                await self?.optionalLLMProvider()
            }
            #endif
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
            Task { await notifier.removeReminders() }
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
            // Takvim eşitlemesi değişiklik bildirimlerini art arda gönderir; her biri takvimi ana iş parçacığında okur
            // (çalma ve kayıt ekranı takılır). Bildirimler birleştirilir: son bildirimden 2 sn sonra bir kez okunur.
            var pending: Task<Void, Never>?
            for await _ in changes {
                pending?.cancel()
                pending = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(2))
                    } catch {
                        return
                    }
                    await self?.refreshCalendar()
                }
            }
            pending?.cancel()
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
        await requestReminderPermission()
        startCalendarServices()
    }

    /// Hatırlatmaları açar (kullanıcı): bildirim izni istenir (sonradan kapatılmış olabilir); izin yoksa hatırlatmalar
    /// kapanır ve neden hatırlatma satırında görünür.
    func enableMeetingReminders() async {
        await requestReminderPermission()
        startCalendarServices()
    }

    /// Hatırlatmalar için bildirim izni ister; alınamazsa hatırlatmalar kapanır, neden `notificationProblem`'da.
    private func requestReminderPermission() async {
        do {
            try await notifier.requestAuthorization()
            notificationProblem = nil
        } catch {
            Self.logger.warning("Bildirim izni alınamadı, hatırlatmalar kapandı, hata: \(String(describing: error), privacy: .private)")
            UserDefaults.standard.set(false, forKey: SettingsKey.meetingReminders)
            notificationProblem = notificationMessage(error: error)
        }
    }

    /// Bugünün (biteni de: notu takvimden açılır) ve önümüzdeki 24 saatin toplantılarını okur, 3 saat içindekiler için
    /// hatırlatma kurar. Takvim hatası `calendarError`'da (liste yerine gösterilir), hatırlatma hatası
    /// `notificationProblem`'da (hatırlatma satırında; okunan toplantılar görünmeye devam eder).
    private func refreshCalendar() async {
        do {
            let now: Date = Date()
            let dayStart: Date = Calendar.current.startOfDay(for: now)
            upcomingMeetings = try eventKit.meetings(from: dayStart, hours: now.timeIntervalSince(dayStart) / 3600 + 24)
            calendarError = nil
        } catch {
            Self.logger.error("Takvim okunamadı, hata: \(String(describing: error), privacy: .private)")
            calendarError = eventKitMessage(error: error)
            return
        }
        guard UserDefaults.standard.bool(forKey: SettingsKey.meetingReminders) else {
            // Hatırlatmalar kapalı: kurulu olanlar kalkar; izin reddedilip kapandıysa neden görünür kalır.
            await notifier.removeReminders()
            return
        }
        // Son bir dakikaya girmiş toplantı yeniden kurulmaz (hatırlatması zaten gösterildi; çift bildirim olmasın).
        let remind: [CalendarMeeting] = meetingsToRemind(meetings: upcomingMeetings, now: Date().addingTimeInterval(60), horizonSec: 3 * 3600)
        do {
            try await notifier.scheduleReminders(meetings: remind)
            notificationProblem = nil
        } catch {
            Self.logger.error("Toplantı hatırlatmaları kurulamadı, hata: \(String(describing: error), privacy: .private)")
            notificationProblem = notificationMessage(error: error)
        }
    }

    /// Başka bir uygulama mikrofonu açtı (kayıt yokken). Takvimde süren çevrim içi görüşme varsa ve kendiliğinden başlatma
    /// açıksa kayıt başlar ve bildirilir; değilse (10 dk'da en fazla bir) "dinlemeye başla" önerisi.
    private func microphoneStartedElsewhere() {
        guard !isRecording, !isStarting else {
            return
        }
        // Kayıt başlatılamıyorsa öneri ve kendiliğinden kayıt yapılmaz (neden Ana sayfada başlat düğmesinin yanında).
        guard !isStartBlocked() else {
            Self.logger.info("Görüşme algılandı ama kayıt şu an başlatılamıyor; öneri gösterilmedi")
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
                    Self.logger.error("Kendiliğinden kayıt bildirilemedi, hata: \(String(describing: error), privacy: .private)")
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
                Self.logger.error("Görüşme önerisi gösterilemedi, hata: \(String(describing: error), privacy: .private)")
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
        guard !isAIBlockedBySubscription() else {
            return
        }
        #if HOSTED_EDITION
        // Denemesi henüz başlamamış hesap soru soramaz (sunucu `trial_not_started` der); neden Sor sayfasında yazar.
        if let reason = hostedAskUnavailableReason(account: .shared) {
            Self.logger.info("Sor kullanılamıyor, soru gönderilmedi, neden: \(reason, privacy: .public)")
            return
        }
        #endif
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
                    // Cihaz içi modelde dili desteklenmeyen toplantılar okunmaz; model satırında hangileri yazılır.
                    let readable: OnDeviceReadableRecords = try onDeviceAskableArchive(records: records, provider: provider, outputLanguage: selectedNoteLanguage())
                    self?.updateExchange(id: id) { $0.modelName = askModelName(provider: provider, readable: readable) }
                    _ = try await AINotepadCore.askArchive(
                        question: trimmed, history: history, records: readable.records, userName: userName, language: selectedNoteLanguage(), llm: provider,
                        maxChars: noteLimits(provider: provider).archiveChars, now: Date(), onProgress: onProgress
                    )
                } else {
                    try requireOnDeviceLanguages(provider: provider, meetingLanguages: scoped.compactMap(\.language), outputLanguage: selectedNoteLanguage())
                    _ = try await askAboutMeetings(
                        question: trimmed, history: history, records: scoped, userName: userName, language: selectedNoteLanguage(), llm: provider,
                        maxChars: noteLimits(provider: provider).archiveChars, now: Date(),
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
            try saveUserRecipes(recipes: recipes, defaults: try userContentDefaults())
            userRecipes = recipes
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Kayıtlı kullanıcı tariflerini okur (açılışta); okunamazsa neden gösterilir, yerleşikler çalışır.
    func loadRecipes() {
        do {
            userRecipes = try loadUserRecipes(defaults: try userContentDefaults())
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
            Self.logger.error("Sohbet silinemedi, sohbet: \(id.uuidString, privacy: .public), hata: \(String(describing: error), privacy: .private)")
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
                    Self.logger.error("Sohbet okunamadı, dosya: \(failure.file, privacy: .public), neden: \(failure.reason, privacy: .private)")
                }
                if !result.failures.isEmpty {
                    errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Sohbet geçmişinden \(result.failures.count) sohbet okunamadı."))
                }
            } catch {
                Self.logger.error("Sohbet geçmişi okunamadı, hata: \(String(describing: error), privacy: .private)")
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
            Self.logger.error("Sohbet saklanamadı, sohbet: \(id.uuidString, privacy: .public), hata: \(String(describing: error), privacy: .private)")
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
        guard let record = meetings.first(where: { $0.id == meetingID }), let note = record.note else {
            return nil
        }
        do {
            try await eventKit.addReminder(draft: reminderDraft(record: record, task: task, language: note.writtenLanguage, calendar: Calendar.current))
        } catch {
            Self.logger.error("Anımsatıcı eklenemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
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

    /// Toplantı sayfalarının son açık sekmesi (toplantı başına, oturum boyunca): sayfa başka bölüme geçip dönünce
    /// yeniden kurulur ve kaldığı sekmede açılır. Görünümler yalnızca açılışta okur, gözlenmez.
    @ObservationIgnored var meetingPageTabs: [String: String] = [:]
    /// "--cal" açılış argümanının çalması başladı: sayfa yeniden açılınca tekrar başlamaz.
    @ObservationIgnored var launchPlaybackStarted: Bool = false

    /// Toplantı başına gönderimin durumu (toplantı sayfasında görünür).
    var webhookStates: [String: WebhookSendState] = [:]
    /// Bağlı not hedefleri (Ayarlar › Bağlantılar); birden çok olabilir.
    private(set) var destinations: [NoteDestination] = []
    /// Görev araçları (Linear, Jira).
    private(set) var taskTrackers: [TaskTracker] = []
    /// Toplantı başına görev gönderiminin durumu.
    var trackerStates: [String: WebhookSendState] = [:]
    /// Gönderim sonuçlarının kalkma zamanlayıcıları (`durum dizisi|toplantı`); yeni durum gelince eskisi iptal edilir.
    @ObservationIgnored private var sendStateFades: [String: Task<Void, Never>] = [:]

    /// Hedeflerin deposu (ilk kullanımda kurulur, bkz. `destinationVault()`).
    @ObservationIgnored private var destinationVaultCache: DestinationVault?
    /// Görev araçlarının deposu (ilk kullanımda kurulur, bkz. `trackerVault()`).
    @ObservationIgnored private var trackerVaultCache: TrackerVault?
    /// Kendiliğinden gönderim sürüyor: açılış, saatlik denetim ve işleme sonu aynı anda ikinci tur başlatmasın.
    @ObservationIgnored private var autoSendRunning: Bool = false
    /// Tur sürerken yeni istek geldi (ör. bir toplantı bitti): tur bitince bir kez daha çalışır, toplantı bir saat
    /// beklemez.
    @ObservationIgnored private var autoSendRequested: Bool = false

    /// Hedeflerin deposu: hesap jetonlarını hedef başına tek seferde yeniler. Abonelikte yüklü hesabın Anahtar Zinciri
    /// servisindedir (bkz. `userContentKeychainService`); hesap yüklenmediyse hata. Süreçte hesap değişmediği için bir
    /// kez kurulur.
    func destinationVault() throws -> DestinationVault {
        if let destinationVaultCache {
            return destinationVaultCache
        }
        let vault: DestinationVault = DestinationVault(service: try userContentKeychainService(), account: .destinations, clientName: appName) {
            (connection: ChannelConnection) async throws -> ChannelConnection in
            try await refreshConnectionTokens(connection: connection)
        }
        destinationVaultCache = vault
        return vault
    }

    /// Görev araçlarının deposu: aynı araca işlemler sırayla, yenilenen jeton hemen yazılır. Hedefler gibi hesabın
    /// servisindedir (bkz. `destinationVault()`).
    func trackerVault() throws -> TrackerVault {
        if let trackerVaultCache {
            return trackerVaultCache
        }
        let vault: TrackerVault = TrackerVault(service: try userContentKeychainService(), clientName: appName)
        trackerVaultCache = vault
        return vault
    }

    /// Hedefleri ve görev araçlarını yükler; eski sürümün tek bağlantısı (hesap ya da webhook) bir kez hedeflere taşınır.
    func loadDestinations() async {
        do {
            try await migrateLegacyChannelIfNeeded()
            destinations = try await destinationVault().all()
            taskTrackers = try await trackerVault().all()
        } catch {
            Self.logger.error("Hedefler okunamadı, hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Bağlantılar okunamadı: \(userFacingMessage(error: error))"))
        }
    }

    private func migrateLegacyChannelIfNeeded() async throws {
        guard try await destinationVault().all().isEmpty else {
            return
        }
        let service: String = try userContentKeychainService()
        let connection: ChannelConnection? = try await optionalSecretInBackground(service: service, account: .channel)
            .map { (text: String) throws -> ChannelConnection in try decodeChannelConnection(text: text) }
        let webhook: URL? = try await optionalSecretInBackground(service: service, account: .webhook).flatMap { URL(string: $0) }
        let migrated: [NoteDestination] = migratedDestinations(
            connection: connection, webhook: webhook, autoSend: UserDefaults.standard.bool(forKey: SettingsKey.webhookAutoSend), now: Date()
        ) { UUID().uuidString }
        guard !migrated.isEmpty else {
            return
        }
        for destination in migrated {
            try await destinationVault().upsert(destination)
        }
        try deleteSecret(service: service, account: .channel)
        try deleteSecret(service: service, account: .webhook)
        Self.logger.info("Eski kanal bağlantısı hedeflere taşındı, sayı: \(migrated.count, privacy: .public)")
    }

    /// Yeni hedef ekler (kendiliğinden gönderim kapalı başlar; kullanıcı açar).
    @discardableResult
    func addDestination(target: DestinationTarget) async throws -> NoteDestination {
        let destination: NoteDestination = NoteDestination(id: UUID().uuidString, target: target, autoSend: false, createdAt: Date(), needsReconnect: false)
        try await destinationVault().upsert(destination)
        destinations = try await destinationVault().all()
        return destination
    }

    /// Hedefin bağlantısını değiştirir (kanalı değiştir, yeniden bağlan); kimliği ve ayarı korunur.
    /// Değişmeden önceki kayıtlı hedef döner (yerini alan eski izni geri almak için).
    @discardableResult
    func replaceDestinationTarget(id: String, target: DestinationTarget) async throws -> NoteDestination {
        let previous: NoteDestination = try await destinationVault().replaceTarget(id: id, target: target)
        destinations = try await destinationVault().all()
        return previous
    }

    /// Kendiliğinden gönderimi açar ya da kapatır; kayıtlı hedefin yalnızca bu ayarı değişir (bellekteki kopya eski
    /// jetonlar taşıyabilir).
    func setAutoSend(destinationID: String, enabled: Bool) async {
        do {
            try await destinationVault().setAutoSend(id: destinationID, enabled: enabled)
            destinations = try await destinationVault().all()
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Hedefi kaldırır; servis tarafında da kapatılır (Slack jetonu ve Notion izni geri alınır, Discord webhook'u
    /// silinir). Servis tarafı kapatılamazsa hedef yine kaldırılır (kullanıcı kaldırmak istedi); neden ve erişimin
    /// servisin ayarlarından nasıl kaldırılacağı gösterilir.
    func removeDestination(id: String) async {
        do {
            let removed: NoteDestination = try await destinationVault().remove(id: id)
            destinations = try await destinationVault().all()
            do {
                try await revokeDestination(destination: removed, clientName: appName)
            } catch {
                Self.logger.warning("Hedef servis tarafında kapatılamadı, hedef: \(destinationName(destination: removed), privacy: .public), hata: \(String(describing: error), privacy: .private)")
                errorMessages = appendUnique(messages: errorMessages, message: remoteRevocationFailureMessage(service: destinationName(destination: removed), appName: appName, error: error))
            }
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Hesap hedefinin kanallarını yeniden listeler (yeniden giriş yapmadan kanal değiştirmek için).
    func channelOptions(destinationID: String) async throws -> (signIn: ChannelSignIn, options: [ChannelOption]) {
        let connection: ChannelConnection = try await destinationVault().connection(id: destinationID)
        // Bağlantı alınırken jetonlar yenilenip yazılmış olabilir: bellekteki liste eski jetonlarla kalmasın.
        await refreshDestinationList()
        let signIn: ChannelSignIn = ChannelSignIn(service: connection.service, tokens: connection.tokens, workspace: connection.workspace)
        return (signIn, try await listChannels(signIn: signIn))
    }

    /// Notu bir hedefe gönderir; başarılıysa toplantıya işlenir (kendiliğinden gönderim yinelemez). Hata metni döner;
    /// toplantı, not ya da hedef yoksa ve aynı gönderim zaten sürüyorsa da (iki kez düşmesin) hata metni döner.
    func sendNote(meetingID: String, destinationID: String) async -> String? {
        guard let record = meetings.first(where: { $0.id == meetingID }) else {
            return userFacingMessage(error: NoteSendError.meetingNotFound(id: meetingID))
        }
        guard let note = record.note else {
            return userFacingMessage(error: NoteSendError.noNote(meetingID: meetingID))
        }
        guard let destination = destinations.first(where: { $0.id == destinationID }) else {
            return userFacingMessage(error: DestinationError.notFound(id: destinationID))
        }
        let sendKey: String = meetingDestinationKey(meetingID: meetingID, destinationID: destinationID)
        guard !notesInFlight.contains(sendKey) else {
            Self.logger.info("Not zaten gönderiliyor, atlandı, toplantı: \(meetingID, privacy: .public), hedef: \(destinationID, privacy: .public)")
            return userFacingMessage(error: NoteSendError.alreadySending(meetingID: meetingID, destinationID: destinationID))
        }
        notesInFlight.insert(sendKey)
        defer { notesInFlight.remove(sendKey) }
        // Elle gönderim belirsiz işaretini kaldırır: kullanıcı kontrol edip yeniden göndermeyi seçti.
        clearUncertain(meetingID: meetingID, destinationID: destinationID)
        do {
            try await deliverNote(vault: destinationVault(), destination: destination, record: record, note: note)
            markSent(meetingID: meetingID, destination: destination)
            Self.logger.info("Not hedefe gönderildi, toplantı: \(meetingID, privacy: .public), hedef: \(destinationName(destination: destination), privacy: .public)")
            return nil
        } catch let error as DeliveryUncertainError {
            // Not gitmiş olabilir: kendiliğinden yeniden gönderilmez (iki kez düşmesin); kullanıcıya gösterilir.
            markUncertain(meetingID: meetingID, destinationID: destinationID)
            Self.logger.warning("Not gönderiminin sonucu belirsiz, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            return String(localized: "\(destinationName(destination: destination)): \(userFacingMessage(error: error))")
        } catch {
            Self.logger.error("Not hedefe gönderilemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            return String(localized: "\(destinationName(destination: destination)): \(userFacingMessage(error: error))")
        }
    }

    /// Gönderim durumunu yazar. Sonuç (gitti, hata) süresi dolunca kendiliğinden kalkar (gitti 3,5 sn, hata 5 sn): aynı
    /// sonuç yeniden gelince yine görünür. "Gönderiliyor" sonuç gelene dek kalır.
    private func showSendState(state: WebhookSendState, meetingID: String, states: ReferenceWritableKeyPath<AppModel, [String: WebhookSendState]>) {
        let key: String = "\(states)|\(meetingID)"
        sendStateFades[key]?.cancel()
        self[keyPath: states][meetingID] = state
        guard let delay = sendResultFadeDelay(state: state) else {
            sendStateFades[key] = nil
            return
        }
        sendStateFades[key] = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                // Yalnızca iptal: yeni bir durum geldi, eski sonucun zamanlayıcısı bir şey kaldırmaz.
                return
            }
            self?[keyPath: states][meetingID] = nil
            self?.sendStateFades[key] = nil
        }
    }

    /// Notu verilen hedeflere sırayla gönderir; toplantı sayfasındaki durum güncellenir.
    func sendNote(meetingID: String, destinationIDs: [String]) async {
        showSendState(state: .sending, meetingID: meetingID, states: \.webhookStates)
        var failures: [String] = []
        for id in destinationIDs {
            if let failure = await sendNote(meetingID: meetingID, destinationID: id) {
                failures.append(failure)
            }
        }
        await refreshDestinationList()
        showSendState(state: failures.isEmpty ? .sent : .failed(failures.joined(separator: "\n")), meetingID: meetingID, states: \.webhookStates)
    }

    /// Süren not gönderimleri (`toplantı|hedef`): elle gönderim, kendiliğinden gönderim ve "Tümüne gönder" aynı notu
    /// aynı hedefe üst üste göndermesin.
    @ObservationIgnored private var notesInFlight: Set<String> = []

    /// Toplantı ve hedef çiftinin anahtarı (süren ve sonucu belirsiz gönderimler). Saf fonksiyondur.
    private func meetingDestinationKey(meetingID: String, destinationID: String) -> String {
        "\(meetingID)|\(destinationID)"
    }

    /// Ayarlardaki "Dene": örnek notu hedefe gönderir; hedef yoksa (bu arada kaldırıldı) hata metni döner.
    func sendTestNote(destinationID: String) async -> String? {
        guard let destination = destinations.first(where: { $0.id == destinationID }) else {
            return userFacingMessage(error: DestinationError.notFound(id: destinationID))
        }
        let sample: MeetingRecord = MeetingRecord(
            id: "deneme", title: appName, startedAt: Date(), endedAt: Date(), language: nil, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud,
            notice: nil, meNeedsFinalPass: nil
        )
        let note: MeetingNote = MeetingNote(
            title: String(localized: "\(appName) bağlantı denemesi"),
            summary: String(localized: "Bu bir deneme mesajıdır: toplantı notların buraya böyle gelecek."),
            decisions: [], tasks: [], glossary: []
        )
        do {
            try await deliverNote(vault: destinationVault(), destination: destination, record: sample, note: note)
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
            destinations = try await destinationVault().all()
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Gönderildi işareti: hedefin kimliği ve cihazdan bağımsız anahtarı (başka Mac aynı kanala yeniden göndermesin).
    /// Toplantı kilitliyse (işleniyor) işleme bitince uygulanır.
    private func markSent(meetingID: String, destination: NoteDestination) {
        let marks: [String] = [destination.id] + [destinationSendKey(destination: destination)].compactMap { $0 }
        guard !isLocked(meetingID: meetingID) else {
            pendingSentMarks[meetingID, default: []].formUnion(marks)
            return
        }
        updateRecordFromDisk(meetingID: meetingID) { (record: MeetingRecord) -> MeetingRecord in
            marks.reduce(record) { (result: MeetingRecord, mark: String) -> MeetingRecord in result.markingSent(destinationID: mark) }
        }
    }

    /// Değişikliği diskteki en güncel kayda uygular (iPhone'dan iCloud'la gelmiş düzenlemeler bellekteki eski kopyayla
    /// ezilmesin).
    private func updateRecordFromDisk(meetingID: String, change: (MeetingRecord) -> MeetingRecord) {
        withSessionDirectory(id: meetingID) { (directory: URL) -> Void in
            do {
                saveRecord(record: change(try loadMeeting(directory: directory)), directory: directory)
            } catch {
                Self.logger.error("Toplantı güncellenemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Toplantı kaydedilemedi: \(userFacingMessage(error: error))"))
            }
        }
    }

    /// Sonucu belirsiz gönderimler: kendiliğinden gönderim bunları atlar.
    private func uncertainSends() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: SettingsKey.uncertainSends) ?? [])
    }

    /// Gönderimin sonucu belirsiz: kendiliğinden yeniden gönderilmez.
    private func markUncertain(meetingID: String, destinationID: String) {
        storeUncertainSends(sends: uncertainSends().union([meetingDestinationKey(meetingID: meetingID, destinationID: destinationID)]))
    }

    /// Belirsiz işareti kalkar (kullanıcı elle yeniden gönderdi).
    private func clearUncertain(meetingID: String, destinationID: String) {
        storeUncertainSends(sends: uncertainSends().subtracting([meetingDestinationKey(meetingID: meetingID, destinationID: destinationID)]))
    }

    /// Belirsiz gönderimleri yazar (değişmediyse yazılmaz).
    private func storeUncertainSends(sends: Set<String>) {
        guard sends != uncertainSends() else {
            return
        }
        UserDefaults.standard.set(sends.sorted(), forKey: SettingsKey.uncertainSends)
    }

    /// İşleme sürerken gönderilen hedefler; işleme bitince kayda işlenir.
    @ObservationIgnored private var pendingSentMarks: [String: Set<String>] = [:]

    /// Bekleyen kendiliğinden gönderimleri yapar: işleme bitince, açılışta ve saatte bir. Ağ yokken kaçanlar böylece
    /// sonra gider; her (toplantı, hedef) bir kez gönderilir.
    func processPendingAutoSends() async {
        #if DEBUG
        // "--otomatik-gonderim-yok": ölçüm ve kabul testlerinde test toplantıları hedeflere gitmesin (yalnız Debug).
        if CommandLine.arguments.contains("--otomatik-gonderim-yok") {
            return
        }
        #endif
        guard !autoSendRunning else {
            autoSendRequested = true
            return
        }
        autoSendRunning = true
        defer { autoSendRunning = false }
        repeat {
            autoSendRequested = false
            await refreshDestinationList()
            await resolveMissingNotionIdentities()
            let uncertain: Set<String> = uncertainSends()
            let pending: [(meetingID: String, destinationID: String)] = pendingAutoSends(records: meetings, destinations: destinations, now: Date())
                .filter { (item: (meetingID: String, destinationID: String)) -> Bool in
                    !(pendingSentMarks[item.meetingID] ?? []).contains(item.destinationID) && !isLocked(meetingID: item.meetingID)
                        && !uncertain.contains(meetingDestinationKey(meetingID: item.meetingID, destinationID: item.destinationID))
                }
            for item in pending {
                // Liste kurulduktan sonra elle gönderilmeye başlandıysa ya da gönderildiyse (başka Mac'ten de) atlanır
                // (not iki kez düşmesin).
                let record: MeetingRecord? = meetings.first { $0.id == item.meetingID }
                let destination: NoteDestination? = destinations.first { $0.id == item.destinationID }
                let sentMeanwhile: Bool = (pendingSentMarks[item.meetingID] ?? []).contains(item.destinationID)
                    || (record.flatMap { (current: MeetingRecord) -> Bool? in destination.map { wasSent(record: current, destination: $0) } } ?? false)
                guard !sentMeanwhile, !notesInFlight.contains(meetingDestinationKey(meetingID: item.meetingID, destinationID: item.destinationID)) else {
                    continue
                }
                if let failure = await sendNote(meetingID: item.meetingID, destinationID: item.destinationID) {
                    errorMessages = appendUnique(messages: errorMessages, message: failure)
                }
            }
            if !pending.isEmpty {
                await refreshDestinationList()
            }
        } while autoSendRequested
    }

    /// Notion'a tek tıkla bağlanır (tarayıcıda izin) ve hedef olarak ekler; hesabın kimliği hemen okunur (bkz.
    /// `resolveMissingNotionIdentities`).
    func connectNotion() async throws {
        let connection: MCPConnection = try await signInToMCP(service: .notion, appName: appName) { (url: URL) async -> Void in
            await MainActor.run { openSignInPage(url: url) }
        }
        try await addDestination(target: .notion(NotionTarget(connection: connection, pageTitle: String(localized: "Özel sayfalar"), identity: nil)))
        await resolveMissingNotionIdentities()
    }

    /// Notion hedefini yeniden bağlar: kimliği, kendiliğinden gönderim ayarı ve bağlanma anı korunur (bağlantı koptuğu
    /// sırada kaçan toplantılar da gönderilir, gönderim geçmişi kaybolmaz). Başka bir hesapla bağlanılmış olabileceği
    /// için hesabın kimliği yeniden okunur. Yeni bağlantı kaydedildikten sonra yerini aldığı eski izin geri alınır (bkz.
    /// `revokeReplacedGrant`).
    func reconnectNotion(destinationID: String) async throws {
        let connection: MCPConnection = try await signInToMCP(service: .notion, appName: appName) { (url: URL) async -> Void in
            await MainActor.run { openSignInPage(url: url) }
        }
        let previous: NoteDestination = try await replaceDestinationTarget(
            id: destinationID, target: .notion(NotionTarget(connection: connection, pageTitle: String(localized: "Özel sayfalar"), identity: nil))
        )
        if case .notion(let old) = previous.target, let replaced = replacedGrant(old: old.connection, new: connection) {
            revokeReplacedGrant(connection: replaced, service: MCPService.notion.displayName)
        }
        await resolveMissingNotionIdentities()
    }

    /// Yeniden bağlanınca yerini alan eski bağlantının OAuth iznini arka planda geri alır (yeniden bağlanmayı
    /// bekletmez). Geri alınamazsa uyarı loglanır ve engellemeyen bir mesaj gösterilir: yeni bağlantı çalışır, kullanıcı
    /// eski erişimi servisin ayarlarından kaldırabilir.
    private func revokeReplacedGrant(connection: MCPConnection, service: String) {
        Task {
            do {
                try await revokeMCPConnection(connection: connection, clientName: appName)
            } catch {
                Self.logger.warning("Eski bağlantının izni geri alınamadı, servis: \(service, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                errorMessages = appendUnique(messages: errorMessages, message: replacedGrantRevocationFailureMessage(service: service, error: error))
            }
        }
    }

    /// Kimliği bilinmeyen Notion hedeflerinin çalışma alanını ve kullanıcısını okur (yeni bağlanan, yeniden bağlanan ve
    /// eski sürümde bağlananlar); kimlik, notun başka Mac'ten aynı Notion hesabına gönderildiğini tanımak içindir (bkz.
    /// `destinationSendKey`). Okunamazsa hedef kimliksiz kalır, uyarı loglanır ve sonraki gönderim turunda yeniden
    /// denenir: gönderim engellenmez, o zamana dek gönderildi işareti yalnızca bu cihazın hedef kimliğiyle denetlenir.
    private func resolveMissingNotionIdentities() async {
        let missing: [String] = destinations.compactMap { (destination: NoteDestination) -> String? in
            guard case .notion(let target) = destination.target, target.identity == nil, !destination.needsReconnect else {
                return nil
            }
            return destination.id
        }
        guard !missing.isEmpty else {
            return
        }
        for id in missing {
            do {
                try await destinationVault().resolveNotionIdentity(id: id)
                Self.logger.info("Notion hesabının kimliği okundu, hedef: \(id, privacy: .public)")
            } catch {
                Self.logger.warning("Notion hesabının kimliği okunamadı, hedef: \(id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            }
        }
        await refreshDestinationList()
    }

    // MARK: Görev araçları (Linear, Jira)

    /// Linear ya da Jira'ya tek tıkla bağlanır (tarayıcıda izin; uygulama kaydı ya da API anahtarı gerekmez).
    /// Bağlanırken sunucuda iş açan araç olduğu denetlenir; yoksa bağlantı kaldırılır ve neden gösterilir. Aynı servis
    /// yeniden bağlanırsa kimlik ve hedef korunur (gönderilen görevler yeniden gönderilmez); yeni bağlantı kaydedildikten
    /// sonra yerini aldığı eski izin geri alınır (bkz. `revokeReplacedGrant`) ve hesabın kimliği okunur (bkz.
    /// `resolveTrackerIdentity`).
    func connectTracker(service: MCPService) async throws {
        let connection: MCPConnection = try await signInToMCP(service: service, appName: appName) { (url: URL) async -> Void in
            await MainActor.run { openSignInPage(url: url) }
        }
        let connected: TrackerConnectResult = try await trackerVault().connect(service: service, connection: connection, newID: UUID().uuidString)
        let tracker: TaskTracker = connected.tracker
        if let replaced = connected.replaced {
            revokeReplacedGrant(connection: replaced, service: service.displayName)
        }
        defer { Task { await self.refreshTrackerList() } }
        do {
            try await trackerVault().withTracker(id: tracker.id) {
                (current: TaskTracker, persist: @escaping @Sendable (MCPConnection, MCPConnection) async throws -> Void) async throws -> Void in
                try await validateTracker(service: current.service, connection: current.connection, clientName: appName, persist: persist)
            }
        } catch TaskTrackerError.noCreateTool(let name) {
            await revokeTracker(tracker: try await trackerVault().remove(id: tracker.id))
            throw TaskTrackerError.noCreateTool(service: name)
        }
        await resolveTrackerIdentity(id: tracker.id)
    }

    /// Aracın hesap kimliğini okur: görevlerin başka Mac'ten aynı hesap ve hedefe gönderildiğini tanımak içindir (bkz.
    /// `trackerSendKey`). Okunamazsa araç kimliksiz kalır, uyarı loglanır ve sonraki gönderimde yeniden denenir:
    /// gönderim engellenmez, o zamana dek gönderildi işareti yalnızca bu cihazın araç kimliğiyle denetlenir.
    private func resolveTrackerIdentity(id: String) async {
        do {
            try await trackerVault().resolveIdentity(id: id)
            Self.logger.info("Görev aracının hesap kimliği okundu, araç: \(id, privacy: .public)")
        } catch {
            Self.logger.warning("Görev aracının hesap kimliği okunamadı, araç: \(id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        }
        await refreshTrackerList()
    }

    /// Görev aracını kaldırır; OAuth izni sunucuda da geri alınır (bkz. `revokeTracker`).
    func removeTracker(id: String) async {
        let removed: TaskTracker
        do {
            removed = try await trackerVault().remove(id: id)
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            await refreshTrackerList()
            return
        }
        // Satır hemen kalkar; izin arka planda geri alınır (ağ yavaşsa bir dakikaya dek sürebilir).
        await refreshTrackerList()
        Task { await revokeTracker(tracker: removed) }
    }

    /// Kaldırılan aracın OAuth iznini yetkilendirme sunucusunda geri alır. Geri alınamazsa araç yine kaldırılmış kalır
    /// (kullanıcı kaldırmak istedi); neden ve erişimin servisin ayarlarından nasıl kaldırılacağı gösterilir.
    private func revokeTracker(tracker: TaskTracker) async {
        do {
            try await revokeMCPConnection(connection: tracker.connection, clientName: appName)
        } catch {
            Self.logger.warning("Görev aracının izni geri alınamadı, servis: \(tracker.service.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: remoteRevocationFailureMessage(service: tracker.service.displayName, appName: appName, error: error))
        }
    }

    /// Görev aracında seçilebilir hedefler (Linear takımları, Jira projeleri); Ayarlar'daki seçici gösterir.
    func trackerTargets(id: String) async throws -> [String] {
        try await trackerVault().targets(id: id)
    }

    func setTrackerTarget(id: String, target: String) async {
        do {
            try await trackerVault().setTarget(id: id, target: target.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
        await refreshTrackerList()
    }

    private func refreshTrackerList() async {
        do {
            taskTrackers = try await trackerVault().all()
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Toplantının kapsamdaki görevlerini (`scope`: yalnız sana düşenler ya da hepsi) araçta iş olarak açar; daha önce
    /// gönderilenler yinelenmez. Sonuç özeti ya da hata toplantı sayfasında görünür.
    func sendTasks(meetingID: String, trackerID: String, scope: TaskSendScope) async {
        // Hesap kimliği bilinmiyorsa (eski sürümde bağlanan araç) önce okunur: başka Mac'ten gönderilenler tanınsın.
        if let known = taskTrackers.first(where: { $0.id == trackerID }), known.identity == nil {
            await resolveTrackerIdentity(id: trackerID)
        }
        guard let record = meetings.first(where: { $0.id == meetingID }), let note = record.note,
              let tracker = taskTrackers.first(where: { $0.id == trackerID }) else {
            return
        }
        let tasks: [NoteTask] = tasksInScope(tasks: note.tasks, scope: scope)
            .filter { !isTaskSent(record: record, tracker: tracker, task: $0) && !isTaskDone(record: record, task: $0) }
        guard !tasks.isEmpty else {
            showSendState(state: .failed(String(localized: "Gönderilecek açık görev yok (hepsi gönderilmiş ya da tamamlanmış).")), meetingID: meetingID, states: \.trackerStates)
            return
        }
        showSendState(state: .sending, meetingID: meetingID, states: \.trackerStates)
        defer { Task { await self.refreshTrackerList() } }
        do {
            let llm: LLMProvider = try await resolveLLMProvider()
            let title: String = note.title
            let language: ShareLanguage = selectedNoteLanguage()
            try requireOnDeviceLanguages(provider: llm, meetingLanguages: note.writtenLanguage.meetingLanguage.map { [$0] } ?? [], outputLanguage: language)
            let result: TrackerSendResult = try await trackerVault().withTracker(id: trackerID) {
                (current: TaskTracker, persist: @escaping @Sendable (MCPConnection, MCPConnection) async throws -> Void) async throws -> TrackerSendResult in
                try await sendTasksToTracker(tracker: current, clientName: appName, persist: persist, tasks: tasks, meetingTitle: title, language: language, llm: llm)
            }
            markTasksSent(meetingID: meetingID, tracker: tracker, tasks: result.createdTaskIndices.map { tasks[$0] })
            // Sonuç uygulamanın kendi cümlesiyle gösterilir: ajanın serbest özeti (kabul testinde) başarılı gönderimi
            // "yanlışlıkla açıldı" diye anlatabiliyordu. Ajanın özeti yalnızca loglanır.
            Self.logger.info("Görevler araca gönderildi, araç: \(tracker.service.rawValue, privacy: .public), sayı: \(result.createdTaskIndices.count, privacy: .public), özet: \(result.summary, privacy: .private)")
            showSendState(state: .done(String(localized: "\(tracker.service.displayName): \(result.createdTaskIndices.count) görev açıldı")), meetingID: meetingID, states: \.trackerStates)
        } catch TaskTrackerError.partial(let service, let created, let total, let reason) {
            // Açılanlar işaretlenir: yeniden gönderimde yalnızca kalanlar gider.
            markTasksSent(meetingID: meetingID, tracker: tracker, tasks: created.filter { tasks.indices.contains($0) }.map { tasks[$0] })
            let error: TaskTrackerError = .partial(service: service, created: created, total: total, reason: reason)
            Self.logger.error("Görevlerin bir kısmı açılamadı, araç: \(tracker.service.rawValue, privacy: .public), açılan: \(created.count, privacy: .public)")
            showSendState(state: .failed(userFacingMessage(error: error)), meetingID: meetingID, states: \.trackerStates)
        } catch TaskTrackerError.uncertain(let service, let created, let uncertainTask, let taskTitle, let total, let reason) {
            // Kesin açılanlar işaretlenir; sonucu belirsiz görev işaretlenmez (açılmadıysa gönderilebilsin), kullanıcıya
            // yeniden göndermeden önce araçta kontrol etmesi söylenir.
            markTasksSent(meetingID: meetingID, tracker: tracker, tasks: created.filter { tasks.indices.contains($0) }.map { tasks[$0] })
            let error: TaskTrackerError = .uncertain(
                service: service, created: created, uncertainTask: uncertainTask, taskTitle: taskTitle, total: total, reason: reason
            )
            Self.logger.warning("Görev açmanın sonucu belirsiz, araç: \(tracker.service.rawValue, privacy: .public), açılan: \(created.count, privacy: .public), görev sırası: \(uncertainTask, privacy: .public)")
            showSendState(state: .failed(userFacingMessage(error: error)), meetingID: meetingID, states: \.trackerStates)
        } catch {
            Self.logger.error("Görevler araca gönderilemedi, araç: \(tracker.service.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            showSendState(state: .failed(String(localized: "\(tracker.service.displayName): \(userFacingMessage(error: error))")), meetingID: meetingID, states: \.trackerStates)
        }
    }

    /// Araçta açılan görevleri aracın bu cihazdaki kimliği ve cihazdan bağımsız anahtarıyla işaretler (bkz.
    /// `markingTasksSent`); toplantı kilitliyse (işleniyor) işleme bitince uygulanır.
    private func markTasksSent(meetingID: String, tracker: TaskTracker, tasks: [NoteTask]) {
        guard !tasks.isEmpty else {
            return
        }
        guard !isLocked(meetingID: meetingID) else {
            pendingTaskMarks[meetingID, default: []].append((tracker: tracker, tasks: tasks))
            return
        }
        updateRecordFromDisk(meetingID: meetingID) { (record: MeetingRecord) -> MeetingRecord in
            markingTasksSent(record: record, tracker: tracker, tasks: tasks)
        }
    }

    /// İşleme sürerken araca gönderilen görevler; işleme bitince kayda işlenir.
    @ObservationIgnored private var pendingTaskMarks: [String: [(tracker: TaskTracker, tasks: [NoteTask])]] = [:]

    // MARK: Apple Notlar ve klasör

    /// Notun Markdown olarak yazıldığı klasör (Obsidian, iCloud Drive…); seçilmediyse boş. Abonelikte hesabındır (bkz.
    /// `userContentDefaults`), hesap verisi yüklenince okunur (bkz. `loadExportSettings`).
    private(set) var markdownFolder: String = ""
    /// Not hazır olunca (ve her değişince) klasördeki kopya kendiliğinden yazılır.
    private(set) var markdownAutoExport: Bool = false
    /// Not hazır olunca Apple Notlar'a kendiliğinden gönderilir (bir kez).
    private(set) var appleNotesAutoSend: Bool = false

    /// Dışa aktarma ayarlarını okur (açılışta; abonelikte hesap verisi yüklenince). Okunamazsa neden gösterilir.
    func loadExportSettings() {
        do {
            let defaults: UserDefaults = try userContentDefaults()
            markdownFolder = defaults.string(forKey: SettingsKey.markdownFolder) ?? ""
            markdownAutoExport = defaults.bool(forKey: SettingsKey.markdownAutoExport)
            appleNotesAutoSend = defaults.bool(forKey: SettingsKey.appleNotesAutoSend)
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Markdown klasörünü saklar; saklanamazsa neden gösterilir.
    func setMarkdownFolder(path: String) {
        do {
            try userContentDefaults().set(path, forKey: SettingsKey.markdownFolder)
            markdownFolder = path
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Klasöre kendiliğinden yazmayı açar ya da kapatır; saklanamazsa neden gösterilir.
    func setMarkdownAutoExport(enabled: Bool) {
        do {
            try userContentDefaults().set(enabled, forKey: SettingsKey.markdownAutoExport)
            markdownAutoExport = enabled
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Apple Notlar'a kendiliğinden göndermeyi açar ya da kapatır; saklanamazsa neden gösterilir.
    func setAppleNotesAutoSend(enabled: Bool) {
        do {
            try userContentDefaults().set(enabled, forKey: SettingsKey.appleNotesAutoSend)
            appleNotesAutoSend = enabled
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Notu Apple Notlar'da uygulamanın adını taşıyan klasöre ("AI-Notepad" ya da "Gistsmith") yazar (ilk seferde macOS izin sorar); hata varsa kullanıcı metni döner.
    func sendToAppleNotes(meetingID: String) async -> String? {
        guard let record = meetings.first(where: { $0.id == meetingID }), let note = record.note else {
            return nil
        }
        let source: String = appleNotesScript(html: notesHTML(record: record, note: note), folder: appName)
        // NSAppleScript yalnızca ana iş parçacığında güvenli.
        let failure: String? = runAppleScript(source: source)
        if let failure {
            Self.logger.error("Not Apple Notlar'a yazılamadı, toplantı: \(meetingID, privacy: .public), hata: \(failure, privacy: .private)")
            return String(localized: "Apple Notlar'a yazılamadı: \(failure). Sistem Ayarları › Gizlilik ve Güvenlik › Otomasyon'da \(appName) için Notlar'a izin ver.")
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
        let path: String = markdownFolder
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
        guard markdownAutoExport, let error = exportToFolder(meetingID: meetingID) else {
            return
        }
        errorMessages = appendUnique(messages: errorMessages, message: error)
    }

    /// İşleme bitince açık olan hedeflere kendiliğinden gönderir: webhook, Apple Notlar (bir kez) ve klasör (her
    /// seferinde güncellenir). Hata panelde görünür; gönderilenler toplantıya işlenir.
    private func autoSendToDestinations(record: MeetingRecord) {
        #if DEBUG
        if CommandLine.arguments.contains("--otomatik-gonderim-yok") {
            return
        }
        #endif
        Task { await processPendingAutoSends() }
        guard record.note != nil else {
            return
        }
        if markdownAutoExport, let error = exportToFolder(meetingID: record.id) {
            errorMessages = appendUnique(messages: errorMessages, message: error)
        }
        guard appleNotesAutoSend, record.notesSentAt == nil else {
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
        let trackerMarks: [(tracker: TaskTracker, tasks: [NoteTask])] = pendingTaskMarks.removeValue(forKey: record.id) ?? []
        let withTasks: MeetingRecord = trackerMarks.reduce(withSent) { (result: MeetingRecord, mark: (tracker: TaskTracker, tasks: [NoteTask])) -> MeetingRecord in
            markingTasksSent(record: result, tracker: mark.tracker, tasks: mark.tasks)
        }
        return tasks.reduce(withTasks) { (result: MeetingRecord, task: NoteTask) -> MeetingRecord in markingReminded(record: result, task: task) }
    }

    /// Uzun not işinin (işleme, düzenleme, yeniden yazma; 30–300 sn) kaydedilecek sonucu. İş, başladığı andaki kaydın
    /// kopyasıyla çalışır; bu arada diğer cihazda (iCloud) ya da kendiliğinden gönderimde diske yazılan işaretler için
    /// diskteki kayıt esas alınır (iş başında diske yazılan kaydın güncel hali: orada kaldırılan işaret geri gelmez),
    /// bekleyen işaretler ona uygulanır ve yeni nota taşınır (`withJobMarks`). Bekleyen işaretler eski notun görevlerine
    /// göredir: önce eski kayda uygulanır, sonra taşınır. Disk okunamazsa neden gösterilir ve işin başındaki işaretlerle
    /// kaydedilir (işin sonucu kaybolmaz).
    private func withLatestMarks(result: MeetingRecord, start: MeetingRecord, directory: URL) -> MeetingRecord {
        let latest: MeetingRecord
        do {
            latest = try loadMeeting(directory: directory)
        } catch {
            Self.logger.error("Not işi sonrası kayıt diskten okunamadı, toplantı: \(start.id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Diğer cihazdaki işaretler okunamadı, not onlarsız kaydedildi: \(userFacingMessage(error: error))"))
            latest = start
        }
        return withJobMarks(old: applyingPendingReminders(record: latest), result: result)
    }

    /// Not işi başarısız oldu: iş sürerken bekletilen işaretler (Anımsatıcılar, gönderimler) diskteki kayda yazılır,
    /// yoksa kaybolur ve görevler yeniden eklenebilir ya da gönderilebilirdi.
    private func savePendingMarks(meetingID: String) {
        guard pendingReminded[meetingID] != nil || pendingSentMarks[meetingID] != nil || pendingTaskMarks[meetingID] != nil else {
            return
        }
        updateRecordFromDisk(meetingID: meetingID) { (record: MeetingRecord) -> MeetingRecord in applyingPendingReminders(record: record) }
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
            Self.logger.error("Ses izi için model klasörü alınamadı, hata: \(String(describing: error), privacy: .private)")
            voiceRegistryError = userFacingMessage(error: error)
            return nil
        }
    }

    private func loadVoices() {
        do {
            registeredVoices = try loadRegisteredVoices(url: try voicesFileURL())
            voiceRegistryError = nil
        } catch {
            Self.logger.error("Kayıtlı sesler okunamadı, hata: \(String(describing: error), privacy: .private)")
            voiceRegistryError = userFacingMessage(error: error)
        }
    }

    private func storeVoices(voices: [RegisteredVoice]) {
        do {
            try saveRegisteredVoices(voices: voices, url: try voicesFileURL())
            registeredVoices = voices
            voiceRegistryError = nil
        } catch {
            Self.logger.error("Kayıtlı sesler yazılamadı, hata: \(String(describing: error), privacy: .private)")
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
            Self.logger.error("Kişiler defteri okunamadı, hata: \(String(describing: error), privacy: .private)")
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
            Self.logger.error("Kişiler defteri yazılamadı, hata: \(String(describing: error), privacy: .private)")
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
        guard let request = speakerReviewRequest(segments: segments, speakerNames: record.speakerNames, userName: userName, attendees: record.attendees ?? [], language: selectedNoteLanguage()) else {
            return
        }
        let persons: Set<Int> = Set(segments.compactMap(\.person))
        speakerReviewTasks[meetingID]?.cancel()
        speakerReviews[meetingID] = .loading
        speakerReviewTasks[meetingID] = Task { [weak self] in
            let state: SpeakerReviewState
            do {
                let provider: LLMProvider = try await resolveLLMProvider()
                try requireOnDeviceLanguages(provider: provider, meetingLanguages: record.language.map { [$0] } ?? [], outputLanguage: selectedNoteLanguage())
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
        // Kuyruktaki (işlenmemiş) toplantının uyku engeli de toplantıyla biter.
        allowSleep(meetingID: meetingID)
        meetings.removeAll { $0.id == meetingID }
        meetingReloader.invalidate()
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

    /// Ses dosyalarını siler; metin ve not kalır.
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
                Self.logger.error("Ses silinemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            }
        }
    }

    /// Açılışta: kayıtları yükler, yarıda kalanları işaretler, saklama süresini uygular ve günlük uygulamayı başlatır.
    /// Abonelikte hesap verisi yüklenmeden çağrılmaz (bkz. `isAccountDataReady`); süreç başına bir kez.
    func performStartupMaintenance() {
        loadVoices()
        loadPeople()
        #if HOSTED_EDITION
        loadFolders()
        #endif
        loadRecipes()
        loadExportSettings()
        loadAskHistory()
        // Toplantılar arka planda okunur (büyük arşivde açılış donmasın); listeye bağlı işler okuma bitince başlar.
        Task {
            await reloadMeetingsAndWait()
            // Takvim (kendiliğinden kayıt, kaydı olan etkinlik) toplantı listesine bakar.
            startCalendarServices()
            // Yalnızca bu cihazdaki toplantılar: iCloud'daki başka cihazın işlediği toplantı "yarıda kaldı" sayılmaz.
            // Okuma sürerken başlatılmış kayıt (kilitli) yarıda kalmış sayılmaz.
            let local: Set<String> = localMeetingIDsReportingFailure()
            let interrupted: [MeetingRecord] = staleStatusesToInterrupt(records: meetings.filter { local.contains($0.id) && !isLocked(meetingID: $0.id) })
            for record in hostedRequeued(records: interrupted) {
                withSessionDirectory(id: record.id) { (directory: URL) -> Void in
                    saveRecord(record: record, directory: directory)
                }
            }
            applyRetention()
            await loadDestinations()
            await processPendingAutoSends()
        }
        startRetentionTimer()
        startCloudSyncIfEnabled()
        Task { await refreshSetupProblems() }
        Task { await refreshSharedKeys() }
    }

    /// Abonelikte yarıda kalan çevrimdışı kayıt (sunucu oturumu yok) kuyruğa döner; geliştirici sürümünde değişmez.
    private func hostedRequeued(records: [MeetingRecord]) -> [MeetingRecord] {
        #if HOSTED_EDITION
        do {
            let requeued: [MeetingRecord] = queuingUnlinkedInterrupted(records: records, linkedRecordIDs: try hostedLinkedRecordIDs())
            if requeued.contains(where: { $0.status == .queued }) {
                Task { await runOfflineQueue() }
            }
            return requeued
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            return records
        }
        #else
        return records
        #endif
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

    /// Toplantıları arka planda yeniden okur (iCloud değişikliği, taşıma); art arda gelen istekler birleşir.
    func reloadMeetings() {
        Task { await reloadMeetingsAndWait() }
    }

    /// Toplantıları ana iş parçacığını bekletmeden yeniden okur; liste güncellenince döner.
    private func reloadMeetingsAndWait() async {
        await meetingReloader.reload(load: { () async throws -> MeetingLoadResult in
            try await loadMeetingsInBackground(location: self.activeStorageLocation)
        }, apply: { (result: MeetingLoadResult) -> Void in
            self.meetings = result.meetings
            self.meetingLoadFailures = result.failures
            self.cloudDownloadingCount = result.downloading.count
            for failure in result.failures {
                Self.logger.error("Toplantı okunamadı, klasör: \(failure.folder, privacy: .public), neden: \(failure.reason, privacy: .private)")
            }
        }, fail: { (error: any Error) -> Void in
            self.meetingLoadFailures = [MeetingLoadFailure(folder: "Sessions", reason: userFacingMessage(error: error))]
        })
    }

    /// Kaydı diske yazar ve bellekteki listeyi günceller (her kayıtta tüm toplantılar yeniden okunmaz).
    private func saveRecord(record: MeetingRecord, directory: URL) {
        do {
            try saveMeeting(record: record, directory: directory)
            meetings = upsertMeeting(records: meetings, record: record)
            // Süren bir arka plan okuması bu yazmayı görmemiş olabilir: sonucu bu kaydı geri almasın.
            meetingReloader.invalidate()
        } catch {
            Self.logger.error("Toplantı kaydedilemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
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

    /// Açılışta iCloud seçiliyse eşitlemeyi başlatır; iCloud kullanılamıyorsa neden listede de görünür
    /// (bkz. `visibleLoadFailures`).
    func startCloudSyncIfEnabled() {
        Task {
            await cloud.start(excluding: cloudMoveExclusions) { [weak self] in self?.reloadMeetings() }
        }
    }

    /// iCloud eşitlemesini açar (bkz. `CloudSyncController.enable`).
    func enableCloudSync() async {
        await cloud.enable(excluding: cloudMoveExclusions) { [weak self] in self?.reloadMeetings() }
    }

    /// iCloud eşitlemesini kapatır (bkz. `CloudSyncController.disable`).
    func disableCloudSync() async {
        await cloud.disable { [weak self] in self?.reloadMeetings() }
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
                guard let value = try await optionalSecretInBackground(service: appKeychainService, account: account) else {
                    // Bu Mac'te artık olmayan anahtarın iPhone kopyası da kalkar.
                    try await Task.detached { try deleteSyncedSecret(service: appKeychainService, account: account) }.value
                    continue
                }
                try await Task.detached { try saveSyncedSecret(service: appKeychainService, account: account, value: value) }.value
            }
            keySync = .idle
        } catch {
            Self.logger.error("Anahtarlar iCloud'a kopyalanamadı, hata: \(String(describing: error), privacy: .private)")
            keySync = .failed(userFacingMessage(error: error))
        }
        await refreshSharedKeys()
    }

    /// Eşitlenen kopyaları siler (iPhone'daki uygulama da artık göremez).
    func stopSharingKeys() async {
        keySync = .working
        do {
            for account in SecretAccount.allCases {
                try await Task.detached { try deleteSyncedSecret(service: appKeychainService, account: account) }.value
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
            for account in SecretAccount.allCases where try await Task.detached(operation: { try syncedSecretExists(service: appKeychainService, account: account) }).value {
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

/// Gönderim sonucunun kalkma süresi: gitti 3,5 sn, hata 5 sn; gönderilirken kalır. Saf fonksiyondur.
private func sendResultFadeDelay(state: WebhookSendState) -> Duration? {
    switch state {
    case .sending: nil
    case .sent, .done: .seconds(3.5)
    case .failed: .seconds(5)
    }
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
    case HostedImportError.longerThanMeetingAllowance(let durationMinutes, let maxMinutes):
        String(localized: "dosya \(durationMinutes) dakika; bir toplantı şu an en çok \(maxMinutes) dakika işlenebilir. Dosyayı bölüp parçaları ayrı içe aktar.")
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

/// Giriş sayfasını varsayılan tarayıcıda açar; yalnızca https (keşiften gelen adres `file:` ya da özel şema olup yerel
/// bir uygulamayı başlatamasın).
@MainActor
private func openSignInPage(url: URL) {
    guard url.scheme?.lowercased() == "https" else {
        Logger(subsystem: "com.senoldogan.AINotepad", category: "AppModel").error("Güvenli olmayan giriş adresi açılmadı, şema: \(url.scheme ?? "yok", privacy: .public)")
        return
    }
    NSWorkspace.shared.open(url)
}
