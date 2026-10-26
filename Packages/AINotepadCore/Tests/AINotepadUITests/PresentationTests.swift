import AINotepadCore
import Foundation
import SwiftUI
import Testing
@testable import AINotepadUI

func seg(_ speaker: Speaker, _ index: Int, _ start: Double, _ text: String, person: Int?) -> LiveSegment {
    LiveSegment(id: SegmentID(speaker: speaker, index: index), startSec: start, endSec: start + 2, text: text, isFinal: true, failureMessage: nil, person: person)
}

func state(transcript: [LiveSegment], isRecording: Bool, errors: [String]) -> LiveViewState {
    makeLiveViewState(transcript: transcript, translations: [:], displayMode: .bilingual, failedTranslations: [], assistantCard: nil, phase: isRecording ? .recording : .idle, startedAt: nil, statusText: "Hazır", languageText: "Fince", errors: errors)
}

@Suite struct PresentationTests {
    @Test func personColorWraps() {
        #expect(personColor(person: 7) == personColor(person: 1))
        #expect(personColor(person: 2) != personColor(person: 1))
    }

    @Test func latestSentenceTruncatesFromStart() {
        let long: String = String(repeating: "a", count: 190) + "lopussa"
        let result: String = truncateFromStart(text: long, maxCharacters: 140)
        #expect(result.count == 141)
        #expect(result.hasPrefix("…"))
        #expect(result.hasSuffix("lopussa"))
        #expect(truncateFromStart(text: "lyhyt", maxCharacters: 140) == "lyhyt")
    }

    @Test func islandHiddenWhenNotRecording() {
        #expect(state(transcript: [], isRecording: false, errors: []).isIslandVisible == false)
        #expect(state(transcript: [], isRecording: true, errors: []).isIslandVisible == true)
    }

    @Test func viewStateUsesEchoFilteredTranscript() {
        let others: LiveSegment = seg(.others, 0, 1, "Tässä lähetyksessä tapaamme Jarnon", person: 1)
        let echo: LiveSegment = seg(.me, 0, 1.2, "Tässä lähetyksessä tapaamme Jarnon", person: nil)
        let viewState: LiveViewState = state(transcript: [others, echo], isRecording: true, errors: [])
        #expect(viewState.blocks.map(\.speaker) == [.others])
        #expect(viewState.latestOthersSentence == "Tässä lähetyksessä tapaamme Jarnon")
    }

    @Test func errorsKeepLastThree() {
        #expect(state(transcript: [], isRecording: true, errors: ["1", "2", "3", "4"]).errors == ["2", "3", "4"])
    }

    @Test func latestSentenceJoinsLastOthersBlock() {
        let first: LiveSegment = seg(.others, 0, 1, "Hienoa. Kuka voisi ottaa vastuun esityksestä", person: 2)
        let second: LiveSegment = seg(.others, 1, 4, "perjantaina?", person: 2)
        let viewState: LiveViewState = state(transcript: [first, second], isRecording: true, errors: [])
        #expect(viewState.latestOthersSentence == "Hienoa. Kuka voisi ottaa vastuun esityksestä perjantaina?")
    }
}

@Suite struct LanguageTextTests {
    @Test func lockedLanguageWins() {
        #expect(languageText(locked: .finnish, mode: .automatic, isRecording: true) == "🇫🇮 Fince")
    }

    @Test func automaticShowsDetectingWhileRecording() {
        #expect(languageText(locked: nil, mode: .automatic, isRecording: true) == "Dil algılanıyor…")
        #expect(languageText(locked: nil, mode: .automatic, isRecording: false) == "Dil: Otomatik")
        #expect(languageText(locked: nil, mode: .fixed(.english), isRecording: false) == "🇬🇧 İngilizce")
    }
}

@Suite struct TranslationPresentationTests {
    @Test func translationsKeyedBySegment() {
        let first: LiveSegment = seg(.others, 0, 1, "Hyvää huomenta.", person: 1)
        let second: LiveSegment = seg(.others, 1, 3, "Aloitetaan.", person: 1)
        let blocks: [SpeakerBlock] = groupBySpeaker(transcript: [first, second])
        let translations: [SegmentID: String] = [second.id: "Başlayalım.", first.id: "Günaydın."]
        #expect(blockTurkishText(block: blocks[0], translations: translations) == "Günaydın. Başlayalım.")
        #expect(blockTurkishText(block: blocks[0], translations: [:]) == nil)
    }

    @Test func latestUsesTurkishWhenAvailable() {
        let others: LiveSegment = seg(.others, 0, 1, "Hyvää huomenta.", person: 1)
        let viewState: LiveViewState = makeLiveViewState(
            transcript: [others], translations: [others.id: "Günaydın."], displayMode: .bilingual, failedTranslations: [], assistantCard: nil,
            phase: .recording, startedAt: nil, statusText: "", languageText: "", errors: []
        )
        #expect(viewState.latestOthersSentence == "Günaydın.")
    }

    // Çevirisi beklenen en yeni cümle adada orijinal haliyle (soluk) görünür; eski Türkçe onu gizlemez.
    @Test func islandShowsPendingOriginalAfterTurkish() {
        let first: LiveSegment = seg(.others, 0, 1, "Hyvää huomenta.", person: 1)
        let second: LiveSegment = seg(.others, 1, 3, "Aloitetaan.", person: 1)
        let viewState: LiveViewState = makeLiveViewState(
            transcript: [first, second], translations: [first.id: "Günaydın."], displayMode: .bilingual, failedTranslations: [], assistantCard: nil,
            phase: .recording, startedAt: nil, statusText: "", languageText: "", errors: []
        )
        #expect(viewState.latestOthersParts == [
            DisplayPart(text: "Günaydın.", isTranslated: true, isFinal: true),
            DisplayPart(text: "Aloitetaan.", isTranslated: false, isFinal: true),
        ])
    }

    @Test func partsTruncateFromStart() {
        let parts: [DisplayPart] = [
            DisplayPart(text: "Eski uzun cümle burada.", isTranslated: true, isFinal: true),
            DisplayPart(text: "Yeni.", isTranslated: false, isFinal: true),
        ]
        let kept: [DisplayPart] = truncatePartsFromStart(parts: parts, maxCharacters: 12)
        #expect(kept.last == parts.last)
        #expect(kept.first?.text.hasPrefix("…") == true)
        #expect(kept.first?.text == "…urada.")
    }

    // Kayıt durunca da ada "Bitiriliyor…" için görünür kalır.
    @Test func islandVisibleWhileFinishing() {
        let finishing: LiveViewState = makeLiveViewState(
            transcript: [], translations: [:], displayMode: .bilingual, failedTranslations: [], assistantCard: nil,
            phase: .finishing, startedAt: nil, statusText: "", languageText: "", errors: []
        )
        #expect(finishing.isIslandVisible)
        #expect(!finishing.isRecording)
    }

    // "Sadece Türkçe": çevrilen bölüm Türkçe, henüz çevrilmeyen (ve kesinleşmeyen) bölüm orijinal ve soluk.
    @Test func turkishOnlyShowsUntranslatedOriginals() {
        let first: LiveSegment = seg(.others, 0, 1, "Hyvää huomenta.", person: 1)
        let second: LiveSegment = seg(.others, 1, 3, "Aloitetaan.", person: 1)
        let blocks: [SpeakerBlock] = groupBySpeaker(transcript: [first, second])
        #expect(turkishOnlyParts(block: blocks[0], translations: [first.id: "Günaydın."]) == [
            DisplayPart(text: "Günaydın.", isTranslated: true, isFinal: true),
            DisplayPart(text: "Aloitetaan.", isTranslated: false, isFinal: true),
        ])
    }
}
