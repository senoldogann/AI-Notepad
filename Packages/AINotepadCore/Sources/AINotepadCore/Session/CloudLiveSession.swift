import Foundation
import os

/// Bulut (Deepgram + ElevenLabs) canlı oturum ayarları.
public struct CloudSessionConfig: Sendable {
    public let languageMode: LanguageMode
    /// `me.caf` ve `others.caf` dosyalarının yazılacağı klasör.
    public let recordingDirectory: URL
    public let deepgramKey: String
    public let elevenLabsKey: String
    /// İlk konuşmacı ayırma penceresinin zamanı; otomatik modda dil de burada algılanır.
    public let firstDiarizationAfterSec: Double
    /// Sonraki pencerelerin aralığı.
    public let diarizationIntervalSec: Double
    /// Her pencerede gönderilen "Diğerleri" sesinin uzunluğu.
    public let diarizationWindowSec: Double
    /// Bundan kısa pencere gönderilmez.
    public let minDiarizationAudioSec: Double
    /// Otomatik modda dili kilitlemek için gereken en düşük ElevenLabs dil olasılığı.
    public let languageConfidence: Double
    /// Deepgram'a verilen adlar ve terimler (bkz. `meetingKeyterms`).
    public let keyterms: [String]
    /// Ses izi (geri dönen konuşmacıyı tanımak için); kapalıysa nil.
    public let voiceEmbedder: (any VoiceEmbedder)?
    /// Otomatik modda Deepgram'ın başladığı dil (ana toplantı dili); ilk konuşmacı ayırma penceresi asıl dili bulur.
    public let automaticStartLanguage: MeetingLanguage

    public init(
        languageMode: LanguageMode,
        recordingDirectory: URL,
        deepgramKey: String,
        elevenLabsKey: String,
        firstDiarizationAfterSec: Double,
        diarizationIntervalSec: Double,
        diarizationWindowSec: Double,
        minDiarizationAudioSec: Double,
        languageConfidence: Double,
        keyterms: [String],
        voiceEmbedder: (any VoiceEmbedder)?,
        automaticStartLanguage: MeetingLanguage
    ) {
        self.languageMode = languageMode
        self.recordingDirectory = recordingDirectory
        self.deepgramKey = deepgramKey
        self.elevenLabsKey = elevenLabsKey
        self.firstDiarizationAfterSec = firstDiarizationAfterSec
        self.diarizationIntervalSec = diarizationIntervalSec
        self.diarizationWindowSec = diarizationWindowSec
        self.minDiarizationAudioSec = minDiarizationAudioSec
        self.languageConfidence = languageConfidence
        self.keyterms = keyterms
        self.voiceEmbedder = voiceEmbedder
        self.automaticStartLanguage = automaticStartLanguage
    }
}

/// Bulut canlı oturumu: iki ses akışını kaydeder, Deepgram ile canlı yazıya döker ve "Diğerleri"ni
/// ElevenLabs ile belirli aralıklarla konuşmacılara ayırır. Otomatik modda ana toplantı diliyle başlar; ilk güvenilir
/// dil sonucu desteklenen başka bir dilse iki akış o dile geçer.
///
/// İki giriş akışı bitince Deepgram akışları boşalır, son bir ayırma penceresi çalışır ve olay akışı biter.
/// Kullanıcı kayıt sırasında dili değiştirirse iki akış o andan itibaren yeni dile geçer ve dil kilitlenir.
public func runCloudLiveSession(
    config: CloudSessionConfig,
    meAudio: AsyncStream<[Float]>,
    othersAudio: AsyncStream<[Float]>
) -> LiveSessionHandle {
    let (events, sink): (AsyncStream<LiveSessionEvent>, AsyncStream<LiveSessionEvent>.Continuation) =
        AsyncStream.makeStream(of: LiveSessionEvent.self)
    let state: CloudSessionState = CloudSessionState(windowSamples: Int(config.diarizationWindowSec * Double(cloudSampleRate)))
    let startLanguage: MeetingLanguage = initialLanguage(languageMode: config.languageMode, automaticStart: config.automaticStartLanguage)
    let (meForward, meInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    let (othersForward, othersInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    let meStream: DeepgramStream = startDeepgramStream(apiKey: config.deepgramKey, language: startLanguage, keyterms: config.keyterms, audio: meForward)
    let othersStream: DeepgramStream = startDeepgramStream(apiKey: config.deepgramKey, language: startLanguage, keyterms: config.keyterms, audio: othersForward)
    let streams: [DeepgramStream] = [meStream, othersStream]

    Task {
        let diarizer: Task<Void, Never> = Task {
            await runDiarizationSchedule(config: config, state: state, streams: streams, events: sink)
        }
        await withTaskGroup(of: Void.self) { (group: inout TaskGroup<Void>) -> Void in
            group.addTask {
                await pumpAudio(speaker: .me, audio: meAudio, config: config, forward: meInput, events: sink) { (_: [Float]) async -> Void in }
            }
            group.addTask {
                // "Diğerleri" sesi ayrıca konuşmacı ayırma tamponuna gider.
                await pumpAudio(speaker: .others, audio: othersAudio, config: config, forward: othersInput, events: sink) { (chunk: [Float]) async -> Void in
                    await state.appendOthers(samples: chunk)
                }
            }
            group.addTask {
                await consumeTranscripts(speaker: .me, stream: meStream, state: state, events: sink)
            }
            group.addTask {
                await consumeTranscripts(speaker: .others, stream: othersStream, state: state, events: sink)
            }
        }
        // İptal yerine durdurma işareti: süren ElevenLabs isteği yarıda kesilmez (sahte iptal hatası olmaz).
        await state.requestStop()
        // Oturumun son dakikası da etiketlensin; ağ takılırsa (her pencere 60 sn × 3 deneme) "Bitiriliyor…" dakikalarca
        // sürmesin diye en fazla `stopLabelingDeadlineSec` beklenir. Son geçiş konuşmacıları kaydın tamamından yeniden
        // ayırdığı için geç kalan etiketler kaybolmaz.
        let labeled: Bool = await finishesWithin(seconds: stopLabelingDeadlineSec) {
            await diarizer.value
            await runDiarizationWindow(config: config, state: state, streams: streams, events: sink)
        }
        if !labeled {
            cloudLogger.warning("Kapanışta konuşmacı ayırma süre sınırında bitmedi, süre: \(stopLabelingDeadlineSec, privacy: .public)")
        }
        sink.finish()
    }
    return LiveSessionHandle(events: events) { (language: MeetingLanguage) async -> Void in
        // Önce kilit: süren ayırma penceresi otomatik algılamayla dili geri değiştirmesin. Etiket hemen güncellenir;
        // akışlar yeniden bağlanırken (ağ yoksa uzun sürebilir) beklenmez.
        await state.lock(language: language, events: sink)
        await switchStreams(streams: streams, state: state)
    }
}

/// İki akışı kilitli dile geçirir. Dil her akıştan hemen önce yeniden okunur ("son seçim kazanır"): otomatik
/// geçiş sürerken kullanıcı dil seçerse akışlar farklı dillerde kalmaz.
private func switchStreams(streams: [DeepgramStream], state: CloudSessionState) async {
    for stream in streams {
        guard let language = await state.locked() else {
            return
        }
        await stream.switchLanguage(to: language)
    }
}

private let cloudSampleRate: Int = 16000
/// Kayıt durunca son konuşmacı etiketleri için en uzun bekleme.
private let stopLabelingDeadlineSec: Double = 20
private let cloudLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "CloudLiveSession")

/// Deepgram'ın başlangıç dili: sabit dil ya da otomatik modda ana toplantı dili.
private func initialLanguage(languageMode: LanguageMode, automaticStart: MeetingLanguage) -> MeetingLanguage {
    switch languageMode {
    case .fixed(let language): language
    case .automatic: automaticStart
    }
}

/// Görevler arasında paylaşılan oturum durumu.
private actor CloudSessionState {
    private let windowSamples: Int
    /// "Diğerleri"nin son sesi; `bufferStartSample` mutlak konumu.
    private var buffer: [Float] = []
    private var bufferStartSample: Int = 0
    private var othersFinals: [LiveSegment] = []
    private var mapping: SpeakerMapping = .initial
    private var lockedLanguage: MeetingLanguage?
    private var stopRequested: Bool = false
    /// Anahtar reddedildiyse (401/403) sonraki pencereler gönderilmez.
    private var diarizationDisabled: Bool = false
    /// Doldurulan boşlukların sayısı.
    private var gapCount: Int = 0

    init(windowSamples: Int) {
        self.windowSamples = windowSamples
    }

    func appendOthers(samples: [Float]) {
        buffer += samples
        // Her parçada kaydırmak pahalı: tampon pencerenin iki katına ulaşınca bir kez kırpılır.
        if buffer.count > windowSamples * 2 {
            let excess: Int = buffer.count - windowSamples
            buffer.removeFirst(excess)
            bufferStartSample += excess
        }
    }

    /// Son pencere sesi ve mutlak başlangıç zamanı.
    func window() -> (samples: [Float], startSec: Double) {
        let start: Int = max(0, buffer.count - windowSamples)
        return (Array(buffer[start...]), Double(bufferStartSample + start) / Double(cloudSampleRate))
    }

    /// Doldurulan boşluğun bölüm numarası.
    func nextGapIndex() -> Int {
        gapCount += 1
        return gapIndexBase + gapCount
    }

    func addOthersFinal(segment: LiveSegment) {
        othersFinals.append(segment)
    }

    func finals() -> [LiveSegment] {
        othersFinals
    }

    /// Ayırma penceresinden önce biten bölümler bir daha kelime alamaz: liste uzun toplantıda büyümesin.
    func dropFinals(endingBefore startSec: Double) {
        othersFinals.removeAll { (segment: LiveSegment) -> Bool in segment.endSec < startSec }
    }

    func currentMapping() -> SpeakerMapping {
        mapping
    }

    func setMapping(mapping newMapping: SpeakerMapping) {
        mapping = newMapping
    }

    func locked() -> MeetingLanguage? {
        lockedLanguage
    }

    /// Kullanıcının seçimi: dili kilitler ve olayı aktörün içinde yayınlar (olay sırası kilit sırasıyla aynı olsun).
    func lock(language: MeetingLanguage, events: AsyncStream<LiveSessionEvent>.Continuation) {
        lockedLanguage = language
        events.yield(.languageLocked(language))
    }

    /// Otomatik algılama: dil henüz kilitli değilse kilitler ve yayınlar; kullanıcının seçimi araya girmişse dokunmaz.
    func lockIfUnlocked(language: MeetingLanguage, events: AsyncStream<LiveSessionEvent>.Continuation) -> Bool {
        guard lockedLanguage == nil else {
            return false
        }
        lockedLanguage = language
        events.yield(.languageLocked(language))
        return true
    }

    func requestStop() {
        stopRequested = true
    }

    func isStopping() -> Bool {
        stopRequested
    }

    func disableDiarization() {
        diarizationDisabled = true
    }

    func isDiarizationDisabled() -> Bool {
        diarizationDisabled
    }
}

/// Konuşmacı sesini kaydeder, Deepgram'a iletir ve her parçayı `onChunk`'a verir.
private func pumpAudio(
    speaker: Speaker,
    audio: AsyncStream<[Float]>,
    config: CloudSessionConfig,
    forward: AsyncStream<[Float]>.Continuation,
    events: AsyncStream<LiveSessionEvent>.Continuation,
    onChunk: @Sendable ([Float]) async -> Void
) async {
    let fileURL: URL = config.recordingDirectory.appending(path: "\(speaker.rawValue).caf")
    var recorder: CafRecorder?
    do {
        recorder = try CafRecorder(fileURL: fileURL)
    } catch {
        events.yield(.recordingFailed(speaker: speaker, message: userFacingMessage(error: error)))
    }
    for await chunk in audio {
        if let activeRecorder = recorder {
            do {
                try activeRecorder.append(samples: chunk)
            } catch {
                // Kayıt bozuldu: bir kez bildir, yazıya dökmeye kayıtsız devam et.
                events.yield(.recordingFailed(speaker: speaker, message: userFacingMessage(error: error)))
                activeRecorder.close()
                recorder = nil
            }
        }
        forward.yield(chunk)
        await onChunk(chunk)
    }
    forward.finish()
    recorder?.close()
    events.yield(.captureEnded(speaker: speaker))
}

/// Deepgram olaylarını bölümlere çevirir; her kesin sonuçtan sonra bölüm numarası artar.
private func consumeTranscripts(
    speaker: Speaker,
    stream: DeepgramStream,
    state: CloudSessionState,
    events: AsyncStream<LiveSessionEvent>.Continuation
) async {
    var index: Int = 0
    for await event in stream.events {
        switch event {
        case .partial(let text, let start, let end):
            events.yield(.segment(LiveSegment(
                id: SegmentID(speaker: speaker, index: index),
                startSec: start, endSec: end, text: text, isFinal: false, failureMessage: nil, person: nil
            )))
        case .final(let text, let start, let end):
            let segment: LiveSegment = LiveSegment(
                id: SegmentID(speaker: speaker, index: index),
                startSec: start, endSec: end, text: text, isFinal: true, failureMessage: nil, person: nil
            )
            // Boş kesin sonuç da yayınlanır: reducer ekrandaki geçici metni siler.
            events.yield(.segment(segment))
            if speaker == .others, !text.isEmpty {
                await state.addOthersFinal(segment: segment)
            }
            index += 1
        case .failed(let message):
            events.yield(.streamFailed(speaker: speaker, message: message))
        case .incomplete(let untranscribedSec):
            events.yield(.streamIncomplete(speaker: speaker, untranscribedSec: untranscribedSec))
        }
    }
}

/// İlk pencere `firstDiarizationAfterSec`'te, sonrakiler `diarizationIntervalSec` aralıkla;
/// durdurma işaretine kadar. Bekleme kısa adımlarla yapılır ki durdurma hemen fark edilsin.
private func runDiarizationSchedule(
    config: CloudSessionConfig,
    state: CloudSessionState,
    streams: [DeepgramStream],
    events: AsyncStream<LiveSessionEvent>.Continuation
) async {
    var delay: Double = config.firstDiarizationAfterSec
    while true {
        let deadline: ContinuousClock.Instant = .now + .seconds(delay)
        while ContinuousClock.now < deadline {
            if await state.isStopping() {
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                // Bu görev iptal edilmez; yine de iptal gelirse zamanlayıcı biter.
                return
            }
        }
        if await state.isStopping() {
            return
        }
        await runDiarizationWindow(config: config, state: state, streams: streams, events: events)
        delay = config.diarizationIntervalSec
    }
}

/// Bir ayırma penceresi: ElevenLabs → dil kilidi (otomatik modda) → kişi eşleme → bölüm atama.
private func runDiarizationWindow(
    config: CloudSessionConfig,
    state: CloudSessionState,
    streams: [DeepgramStream],
    events: AsyncStream<LiveSessionEvent>.Continuation
) async {
    guard !(await state.isDiarizationDisabled()) else {
        return
    }
    let window: (samples: [Float], startSec: Double) = await state.window()
    await state.dropFinals(endingBefore: window.startSec)
    guard Double(window.samples.count) >= config.minDiarizationAudioSec * Double(cloudSampleRate) else {
        return
    }
    let locked: MeetingLanguage? = await state.locked()
    let requestMode: LanguageMode = locked.map { (language: MeetingLanguage) -> LanguageMode in .fixed(language) } ?? config.languageMode
    // Ses izleri ElevenLabs isteğiyle aynı anda, aynı ses üzerinde (Mac'te) çıkarılır.
    let voiceTask: Task<[VoiceCluster], any Error>? = config.voiceEmbedder.map { (embedder: any VoiceEmbedder) -> Task<[VoiceCluster], any Error> in
        Task { try await embedder.clusters(samples: window.samples) }
    }
    let result: DiarizationResult
    do {
        result = try await diarizeWithElevenLabs(apiKey: config.elevenLabsKey, samples: window.samples, languageMode: requestMode)
    } catch {
        voiceTask?.cancel()
        cloudLogger.error("Konuşmacı ayırma penceresi başarısız: \(String(describing: error), privacy: .private)")
        events.yield(.diarizationFailed(message: userFacingMessage(error: error)))
        if case CloudSTTError.http(_, let status, _) = error, status == 401 || status == 403 {
            // Anahtar reddedildi ya da kota doldu: her dakika aynı hatayı üretmek yerine ayırma durur.
            await state.disableDiarization()
        }
        return
    }

    // Oturum bitiyorsa (son pencere) dil değiştirmek yeni, sahipsiz bağlantı açar. Kilit istek sürerken
    // (kullanıcı dili seçince) konmuş olabilir: yeniden okunur.
    if case .automatic = config.languageMode, !(await state.isStopping()),
       let detected = confidentLanguage(result: result, minimumProbability: config.languageConfidence),
       await state.lockIfUnlocked(language: detected, events: events) {
        if detected != initialLanguage(languageMode: config.languageMode, automaticStart: config.automaticStartLanguage) {
            await switchStreams(streams: streams, state: state)
        }
    }

    let labelVoices: [String: Voiceprint] = await windowLabelVoices(task: voiceTask, words: result.words)
    let mapping: SpeakerMapping = applyWindow(
        mapping: await state.currentMapping(), windowWords: result.words, windowStartSec: window.startSec, labelVoices: labelVoices
    )
    await state.setMapping(mapping: mapping)
    let finals: [LiveSegment] = await state.finals()
    let assignments: [SegmentID: Int] = assignPersons(segments: finals, words: mapping.words)
    if !assignments.isEmpty {
        events.yield(.speakersAssigned(assignments))
    }
    // Deepgram'ın boş kesinleştirdiği konuşma pencerenin kelimeleriyle doldurulur (kişisiyle birlikte).
    let absoluteWords: [DiarizedWord] = result.words.map { (word: DiarizedWord) -> DiarizedWord in
        DiarizedWord(text: word.text, startSec: word.startSec + window.startSec, endSec: word.endSec + window.startSec, speaker: word.speaker)
    }
    let gaps: [TranscriptGap] = transcriptGaps(
        words: absoluteWords, persons: mapping.words.map(\.person), finals: finals,
        coveredUntilSec: finals.map(\.endSec).max() ?? 0, minWords: gapMinWords
    )
    for gap in gaps {
        let segment: LiveSegment = LiveSegment(
            id: SegmentID(speaker: .others, index: await state.nextGapIndex()),
            startSec: gap.startSec, endSec: gap.endSec, text: gap.text, isFinal: true, failureMessage: nil, person: gap.person
        )
        await state.addOthersFinal(segment: segment)
        events.yield(.segment(segment))
    }
    if !gaps.isEmpty {
        cloudLogger.info("Canlı transkriptteki boşluklar dolduruldu, adet: \(gaps.count, privacy: .public)")
    }
}

/// Penceredeki ElevenLabs etiketlerinin ses izleri. Ses izi çıkarılamazsa (model indirilemedi gibi) pencere yalnızca
/// zaman örtüşmesiyle eşlenir: hata loglanır, konuşmacı ayırma sürer.
private func windowLabelVoices(task: Task<[VoiceCluster], any Error>?, words: [DiarizedWord]) async -> [String: Voiceprint] {
    guard let task else {
        return [:]
    }
    do {
        let clusters: [VoiceCluster] = try await task.value
        return labelVoiceprints(
            spans: words.map { LabeledSpan(label: $0.speaker, startSec: $0.startSec, endSec: $0.endSec) },
            clusters: clusters
        )
    } catch {
        cloudLogger.error("Ses izi çıkarılamadı, pencere yalnızca zamanla eşlendi, hata: \(String(describing: error), privacy: .private)")
        return [:]
    }
}

/// Boşluk sayılması için gereken en az kelime (tek tük dolgu sözcükleri boşluk değildir).
private let gapMinWords: Int = 3
/// Doldurulan bölümlerin numaraları Deepgram'ınkilerle çakışmasın diye buradan başlar.
private let gapIndexBase: Int = 1_000_000

/// Dil olasılığı eşiği geçiyorsa ve desteklenen bir dilse dili döndürür. Saf fonksiyondur.
func confidentLanguage(result: DiarizationResult, minimumProbability: Double) -> MeetingLanguage? {
    guard let code = result.languageCode, let probability = result.languageProbability, probability >= minimumProbability else {
        return nil
    }
    return meetingLanguage(elevenLabsCode: code)
}

