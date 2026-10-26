import AINotepadCore
import Foundation
import SwiftUI
import Testing
@testable import AINotepadUI

func seg(_ speaker: Speaker, _ index: Int, _ start: Double, _ text: String, person: Int?) -> LiveSegment {
    LiveSegment(id: SegmentID(speaker: speaker, index: index), startSec: start, endSec: start + 2, text: text, isFinal: true, failureMessage: nil, person: person)
}

func state(transcript: [LiveSegment], isRecording: Bool, errors: [String]) -> LiveViewState {
    makeLiveViewState(transcript: transcript, translations: [:], displayMode: .bilingual, failedTranslations: [], assistantCard: nil, phase: isRecording ? .recording : .idle, newPersonNumber: 9, isPaused: false, isMicMuted: false, canToggleMic: true, isInPerson: false, canStart: true, startedAt: nil, statusText: "Hazır", languageText: "Fince", errors: errors)
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
            phase: .recording, newPersonNumber: 9, isPaused: false, isMicMuted: false, canToggleMic: true, isInPerson: false, canStart: true, startedAt: nil, statusText: "", languageText: "", errors: []
        )
        #expect(viewState.latestOthersSentence == "Günaydın.")
    }

    // Ada: ana satır son cümlenin Türkçesi, alt satır çevirisi beklenen en yeni orijinal (canlı).
    @Test func islandShowsTurkishAndPendingOriginal() {
        let first: LiveSegment = seg(.others, 0, 1, "Hyvää huomenta.", person: 1)
        let second: LiveSegment = seg(.others, 1, 3, "Aloitetaan.", person: 1)
        let viewState: LiveViewState = makeLiveViewState(
            transcript: [first, second], translations: [first.id: "Günaydın."], displayMode: .bilingual, failedTranslations: [], assistantCard: nil,
            phase: .recording, newPersonNumber: 9, isPaused: false, isMicMuted: false, canToggleMic: true, isInPerson: false, canStart: true, startedAt: nil, statusText: "", languageText: "", errors: []
        )
        #expect(viewState.islandLine == IslandLine(speaker: .others, person: 1, primary: "Günaydın.", primaryIsOriginal: false, secondary: "Aloitetaan."))
        #expect(viewState.persons == [1])
    }

    // Her şey çevrildiyse "İki dil"de alt satır orijinal, "Sadece Türkçe"de alt satır yok; en fazla son iki cümle.
    @Test func islandLineModes() {
        let segments: [LiveSegment] = [seg(.others, 0, 1, "Yksi.", person: 1), seg(.others, 1, 3, "Kaksi.", person: 1), seg(.others, 2, 5, "Kolme.", person: 1)]
        let blocks: [SpeakerBlock] = groupBySpeaker(transcript: segments)
        let all: [SegmentID: String] = [segments[0].id: "Bir.", segments[1].id: "İki.", segments[2].id: "Üç."]
        #expect(makeIslandLine(block: blocks[0], translations: all, displayMode: .bilingual) == IslandLine(speaker: .others, person: 1, primary: "İki. Üç.", primaryIsOriginal: false, secondary: "Kaksi. Kolme."))
        #expect(makeIslandLine(block: blocks[0], translations: all, displayMode: .turkishOnly)?.secondary == nil)
        #expect(makeIslandLine(block: blocks[0], translations: all, displayMode: .originalOnly) == IslandLine(speaker: .others, person: 1, primary: "Kaksi. Kolme.", primaryIsOriginal: false, secondary: nil))
        #expect(makeIslandLine(block: blocks[0], translations: [:], displayMode: .bilingual)?.primaryIsOriginal == true)
    }

    // Kayıt durunca da ada "Bitiriliyor…" için görünür kalır.
    @Test func islandVisibleWhileFinishing() {
        let finishing: LiveViewState = makeLiveViewState(
            transcript: [], translations: [:], displayMode: .bilingual, failedTranslations: [], assistantCard: nil,
            phase: .finishing, newPersonNumber: 9, isPaused: false, isMicMuted: false, canToggleMic: true, isInPerson: false, canStart: true, startedAt: nil, statusText: "", languageText: "", errors: []
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

    @Test func originalOnlySkipsLiveTranslation() {
        #expect(!DisplayMode.originalOnly.needsLiveTranslation)
    }
}

@Suite struct KaraokeTests {
    // Söylenen kelimeler tam renk, o anki kelime vurgu renginde (kalın değil: satırlar kırılıp titremesin), gelecekler
    // soluk; metin kelimelerle aynı.
    @Test func activeWordIsEmphasized() {
        let words: [StoredWord] = [
            StoredWord(text: "Hei", startSec: 0, endSec: 1), StoredWord(text: "kaikki", startSec: 1, endSec: 2), StoredWord(text: "taas", startSec: 2, endSec: 3),
        ]
        let text: AttributedString = karaokeText(words: words, activeIndex: 1, accent: .blue)
        #expect(String(text.characters) == "Hei kaikki taas")
        let accented: [String] = text.runs.compactMap { (run: AttributedString.Runs.Run) -> String? in
            run.foregroundColor == .blue ? String(text[run.range].characters) : nil
        }
        #expect(accented == [" kaikki"])
        #expect(text.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }
}
