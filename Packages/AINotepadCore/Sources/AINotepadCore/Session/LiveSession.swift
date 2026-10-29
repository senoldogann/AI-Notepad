import Foundation
import os

/// Canlı oturum ayarları.
public struct LiveSessionConfig: Sendable {
    public let languageMode: LanguageMode
    public let segmenter: SegmenterConfig
    /// `me.caf` ve `others.caf` dosyalarının yazılacağı klasör.
    public let recordingDirectory: URL
    /// Açık bölüm için geçici metin üretme aralığı.
    public let partialIntervalSec: Double
    /// Geçici metin üretmek için açık bölümde gereken en az konuşma.
    public let minPartialSpeechSec: Double
    /// Otomatik modda dilin kilitlendiği toplantı süresi.
    public let languageLockAfterSec: Double
    /// Otomatik modda aday diller (ilki ana toplantı dili; bkz. `automaticCandidates`).
    public let candidateLanguages: [MeetingLanguage]

    public init(
        languageMode: LanguageMode,
        segmenter: SegmenterConfig,
        recordingDirectory: URL,
        partialIntervalSec: Double,
        minPartialSpeechSec: Double,
        languageLockAfterSec: Double,
        candidateLanguages: [MeetingLanguage]
    ) {
        self.languageMode = languageMode
        self.segmenter = segmenter
        self.recordingDirectory = recordingDirectory
        self.partialIntervalSec = partialIntervalSec
        self.minPartialSpeechSec = minPartialSpeechSec
        self.languageLockAfterSec = languageLockAfterSec
        self.candidateLanguages = candidateLanguages
    }
}

/// Canlı oturumu çalıştırır: iki ses akışını kaydeder, bölümler, yazıya döker ve olay yayınlar.
///
/// İki giriş akışı bitince (yakalama durdurulunca) kalan bölümler işlenir ve olay akışı biter.
/// Motor çağrıları tek bir seri işçiden yapılır. Kullanıcı dili değiştirirse sonraki işler yeni dille yapılır.
public func runLiveSession(
    config: LiveSessionConfig,
    engine: any TranscriptionEngine,
    meAudio: AsyncStream<[Float]>,
    othersAudio: AsyncStream<[Float]>
) -> LiveSessionHandle {
    let (events, eventSink): (AsyncStream<LiveSessionEvent>, AsyncStream<LiveSessionEvent>.Continuation) =
        AsyncStream.makeStream(of: LiveSessionEvent.self)
    let recordedMe: AsyncStream<[Float]> = recordedStream(speaker: .me, audio: meAudio, directory: config.recordingDirectory, events: eventSink)
    let recordedOthers: AsyncStream<[Float]> = recordedStream(speaker: .others, audio: othersAudio, directory: config.recordingDirectory, events: eventSink)
    return runTranscriptionPipeline(config: config, engine: engine, meAudio: recordedMe, othersAudio: recordedOthers, events: events, eventSink: eventSink)
}

/// Konuşmacının sesini `<konuşmacı>.caf` dosyasına yazar ve her parçayı olduğu gibi aktarır. Dosya açılamaz ya da
/// yazılamazsa bir kez `.recordingFailed` yayınlanır, aktarım kayıtsız sürer; giriş bitince dosya kapanır,
/// `.captureEnded` yayınlanır ve çıkış akışı biter.
func recordedStream(speaker: Speaker, audio: AsyncStream<[Float]>, directory: URL, events: AsyncStream<LiveSessionEvent>.Continuation) -> AsyncStream<[Float]> {
    let (output, sink): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    Task {
        var recorder: CafRecorder?
        do {
            recorder = try CafRecorder(fileURL: directory.appending(path: "\(speaker.rawValue).caf"))
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
            sink.yield(chunk)
        }
        recorder?.close()
        // Olay, çıkış bitmeden yayınlanır: çıkışı tüketen oturum bitince olay akışını kapatır.
        events.yield(.captureEnded(speaker: speaker))
        sink.finish()
    }
    return output
}

/// Kaydedilmiş (ya da kaydedilmesi gerekmeyen) iki ses akışını bölümler ve yazıya döker; olaylar `eventSink`'e gider,
/// iki akış bitip kalan işler yapılınca `eventSink` biter. Kayıt yapmaz (`config.recordingDirectory` kullanılmaz).
func runTranscriptionPipeline(
    config: LiveSessionConfig,
    engine: any TranscriptionEngine,
    meAudio: AsyncStream<[Float]>,
    othersAudio: AsyncStream<[Float]>,
    events: AsyncStream<LiveSessionEvent>,
    eventSink: AsyncStream<LiveSessionEvent>.Continuation
) -> LiveSessionHandle {
    let (jobs, jobSink): (AsyncStream<TranscriptionJob>, AsyncStream<TranscriptionJob>.Continuation) =
        AsyncStream.makeStream(of: TranscriptionJob.self)
    let tracker: OpenSegmentTracker = OpenSegmentTracker()
    let languageRequest: LanguageRequest = LanguageRequest()

    Task {
        let worker: Task<Void, Never> = Task {
            await runTranscriptionWorker(jobs: jobs, engine: engine, config: config, tracker: tracker, languageRequest: languageRequest, events: eventSink)
        }
        let ticker: Task<Void, Never> = Task {
            await runPartialTicker(config: config, tracker: tracker, jobs: jobSink)
        }
        await withTaskGroup(of: Void.self) { (group: inout TaskGroup<Void>) -> Void in
            group.addTask {
                await runCapture(speaker: .me, audio: meAudio, config: config, tracker: tracker, jobs: jobSink)
            }
            group.addTask {
                await runCapture(speaker: .others, audio: othersAudio, config: config, tracker: tracker, jobs: jobSink)
            }
        }
        ticker.cancel()
        await ticker.value
        jobSink.finish()
        await worker.value
        eventSink.finish()
    }
    return LiveSessionHandle(events: events) { (language: MeetingLanguage) async -> Void in
        await languageRequest.request(language: language)
        eventSink.yield(.languageLocked(language))
    }
}

/// Kullanıcının kayıt sırasında seçtiği dil; işçi bir sonraki işte alır.
actor LanguageRequest {
    private var pending: MeetingLanguage?

    func request(language: MeetingLanguage) {
        pending = language
    }

    /// Bekleyen isteği döndürür ve temizler.
    func take() -> MeetingLanguage? {
        defer { pending = nil }
        return pending
    }

    /// Kullanıcı dil seçti ama işçi henüz uygulamadı: otomatik kilit bu arada konmamalı.
    func hasPending() -> Bool {
        pending != nil
    }
}

private let sessionLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "LiveSession")

/// Seri işçiye verilen yazıya dökme işi.
struct TranscriptionJob: Sendable {
    let id: SegmentID
    let samples: [Float]
    let startSec: Double
    let endSec: Double
    let isFinal: Bool
}

/// Açık bölümleri ve kuyruktaki iş sayısını tutar; kısmi iş üretimini buna göre kısıtlar.
actor OpenSegmentTracker {
    private var openSegments: [Speaker: OpenSegment] = [:]
    private var pendingJobs: Int = 0

    func update(speaker: Speaker, open: OpenSegment?) {
        openSegments[speaker] = open
    }

    func jobEnqueued() {
        pendingJobs += 1
    }

    func jobFinished() {
        pendingJobs -= 1
    }

    /// Kuyruk boşsa ve yeterli konuşma içeren açık bölüm varsa onu döndürür ve işi sayar.
    /// Önce "Diğerleri", sonra "Sen".
    func takePartialCandidate(minSpeechSamples: Int) -> (speaker: Speaker, segment: OpenSegment)? {
        guard pendingJobs == 0 else {
            return nil
        }
        for speaker in [Speaker.others, Speaker.me] {
            if let segment = openSegments[speaker], segment.speechSampleCount >= minSpeechSamples {
                pendingJobs += 1
                return (speaker, segment)
            }
        }
        return nil
    }
}

/// Bir konuşmacının ses akışını bölümleyip kesin işleri kuyruğa koyar (kayıt `recordedStream`'dedir).
private func runCapture(
    speaker: Speaker,
    audio: AsyncStream<[Float]>,
    config: LiveSessionConfig,
    tracker: OpenSegmentTracker,
    jobs: AsyncStream<TranscriptionJob>.Continuation
) async {
    var state: SegmenterState = .initial
    for await chunk in audio {
        let output: SegmenterOutput = segmentAudio(state: state, newSamples: chunk, config: config.segmenter)
        state = output.state
        await tracker.update(speaker: speaker, open: state.open)
        await enqueueFinals(speaker: speaker, segments: output.closed, config: config, tracker: tracker, jobs: jobs)
    }

    let flushed: SegmenterOutput = flushSegmenter(state: state, config: config.segmenter)
    await tracker.update(speaker: speaker, open: nil)
    await enqueueFinals(speaker: speaker, segments: flushed.closed, config: config, tracker: tracker, jobs: jobs)
}

private func enqueueFinals(
    speaker: Speaker,
    segments: [ClosedSegment],
    config: LiveSessionConfig,
    tracker: OpenSegmentTracker,
    jobs: AsyncStream<TranscriptionJob>.Continuation
) async {
    for segment in segments {
        await tracker.jobEnqueued()
        jobs.yield(makeJob(speaker: speaker, index: segment.index, startSample: segment.startSample, samples: segment.samples, isFinal: true, sampleRate: config.segmenter.sampleRate))
    }
}

/// Belirli aralıklarla, işçi boştaysa açık bölüm için geçici iş üretir.
private func runPartialTicker(
    config: LiveSessionConfig,
    tracker: OpenSegmentTracker,
    jobs: AsyncStream<TranscriptionJob>.Continuation
) async {
    let minSpeechSamples: Int = Int(config.minPartialSpeechSec * Double(config.segmenter.sampleRate))
    while !Task.isCancelled {
        do {
            try await Task.sleep(for: .seconds(config.partialIntervalSec))
        } catch {
            // Yalnızca iptalde fırlatır: oturum bitiyor.
            return
        }
        if let candidate = await tracker.takePartialCandidate(minSpeechSamples: minSpeechSamples) {
            jobs.yield(makeJob(
                speaker: candidate.speaker,
                index: candidate.segment.index,
                startSample: candidate.segment.startSample,
                samples: candidate.segment.samples,
                isFinal: false,
                sampleRate: config.segmenter.sampleRate
            ))
        }
    }
}

private func makeJob(speaker: Speaker, index: Int, startSample: Int, samples: [Float], isFinal: Bool, sampleRate: Int) -> TranscriptionJob {
    let rate: Double = Double(sampleRate)
    return TranscriptionJob(
        id: SegmentID(speaker: speaker, index: index),
        samples: samples,
        startSec: Double(startSample) / rate,
        endSec: Double(startSample + samples.count) / rate,
        isFinal: isFinal
    )
}

/// Seri işçinin işler arasında taşıdığı durum.
struct WorkerState: Sendable {
    let votes: LanguageVotes
    let locked: MeetingLanguage?
    /// Kesin metni yayınlanmış bölümler.
    let finalized: Set<SegmentID>
}

/// İşleri sırayla yazıya döker; dil oylarını ve kilidi yönetir.
private func runTranscriptionWorker(
    jobs: AsyncStream<TranscriptionJob>,
    engine: any TranscriptionEngine,
    config: LiveSessionConfig,
    tracker: OpenSegmentTracker,
    languageRequest: LanguageRequest,
    events: AsyncStream<LiveSessionEvent>.Continuation
) async {
    var state: WorkerState = WorkerState(votes: .empty, locked: fixedLanguage(mode: config.languageMode), finalized: [])
    for await job in jobs {
        if let requested = await languageRequest.take() {
            state = WorkerState(votes: state.votes, locked: requested, finalized: state.finalized)
            // Arada otomatik kilit yayınlanmış olabilir: son olay kullanıcının seçimi olsun.
            events.yield(.languageLocked(requested))
        }
        state = await processJob(job: job, state: state, engine: engine, config: config, languageRequest: languageRequest, events: events)
        await tracker.jobFinished()
    }
}

private func fixedLanguage(mode: LanguageMode) -> MeetingLanguage? {
    guard case .fixed(let language) = mode else {
        return nil
    }
    return language
}

/// Tek bir işi yazıya döker, olayları yayınlar ve yeni işçi durumunu döndürür.
private func processJob(
    job: TranscriptionJob,
    state: WorkerState,
    engine: any TranscriptionEngine,
    config: LiveSessionConfig,
    languageRequest: LanguageRequest,
    events: AsyncStream<LiveSessionEvent>.Continuation
) async -> WorkerState {
    // Kesinleşmiş bölümün geç kalan geçici işi eski metni geri getirmesin.
    if !job.isFinal && state.finalized.contains(job.id) {
        return state
    }
    let finalized: Set<SegmentID> = job.isFinal ? state.finalized.union([job.id]) : state.finalized

    do {
        var votes: LanguageVotes = state.votes
        let language: MeetingLanguage
        if let locked = state.locked {
            language = locked
        } else if job.isFinal {
            let logProbs: [String: Float] = try await engine.detectLanguage(samples: job.samples)
            votes = addVote(votes: votes, logProbs: logProbs, candidates: config.candidateLanguages)
            language = resolveSegmentLanguage(
                detected: pickLanguage(logProbs: logProbs, candidates: config.candidateLanguages), votes: votes, candidates: config.candidateLanguages
            )
        } else if let leading = leadingLanguage(votes: votes, candidates: config.candidateLanguages) {
            language = leading
        } else {
            // Henüz hiç dil oyu yok: geçici metin üretilemez.
            return WorkerState(votes: votes, locked: nil, finalized: finalized)
        }

        let text: String = try await engine.transcribe(samples: job.samples, language: language)
        events.yield(.segment(LiveSegment(id: job.id, startSec: job.startSec, endSec: job.endSec, text: text, isFinal: job.isFinal, failureMessage: nil, person: nil)))

        guard state.locked == nil, job.isFinal, !(await languageRequest.hasPending()),
              let lockedNow = lockedLanguage(votes: votes, elapsedSec: job.endSec, lockAfterSec: config.languageLockAfterSec, candidates: config.candidateLanguages)
        else {
            return WorkerState(votes: votes, locked: state.locked, finalized: finalized)
        }
        events.yield(.languageLocked(lockedNow))
        return WorkerState(votes: votes, locked: lockedNow, finalized: finalized)
    } catch {
        sessionLogger.error("Bölüm yazıya dökülemedi: \(String(describing: error), privacy: .private)")
        if job.isFinal {
            events.yield(.segment(LiveSegment(
                id: job.id,
                startSec: job.startSec,
                endSec: job.endSec,
                text: "",
                isFinal: true,
                failureMessage: userFacingMessage(error: error),
                person: nil
            )))
        }
        return WorkerState(votes: state.votes, locked: state.locked, finalized: finalized)
    }
}
