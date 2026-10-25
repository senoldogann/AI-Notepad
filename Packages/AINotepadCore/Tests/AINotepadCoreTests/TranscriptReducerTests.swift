import Foundation
import Testing
@testable import AINotepadCore

/// Test için kısa bölüm üretir.
func segment(speaker: Speaker, index: Int, start: Double, text: String, isFinal: Bool, failure: String?) -> LiveSegment {
    LiveSegment(
        id: SegmentID(speaker: speaker, index: index),
        startSec: start,
        endSec: start + 1,
        text: text,
        isFinal: isFinal,
        failureMessage: failure
    )
}

@Suite struct TranscriptReducerTests {
    @Test func partialThenFinalReplacesInPlace() {
        let partial: LiveSegment = segment(speaker: .others, index: 0, start: 0, text: "Hyv", isFinal: false, failure: nil)
        let final: LiveSegment = segment(speaker: .others, index: 0, start: 0, text: "Hyvää", isFinal: true, failure: nil)
        let afterPartial: [LiveSegment] = applyEvent(transcript: [], event: .segment(partial))
        let afterFinal: [LiveSegment] = applyEvent(transcript: afterPartial, event: .segment(final))
        #expect(afterFinal == [final])
    }

    @Test func keepsSortedByStart() {
        let others: LiveSegment = segment(speaker: .others, index: 0, start: 5, text: "b", isFinal: true, failure: nil)
        let me: LiveSegment = segment(speaker: .me, index: 0, start: 2, text: "a", isFinal: true, failure: nil)
        let result: [LiveSegment] = applyEvent(transcript: applyEvent(transcript: [], event: .segment(others)), event: .segment(me))
        #expect(result == [me, others])
    }

    @Test func emptyFinalRemovesSegment() {
        let partial: LiveSegment = segment(speaker: .me, index: 3, start: 1, text: "Kii", isFinal: false, failure: nil)
        let emptyFinal: LiveSegment = segment(speaker: .me, index: 3, start: 1, text: "", isFinal: true, failure: nil)
        let result: [LiveSegment] = applyEvent(transcript: [partial], event: .segment(emptyFinal))
        #expect(result.isEmpty)
    }

    @Test func failureMarksSegment() {
        let failed: LiveSegment = segment(speaker: .others, index: 1, start: 4, text: "", isFinal: true, failure: "model hatası")
        let result: [LiveSegment] = applyEvent(transcript: [], event: .segment(failed))
        #expect(result == [failed])
    }

    @Test func nonSegmentEventsDoNotChange() {
        let existing: [LiveSegment] = [segment(speaker: .me, index: 0, start: 0, text: "a", isFinal: true, failure: nil)]
        #expect(applyEvent(transcript: existing, event: .languageLocked(.finnish)) == existing)
        #expect(applyEvent(transcript: existing, event: .captureEnded(speaker: .me)) == existing)
    }
}
