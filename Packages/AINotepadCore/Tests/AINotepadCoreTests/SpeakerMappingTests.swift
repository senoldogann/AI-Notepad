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
            windowStartSec: 0,
            labelVoices: [:]
        )
        #expect(mapping.words.map(\.person) == [1, 2])
        #expect(mapping.nextPerson == 3)
    }

    @Test func overlapKeepsIdentityWhenLabelsSwap() {
        let first: SpeakerMapping = applyWindow(
            mapping: .initial,
            windowWords: words("speaker_0", from: 0, to: 60) + words("speaker_1", from: 60, to: 120),
            windowStartSec: 0,
            labelVoices: [:]
        )
        // İkinci pencere 60. sn'de başlar; ElevenLabs aynı kişiye artık "speaker_0" der.
        let second: SpeakerMapping = applyWindow(
            mapping: first,
            windowWords: words("speaker_0", from: 0, to: 60) + words("speaker_1", from: 60, to: 120),
            windowStartSec: 60,
            labelVoices: [:]
        )
        #expect(Set(second.words.filter { $0.startSec < 120 }.map(\.person)) == [2])
        #expect(Set(second.words.filter { $0.startSec >= 120 }.map(\.person)) == [3])
        #expect(second.nextPerson == 4)
        #expect(second.words.first?.startSec == 60)
    }

    @Test func twoLabelsCannotClaimSamePerson() {
        let previous: SpeakerMapping = SpeakerMapping(words: [AttributedWord(startSec: 0, endSec: 10, person: 1)], nextPerson: 2, voices: [:])
        let next: SpeakerMapping = applyWindow(
            mapping: previous,
            windowWords: [word("speaker_0", 0, 6), word("speaker_1", 6, 10)],
            windowStartSec: 0,
            labelVoices: [:]
        )
        #expect(next.words.map(\.person) == [1, 2])
        #expect(next.nextPerson == 3)
    }

    @Test func newSpeakerGetsNextNumber() {
        let previous: SpeakerMapping = SpeakerMapping(words: [AttributedWord(startSec: 0, endSec: 10, person: 1)], nextPerson: 2, voices: [:])
        let next: SpeakerMapping = applyWindow(
            mapping: previous,
            windowWords: [word("speaker_0", 0, 5), word("speaker_1", 10, 15)],
            windowStartSec: 5,
            labelVoices: [:]
        )
        #expect(next.words.map(\.person) == [1, 2])
        #expect(next.words.map(\.startSec) == [5, 15])
    }

    @Test func emptyWindowKeepsMapping() {
        let previous: SpeakerMapping = SpeakerMapping(words: [AttributedWord(startSec: 0, endSec: 10, person: 1)], nextPerson: 2, voices: [:])
        #expect(applyWindow(mapping: previous, windowWords: [], windowStartSec: 60, labelVoices: [:]) == previous)
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

@Suite struct TranscriptGapTests {
    // Deepgram'ın boş bıraktığı 3+ kelimelik konuşma boşluk olur; kapsananlar, tek tük kelimeler ve henüz
    // kesinleşmemiş son kısım boşluk sayılmaz.
    @Test func uncoveredRunsBecomeGaps() {
        let spoken: [DiarizedWord] = [
            DiarizedWord(text: "ottaa", startSec: 10, endSec: 10.5, speaker: "a"),
            DiarizedWord(text: "julkisen", startSec: 13.2, endSec: 13.6, speaker: "a"),
            DiarizedWord(text: "talouden", startSec: 13.6, endSec: 14.2, speaker: "a"),
            DiarizedWord(text: "varoista,", startSec: 14.3, endSec: 14.9, speaker: "b"),
            DiarizedWord(text: "niin", startSec: 15.0, endSec: 15.3, speaker: "a"),
            DiarizedWord(text: "öö", startSec: 20.0, endSec: 20.3, speaker: "a"),
            DiarizedWord(text: "ei", startSec: 22, endSec: 22.3, speaker: "a"),
            DiarizedWord(text: "kesken", startSec: 40, endSec: 40.5, speaker: "a"),
            DiarizedWord(text: "olevaa", startSec: 40.5, endSec: 41, speaker: "a"),
            DiarizedWord(text: "puhetta", startSec: 41, endSec: 41.5, speaker: "a"),
        ]
        let finals: [LiveSegment] = [othersSegment(index: 0, start: 9, end: 13), othersSegment(index: 2, start: 21.8, end: 25)]
        let gaps: [TranscriptGap] = transcriptGaps(
            words: spoken, persons: [1, 1, 1, 2, 1, 1, 1, 1, 1, 1], finals: finals, coveredUntilSec: 25, minWords: 3
        )
        #expect(gaps == [TranscriptGap(startSec: 13.2, endSec: 15.3, text: "julkisen talouden varoista, niin", person: 1)])
    }
}

@Suite struct VoiceReidentificationTests {
    private func voice(_ values: [Float], seconds: Double) -> Voiceprint {
        Voiceprint(embedding: normalizedEmbedding(values: values), seconds: seconds)
    }

    // Uzun süre konuşmayıp geri dönen kişi (örtüşme yok) ses iziyle eski numarasını alır; tanınmayan ses yeni numara alır.
    @Test func returningSpeakerKeepsNumberByVoice() {
        let previous: SpeakerMapping = SpeakerMapping(
            words: [AttributedWord(startSec: 0, endSec: 10, person: 2)], nextPerson: 3,
            voices: [1: voice([1, 0, 0], seconds: 60), 2: voice([0, 1, 0], seconds: 60)]
        )
        let next: SpeakerMapping = applyWindow(
            mapping: previous,
            windowWords: words("speaker_0", from: 0, to: 30) + words("speaker_1", from: 30, to: 60),
            windowStartSec: 300,
            labelVoices: ["speaker_0": voice([0.95, 0.05, 0], seconds: 30), "speaker_1": voice([0, 0, 1], seconds: 30)]
        )
        #expect(Set(next.words.filter { $0.startSec < 330 }.map(\.person)) == [1])
        #expect(Set(next.words.filter { $0.startSec >= 330 }.map(\.person)) == [3])
        #expect(next.voices.keys.sorted() == [1, 2, 3])
        // Kısa konuşma (karar için yetersiz) ses iziyle eşlenmez.
        let short: SpeakerMapping = applyWindow(
            mapping: previous, windowWords: words("speaker_0", from: 0, to: 10), windowStartSec: 300,
            labelVoices: ["speaker_0": voice([1, 0, 0], seconds: 6)]
        )
        #expect(short.words.map(\.person) == [3])
    }

    // Kayıtlı seslerden ad: emin olunanlar, bir ad tek kişiye; yakın iki aday (marj yok) ad almaz.
    @Test func recognizedNamesAreConfidentAndUnique() {
        let now: Date = Date(timeIntervalSince1970: 0)
        let registry: [RegisteredVoice] = registering(
            voices: registering(voices: [], name: "Aino", voiceprint: voice([1, 0, 0], seconds: 100), source: "a#1", now: now),
            name: " aino ", voiceprint: voice([1, 0.1, 0], seconds: 100), source: "b#2", now: now
        ) + [RegisteredVoice(name: "Mikko", voiceprint: voice([0, 1, 0], seconds: 100), updatedAt: now, contributions: nil)]
        #expect(registry.map(\.name) == ["Aino", "Mikko"])
        let names: [Int: String] = recognizedNames(
            voiceprints: [1: voice([1, 0.05, 0], seconds: 200), 2: voice([0.9, 0.1, 0], seconds: 40), 3: voice([0.7, 0.7, 0], seconds: 200), 4: voice([0, 1, 0], seconds: 5)],
            registry: registry
        )
        #expect(names == [1: "Aino"])
        // Yanlış verilen ad düzeltilince o toplantının katkısı tam geri alınır; son katkı gidince ses silinir; aynı
        // kaynak yeniden adlandırılınca iki kez sayılmaz.
        let undone: [RegisteredVoice] = unregistering(voices: registry, name: "Aino", source: "b#2", now: now)
        #expect(undone.first?.voiceprint == voice([1, 0, 0], seconds: 100))
        #expect(unregistering(voices: undone, name: "aino", source: "a#1", now: now).map(\.name) == ["Mikko"])
        #expect(registering(voices: undone, name: "Aino", voiceprint: voice([1, 0, 0], seconds: 100), source: "a#1", now: now).first?.voiceprint.seconds == 100)
        #expect(unregistering(voices: registry, name: "Mikko", source: "a#1", now: now) == registry)
    }

    // Etiketin izi yalnızca ona ait (konuşmasının çoğu o etiket olan) SpeakerKit konuşmacılarından gelir; ikiye
    // bölünmüş kişinin iki konuşmacısı birleşir, karışık konuşmacı yazılmaz.
    @Test func labelVoiceComesFromOwnedClusters() {
        let clusters: [VoiceCluster] = [
            VoiceCluster(turns: [0...20], centroid: [3, 0, 0]),
            VoiceCluster(turns: [20...40], centroid: [0, 2, 0]),
            VoiceCluster(turns: [40...50], centroid: [0, 2, 0]),
        ]
        let spans: [LabeledSpan<String>] = [
            LabeledSpan(label: "a", startSec: 0, endSec: 19), LabeledSpan(label: "b", startSec: 5, endSec: 15),
            LabeledSpan(label: "b", startSec: 20, endSec: 30), LabeledSpan(label: "b", startSec: 40, endSec: 45),
        ]
        let voices: [String: Voiceprint] = labelVoiceprints(spans: spans, clusters: clusters)
        #expect(voices["a"] == nil)
        #expect(voices["b"] == Voiceprint(embedding: [0, 1, 0], seconds: 15))
    }
}
