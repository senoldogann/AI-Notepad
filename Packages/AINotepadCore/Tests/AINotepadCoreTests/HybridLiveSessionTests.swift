import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

/// Her konuşma bölümüne sabit metin veren motor (Mac'e geçiş yolunu modelsiz sınamak için).
private struct FixedTextEngine: TranscriptionEngine {
    let text: String

    func detectLanguage(samples: [Float]) async throws -> [String: Float] {
        ["fi": -0.1]
    }

    func transcribe(samples: [Float], language: MeetingLanguage) async throws -> String {
        text
    }
}

/// Hibrit oturumun ayarları: yalnızca "Diğerleri" canlı, sabit Fince.
private func hybridConfig(directory: URL) -> HybridLiveSessionConfig {
    HybridLiveSessionConfig(
        speakers: [.others],
        local: LiveSessionConfig(
            languageMode: .fixed(.finnish), segmenter: .live, recordingDirectory: directory,
            partialIntervalSec: 1000, minPartialSpeechSec: 1.0, languageLockAfterSec: 30, candidateLanguages: [.finnish]
        ),
        maxPendingAudioSec: 300
    )
}

@Suite struct HybridLiveSessionTests {
    // Sunucu Deepgram jetonu vermezse (bütçe doldu) akış ağa çıkmadan durur, oturum Mac'e geçer: ses kesintisiz
    // kaydedilir, metin Mac'teki motordan gelir, bölüm numaraları Deepgram'ınkilerle çakışmaz.
    @Test func fallsBackToLocalEngineWhenTokenIsRefused() async throws {
        let directory: URL = try temporaryDirectory()
        let fixture: [Float] = try loadFixture(name: "fi-dialog")
        let (me, meInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let (others, othersInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        meInput.finish()
        let refused: HostedAPIError = HostedAPIError(code: .deepgramUnavailable, rawCode: "deepgram_unavailable", status: 503, serverMessage: "", path: "/v1/live/deepgram-token")
        let source: DeepgramLiveSource = DeepgramLiveSource(
            language: .finnish, keyterms: [], options: DeepgramListenOptions(model: "nova-3", optOutOfModelImprovement: true),
            onConnectionEvent: { (_: DeepgramConnectionEvent) -> Void in }
        ) { () async throws -> String in
            throw refused
        }
        let handle: LiveSessionHandle = runHybridLiveSession(
            config: hybridConfig(directory: directory), start: .deepgram(source),
            localEngine: { () async throws -> any TranscriptionEngine in FixedTextEngine(text: "hei") },
            recording: startHybridRecording(directory: directory, meAudio: me, othersAudio: others)
        )
        var events: [LiveSessionEvent] = []
        for await event in handle.events {
            events.append(event)
            if case .liveEngineFellBack = event {
                for offset in stride(from: 0, to: fixture.count, by: 1600) {
                    othersInput.yield(Array(fixture[offset..<min(offset + 1600, fixture.count)]))
                }
                othersInput.finish()
            }
        }
        #expect(events.contains(.liveEngineFellBack(message: hostedErrorMessage(error: refused))))
        let finals: [LiveSegment] = events.reduce([]) { (current: [LiveSegment], event: LiveSessionEvent) -> [LiveSegment] in
            applyEvent(transcript: current, event: event)
        }.filter(\.isFinal)
        #expect(!finals.isEmpty)
        #expect(finals.allSatisfy { $0.text == "hei" && $0.id.speaker == .others && $0.id.index >= localSegmentIndexBase })
        #expect(!events.contains { if case .streamFailed = $0 { true } else { false } })
        #expect(events.contains(.captureEnded(speaker: .others)))
        #expect(try AVAudioFile(forReading: directory.appending(path: "others.caf")).length == AVAudioFramePosition(fixture.count))
    }

    // Mac'te başlayan oturumda motor hazırlanamazsa (model inemedi) canlı metin durur ama kayıt sürer.
    @Test func localEngineFailureStopsLiveTextButKeepsRecording() async throws {
        let directory: URL = try temporaryDirectory()
        let samples: [Float] = silence(seconds: 2)
        let handle: LiveSessionHandle = runHybridLiveSession(
            config: hybridConfig(directory: directory), start: .local,
            localEngine: { () async throws -> any TranscriptionEngine in
                throw TranscriptionError.modelLoadFailed(model: "test", reason: "ağ yok")
            },
            recording: startHybridRecording(
                directory: directory, meAudio: chunkedStream(samples: [], chunkSize: 1600), othersAudio: chunkedStream(samples: samples, chunkSize: 1600)
            )
        )
        var events: [LiveSessionEvent] = []
        for await event in handle.events {
            events.append(event)
        }
        #expect(events.contains(.captureEnded(speaker: .others)))
        #expect(try AVAudioFile(forReading: directory.appending(path: "others.caf")).length == AVAudioFramePosition(samples.count))
        #expect(!events.contains { if case .segment = $0 { true } else { false } })
    }

    // Ses, oturum başlamadan (toplantı oturumu açılırken, ağ beklenirken) diske yazılır; oturum sonra aynı sesi alır.
    @Test func recordingWritesToDiskBeforeSessionStarts() async throws {
        let directory: URL = try temporaryDirectory()
        let samples: [Float] = silence(seconds: 1)
        let (others, othersInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let recording: HybridRecording = startHybridRecording(directory: directory, meAudio: chunkedStream(samples: [], chunkSize: 1600), othersAudio: others)
        othersInput.yield(samples)
        let file: URL = directory.appending(path: "others.caf")
        var written: Int = 0
        // Yazma beklenir; sınır geniş (10 sn): yüklü CI makinesinde 1 sn yetmeyebilir.
        let deadline: ContinuousClock.Instant = .now + .seconds(10)
        while written < samples.count * 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            written = (try? Data(contentsOf: file).count) ?? 0
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(written >= samples.count * 2)
        othersInput.finish()
        let handle: LiveSessionHandle = runHybridLiveSession(
            config: hybridConfig(directory: directory), start: .local,
            localEngine: { () async throws -> any TranscriptionEngine in FixedTextEngine(text: "hei") },
            recording: recording
        )
        var events: [LiveSessionEvent] = []
        for await event in handle.events {
            events.append(event)
        }
        #expect(events.contains(.captureEnded(speaker: .others)))
        #expect(try AVAudioFile(forReading: file).length == AVAudioFramePosition(samples.count))
    }

    @Test func localEventsMoveToMeetingTimeline() {
        let segment: LiveSegment = LiveSegment(id: SegmentID(speaker: .me, index: 3), startSec: 1, endSec: 2, text: "x", isFinal: true, failureMessage: nil, person: nil)
        let shifted: LiveSessionEvent? = shiftedLocalEvent(event: .segment(segment), timeline: LocalTimeline(meStartSec: 60, othersStartSec: 0))
        #expect(shifted == .segment(LiveSegment(id: SegmentID(speaker: .me, index: localSegmentIndexBase + 3), startSec: 61, endSec: 62, text: "x", isFinal: true, failureMessage: nil, person: nil)))
        #expect(shiftedLocalEvent(event: .captureEnded(speaker: .me), timeline: LocalTimeline(meStartSec: 0, othersStartSec: 0)) == nil)
    }
}
