import Foundation
import Testing
@testable import AINotepadCore

private func others(_ index: Int, person: Int?) -> LiveSegment {
    LiveSegment(id: SegmentID(speaker: .others, index: index), startSec: Double(index), endSec: Double(index) + 1, text: "t\(index)", isFinal: true, failureMessage: nil, person: person)
}

@Suite struct SpeakerCorrectionTests {
    // Tek blok başka konuşmacıya atanır; otomatik ayırma sonra farklı kişi verse de düzeltme kalır.
    @Test func blockOverrideWins() {
        let corrections: SpeakerCorrections = SpeakerCorrections.none.assigning(segments: [SegmentID(speaker: .others, index: 1)], to: 1)
        let corrected: [LiveSegment] = applyCorrections(transcript: [others(0, person: 1), others(1, person: 2)], corrections: corrections)
        #expect(corrected.map(\.person) == [1, 1])
    }

    // Birleştirme geçmiş ve gelecek bölümlere uygulanır; zincirler son kişide biter.
    @Test func mergeAppliesToAllAndChains() {
        let corrections: SpeakerCorrections = SpeakerCorrections.none.merging(person: 3, into: 2).merging(person: 2, into: 1)
        let corrected: [LiveSegment] = applyCorrections(transcript: [others(0, person: 1), others(1, person: 2), others(2, person: 3), others(3, person: nil)], corrections: corrections)
        #expect(corrected.map(\.person) == [1, 1, 1, nil])
        #expect(knownPersons(transcript: corrected) == [1])
    }

    @Test func storedMergeMovesNames() {
        let record: MeetingRecord = MeetingRecord(
            id: "x", title: "T", startedAt: Date(), endedAt: nil, language: .finnish, status: .done, failureMessage: nil,
            liveSegments: [],
            finalSegments: [
                StoredSegment(key: "final-0", speaker: .others, person: 1, startSec: 0, endSec: 1, text: "a", words: nil),
                StoredSegment(key: "final-1", speaker: .others, person: 2, startSec: 1, endSec: 2, text: "b", words: nil),
            ],
            translations: [:], speakerNames: [2: "Aino"], note: nil, audioDeleted: false, engine: .cloud, notice: nil
        )
        let merged: MeetingRecord = mergingPersons(record: record, from: 2, into: 1)
        #expect(merged.finalSegments.map(\.person) == [1, 1])
        #expect(merged.speakerNames == [1: "Aino"])
    }

    // Tahmini kelime zamanları süreyi harf sayısıyla böler; çalma anındaki kelime doğru bulunur.
    @Test func estimatedWordTimingAndActiveWord() {
        let words: [StoredWord] = estimatedWords(text: "Hei kaikki", startSec: 10, endSec: 19)
        #expect(words.map(\.text) == ["Hei", "kaikki"])
        #expect(words[0].startSec == 10)
        #expect(abs(words[1].startSec - 13) < 0.001)
        #expect(activeWordIndex(words: words, timeSec: 9) == nil)
        #expect(activeWordIndex(words: words, timeSec: 12) == 0)
        #expect(activeWordIndex(words: words, timeSec: 15) == 1)
    }

    // Birleştirilip görünmez olan numara "Yeni konuşmacı"ya verilmez (yoksa eski kişiye geri eşlenirdi).
    @Test func newSpeakerNumberSkipsMergedNumbers() {
        let corrections: SpeakerCorrections = SpeakerCorrections.none.merging(person: 3, into: 2)
        let transcript: [LiveSegment] = [others(0, person: 1), others(1, person: 2), others(2, person: 3)]
        #expect(knownPersons(transcript: applyCorrections(transcript: transcript, corrections: corrections)) == [1, 2])
        #expect(nextFreePerson(transcript: transcript, corrections: corrections) == 4)
    }
}
