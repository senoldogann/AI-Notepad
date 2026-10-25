import Foundation
import Testing
@testable import AINotepadCore

@Suite struct TranscriptFormattingTests {
    @Test func groupsConsecutiveSameSpeaker() {
        let o0: LiveSegment = segment(speaker: .others, index: 0, start: 1, text: "Hyvää huomenta.", isFinal: true, failure: nil)
        let o1: LiveSegment = segment(speaker: .others, index: 1, start: 3, text: "Aloitetaan.", isFinal: true, failure: nil)
        let m0: LiveSegment = segment(speaker: .me, index: 0, start: 6, text: "Kiitos.", isFinal: true, failure: nil)
        let o2: LiveSegment = segment(speaker: .others, index: 2, start: 9, text: "Ensimmäinen asia.", isFinal: false, failure: nil)

        let blocks: [SpeakerBlock] = groupBySpeaker(transcript: [o0, o1, m0, o2])

        #expect(blocks.map(\.speaker) == [.others, .me, .others])
        #expect(blocks.map(\.segments) == [[o0, o1], [m0], [o2]])
        #expect(blocks.map(\.id) == [o0.id, m0.id, o2.id])
        #expect(blocks.map(\.startSec) == [1, 6, 9])
    }

    @Test func emptyTranscriptGivesNoBlocks() {
        #expect(groupBySpeaker(transcript: []).isEmpty)
    }

    @Test func plainTextJoinsBlocksWithTimestampAndLabel() {
        let blocks: [SpeakerBlock] = groupBySpeaker(transcript: [
            segment(speaker: .others, index: 0, start: 5, text: "Hyvää huomenta.", isFinal: true, failure: nil),
            segment(speaker: .others, index: 1, start: 7, text: "Aloitetaan.", isFinal: false, failure: nil),
            segment(speaker: .others, index: 2, start: 9, text: "", isFinal: true, failure: "model hatası"),
            segment(speaker: .me, index: 0, start: 62, text: "Kiitos.", isFinal: true, failure: nil),
        ])
        #expect(plainText(blocks: blocks) == "[00:05] Diğerleri: Hyvää huomenta. Aloitetaan.\n\n[01:02] Sen: Kiitos.")
    }

    @Test func plainTextUsesHoursForLongMeetings() {
        let blocks: [SpeakerBlock] = groupBySpeaker(transcript: [
            segment(speaker: .me, index: 0, start: 3725, text: "Selvä.", isFinal: true, failure: nil),
        ])
        #expect(plainText(blocks: blocks) == "[1:02:05] Sen: Selvä.")
    }

    @Test func groupsSplitByPerson() {
        let blocks: [SpeakerBlock] = groupBySpeaker(transcript: [
            segment(speaker: .others, index: 0, start: 0, text: "a", isFinal: true, failure: nil, person: 1),
            segment(speaker: .others, index: 1, start: 2, text: "b", isFinal: true, failure: nil, person: 1),
            segment(speaker: .others, index: 2, start: 4, text: "c", isFinal: true, failure: nil, person: 2),
        ])
        #expect(blocks.map(\.person) == [1, 2])
        #expect(blocks.map { $0.segments.count } == [2, 1])
    }

    @Test func plainTextUsesPersonLabel() {
        let blocks: [SpeakerBlock] = groupBySpeaker(transcript: [
            segment(speaker: .others, index: 0, start: 5, text: "Hyvää huomenta.", isFinal: true, failure: nil, person: 2),
        ])
        #expect(plainText(blocks: blocks) == "[00:05] Konuşmacı 2: Hyvää huomenta.")
        #expect(speakerLabel(speaker: .others, person: nil) == "Diğerleri")
        #expect(speakerLabel(speaker: .me, person: nil) == "Sen")
    }
}
