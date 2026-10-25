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

    public init(
        languageMode: LanguageMode,
        segmenter: SegmenterConfig,
        recordingDirectory: URL,
        partialIntervalSec: Double,
        minPartialSpeechSec: Double,
        languageLockAfterSec: Double
    ) {
        self.languageMode = languageMode
        self.segmenter = segmenter
        self.recordingDirectory = recordingDirectory
        self.partialIntervalSec = partialIntervalSec
        self.minPartialSpeechSec = minPartialSpeechSec
        self.languageLockAfterSec = languageLockAfterSec
    }
}

/// Canlı oturumu çalıştırır: iki ses akışını kaydeder, bölümler, yazıya döker ve olay yayınlar.
///
/// İki giriş akışı bitince (yakalama durdurulunca) kalan bölümler işlenir ve olay akışı biter.
/// Motor çağrıları tek bir seri işçiden yapılır.
public func runLiveSession(
    config: LiveSessionConfig,
    engine: any TranscriptionEngine,
    meAudio: AsyncStream<[Float]>,
    othersAudio: AsyncStream<[Float]>
) -> AsyncStream<LiveSessionEvent> {
    let (events, eventSink): (AsyncStream<LiveSessionEvent>, AsyncStream<LiveSessionEvent>.Continuation) =
        AsyncStream.makeStream(of: LiveSessionEvent.self)
    let (jobs, jobSink): (AsyncStream<TranscriptionJob>, AsyncStream<TranscriptionJob>.Continuation) =
        AsyncStream.makeStream(of: TranscriptionJob.self)
    let tracker: OpenSegmentTracker = OpenSegmentTracker()

    Task {
        let worker: Task<Void, Never> = Task {
            await runTranscriptionWorker(jobs: jobs, engine: engine, config: config, tracker: tracker, events: eventSink)
        }
        let ticker: Task<Void, Never> = Task {
            await runPartialTicker(config: config, tracker: tracker, jobs: jobSink)
        }
        await withTaskGroup(of: Void.self) { (group: inout TaskGroup<Void>) -> Void in
            group.addTask {
                await runCapture(speaker: .me, audio: meAudio, config: config, tracker: tracker, jobs: jobSink, events: eventSink)
            }
            group.addTask {
                await runCapture(speaker: .others, audio: othersAudio, config: config, tracker: tracker, jobs: jobSink, events: eventSink)
            }
        }
        ticker.cancel()
        await ticker.value
        jobSink.finish()
        await worker.value
        eventSink.finish()
    }
    return events
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
            if let segment = openSegments[speaker], segment.samples.count - segment.trailingSilenceSamples >= minSpeechSamples {
                pendingJobs += 1
                return (speaker, segment)
            }
        }
        return nil
    }
}

/// Bir konuşmacının ses akışını kaydeder ve bölümleyip kesin işleri kuyruğa koyar.
private func runCapture(
    speaker: Speaker,
    audio: AsyncStream<[Float]>,
    config: LiveSessionConfig,
    tracker: OpenSegmentTracker,
    jobs: AsyncStream<TranscriptionJob>.Continuation,
    events: AsyncStream<LiveSessionEvent>.Continuation
) async {
    let fileURL: URL = config.recordingDirectory.appending(path: "\(speaker.rawValue).caf")
    var recorder: CafRecorder?
    do {
        recorder = try CafRecorder(fileURL: fileURL)
    } catch {
        events.yield(.recordingFailed(speaker: speaker, message: String(describing: error)))
    }

    var state: SegmenterState = .initial
    for await chunk in audio {
        if let activeRecorder = recorder {
            do {
                try activeRecorder.append(samples: chunk)
            } catch {
                // Kayıt bozuldu: bir kez bildir, yazıya dökmeye kayıtsız devam et.
                events.yield(.recordingFailed(speaker: speaker, message: String(describing: error)))
                activeRecorder.close()
                recorder = nil
            }
        }
        let output: SegmenterOutput = segmentAudio(state: state, newSamples: chunk, config: config.segmenter)
        state = output.state
        await tracker.update(speaker: speaker, open: state.open)
        await enqueueFinals(speaker: speaker, segments: output.closed, config: config, tracker: tracker, jobs: jobs)
    }

    let flushed: SegmenterOutput = flushSegmenter(state: state, config: config.segmenter)
    await tracker.update(speaker: speaker, open: nil)
    await enqueueFinals(speaker: speaker, segments: flushed.closed, config: config, tracker: tracker, jobs: jobs)
    recorder?.close()
    events.yield(.captureEnded(speaker: speaker))
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
    events: AsyncStream<LiveSessionEvent>.Continuation
) async {
    var state: WorkerState = WorkerState(votes: .empty, locked: fixedLanguage(mode: config.languageMode), finalized: [])
    for await job in jobs {
        state = await processJob(job: job, state: state, engine: engine, config: config, events: events)
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
            votes = addVote(votes: votes, logProbs: logProbs)
            language = resolveSegmentLanguage(detected: pickLanguage(logProbs: logProbs), votes: votes)
        } else if let leading = leadingLanguage(votes: votes) {
            language = leading
        } else {
            // Henüz hiç dil oyu yok: geçici metin üretilemez.
            return WorkerState(votes: votes, locked: nil, finalized: finalized)
        }

        let text: String = try await engine.transcribe(samples: job.samples, language: language)
        events.yield(.segment(LiveSegment(id: job.id, startSec: job.startSec, endSec: job.endSec, text: text, isFinal: job.isFinal, failureMessage: nil, person: nil)))

        guard state.locked == nil, job.isFinal,
              let lockedNow = lockedLanguage(votes: votes, elapsedSec: job.endSec, lockAfterSec: config.languageLockAfterSec)
        else {
            return WorkerState(votes: votes, locked: state.locked, finalized: finalized)
        }
        events.yield(.languageLocked(lockedNow))
        return WorkerState(votes: votes, locked: lockedNow, finalized: finalized)
    } catch {
        sessionLogger.error("Bölüm yazıya dökülemedi: \(String(describing: error), privacy: .public)")
        if job.isFinal {
            events.yield(.segment(LiveSegment(
                id: job.id,
                startSec: job.startSec,
                endSec: job.endSec,
                text: "",
                isFinal: true,
                failureMessage: String(describing: error),
                person: nil
            )))
        }
        return WorkerState(votes: state.votes, locked: state.locked, finalized: finalized)
    }
}
