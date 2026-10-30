import Foundation
import Testing
@testable import AINotepadCore

/// Testlerde kullanılan 16 kHz sinüs sesi (genlik 0.3, 440 Hz).
func tone(seconds: Double) -> [Float] {
    let count: Int = Int(seconds * 16000)
    return (0..<count).map { (index: Int) -> Float in
        Float(0.3 * sin(2.0 * Double.pi * 440.0 * Double(index) / 16000.0))
    }
}

/// Testlerde kullanılan 16 kHz sessizlik.
func silence(seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * 16000))
}

/// Örnekleri verilen boyutta parçalara bölüp bölümleyiciye sırayla verir, sonunda flush eder.
func runSegmenter(samples: [Float], chunkSize: Int) -> [ClosedSegment] {
    var state: SegmenterState = .initial
    var closed: [ClosedSegment] = []
    var offset: Int = 0
    while offset < samples.count {
        let end: Int = min(offset + chunkSize, samples.count)
        let output: SegmenterOutput = segmentAudio(state: state, newSamples: Array(samples[offset..<end]), config: .live)
        state = output.state
        closed += output.closed
        offset = end
    }
    let flushed: SegmenterOutput = flushSegmenter(state: state, config: .live)
    return closed + flushed.closed
}

@Suite struct SpeechSegmenterTests {
    @Test func silenceProducesNoSegments() {
        let output: SegmenterOutput = segmentAudio(state: .initial, newSamples: silence(seconds: 5), config: .live)
        #expect(output.closed.isEmpty)
        #expect(output.state.open == nil)
    }

    @Test func speechThenSilenceClosesOneSegment() {
        let output: SegmenterOutput = segmentAudio(
            state: .initial,
            newSamples: tone(seconds: 1.0) + silence(seconds: 1.0),
            config: .live
        )
        #expect(output.closed.count == 1)
        #expect(output.closed.first?.startSample == 0)
        #expect(output.closed.first?.samples.count == 16000)
    }

    @Test func shortBlipIsDropped() {
        let output: SegmenterOutput = segmentAudio(
            state: .initial,
            newSamples: tone(seconds: 0.1) + silence(seconds: 1.0),
            config: .live
        )
        #expect(output.closed.isEmpty)
        #expect(output.state.open == nil)
    }

    @Test func longSpeechSplitsContiguously() {
        let segments: [ClosedSegment] = runSegmenter(samples: tone(seconds: 20), chunkSize: 16000)
        #expect(segments.count == 2)
        #expect(segments[0].samples.count == 240_000)
        #expect(segments[1].startSample == 240_000)
        #expect(segments.reduce(0) { $0 + $1.samples.count } == 320_000)
    }

    @Test func chunkBoundariesDoNotMatter() {
        let samples: [Float] = tone(seconds: 1) + silence(seconds: 1)
        let whole: [ClosedSegment] = runSegmenter(samples: samples, chunkSize: samples.count)
        let small: [ClosedSegment] = runSegmenter(samples: samples, chunkSize: 37)
        #expect(whole.count == 1)
        #expect(whole == small)
    }

    @Test func flushClosesOpenSegment() {
        let output: SegmenterOutput = segmentAudio(state: .initial, newSamples: tone(seconds: 2), config: .live)
        #expect(output.closed.isEmpty)
        let flushed: SegmenterOutput = flushSegmenter(state: output.state, config: .live)
        #expect(flushed.closed.count == 1)
        #expect(flushed.closed.first?.samples.count == 32000)
        #expect(flushed.state.open == nil)
    }

    // Konuşmadan önceki sessiz çerçeve bölümün başına eklenir (ilk hece kesilmesin); bölümün sınırı bir çerçeve öne alınır.
    @Test func preRollKeepsFrameBeforeSpeech() {
        let output: SegmenterOutput = segmentAudio(
            state: .initial,
            newSamples: silence(seconds: 0.5) + tone(seconds: 1.0) + silence(seconds: 1.0),
            config: .live
        )
        #expect(output.closed.count == 1)
        #expect(output.closed.first?.startSample == 6400)
        #expect(output.closed.first?.samples.count == 17600)
    }

    // Ön-kayıt konuşma sayılmaz: 0.2 sn ses + 0.1 sn ön-kayıt eşiğe (0.3 sn) ulaşsa da bölüm atılır.
    @Test func preRollDoesNotCountAsSpeech() {
        let output: SegmenterOutput = segmentAudio(
            state: .initial,
            newSamples: silence(seconds: 0.5) + tone(seconds: 0.2) + silence(seconds: 1.0),
            config: .live
        )
        #expect(output.closed.isEmpty)
    }
}
