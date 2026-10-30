import ActivityKit
import AINotepadCore
import AINotepadUI
import BackgroundTasks
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
    /// Bulut ya da cihaz içi (Apple konuşma tanıma) kayıt; son geçiş buna göre yapılır.
    let engine: RecordingEngine
    /// Kaydın bağlandığı takvim etkinliği (başlık ve katılımcılar kayda geçer); yoksa nil.
    let linkedMeeting: CalendarMeeting?
}

/// iPhone kaydı: yüz yüze toplantı (odadaki herkes telefon mikrofonundan gelir ve konuşmacılara ayrılır). Bulutta canlı
/// metin Deepgram, konuşmacılar ve son geçiş ElevenLabs, çeviri ve not Claude ile; cihaz içi modda metin ve son geçiş
/// Apple'ın konuşma tanımasıyla (konuşmacısız), çeviri ve not Apple Intelligence ile. İşleme Mac'teki `processMeeting`'dir.
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
    /// Cihaz içi konuşma modelinin indirme ilerlemesi (0…1) kayıt başlarken; indirme yoksa nil.
    private(set) var speechModelProgress: Double?
    /// Cihaz içi konuşma tanıma motoru (model kayıtlar arasında bellekte kalır).
    @ObservationIgnored private let speechEngine: AppleSpeechEngine = AppleSpeechEngine()
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
    /// Sistemin ilerleme arayüzüyle süren işleme görevleri (anahtar: toplantı kimliği).
    @ObservationIgnored private var continuedTasks: [String: BGContinuedProcessingTask] = [:]
    /// Süren işlemeler (anahtar: toplantı kimliği): sistem görevi sona erince iptal edilir.
    @ObservationIgnored private var processingTasks: [String: Task<Void, Never>] = [:]
    /// Canlı etkinlik en fazla bu sıklıkta güncellenir (sistem sık güncellemeyi kısar).
    @ObservationIgnored private var lastActivityUpdate: Date = .distantPast
    /// Kayıt başlarken takvimde süren toplantı (takvim açıksa; uygulama bağlar); başlık ve katılımcılar kayda geçer.
    @ObservationIgnored var currentCalendarMeeting: (@MainActor () -> CalendarMeeting?)?

    init(store: PhoneStore) {
        self.store = store
    }

    /// Kaydı başlatır. Bulutta Deepgram ve ElevenLabs anahtarı yoksa hiçbir şey başlamaz (eksiklerin hepsi bildirilir);
    /// cihaz içi modda dilin konuşma modeli gerekirse önce indirilir.
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
        // Cihaz içi tanıma dil algılamaz: otomatikte ana toplantı diliyle başlar; dil kayıt sırasında değiştirilebilir.
        let speechLanguage: MeetingLanguage = appleSpeechLanguage(mode: languageMode, primary: phonePrimaryMeetingLanguage())
        let cloudKeys: (deepgram: String, elevenLabs: String)?
        switch phoneEngine() {
        case .cloud:
            let deepgram: Result<String, any Error> = await secretResult(account: .deepgram)
            let elevenLabs: Result<String, any Error> = await secretResult(account: .elevenlabs)
            guard case .success(let deepgramKey) = deepgram, case .success(let elevenLabsKey) = elevenLabs else {
                for case .failure(let error) in [deepgram, elevenLabs] {
                    errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
                }
                phase = .idle
                return
            }
            cloudKeys = (deepgramKey, elevenLabsKey)
        case .onDevice:
            do {
                _ = try await prepareAppleSpeech(language: speechLanguage) { [weak self] (fraction: Double) -> Void in
                    Task { @MainActor in
                        self?.speechModelProgress = fraction < 1 ? fraction : nil
                    }
                }
                speechModelProgress = nil
            } catch {
                speechModelProgress = nil
                errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
                phase = .idle
                return
            }
            cloudKeys = nil
        }
        let keys: ProcessingKeys = ProcessingKeys(elevenLabs: cloudKeys?.elevenLabs, llm: await llmProviderReportingFailure())
        let started: Date = Date()
        // Takvimde şu anki toplantı: başlık ve katılımcı adları kayda geçer, adlar tanımaya yardım eder.
        let linkedMeeting: CalendarMeeting? = currentCalendarMeeting?()
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
        // En yüksek seviye kilitli kutuda birikir; ana aktöre çubuk aralığının yarısında bir geçilir (her parça için
        // görev açılmaz; bkz. `levelThrottleInterval`).
        let throttle: LevelThrottle = LevelThrottle(intervalSec: levelThrottleInterval(barInterval: levels.interval))
        let metered: AsyncStream<[Float]> = meteredStream(audio: audio) { (level: Float) -> Void in
            guard let peak = throttle.add(level: level) else {
                return
            }
            Task { @MainActor in levels.record(level: peak) }
        }
        let handle: LiveSessionHandle
        if let cloudKeys {
            handle = runCloudLiveSession(
                config: CloudSessionConfig(
                    languageMode: languageMode, recordingDirectory: directory, deepgramKey: cloudKeys.deepgram, elevenLabsKey: cloudKeys.elevenLabs,
                    firstDiarizationAfterSec: 15, diarizationIntervalSec: 60, diarizationWindowSec: 120, minDiarizationAudioSec: 5,
                    languageConfidence: 0.8, keyterms: keytermsWithAttendees(attendees: linkedMeeting?.attendees ?? [], keyterms: [], limit: 30),
                    voiceEmbedder: nil, automaticStartLanguage: phonePrimaryMeetingLanguage()
                ),
                // Yüz yüze: "Sen" akışı yoktur, odadaki herkes "Diğerleri" akışında konuşmacılara ayrılır.
                meAudio: finishedAudioStream(),
                othersAudio: metered
            )
        } else {
            handle = runLiveSession(
                config: LiveSessionConfig(
                    languageMode: .fixed(speechLanguage), segmenter: .live, recordingDirectory: directory, partialIntervalSec: 1.5,
                    minPartialSpeechSec: 1.0, languageLockAfterSec: 30, candidateLanguages: [speechLanguage]
                ),
                engine: speechEngine,
                meAudio: finishedAudioStream(),
                othersAudio: metered
            )
            // Ekranda dil görünsün (sabit dilde oturum kilit olayı yayınlamaz).
            await handle.setLanguage(speechLanguage)
        }
        let recording: ActiveRecording = ActiveRecording(
            directory: directory, startedAt: started, handle: handle, keys: keys, engine: cloudKeys == nil ? .local : .cloud,
            linkedMeeting: linkedMeeting
        )
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
        if let recording = active {
            let id: String = recording.directory.lastPathComponent
            beginBackgroundTask(id: id)
            // Sistem görevi kullanıcının "Bitir" anında istenir: istek yalnızca uygulama öndeyken kabul edilir.
            submitContinuedProcessing(id: id, subtitle: continuedProcessingSubtitle(title: recording.linkedMeeting?.title ?? String(localized: "Toplantı"), startedAt: recording.startedAt))
        }
        levels.stop()
        microphone.stop()
        updateActivityNow(state: RecordingActivityAttributes.ContentState(lastLine: activityLine.text, speaker: activityLine.speaker, isFinishing: true))
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

    /// Açılışta (ve arka plandan dönünce) bu iPhone'da kayıtta ya da işlemede kalmış toplantılar eldeki anahtarlarla
    /// yeniden işlenir; ElevenLabs anahtarı yoksa son geçiş atlanır ve nedeni toplantıda görünür, LLM yoksa not yazılmaz
    /// ve sonra "Notu yenile" ile yazılabilir.
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
        // Son geçiş ayara değil kaydın motoruna göre seçilir (bkz. `process`): ElevenLabs anahtarı yalnız bulutta
        // kaydedilmiş bir toplantı kaldıysa aranır (yalnız cihaz içi kayıtlar kaldıysa "anahtar yok" görünmez).
        let elevenLabs: String? = stale.contains { (record: MeetingRecord) -> Bool in record.engine != .local } ? await optionalElevenLabsKey() : nil
        let keys: ProcessingKeys = ProcessingKeys(elevenLabs: elevenLabs, llm: await llmProviderReportingFailure())
        for record in stale {
            do {
                let directory: URL = try store.sessionDirectory(id: record.id)
                Self.logger.info("Yarıda kalan toplantı yeniden işleniyor, toplantı: \(record.id, privacy: .public)")
                // Anahtarlar beklenirken aynı toplantı başka bir çağrıyla işlemeye girmiş olabilir: ikinci sistem görevi
                // istenmez (sahipsiz kalıp süresi dolunca süren işlemeyi iptal ederdi).
                guard process(record: record.with(status: .processing, failureMessage: nil), directory: directory, keys: keys) else {
                    continue
                }
                submitContinuedProcessing(id: record.id, subtitle: continuedProcessingSubtitle(title: record.title, startedAt: record.startedAt))
            } catch {
                errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            }
        }
    }

    #if DEBUG
    /// `--ornek-kayit` (yalnız Debug, görsel kontrol): mikrofon ve bulut olmadan örnek bir canlı kayıt gösterir.
    func showSampleRecording() {
        let sample: [(text: String, person: Int, translation: String?, isFinal: Bool)] = [
            ("Hyvää huomenta kaikille, aloitetaan viikkopalaveri.", 1, "Herkese günaydın, haftalık toplantıya başlayalım.", true),
            ("Budjetti on nyt valmis ja se lähtee hallitukselle perjantaina.", 1, "Bütçe hazır ve cuma günü yönetim kuruluna gidiyor.", true),
            ("Hyvä. Kuka hoitaa asiakasesityksen?", 2, "Güzel. Müşteri sunumunu kim üstleniyor?", true),
            ("Minä voin tehdä sen, kunhan saan luvut tiistaihin mennessä", 3, nil, false),
        ]
        transcript = sample.enumerated().map { (item: (offset: Int, element: (text: String, person: Int, translation: String?, isFinal: Bool))) -> LiveSegment in
            LiveSegment(
                id: SegmentID(speaker: .others, index: item.offset), startSec: Double(item.offset * 6), endSec: Double(item.offset * 6 + 5),
                text: item.element.text, isFinal: item.element.isFinal, failureMessage: nil, person: item.element.person
            )
        }
        translations = Dictionary(uniqueKeysWithValues: sample.enumerated().compactMap { (item: (offset: Int, element: (text: String, person: Int, translation: String?, isFinal: Bool))) -> (SegmentID, String)? in
            item.element.translation.map { (SegmentID(speaker: .others, index: item.offset), $0) }
        })
        lockedLanguage = .finnish
        startedAt = Date().addingTimeInterval(-754)
        levels.showSample(values: [0.1, 0.4, 0.7, 0.5, 0.9, 0.3, 0.6, 0.2, 0.8, 0.5])
        phase = .recording
        consentReminderVisible = true
        startActivity(startedAt: startedAt ?? Date())
        updateActivityNow(state: RecordingActivityAttributes.ContentState(lastLine: sample[2].text, speaker: speakerLabel(speaker: .others, person: 2), isFinishing: false))
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
                updateActivityThrottled(state: RecordingActivityAttributes.ContentState(
                    lastLine: segment.text, speaker: segment.person.map { speakerLabel(speaker: segment.id.speaker, person: $0) } ?? "",
                    isFinishing: phase == .finishing
                ))
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
        case .streamIncomplete(let speaker, let untranscribedSec):
            // iPhone'da ses "Diğerleri" akışındadır ve son geçişten her zaman geçer: eksik kalan son metin orada tamamlanır.
            Self.logger.warning("Canlı metnin sonu eksik, konuşmacı: \(speaker.rawValue, privacy: .public), süre: \(untranscribedSec, privacy: .public)")
        case .diarizationFailed(let message):
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Konuşmacı ayırma başarısız: \(message)"))
        case .speakersAssigned:
            break
        case .liveEngineFellBack(let message):
            // iPhone hibrit oturum kullanmaz; olay gelirse yine görünür.
            errorMessages = appendUnique(messages: errorMessages, message: message)
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

    /// Toplantıyı işler (ses, son geçiş, not) ve saklar. Uygulama arka plana geçerse iOS'tan ek süre istenir ve varsa
    /// sürdürülen işleme görevinin ilerlemesi güncellenir; süre yetmezse toplantı açılışta yeniden işlenir
    /// (`resumeUnfinished`). Aynı toplantı aynı anda iki kez işlenmez (çift ücret, aynı dosyaya iki yazar). İşleme
    /// başlatıldıysa true; toplantı zaten işleniyorsa false.
    @discardableResult
    private func process(record: MeetingRecord, directory: URL, keys: ProcessingKeys) -> Bool {
        guard processingSteps[record.id] == nil else {
            Self.logger.warning("Toplantı zaten işleniyor, ikinci işleme başlatılmadı, toplantı: \(record.id, privacy: .public)")
            return false
        }
        saveRecord(record: record, directory: directory)
        processingSteps[record.id] = .convertingAudio
        beginBackgroundTask(id: record.id)
        // Cihaz içi kayıt buluta gönderilmez: son geçiş Apple'ın konuşma tanımasıyla yapılır.
        let finalPass: FinalPassPlan = record.engine == .local
            ? .run(AppleSpeechFinalTranscriber(primaryLanguage: phonePrimaryMeetingLanguage()))
            : keys.elevenLabs.map { (key: String) -> FinalPassPlan in
                .run(ElevenLabsFinalTranscriber(apiKey: key, keyterms: []))
            } ?? .skip(reason: String(localized: "ElevenLabs anahtarı kayıtlı değil."))
        processingTasks[record.id] = Task {
            let result: MeetingRecord = await processMeeting(
                record: record, directory: directory, finalPass: finalPass, llm: keys.llm,
                languageMode: record.language.map { LanguageMode.fixed($0) } ?? .automatic, userName: phoneUserName(),
                noteLanguage: phoneNoteLanguage(), voiceEmbedder: nil, registry: []
            ) { (step: ProcessingStep) async -> Void in
                self.processingSteps[record.id] = step
                self.continuedTasks[record.id]?.progress.completedUnitCount = continuedProcessingCompletedUnits(step: step)
            }
            processingTasks[record.id] = nil
            guard !Task.isCancelled else {
                // Sistem görevi sona erdi: yarım sonuç saklanmaz; toplantı diskte `processing` kalır ve açılışta
                // kaldığı yerden işlenir (`resumeUnfinished`).
                Self.logger.warning("İşleme iptal edildi, toplantı açılışta yeniden işlenecek, toplantı: \(record.id, privacy: .public)")
                processingSteps[record.id] = nil
                endBackgroundTask(id: record.id)
                return
            }
            saveRecord(record: result, directory: directory)
            processingSteps[record.id] = nil
            // iCloud'a taşıma sistem görevine bağlanmaz (yarıda iptal edilmesin); arka plan süresiyle sürer.
            finishContinuedTask(meetingID: record.id, success: result.status == .done)
            if result.status == .done {
                await store.cloud.moveFinishedMeetings(excluding: busyMeetingIDs.union([store.playingMeetingID].compactMap { $0 })) { [store] in store.reload() }
            }
            endBackgroundTask(id: record.id)
        }
        return true
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

    // MARK: Sürdürülen işleme

    /// Toplantının işlenmesi için iOS'tan sürdürülen işleme görevi ister: uygulamadan çıkılsa da işleme sistemin
    /// ilerleme arayüzüyle sürer. İstek reddedilirse (desteklenmiyor, kullanıcı arka plan çalışmasını kapattı, uygulama
    /// önde değil, sistem yoğun) uyarı loglanır ve işleme arka plan süresiyle (`beginBackgroundTask`) sürer; süre
    /// yetmezse açılışta yeniden işlenir.
    private func submitContinuedProcessing(id: String, subtitle: String) {
        let identifier: String = continuedProcessingIdentifier(suffix: UUID().uuidString)
        // Joker kalıbın (`<önek>.*`) kendisine işleyici kaydedilemez; her istek kendi tekil kimliğiyle kaydedilir.
        // Sürdürülen işleme görevleri açılış bittikten sonra da kaydedilebilir. İşleyici ana kuyrukta (ana aktörde)
        // çalışır.
        let registered: Bool = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] (task: BGTask) -> Void in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            self.attachContinuedTask(task: task, meetingID: id)
        }
        guard registered else {
            Self.logger.warning("Sürdürülen işleme görevi kaydedilemedi, işleme arka plan süresiyle sürecek, toplantı: \(id, privacy: .public), görev: \(identifier, privacy: .public)")
            return
        }
        let request: BGContinuedProcessingTaskRequest = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: String(localized: "Not hazırlanıyor"), subtitle: subtitle
        )
        // Sistem yoğunsa istek sıraya girer; işleme o arada uygulamada sürer, görev başlayınca ona bağlanır.
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.logger.info("Sürdürülen işleme görevi istendi, toplantı: \(id, privacy: .public), görev: \(identifier, privacy: .public)")
        } catch {
            Self.logger.warning("Sürdürülen işleme görevi reddedildi, işleme arka plan süresiyle sürecek, toplantı: \(id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        }
    }

    /// Sistem görevi başladı: toplantının işlenmesine bağlanır (ilerleme, süre dolunca iptal). İşleme görev başlamadan
    /// bittiyse ya da toplantıya zaten bir görev bağlıysa yeni görev hemen tamamlanır (bağlı olanın yerine geçmez:
    /// sahipsiz kalan görevin süresi dolunca süren işleme iptal edilirdi).
    private func attachContinuedTask(task: BGTask, meetingID: String) {
        guard let continued = task as? BGContinuedProcessingTask else {
            Self.logger.error("Beklenmeyen arka plan görevi türü, görev: \(task.identifier, privacy: .public)")
            task.setTaskCompleted(success: false)
            return
        }
        guard continuedTasks[meetingID] == nil else {
            Self.logger.warning("Toplantıya zaten sürdürülen işleme görevi bağlı, yeni görev bitiriliyor, toplantı: \(meetingID, privacy: .public), görev: \(task.identifier, privacy: .public)")
            continued.setTaskCompleted(success: false)
            return
        }
        // Kapanış (mikrofon kapandı, oturum bitiyor) ya da işleme sürüyor.
        let running: Bool = processingSteps[meetingID] != nil || active?.directory.lastPathComponent == meetingID
        guard running else {
            let success: Bool = store.meetings.first { (record: MeetingRecord) -> Bool in record.id == meetingID }?.status == .done
            Self.logger.info("İşleme sistem görevi başlamadan bitti, toplantı: \(meetingID, privacy: .public)")
            continued.setTaskCompleted(success: success)
            return
        }
        continued.progress.totalUnitCount = continuedProcessingTotalUnits
        continued.progress.completedUnitCount = continuedProcessingCompletedUnits(step: processingSteps[meetingID])
        // Sistem işleyiciyi hangi kuyrukta çağıracağını belirtmez: ana aktöre geçilir.
        continued.expirationHandler = { @Sendable [weak self] () -> Void in
            Task { @MainActor in
                self?.expireContinuedTask(meetingID: meetingID)
            }
        }
        continuedTasks[meetingID] = continued
        Self.logger.info("Sürdürülen işleme görevi başladı, toplantı: \(meetingID, privacy: .public)")
    }

    /// Sistem görevinin süresi doldu ya da kullanıcı onu sistem arayüzünden durdurdu: işleme iptal edilir, toplantı
    /// `processing` kalır ve açılışta yeniden işlenir (`resumeUnfinished`).
    private func expireContinuedTask(meetingID: String) {
        guard let task = continuedTasks.removeValue(forKey: meetingID) else {
            return
        }
        Self.logger.warning("Sürdürülen işleme sona erdi, işleme iptal ediliyor, toplantı: \(meetingID, privacy: .public)")
        processingTasks[meetingID]?.cancel()
        task.setTaskCompleted(success: false)
    }

    /// İşleme bitti: varsa sistem görevi tamamlanır.
    private func finishContinuedTask(meetingID: String, success: Bool) {
        guard let task = continuedTasks.removeValue(forKey: meetingID) else {
            return
        }
        task.progress.completedUnitCount = continuedProcessingTotalUnits
        task.setTaskCompleted(success: success)
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
            Self.logger.error("Canlı etkinlik başlatılamadı, hata: \(String(describing: error), privacy: .private)")
        }
    }

    /// Canlı etkinliği en fazla 2 sn'de bir günceller (her cümlede çağrılır; sistem sık güncellemeyi kısar).
    private func updateActivityThrottled(state: RecordingActivityAttributes.ContentState) {
        guard Date().timeIntervalSince(lastActivityUpdate) >= 2 else {
            return
        }
        updateActivityNow(state: state)
    }

    /// Canlı etkinliği hemen günceller (kayıt başladı, bitiyor, sessizlikte tazeleme).
    private func updateActivityNow(state: RecordingActivityAttributes.ContentState) {
        guard let activity else {
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

    /// Kesinleşmiş bölümü not diline çevirmek üzere sıraya alır; toplantı not dilindeyse metin olduğu gibi kalır.
    private func enqueueTranslation(segment: LiveSegment) {
        // Toplantı not dilindeyse aynı dile çeviri yapılmaz: orijinal tek başına görünür (LLM'e gitmez).
        guard needsLiveTranslation(spoken: lockedLanguage ?? fixedMeetingLanguage(mode: languageMode), noteLanguage: phoneNoteLanguage()) else {
            return
        }
        guard let provider = active?.keys.llm else {
            return
        }
        do {
            let language: MeetingLanguage? = lockedLanguage ?? fixedMeetingLanguage(mode: languageMode)
            try requireOnDeviceLanguages(provider: provider, meetingLanguages: language.map { [$0] } ?? [], outputLanguage: phoneNoteLanguage())
        } catch {
            // Cihaz içi model bu dili anlamıyor: bozuk çeviri yerine açık mesaj (bir kez).
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Çeviri: \(userFacingMessage(error: error))"))
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
                    let translated: String = try await translateSentence(provider: provider, sentence: segment.text, context: context, language: phoneNoteLanguage())
                    // Cümle zaten not dilindeyse (model aynen döndürdü) çeviri saklanmaz: aynı cümle iki kez görünmesin.
                    if requestGeneration == generation, isDistinctTranslation(original: segment.text, translated: translated) {
                        translations[id] = translated
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
        let base: MeetingRecord = MeetingRecord(
            id: recording.directory.lastPathComponent, title: recording.linkedMeeting?.title ?? String(localized: "Toplantı"), startedAt: recording.startedAt, endedAt: endedAt,
            language: lockedLanguage, status: status, failureMessage: nil,
            liveSegments: storedSegments(transcript: transcript), finalSegments: [],
            translations: Dictionary(uniqueKeysWithValues: translations.map { (segmentKey(id: $0.key), $0.value) }),
            speakerNames: [:], note: nil, audioDeleted: false, engine: recording.engine, notice: nil, meNeedsFinalPass: nil
        )
        .with(highlights: highlights)
        .with(myNotes: myNotes)
        // Mac'teki gibi: takvim etkinliğine bağlı kayıt katılımcıları ve etkinlik kimliğini taşır.
        return recording.linkedMeeting.map { base.with(attendees: $0.attendees).with(calendarEventID: $0.id) } ?? base
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
                self.updateActivityNow(state: RecordingActivityAttributes.ContentState(lastLine: self.activityLine.text, speaker: self.activityLine.speaker, isFinishing: false))
            }
        }
    }

    private func saveRecord(record: MeetingRecord, directory: URL) {
        do {
            try saveMeeting(record: record, directory: directory)
            store.upsert(record: record)
        } catch {
            Self.logger.error("Toplantı kaydedilemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
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

    /// LLM sağlayıcısı (Claude ya da cihaz içi); kullanılamazsa çeviri ve not kapalı kalır ve neden bildirilir.
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

/// Sürdürülen işleme görevlerinin kimlik öneki; Info.plist'teki `BGTaskSchedulerPermittedIdentifiers` joker kalıbı
/// (`<önek>.*`, project.yml) ile aynı olmalı.
private let continuedProcessingIdentifierPrefix: String = "com.senoldogan.AINotepad.process"

/// Sürdürülen işleme görevinin tekil kimliği. Saf fonksiyondur.
private func continuedProcessingIdentifier(suffix: String) -> String {
    "\(continuedProcessingIdentifierPrefix).\(suffix)"
}

/// Sistem ilerlemesinin toplam birimi: işleme adımları (ses, son geçiş, not).
private let continuedProcessingTotalUnits: Int64 = Int64(ProcessingStep.allCases.count)

/// Adım başladığında tamamlanmış birim (önceki adımlar); işleme başlamadıysa 0. Saf fonksiyondur.
private func continuedProcessingCompletedUnits(step: ProcessingStep?) -> Int64 {
    Int64(step?.rawValue ?? 0)
}

/// Sistem görevinin alt başlığı: toplantının adı ve başlangıç saati ("Toplantı · 14:30"). Saf fonksiyondur.
private func continuedProcessingSubtitle(title: String, startedAt: Date) -> String {
    "\(title) · \(startedAt.formatted(date: .omitted, time: .shortened))"
}

/// Canlı etkinliğin eskimiş sayılma süresi: kayıt 30 sn'de bir tazeler; uygulama kapanırsa kilit ekranında saymayı
/// sürdürmez.
private let activityStaleSec: TimeInterval = 120
