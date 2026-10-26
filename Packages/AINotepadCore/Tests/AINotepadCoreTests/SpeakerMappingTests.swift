import Foundation
import Testing
@testable import AINotepadCore

/// Pencere içi zamanla kelime.
func word(_ speaker: String, _ start: Double, _ end: Double) -> DiarizedWord {
    DiarizedWord(text: "x", startSec: start, endSec: end, speaker: speaker)
}

/// Bir konuşmacının [start, end) aralığını 10 sn'lik kelimelerle doldurur.
func words(_ speaker: String, from start: Double, to end: Double) -> [DiarizedWord] {
    stride(from: start, to: end, by: 10).map { word(speaker, $0, min($0 + 10, end)) }
}

func othersSegment(index: Int, start: Double, end: Double) -> LiveSegment {
    LiveSegment(id: SegmentID(speaker: .others, index: index), startSec: start, endSec: end, text: "t", isFinal: true, failureMessage: nil, person: nil)
}

@Suite struct SpeakerMappingTests {
    @Test func firstWindowNumbersInOrderOfAppearance() {
        let mapping: SpeakerMapping = applyWindow(
            mapping: .initial,
            windowWords: [word("speaker_1", 0, 1), word("speaker_0", 1, 2)],
            windowStartSec: 0
        )
        #expect(mapping.words.map(\.person) == [1, 2])
        #expect(mapping.nextPerson == 3)
    }

    @Test func overlapKeepsIdentityWhenLabelsSwap() {
        let first: SpeakerMapping = applyWindow(
            mapping: .initial,
            windowWords: words("speaker_0", from: 0, to: 60) + words("speaker_1", from: 60, to: 120),
            windowStartSec: 0
        )
        // İkinci pencere 60. sn'de başlar; ElevenLabs aynı kişiye artık "speaker_0" der.
        let second: SpeakerMapping = applyWindow(
            mapping: first,
            windowWords: words("speaker_0", from: 0, to: 60) + words("speaker_1", from: 60, to: 120),
            windowStartSec: 60
        )
        #expect(Set(second.words.filter { $0.startSec < 120 }.map(\.person)) == [2])
        #expect(Set(second.words.filter { $0.startSec >= 120 }.map(\.person)) == [3])
        #expect(second.nextPerson == 4)
        #expect(second.words.first?.startSec == 60)
    }

    @Test func twoLabelsCannotClaimSamePerson() {
        let previous: SpeakerMapping = SpeakerMapping(words: [AttributedWord(startSec: 0, endSec: 10, person: 1)], nextPerson: 2)
        let next: SpeakerMapping = applyWindow(
            mapping: previous,
            windowWords: [word("speaker_0", 0, 6), word("speaker_1", 6, 10)],
            windowStartSec: 0
        )
        #expect(next.words.map(\.person) == [1, 2])
        #expect(next.nextPerson == 3)
    }

    @Test func newSpeakerGetsNextNumber() {
        let previous: SpeakerMapping = SpeakerMapping(words: [AttributedWord(startSec: 0, endSec: 10, person: 1)], nextPerson: 2)
        let next: SpeakerMapping = applyWindow(
            mapping: previous,
            windowWords: [word("speaker_0", 0, 5), word("speaker_1", 10, 15)],
            windowStartSec: 5
        )
        #expect(next.words.map(\.person) == [1, 2])
        #expect(next.words.map(\.startSec) == [5, 15])
    }

    @Test func emptyWindowKeepsMapping() {
        let previous: SpeakerMapping = SpeakerMapping(words: [AttributedWord(startSec: 0, endSec: 10, person: 1)], nextPerson: 2)
        #expect(applyWindow(mapping: previous, windowWords: [], windowStartSec: 60) == previous)
    }

    @Test func assignPersonsByMajorityDuration() {
        let segment: LiveSegment = othersSegment(index: 0, start: 0, end: 10)
        let words: [AttributedWord] = [
            AttributedWord(startSec: 0, endSec: 3, person: 1),
            AttributedWord(startSec: 3, endSec: 10, person: 2),
        ]
        #expect(assignPersons(segments: [segment], words: words) == [segment.id: 2])
    }

    @Test func segmentWithoutWordsUnassigned() {
        let segment: LiveSegment = othersSegment(index: 0, start: 20, end: 25)
        #expect(assignPersons(segments: [segment], words: [AttributedWord(startSec: 0, endSec: 10, person: 1)]).isEmpty)
    }

    @Test func meSegmentsAreIgnored() {
        let me: LiveSegment = LiveSegment(id: SegmentID(speaker: .me, index: 0), startSec: 0, endSec: 10, text: "t", isFinal: true, failureMessage: nil, person: nil)
        #expect(assignPersons(segments: [me], words: [AttributedWord(startSec: 0, endSec: 10, person: 1)]).isEmpty)
    }
}
