import Foundation
import os

/// Hibrit canlı oturumun Deepgram kaynağı (abonelik sürümü): dil, terimler, adres seçenekleri ve her bağlantıda yeni
/// kısa ömürlü jeton veren kaynak.
public struct DeepgramLiveSource: Sendable {
    /// Akışın dili: sabit dil ya da otomatikte ana toplantı dili (Deepgram akışı dil algılamaz).
    public let language: MeetingLanguage
    public let keyterms: [String]
    public let options: DeepgramListenOptions
    /// Her bağlantıda yeni jeton (sunucudan); jeton saklanmaz.
    public let token: @Sendable () async throws -> String

    public init(language: MeetingLanguage, keyterms: [String], options: DeepgramListenOptions, token: @escaping @Sendable () async throws -> String) {
        self.language = language
        self.keyterms = keyterms
        self.options = options
        self.token = token
    }
}

/// Hibrit oturumun başladığı motor.
public enum HybridLiveStart: Sendable {
    /// Bulut (Deepgram); akış durursa oturum Mac'e geçer.
    case deepgram(DeepgramLiveSource)
    /// Doğrudan Mac (WhisperKit); motor hazırlanırken gelen ses bekletilir.
    case local
}

/// Hibrit oturumun kaydı (`startHybridRecording`): iki ses akışı oluşturulduğu anda `me.caf` ve `others.caf`'a yazılır;
/// yazılan ses ve kayıt olayları oturuma aktarılır.
public struct HybridRecording: Sendable {
    let events: AsyncStream<LiveSessionEvent>
    let sink: AsyncStream<LiveSessionEvent>.Continuation
    let me: AsyncStream<[Float]>
    let others: AsyncStream<[Float]>
}

/// İki ses akışını hemen diske yazmaya başlar (kayıt motordan bağımsız, kesintisizdir): toplantı oturumu açılırken ve
/// canlı motor seçilirken (ağ beklenirken) gelen ses de bellekte değil dosyada durur. Yazılan ses, oturum başlayana dek
/// bekletilir ve `runHybridLiveSession`'a verilir.
public func startHybridRecording(directory: URL, meAudio: AsyncStream<[Float]>, othersAudio: AsyncStream<[Float]>) -> HybridRecording {
    let (events, sink): (AsyncStream<LiveSessionEvent>, AsyncStream<LiveSessionEvent>.Continuation) =
        AsyncStream.makeStream(of: LiveSessionEvent.self)
    return HybridRecording(
        events: events,
        sink: sink,
        me: recordedStream(speaker: .me, audio: meAudio, directory: directory, events: sink),
        others: recordedStream(speaker: .others, audio: othersAudio, directory: directory, events: sink)
    )
}

/// Hibrit canlı oturum ayarları.
public struct HybridLiveSessionConfig: Sendable {
    /// Canlı metni üretilecek konuşmacılar (sesi başlamış olanlar): sessiz akış için Deepgram bağlantısı açılmaz.
    public let speakers: Set<Speaker>
    /// Mac'teki yazıya dökmenin ayarları; `recordingDirectory` alanı kullanılmaz.
    public let local: LiveSessionConfig
    /// Mac motoru hazırlanırken (model inerken) konuşmacı başına bekletilen en uzun ses; daha eskisi canlı metne
    /// katılmaz (kayıtta durur, son geçiş kapsar).
    public let maxPendingAudioSec: Double

    public init(speakers: Set<Speaker>, local: LiveSessionConfig, maxPendingAudioSec: Double) {
        self.speakers = speakers
        self.local = local
        self.maxPendingAudioSec = maxPendingAudioSec
    }
}

/// Mac'e geçişten sonraki bölüm numaralarının başlangıcı: Deepgram bölümleriyle çakışmasın.
let localSegmentIndexBase: Int = 2_000_000

private let hybridSampleRate: Int = 16000
private let hybridLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HybridLiveSession")

/// Abonelik sürümünün canlı oturumu: kaydı süren (`startHybridRecording`) iki ses akışının canlı metnini Deepgram'la (bulut) üretir;
/// Deepgram akışı kalıcı olarak durursa (jeton alınamadı: bütçe, sunucu, ağ; ya da bağlantı kurulamadı) oturum Mac'teki
/// motora (WhisperKit) geçer ve `.liveEngineFellBack` yayınlar. `localEngine` motoru gerektiğinde hazırlar (ilk seferde
/// modeli indirir); hazırlanırken gelen ses `maxPendingAudioSec`'e dek bekletilip sonra yazıya dökülür. Motor
/// hazırlanamazsa canlı metin durur (`.streamFailed`), kayıt sürer. Mac'te başlayan oturum (`.local`) aynı yolu kullanır.
///
/// İki giriş akışı bitince kalan metin üretilir ve olay akışı biter; motor hazırlanırken biterse beklenmez (son geçiş
/// kaydın tamamını yazıya döker). Kullanıcı dili değiştirirse o anki motor yeni dile geçer, sonraki geçiş de o dille olur.
public func runHybridLiveSession(
    config: HybridLiveSessionConfig,
    start: HybridLiveStart,
    localEngine: @escaping @Sendable () async throws -> any TranscriptionEngine,
    recording: HybridRecording
) -> LiveSessionHandle {
    let events: AsyncStream<LiveSessionEvent> = recording.events
    let sink: AsyncStream<LiveSessionEvent>.Continuation = recording.sink
    let recorded: [(Speaker, AsyncStream<[Float]>)] = [(.me, recording.me), (.others, recording.others)]
    let maxPendingSamples: Int = Int(config.maxPendingAudioSec * Double(hybridSampleRate))
    let liveSpeakers: [Speaker] = [Speaker.me, Speaker.others].filter { config.speakers.contains($0) }
    let router: HybridRouter
    switch start {
    case .deepgram(let source):
        var inputs: [Speaker: AsyncStream<[Float]>.Continuation] = [:]
        var streams: [(Speaker, DeepgramStream)] = []
        for speaker in liveSpeakers {
            let (audio, input): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
            inputs[speaker] = input
            streams.append((speaker, startDeepgramStream(token: source.token, options: source.options, language: source.language, keyterms: source.keyterms, audio: audio)))
        }
        router = HybridRouter(backend: .deepgram(inputs: inputs, streams: streams.map(\.1)), consumers: streams.count, maxPendingSamples: maxPendingSamples)
        for (speaker, stream) in streams {
            Task {
                await consumeDeepgram(speaker: speaker, stream: stream, router: router, config: config, localEngine: localEngine, events: sink)
            }
        }
    case .local:
        router = HybridRouter(backend: .preparingLocal, consumers: 0, maxPendingSamples: maxPendingSamples)
        startLocalTranscription(router: router, config: config, localEngine: localEngine, events: sink)
    }

    Task {
        await withTaskGroup(of: Void.self) { (group: inout TaskGroup<Void>) -> Void in
            for (speaker, audio) in recorded {
                group.addTask {
                    for await chunk in audio {
                        await router.route(speaker: speaker, chunk: chunk)
                    }
                    await router.end(speaker: speaker)
                }
            }
        }
        await router.drain()
        sink.finish()
    }
    return LiveSessionHandle(events: events) { (language: MeetingLanguage) async -> Void in
        let backend: HybridBackend = await router.lock(language: language)
        sink.yield(.languageLocked(language))
        switch backend {
        case .deepgram(_, let streams):
            for stream in streams {
                await stream.switchLanguage(to: language)
            }
        case .local(_, let handle):
            await handle.setLanguage(language)
        case .preparingLocal, .unavailable:
            // Mac motoru başlarken kilitli dili alır.
            break
        }
    }
}

/// Hibrit oturumun o anki yazıya dökme arka ucu.
private enum HybridBackend: Sendable {
    case deepgram(inputs: [Speaker: AsyncStream<[Float]>.Continuation], streams: [DeepgramStream])
    /// Mac motoru hazırlanıyor: ses bekletilir.
    case preparingLocal
    case local(inputs: [Speaker: AsyncStream<[Float]>.Continuation], handle: LiveSessionHandle)
    /// Mac motoru hazırlanamadı: canlı metin yok, kayıt sürer.
    case unavailable
}

/// Deepgram akışı durunca verilen karar.
private enum FallbackDecision {
    /// Mac'e geçiş başladı.
    case started
    /// Geçiş zaten başlamış (diğer akış durdu) ya da oturum Mac'te.
    case alreadyLocal
    /// İki giriş de bitti: geçilecek ses yok.
    case ended
}

/// Mac'teki yazıya dökmenin zamanı başladığı mutlak konum (saniye), konuşmacı başına.
struct LocalTimeline: Sendable, Equatable {
    let meStartSec: Double
    let othersStartSec: Double

    func startSec(speaker: Speaker) -> Double {
        switch speaker {
        case .me: meStartSec
        case .others: othersStartSec
        }
    }
}

/// Sesin hangi arka uca gideceğini, geçişi, bekletilen sesi ve bitişi yönetir.
private actor HybridRouter {
    private var backend: HybridBackend
    private let maxPendingSamples: Int
    /// Konuşmacı başına arka uca verilmiş toplam örnek (kaydın zaman çizgisi).
    private var routed: [Speaker: Int] = [.me: 0, .others: 0]
    /// Mac motoru hazırlanırken bekletilen ses ve mutlak başlangıç örneği.
    private var pending: [Speaker: [Float]] = [.me: [], .others: []]
    private var pendingStart: [Speaker: Int] = [.me: 0, .others: 0]
    private var ended: Set<Speaker> = []
    private var lockedLanguage: MeetingLanguage?
    /// Olayları oturuma aktaran ve henüz bitmemiş tüketiciler (Deepgram akışları, Mac oturumu).
    private var activeConsumers: Int
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(backend: HybridBackend, consumers: Int, maxPendingSamples: Int) {
        self.backend = backend
        self.activeConsumers = consumers
        self.maxPendingSamples = maxPendingSamples
    }

    func route(speaker: Speaker, chunk: [Float]) {
        routed[speaker, default: 0] += chunk.count
        switch backend {
        case .deepgram(let inputs, _), .local(let inputs, _):
            inputs[speaker]?.yield(chunk)
        case .preparingLocal:
            // Yerinde eklenir (sözlüğün `default:` alt simgesi değiştirerek erişir): her parçada tüm tamponu kopyalamak
            // 10 dakikalık bekletmede saniyede yüzlerce MB kopya ederdi.
            pending[speaker, default: []].append(contentsOf: chunk)
            // Her parçada kırpmak pahalı: sınır 10 sn aşılınca bir kez kırpılır.
            let count: Int = pending[speaker, default: []].count
            if count > maxPendingSamples + hybridSampleRate * 10 {
                let excess: Int = count - maxPendingSamples
                pending[speaker, default: []].removeFirst(excess)
                pendingStart[speaker, default: 0] += excess
            }
        case .unavailable:
            break
        }
    }

    func end(speaker: Speaker) {
        ended.insert(speaker)
        switch backend {
        case .deepgram(let inputs, _), .local(let inputs, _):
            inputs[speaker]?.finish()
        case .preparingLocal, .unavailable:
            break
        }
    }

    /// Deepgram akışı durdu: ilk duran akış geçişi başlatır (Deepgram girişleri kapanır, ses bekletilmeye başlar).
    func beginFallback() -> FallbackDecision {
        guard case .deepgram(let inputs, _) = backend else {
            return .alreadyLocal
        }
        guard ended.count < 2 else {
            return .ended
        }
        for input in inputs.values {
            input.finish()
        }
        backend = .preparingLocal
        for speaker in [Speaker.me, Speaker.others] {
            pending[speaker] = []
            pendingStart[speaker] = routed[speaker, default: 0]
        }
        return .started
    }

    /// Mac motoru hazır: girişler bağlanır, bekleyen ses aktarılır, bitmiş konuşmacıların girişi kapanır. Mac zamanının
    /// mutlak başlangıcı döner; iki giriş de bittiyse nil (Mac oturumu başlatılmaz).
    func activateLocal(inputs: [Speaker: AsyncStream<[Float]>.Continuation], handle: LiveSessionHandle) -> LocalTimeline? {
        guard case .preparingLocal = backend, ended.count < 2 else {
            pending = [.me: [], .others: []]
            return nil
        }
        for (speaker, input) in inputs {
            let buffered: [Float] = pending[speaker, default: []]
            if !buffered.isEmpty {
                input.yield(buffered)
            }
            if ended.contains(speaker) {
                input.finish()
            }
        }
        let timeline: LocalTimeline = LocalTimeline(
            meStartSec: Double(pendingStart[.me, default: 0]) / Double(hybridSampleRate),
            othersStartSec: Double(pendingStart[.others, default: 0]) / Double(hybridSampleRate)
        )
        pending = [.me: [], .others: []]
        backend = .local(inputs: inputs, handle: handle)
        activeConsumers += 1
        return timeline
    }

    /// Mac motoru hazırlanamadı: bekletilen ses bırakılır, canlı metin durur.
    func localUnavailable() {
        pending = [.me: [], .others: []]
        backend = .unavailable
    }

    func lock(language: MeetingLanguage) -> HybridBackend {
        lockedLanguage = language
        return backend
    }

    func locked() -> MeetingLanguage? {
        lockedLanguage
    }

    func consumerFinished() {
        activeConsumers -= 1
        guard activeConsumers == 0 else {
            return
        }
        let waiters: [CheckedContinuation<Void, Never>] = drainWaiters
        drainWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Tüm tüketiciler bitene dek bekler (iki giriş bittikten sonra çağrılır).
    func drain() async {
        guard activeConsumers > 0 else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) -> Void in
            drainWaiters.append(continuation)
        }
    }
}

/// Deepgram olaylarını bölümlere çevirir; akış kalıcı olarak durursa Mac'e geçişi başlatır.
private func consumeDeepgram(
    speaker: Speaker,
    stream: DeepgramStream,
    router: HybridRouter,
    config: HybridLiveSessionConfig,
    localEngine: @escaping @Sendable () async throws -> any TranscriptionEngine,
    events: AsyncStream<LiveSessionEvent>.Continuation
) async {
    var index: Int = 0
    for await event in stream.events {
        switch event {
        case .partial(let text, let start, let end):
            events.yield(.segment(LiveSegment(
                id: SegmentID(speaker: speaker, index: index), startSec: start, endSec: end, text: text, isFinal: false, failureMessage: nil, person: nil
            )))
        case .final(let text, let start, let end):
            // Boş kesin sonuç da yayınlanır: reducer ekrandaki geçici metni siler.
            events.yield(.segment(LiveSegment(
                id: SegmentID(speaker: speaker, index: index), startSec: start, endSec: end, text: text, isFinal: true, failureMessage: nil, person: nil
            )))
            index += 1
        case .failed(let message):
            // Mac'e geçişte bölüm numaraları başka yerden başlar: bu kimliğin geçici metni hiç yenilenmez, silinir.
            events.yield(.segment(clearingPartial(id: SegmentID(speaker: speaker, index: index))))
            switch await router.beginFallback() {
            case .started:
                hybridLogger.warning("Deepgram akışı durdu, canlı metin Mac'e geçiyor, konuşmacı: \(speaker.rawValue, privacy: .public), neden: \(message, privacy: .private)")
                events.yield(.liveEngineFellBack(message: message))
                startLocalTranscription(router: router, config: config, localEngine: localEngine, events: events)
            case .alreadyLocal:
                break
            case .ended:
                events.yield(.streamFailed(speaker: speaker, message: message))
            }
        case .incomplete(let untranscribedSec):
            events.yield(.streamIncomplete(speaker: speaker, untranscribedSec: untranscribedSec))
        }
    }
    await router.consumerFinished()
}

/// Mac motorunu hazırlar ve bekletilen sesten başlayarak Mac oturumunu çalıştırır; olayları zaman çizgisine kaydırıp
/// oturuma aktarır. Motor hazırlanamazsa canlı metni sesi olan konuşmacılar için durdurur.
private func startLocalTranscription(
    router: HybridRouter,
    config: HybridLiveSessionConfig,
    localEngine: @escaping @Sendable () async throws -> any TranscriptionEngine,
    events: AsyncStream<LiveSessionEvent>.Continuation
) {
    Task {
        let engine: any TranscriptionEngine
        do {
            engine = try await localEngine()
        } catch {
            hybridLogger.error("Mac'teki konuşma tanıma hazırlanamadı, canlı metin durdu, hata: \(String(describing: error), privacy: .private)")
            await router.localUnavailable()
            let message: String = userFacingMessage(error: error)
            for speaker in [Speaker.me, Speaker.others] where config.speakers.contains(speaker) {
                events.yield(.streamFailed(speaker: speaker, message: message))
            }
            return
        }
        let (meAudio, meInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let (othersAudio, othersInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let (localEvents, localSink): (AsyncStream<LiveSessionEvent>, AsyncStream<LiveSessionEvent>.Continuation) =
            AsyncStream.makeStream(of: LiveSessionEvent.self)
        let locked: MeetingLanguage? = await router.locked()
        let local: LiveSessionConfig = LiveSessionConfig(
            languageMode: locked.map { (language: MeetingLanguage) -> LanguageMode in .fixed(language) } ?? config.local.languageMode,
            segmenter: config.local.segmenter,
            recordingDirectory: config.local.recordingDirectory,
            partialIntervalSec: config.local.partialIntervalSec,
            minPartialSpeechSec: config.local.minPartialSpeechSec,
            languageLockAfterSec: config.local.languageLockAfterSec,
            candidateLanguages: config.local.candidateLanguages
        )
        let handle: LiveSessionHandle = runTranscriptionPipeline(
            config: local, engine: engine, meAudio: meAudio, othersAudio: othersAudio, events: localEvents, eventSink: localSink
        )
        guard let timeline = await router.activateLocal(inputs: [.me: meInput, .others: othersInput], handle: handle) else {
            // Oturum motor hazırlanırken bitti: son geçiş kaydın tamamını yazıya döker.
            hybridLogger.info("Mac motoru hazır olduğunda oturum bitmişti, Mac oturumu başlatılmadı")
            meInput.finish()
            othersInput.finish()
            return
        }
        hybridLogger.info("Canlı metin Mac'te sürüyor, başlangıç: \(timeline.othersStartSec, privacy: .public) sn")
        for await event in localEvents {
            if let shifted = shiftedLocalEvent(event: event, timeline: timeline) {
                events.yield(shifted)
            }
        }
        await router.consumerFinished()
    }
}

/// Mac oturumunun olayını hibrit oturumun zaman çizgisine taşır: bölüm zamanları Mac zamanının başladığı konum kadar
/// kayar, numaralar Deepgram bölümleriyle çakışmasın diye `localSegmentIndexBase`'den başlar. Yakalama sonu hibrit
/// kayıttan bildirildiği için atılır. Saf fonksiyondur.
func shiftedLocalEvent(event: LiveSessionEvent, timeline: LocalTimeline) -> LiveSessionEvent? {
    switch event {
    case .segment(let segment):
        let offset: Double = timeline.startSec(speaker: segment.id.speaker)
        return .segment(LiveSegment(
            id: SegmentID(speaker: segment.id.speaker, index: segment.id.index + localSegmentIndexBase),
            startSec: segment.startSec + offset,
            endSec: segment.endSec + offset,
            text: segment.text,
            isFinal: segment.isFinal,
            failureMessage: segment.failureMessage,
            person: segment.person
        ))
    case .captureEnded:
        return nil
    case .languageLocked, .recordingFailed, .speakersAssigned, .streamFailed, .streamIncomplete, .diarizationFailed, .liveEngineFellBack:
        return event
    }
}
