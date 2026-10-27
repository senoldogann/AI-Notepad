import ActivityKit
import AINotepadCore
import AINotepadUI
import Foundation
import os
import UIKit

/// Kaydın durumu.
enum RecorderPhase: Equatable {
    case idle
    case starting
    case recording
    /// Mikrofon kapandı; Deepgram ve konuşmacı ayırma son bölümleri bitiriyor.
    case finishing
}

/// Toplantı sonrası işleme için gereken anahtarlar. Kayıt başında okunur: ekran kilitliyken Anahtar Zinciri okunamaz.
struct ProcessingKeys: Sendable {
    /// Son geçiş (konuşmacılar); yoksa son geçiş atlanır ve nedeni toplantıda görünür.
    let elevenLabs: String?
    /// Çeviri ve not; yoksa canlı çeviri ve not yapılmaz.
    let llm: LLMProvider?
}

/// Süren kayıt.
private struct ActiveRecording {
    let directory: URL
    let startedAt: Date
    let handle: LiveSessionHandle
    let keys: ProcessingKeys
}

/// iPhone kaydı: yüz yüze toplantı (odadaki herkes telefon mikrofonundan gelir ve konuşmacılara ayrılır). Canlı metin
/// Deepgram, konuşmacılar ve son geçiş ElevenLabs, çeviri ve not Claude ile; işleme Mac'teki `processMeeting`'dir.
@MainActor
@Observable
final class PhoneRecorder {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneRecorder")
    /// Aynı anda en fazla bu kadar canlı çeviri isteği.
    private static let maxParallelTranslations: Int = 4

    private(set) var phase: RecorderPhase = .idle
    private(set) var transcript: [LiveSegment] = []
    private(set) var translations: [SegmentID: String] = [:]
    private(set) var lockedLanguage: MeetingLanguage?
    private(set) var errorMessages: [String] = []
    private(set) var startedAt: Date?
    /// İşlenen toplantıların adımı (kimlik → adım).
    private(set) var processingSteps: [String: ProcessingStep] = [:]
    /// Son biten kaydın kimliği (hazırlanma kartı bunu izler).
    private(set) var lastMeetingID: String?
    var languageMode: LanguageMode = .automatic
    /// Kayıtta işaretlenen anlar (not onları öne çıkarır).
    private(set) var highlights: [Highlight] = []
    /// Kullanıcının kayıt sırasında yazdığı notlar (not bunları öncelik sayar).
    var myNotes: String = ""
    /// "Katılımcılara haber ver" kartı bu kayıtta görünür (ayar açıksa kayıt başında açılır, kapatılabilir).
    var consentReminderVisible: Bool = false
    let levels: AudioLevels = AudioLevels(count: 36, interval: 0.08)

    @ObservationIgnored private let store: PhoneStore
    @ObservationIgnored private let microphone: MicrophoneCapture = MicrophoneCapture()
    /// Mikrofon telefon çağrısı ya da alarmla kesildi: kayıt ekranı uyarır, kesinti bitince kayıt sürer.
    private(set) var micInterrupted: Bool = false
    @ObservationIgnored private var active: ActiveRecording?
    @ObservationIgnored private var translationQueue: [SegmentID] = []
    @ObservationIgnored private var translationsInFlight: Int = 0
    /// Her kayıtta artar: önceki kaydın geç gelen çevirisi yenisine yazılmaz.
    @ObservationIgnored private var generation: Int = 0
    @ObservationIgnored private var checkpointTask: Task<Void, Never>?
    /// Kilit ekranı ve Dynamic Island'daki canlı etkinlik; izin yoksa nil.
    @ObservationIgnored private var activity: Activity<RecordingActivityAttributes>?
    /// Süren arka plan görevleri (anahtar: toplantı kimliği): kayıt kapanışı ve işleme uygulama arka plandayken sürsün.
    @ObservationIgnored private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]
    /// Canlı etkinlik en fazla bu sıklıkta güncellenir (sistem sık güncellemeyi kısar).
    @ObservationIgnored private var lastActivityUpdate: Date = .distantPast

    init(store: PhoneStore) {
        self.store = store
    }

    /// Kaydı başlatır. Deepgram ve ElevenLabs anahtarı yoksa hiçbir şey başlamaz; eksiklerin hepsi bildirilir.
    func start() async {
        guard phase == .idle else {
            return
        }
        phase = .starting
        generation += 1
        transcript = []
        translations = [:]
        translationQueue = []
        lockedLanguage = nil
        errorMessages = []
        highlights = []
        myNotes = ""
        let deepgram: Result<String, any Error> = await secretResult(account: .deepgram)
        let elevenLabs: Result<String, any Error> = await secretResult(account: .elevenlabs)
        guard case .success(let deepgramKey) = deepgram, case .success(let elevenLabsKey) = elevenLabs else {
            for case .failure(let error) in [deepgram, elevenLabs] {
                errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            }
            phase = .idle
            return
        }
        let keys: ProcessingKeys = ProcessingKeys(elevenLabs: elevenLabsKey, llm: await llmProviderReportingFailure())
        let started: Date = Date()
        let directory: URL
        let audio: AsyncStream<[Float]>
        do {
            directory = try AppPaths.newSessionDirectory(startedAt: started)
            let origin: ContinuousClock.Instant = .now
            microphone.onInterruptionChange = { [weak self] (interrupted: Bool) -> Void in
                self?.micInterrupted = interrupted
            }
            audio = clockAlignedStream(audio: try await microphone.start(), origin: origin, sampleRate: 16000, thresholdSec: 0.5)
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            phase = .idle
            return
        }
        levels.start()
        let levels: AudioLevels = levels
        let metered: AsyncStream<[Float]> = meteredStream(audio: audio) { (level: Float) -> Void in
            let now: Date = Date()
            Task { @MainActor in levels.record(level: level, at: now) }
        }
        let handle: LiveSessionHandle = runCloudLiveSession(
            config: CloudSessionConfig(
                languageMode: languageMode, recordingDirectory: directory, deepgramKey: deepgramKey, elevenLabsKey: elevenLabsKey,
                firstDiarizationAfterSec: 15, diarizationIntervalSec: 60, diarizationWindowSec: 120, minDiarizationAudioSec: 5,
                languageConfidence: 0.8, keyterms: [], voiceEmbedder: nil, automaticStartLanguage: phonePrimaryMeetingLanguage()
            ),
            // Yüz yüze: "Sen" akışı yoktur, odadaki herkes "Diğerleri" akışında konuşmacılara ayrılır.
            meAudio: finishedAudioStream(),
            othersAudio: metered
        )
        let recording: ActiveRecording = ActiveRecording(directory: directory, startedAt: started, handle: handle, keys: keys)
        active = recording
        startedAt = started
        phase = .recording
        // Uygulama kayıt sırasında kapanırsa toplantı açılışta bulunup işlenir.
        saveRecord(record: liveRecord(recording: recording, status: .recording, endedAt: nil), directory: directory)
        startCheckpoints()
        startActivity(startedAt: started)
        consentReminderVisible = UserDefaults.standard.bool(forKey: PhoneSettingsKey.consentReminder)
        Self.logger.info("Kayıt başladı, klasör: \(directory.lastPathComponent, privacy: .public)")
        let sessionGeneration: Int = generation
        Task { [weak self] in
            for await event in handle.events {
                self?.handle(event: event, generation: sessionGeneration)
            }
            await self?.sessionEnded()
        }
    }

    /// Mikrofonu kapatır; oturum kalan bölümleri bitirip kendiliğinden biter.
    func stop() {
        guard phase == .recording else {
            // Kayıt yokken "Bitir" (kilit ekranı, Denetim Merkezi): uygulama kayıt sırasında kapandıysa kalan canlı
            // etkinlik kalkar.
            endStaleActivities()
            return
        }
        phase = .finishing
        // Kapanış (son ses, son konuşmacı etiketleri, bekleyen çeviriler) uygulama arka plana geçse de bitsin.
        if let id = active?.directory.lastPathComponent {
            beginBackgroundTask(id: id)
        }
        levels.stop()
        microphone.stop()
        updateActivity(state: RecordingActivityAttributes.ContentState(lastLine: activityLine.text, speaker: activityLine.speaker, isFinishing: true), force: true)
    }

    /// Kullanımdaki toplantılar (kayıtta ya da işleniyor): iCloud'a taşınmaz.
    var busyMeetingIDs: Set<String> {
        Set(processingSteps.keys).union([active?.directory.lastPathComponent].compactMap { $0 })
    }

    /// Şu anı işaretler: notta öne çıkar (söz bittikten sonra basılır; aralığı `Highlight` belirler).
    func markMoment() {
        guard phase == .recording, let startedAt else {
            return
        }
        highlights.append(Highlight(startSec: Date().timeIntervalSince(startedAt), endSec: nil))
    }

    /// Kayıt sırasında dili değiştirir; o andan sonraki metin yeni dille yazılır.
    func setLanguage(language: MeetingLanguage) {
        guard phase == .recording, let handle = active?.handle else {
            languageMode = .fixed(language)
            return
        }
        Task {
            await handle.setLanguage(language)
        }
    }

    /// Açılışta kayıtta ya da işlemede kalmış (uygulama kapanmış) toplantılar yeniden işlenir; anahtarlar okunamazsa
    /// "yarıda kaldı" olarak saklanır (toplantı sayfasından yeniden işlenebilir).
    func resumeUnfinished() async {
        endStaleActivities()
        // Bu oturumda işlenmekte olanlar (sahne yeniden kurulduysa) ikinci kez işlenmez: çift ücret, aynı dosyaya iki yazar.
        // Yalnızca bu iPhone'da kaydedilenler: iCloud'daki Mac toplantısı Mac'te işlenir.
        let local: Set<String>
        do {
            local = try AppPaths.localMeetingIDs()
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            return
        }
        let stale: [MeetingRecord] = staleStatusesToInterrupt(records: store.meetings.filter { local.contains($0.id) }).filter { processingSteps[$0.id] == nil }
        guard !stale.isEmpty, phase == .idle else {
            return
        }
        let keys: ProcessingKeys = ProcessingKeys(elevenLabs: await optionalElevenLabsKey(), llm: await llmProviderReportingFailure())
        for record in stale {
            do {
                let directory: URL = try store.sessionDirectory(id: record.id)
                Self.logger.info("Yarıda kalan toplantı yeniden işleniyor, toplantı: \(record.id, privacy: .public)")
                process(record: record.with(status: .processing, failureMessage: nil), directory: directory, keys: keys)
            } catch {
                errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            }
        }
    }

    #if DEBUG
    /// `--ornek-kayit` (yalnız Debug, görsel kontrol): mikrofon ve bulut olmadan örnek bir canlı kayıt gösterir.
    func showSampleRecording() {
        let sample: [(text: String, person: Int, turkish: String?, isFinal: Bool)] = [
            ("Hyvää huomenta kaikille, aloitetaan viikkopalaveri.", 1, "Herkese günaydın, haftalık toplantıya başlayalım.", true),
            ("Budjetti on nyt valmis ja se lähtee hallitukselle perjantaina.", 1, "Bütçe hazır ve cuma günü yönetim kuruluna gidiyor.", true),
            ("Hyvä. Kuka hoitaa asiakasesityksen?", 2, "Güzel. Müşteri sunumunu kim üstleniyor?", true),
            ("Minä voin tehdä sen, kunhan saan luvut tiistaihin mennessä", 3, nil, false),
        ]
        transcript = sample.enumerated().map { (item: (offset: Int, element: (text: String, person: Int, turkish: String?, isFinal: Bool))) -> LiveSegment in
            LiveSegment(
                id: SegmentID(speaker: .others, index: item.offset), startSec: Double(item.offset * 6), endSec: Double(item.offset * 6 + 5),
                text: item.element.text, isFinal: item.element.isFinal, failureMessage: nil, person: item.element.person
            )
        }
        translations = Dictionary(uniqueKeysWithValues: sample.enumerated().compactMap { (item: (offset: Int, element: (text: String, person: Int, turkish: String?, isFinal: Bool))) -> (SegmentID, String)? in
            item.element.turkish.map { (SegmentID(speaker: .others, index: item.offset), $0) }
        })
        lockedLanguage = .finnish
        startedAt = Date().addingTimeInterval(-754)
        levels.start()
        for (index, level) in [0.1, 0.4, 0.7, 0.5, 0.9, 0.3, 0.6, 0.2, 0.8, 0.5].enumerated() {
            levels.record(level: Float(level), at: Date().addingTimeInterval(Double(index)))
        }
        phase = .recording
        consentReminderVisible = true
        startActivity(startedAt: startedAt ?? Date())
        updateActivity(state: RecordingActivityAttributes.ContentState(lastLine: sample[2].text, speaker: speakerLabel(speaker: .others, person: 2), isFinishing: false), force: true)
    }
    #endif

    // MARK: Oturum olayları

    private func handle(event: LiveSessionEvent, generation eventGeneration: Int) {
        guard eventGeneration == generation else {
            return
        }
        transcript = applyEvent(transcript: transcript, event: event)
        switch event {
        case .segment(let segment):
            if segment.isFinal, !segment.text.isEmpty {
                enqueueTranslation(segment: segment)
                updateActivity(state: RecordingActivityAttributes.ContentState(
                    lastLine: segment.text, speaker: segment.person.map { speakerLabel(speaker: segment.id.speaker, person: $0) } ?? "",
                    isFinishing: phase == .finishing
                ), force: false)
            }
        case .languageLocked(let language):
            lockedLanguage = language
        case .captureEnded:
            if phase == .recording {
                errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Mikrofon beklenmedik şekilde durdu. Kaydı bitirip yeniden başlat."))
            }
        case .recordingFailed(_, let message):
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Ses diske yazılamadı: \(message)"))
        case .streamFailed(_, let message):
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Canlı metin durdu: \(message)"))
        case .diarizationFailed(let message):
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Konuşmacı ayırma başarısız: \(message)"))
        case .speakersAssigned:
            break
        }
    }

    /// Oturum bitti: bekleyen çeviriler (en fazla 10 sn) beklenir, toplantı saklanıp işlenir.
    private func sessionEnded() async {
        let completed: Bool = await finishesWithin(seconds: 10) { [weak self] in
            while await self?.hasPendingTranslations() == true {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    // İptal: bekleme biter.
                    return
                }
            }
        }
        if !completed {
            Self.logger.warning("Kayıt sonunda bekleyen çeviriler süre içinde bitmedi")
        }
        // Başlamamış çeviriler artık başlamaz (oturum kapandı); kuyruk boşalmazsa bir sonraki kayda dek her 200 ms'de
        // bekleniyordu.
        translationQueue = []
        checkpointTask?.cancel()
        checkpointTask = nil
        microphone.stop()
        levels.stop()
        endActivity()
        phase = .idle
        consentReminderVisible = false
        guard let finished = active else {
            startedAt = nil
            return
        }
        active = nil
        // Biten kaydın geç çevirisi artık yazılmaz.
        generation += 1
        let record: MeetingRecord = liveRecord(recording: finished, status: .processing, endedAt: Date())
        startedAt = nil
        lastMeetingID = record.id
        Self.logger.info("Kayıt bitti, toplantı: \(record.id, privacy: .public)")
        process(record: record, directory: finished.directory, keys: finished.keys)
    }

    /// Toplantıyı işler (ses, son geçiş, not) ve saklar. Uygulama arka plana geçerse iOS'tan ek süre istenir; süre
    /// yetmezse toplantı açılışta yeniden işlenir (`resumeUnfinished`).
    private func process(record: MeetingRecord, directory: URL, keys: ProcessingKeys) {
        saveRecord(record: record, directory: directory)
        processingSteps[record.id] = .convertingAudio
        beginBackgroundTask(id: record.id)
        let finalPass: FinalPassPlan = keys.elevenLabs.map { (key: String) -> FinalPassPlan in
            .run(ElevenLabsFinalTranscriber(apiKey: key, keyterms: []))
        } ?? .skip(reason: String(localized: "ElevenLabs anahtarı kayıtlı değil."))
        Task {
            let result: MeetingRecord = await processMeeting(
                record: record, directory: directory, finalPass: finalPass, llm: keys.llm,
                languageMode: record.language.map { LanguageMode.fixed($0) } ?? .automatic, userName: phoneUserName(),
                voiceEmbedder: nil, registry: []
            ) { (step: ProcessingStep) async -> Void in
                self.processingSteps[record.id] = step
            }
            saveRecord(record: result, directory: directory)
            processingSteps[record.id] = nil
            if result.status == .done {
                await store.cloud.moveFinishedMeetings(excluding: busyMeetingIDs.union([store.playingMeetingID].compactMap { $0 })) { [store] in store.reload() }
            }
            endBackgroundTask(id: record.id)
        }
    }

    // MARK: Arka plan

    /// Toplantı için iOS'tan arka planda çalışma süresi ister (kapanış ve işleme). Zaten varsa yenisi açılmaz. Süre
    /// dolarsa görev bitirilir (iOS uygulamayı sonlandırmasın); toplantı `processing` kalır ve açılışta kaldığı yerden
    /// işlenir (`resumeUnfinished`).
    private func beginBackgroundTask(id: String) {
        guard backgroundTasks[id] == nil else {
            return
        }
        backgroundTasks[id] = UIApplication.shared.beginBackgroundTask(withName: "AINotepad.\(id)") { [weak self] in
            MainActor.assumeIsolated {
                Self.logger.warning("Arka plan süresi doldu, toplantı açılışta işlenecek, toplantı: \(id, privacy: .public)")
                self?.endBackgroundTask(id: id)
            }
        }
    }

    private func endBackgroundTask(id: String) {
        guard let task = backgroundTasks.removeValue(forKey: id) else {
            return
        }
        UIApplication.shared.endBackgroundTask(task)
    }

    // MARK: Canlı etkinlik

    /// Canlı etkinlikteki son satır: son kesinleşen cümle ve konuşmacısı.
    private var activityLine: (text: String, speaker: String) {
        guard let last = transcript.last(where: { $0.isFinal && !$0.text.isEmpty }) else {
            return ("", "")
        }
        return (last.text, last.person.map { speakerLabel(speaker: last.id.speaker, person: $0) } ?? "")
    }

    /// Kilit ekranı ve Dynamic Island'da kaydı gösterir. Kullanıcı canlı etkinlikleri kapattıysa gösterilmez (loglanır);
    /// kayıt etkilenmez.
    private func startActivity(startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.logger.info("Canlı etkinlikler kapalı; kayıt kilit ekranında gösterilmiyor")
            return
        }
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(startedAt: startedAt),
                content: ActivityContent(state: RecordingActivityAttributes.ContentState(lastLine: "", speaker: "", isFinishing: false), staleDate: Date().addingTimeInterval(activityStaleSec)),
                pushType: nil
            )
            lastActivityUpdate = .distantPast
        } catch {
            Self.logger.error("Canlı etkinlik başlatılamadı, hata: \(String(describing: error), privacy: .public)")
        }
    }

    /// Canlı etkinliği günceller; `force` değilse en fazla 2 sn'de bir (sistem sık güncellemeyi kısar).
    private func updateActivity(state: RecordingActivityAttributes.ContentState, force: Bool) {
        guard let activity, force || Date().timeIntervalSince(lastActivityUpdate) >= 2 else {
            return
        }
        lastActivityUpdate = Date()
        let id: String = activity.id
        Task.detached {
            // Etkinlik görev içinde kimliğiyle bulunur (ana aktörden başka göreve geçirilmez).
            for running in Activity<RecordingActivityAttributes>.activities where running.id == id {
                await running.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(activityStaleSec)))
            }
        }
    }

    /// Uygulama kayıt sırasında kapandıysa kilit ekranında kalan canlı etkinlik kaldırılır (kayıt yokken çağrılır).
    private func endStaleActivities() {
        guard phase == .idle, activity == nil else {
            return
        }
        Task.detached {
            for stale in Activity<RecordingActivityAttributes>.activities {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Kayıt bitti: canlı etkinlik kalkar.
    private func endActivity() {
        guard let activity else {
            return
        }
        self.activity = nil
        let id: String = activity.id
        Task.detached {
            for running in Activity<RecordingActivityAttributes>.activities where running.id == id {
                await running.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: Çeviri

    /// Kesinleşmiş bölümü Türkçeye çevirmek üzere sıraya alır; Türkçe toplantıda metin olduğu gibi kalır.
    private func enqueueTranslation(segment: LiveSegment) {
        if lockedLanguage ?? fixedMeetingLanguage(mode: languageMode) == .turkish {
            translations[segment.id] = segment.text
            return
        }
        guard active?.keys.llm != nil else {
            return
        }
        translationQueue.append(segment.id)
        startQueuedTranslations()
    }

    private func startQueuedTranslations() {
        guard let provider = active?.keys.llm else {
            return
        }
        while translationsInFlight < Self.maxParallelTranslations, !translationQueue.isEmpty {
            let id: SegmentID = translationQueue.removeFirst()
            guard let segment = transcript.first(where: { $0.id == id && $0.isFinal }) else {
                continue
            }
            let context: [String] = translationContext(transcript: transcript, before: id, count: 3)
            let requestGeneration: Int = generation
            translationsInFlight += 1
            Task {
                do {
                    let turkish: String = try await sendLLM(provider: provider, request: translationRequest(sentence: segment.text, context: context))
                    if requestGeneration == generation {
                        translations[id] = turkish
                    }
                } catch {
                    Self.logger.error("Çeviri başarısız, bölüm: \(segmentKey(id: id), privacy: .public), hata: \(String(describing: error), privacy: .private)")
                    if requestGeneration == generation {
                        errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Çeviri: \(userFacingMessage(error: error))"))
                    }
                }
                translationsInFlight -= 1
                startQueuedTranslations()
            }
        }
    }

    private func hasPendingTranslations() -> Bool {
        translationsInFlight > 0 || !translationQueue.isEmpty
    }

    // MARK: Saklama

    /// Canlı transkript ve çevirilerden toplantı kaydı.
    private func liveRecord(recording: ActiveRecording, status: MeetingStatus, endedAt: Date?) -> MeetingRecord {
        MeetingRecord(
            id: recording.directory.lastPathComponent, title: String(localized: "Toplantı"), startedAt: recording.startedAt, endedAt: endedAt,
            language: lockedLanguage, status: status, failureMessage: nil,
            liveSegments: storedSegments(transcript: transcript), finalSegments: [],
            translations: Dictionary(uniqueKeysWithValues: translations.map { (segmentKey(id: $0.key), $0.value) }),
            speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        .with(highlights: highlights)
        .with(myNotes: myNotes)
    }

    /// Kayıt sürerken her 30 sn'de transkript saklanır: uygulama kapanırsa metin toplantıda kalır.
    private func startCheckpoints() {
        checkpointTask?.cancel()
        checkpointTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    // İptal: kayıt bitti.
                    return
                }
                guard let self, self.phase == .recording, let recording = self.active else {
                    return
                }
                self.saveRecord(record: self.liveRecord(recording: recording, status: .recording, endedAt: nil), directory: recording.directory)
                // Sessizlikte de canlı etkinlik tazelenir: uygulama kapanırsa 2 dk sonra eskimiş görünür, saymayı sürdürmez.
                self.updateActivity(state: RecordingActivityAttributes.ContentState(lastLine: self.activityLine.text, speaker: self.activityLine.speaker, isFinishing: false), force: true)
            }
        }
    }

    private func saveRecord(record: MeetingRecord, directory: URL) {
        do {
            try saveMeeting(record: record, directory: directory)
            store.upsert(record: record)
        } catch {
            Self.logger.error("Toplantı kaydedilemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Toplantı kaydedilemedi: \(userFacingMessage(error: error))"))
        }
    }

    // MARK: Anahtarlar

    /// Anahtarı okur; sonucu hata dahil döndürür (birden çok eksik birlikte bildirilsin diye).
    private func secretResult(account: SecretAccount) async -> Result<String, any Error> {
        do {
            return .success(try await readSecretInBackground(service: keychainService, account: account))
        } catch {
            return .failure(error)
        }
    }

    /// Claude sağlayıcısı; okunamazsa çeviri ve not kapalı kalır ve neden bildirilir.
    private func llmProviderReportingFailure() async -> LLMProvider? {
        do {
            return try await phoneLLMProvider()
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Çeviri ve not kapalı: \(userFacingMessage(error: error))"))
            return nil
        }
    }

    /// ElevenLabs anahtarı; okunamazsa nil ve neden bildirilir (son geçiş atlanır).
    private func optionalElevenLabsKey() async -> String? {
        do {
            return try await readSecretInBackground(service: keychainService, account: .elevenlabs)
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            return nil
        }
    }
}

/// Sabit dil seçiliyse o dil; otomatikte nil. Saf fonksiyondur.
func fixedMeetingLanguage(mode: LanguageMode) -> MeetingLanguage? {
    guard case .fixed(let language) = mode else {
        return nil
    }
    return language
}

/// Hemen biten boş ses akışı (yüz yüze kayıtta "Sen" akışı yerine).
private func finishedAudioStream() -> AsyncStream<[Float]> {
    let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    continuation.finish()
    return stream
}

/// Canlı etkinliğin eskimiş sayılma süresi: kayıt 30 sn'de bir tazeler; uygulama kapanırsa kilit ekranında saymayı
/// sürdürmez.
private let activityStaleSec: TimeInterval = 120
