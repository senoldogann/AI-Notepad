import Foundation
import Testing
@testable import AINotepadCore

func block(_ speaker: Speaker, _ index: Int, _ start: Double, _ text: String, person: Int?) -> LiveSegment {
    LiveSegment(id: SegmentID(speaker: speaker, index: index), startSec: start, endSec: start + 2, text: text, isFinal: true, failureMessage: nil, person: person)
}

@Suite struct MeetingPromptsTests {
    @Test func transcriptLinesOnePerSegment() {
        let segments: [LiveSegment] = [
            block(.others, 0, 5, "Hyvää huomenta.", person: 1),
            block(.others, 1, 8, "Aloitetaan.", person: 1),
            block(.me, 0, 62, "Kiitos.", person: nil),
        ]
        #expect(transcriptLines(segments: segments) == "[00:05] Konuşmacı 1: Hyvää huomenta.\n[00:08] Konuşmacı 1: Aloitetaan.\n[01:02] Sen: Kiitos.")
    }

    @Test func emptyWindowNeedsNoRequest() {
        #expect(missedSummaryRequest(segments: [], nowSec: 300, windowSec: 180) == nil)
        #expect(missedSummaryRequest(segments: [block(.others, 0, 10, "Vanha.", person: nil)], nowSec: 300, windowSec: 180) == nil)
    }

    // Aynı konuşmacının ardışık bölümleri tek blokta birleşir; pencere bloğa değil bölüme göre seçilmeli.
    @Test func windowFiltersSegmentsNotBlocks() throws {
        let segments: [LiveSegment] = [
            block(.others, 0, 10, "Vanha asia.", person: 1),
            block(.others, 1, 200, "Uusi asia.", person: 1),
        ]
        let request: ClaudeRequest = try #require(missedSummaryRequest(segments: segments, nowSec: 300, windowSec: 180))
        #expect(request.model == .opus)
        #expect(request.userText.contains("Uusi asia."))
        #expect(!request.userText.contains("Vanha asia."))
        #expect(request.jsonSchema != nil)
    }

    @Test func parseMissedSummaryJSON() throws {
        let summary: MissedSummary = try parseMissedSummary(text: #"{"konu":"Rapor","kararlar":["Cuma teslim"],"sendenIstenenler":["Sunumu hazırla"]}"#)
        #expect(summary == MissedSummary(topic: "Rapor", decisions: ["Cuma teslim"], askedOfYou: ["Sunumu hazırla"]))
    }

    @Test func questionTranscriptCapped() {
        let segments: [LiveSegment] = [
            block(.others, 0, 0, "Hyvin vanha.", person: 1),
            block(.others, 1, 7300, "Tuore.", person: 1),
        ]
        let request: ClaudeRequest = questionRequest(segments: segments, question: "Ne dendi?")
        #expect(request.userText.contains("Tuore."))
        #expect(!request.userText.contains("Hyvin vanha."))
        #expect(request.userText.contains("Ne dendi?"))
    }

    @Test func translationPromptHasContext() {
        let request: ClaudeRequest = translationRequest(sentence: "Kuka tekee diat?", context: ["Esitys on perjantaina."])
        #expect(request.model == .haiku)
        #expect(request.timeoutSec == 20)
        #expect(request.userText.contains("Esitys on perjantaina."))
        #expect(request.userText.contains("Kuka tekee diat?"))
    }
}

extension CloudTests {
@Suite struct MeetingPromptsCloudTests {
    @Test func translatesFinnishToTurkish() async throws {
        let text: String = try await sendClaude(
            apiKey: try cloudKey(account: .anthropic),
            request: translationRequest(sentence: "Seuraavalla viikolla meidän pitää palauttaa raportti.", context: [])
        )
        #expect(text.lowercased().contains("rapor"), "metin: \(text)")
    }

    @Test func missedSummaryFromDialog() async throws {
        let segments: [LiveSegment] = [
            block(.others, 0, 0, "Hyvää huomenta, aloitetaan palaveri.", person: 1),
            block(.others, 1, 3, "Kiitos. Minulla on raportti valmiina.", person: 2),
            block(.others, 2, 7, "Hienoa, esitys on perjantaina. Voisitko sinä tehdä diat?", person: 1),
        ]
        let request: ClaudeRequest = try #require(missedSummaryRequest(segments: segments, nowSec: 12, windowSec: 180))
        let summary: MissedSummary = try parseMissedSummary(text: try await sendClaude(apiKey: try cloudKey(account: .anthropic), request: request))
        #expect(!summary.topic.isEmpty)
    }
}
}

@Suite struct TranslationContextTests {
    @Test func contextIsPreviousThreeOthersFinals() {
        let transcript: [LiveSegment] = [
            block(.others, 0, 0, "a", person: nil),
            block(.me, 0, 1, "minun", person: nil),
            block(.others, 1, 2, "b", person: nil),
            block(.others, 2, 4, "c", person: nil),
            block(.others, 3, 6, "d", person: nil),
            block(.others, 4, 8, "e", person: nil),
        ]
        #expect(translationContext(transcript: transcript, before: SegmentID(speaker: .others, index: 4), count: 3) == ["b", "c", "d"])
    }
}
