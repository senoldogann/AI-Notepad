import Foundation
import Testing
@testable import AINotepadCore

/// İki toplantılık arşiv: kahve makinesi bilgisi yalnızca ilk toplantının Fince transkriptinde (notta yok).
private func archive() -> [MeetingRecord] {
    let first: MeetingRecord = MeetingRecord(
        id: "a", title: "Toplantı", startedAt: Date(timeIntervalSince1970: 1_790_000_000), endedAt: nil, language: .finnish,
        status: .done, failureMessage: nil, liveSegments: [],
        finalSegments: [
            stored("final-0", .others, 1, 0, "Huomenta. Käydään läpi viikon asiat."),
            stored("final-1", .others, 2, 30, "Kahvikone on taas rikki. Minä tilaan uuden kahvinkeittimen ensi maanantaina."),
            stored("final-2", .others, 1, 60, "Hyvä, kiitos Mikko. Sitten myyntiluvut."),
        ],
        translations: [:], speakerNames: [1: "Aino", 2: "Mikko"],
        note: MeetingNote(title: "Haftalık ekip toplantısı", summary: "Ekip haftalık işleri ve satış rakamlarını konuştu.", decisions: [], tasks: [], glossary: []),
        audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
    let second: MeetingRecord = MeetingRecord(
        id: "b", title: "Toplantı", startedAt: Date(timeIntervalSince1970: 1_791_000_000), endedAt: nil, language: .finnish,
        status: .done, failureMessage: nil, liveSegments: [],
        finalSegments: [stored("final-0", .others, 1, 0, "Ensi vuoden budjetti kasvaa kymmenen prosenttia.")],
        translations: [:], speakerNames: [:],
        note: MeetingNote(title: "Bütçe planlaması", summary: "Gelecek yılın bütçesi yüzde 10 artacak.", decisions: ["Bütçe %10 artacak."], tasks: [], glossary: []),
        audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
    return [second, first]
}

@Suite struct ArchiveQuestionTests {
    // Fince köklerle eşleşen transkript parçası seçilir; eşleşme yoksa en yeni notlar; sınır aşılmaz; kaynaklar parçalara bağlanır.
    @Test func retrievalAndSources() throws {
        let passages: [ArchivePassage] = archivePassages(records: archive())
        #expect(passages.filter { $0.kind == .note }.count == 2)
        let coffee: [ArchivePassage] = relevantPassages(passages: passages, terms: ["kahvikone", "kahvinkeitin", "kahve makinesi"], maxChars: 10_000)
        #expect(coffee.first?.meetingID == "a" && coffee.first?.kind == .transcript && coffee.first?.text.contains("Kahvikone") == true)
        #expect(relevantPassages(passages: passages, terms: ["xyzzy"], maxChars: 10_000).map(\.id) == ["a-note", "b-note"])
        #expect(relevantPassages(passages: passages, terms: ["xyzzy"], maxChars: 80).count == 1)
        let answer: ArchiveAnswer = try parseArchiveAnswer(text: #"{"cevap":"Mikko yenisini sipariş edecek.","kaynaklar":[1,9,1]}"#, passages: coffee)
        #expect(answer.sources.map(\.id) == [coffee[0].id])
    }
}

extension CloudTests {
@Suite struct ArchiveQuestionCloudTests {
    // Gerçek model: Türkçe soru, cevabı yalnızca Fince transkriptte olan bilgi; doğru kişi ve toplantı kaynak gösterilir.
    @Test func turkishQuestionFindsFinnishTranscript() async throws {
        let provider: LLMProvider = .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic)))
        let answer: ArchiveAnswer = try await askArchive(
            question: "Kahve makinesi bozulduğunda ne yapılmasına karar verildi, kim ilgilenecek?",
            records: archive(), userName: "Senol", llm: provider, maxChars: 60_000, now: Date(timeIntervalSince1970: 1_792_000_000)
        )
        #expect(answer.text.contains("Mikko"), "\(answer.text)")
        #expect(answer.sources.contains { $0.meetingID == "a" }, "\(answer.sources.map(\.id))")
    }
}
}
