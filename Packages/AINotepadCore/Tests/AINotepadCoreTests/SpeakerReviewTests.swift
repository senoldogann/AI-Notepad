import Foundation
import Testing
@testable import AINotepadCore

@Suite struct SpeakerReviewTests {
    // Uygulanamayan öneriler (bilinmeyen numara, kendine birleştirme, verilmiş ad, ikinci ad) listeye girmez.
    @Test func parseDropsInapplicableSuggestions() throws {
        let review: SpeakerReview = try parseSpeakerReview(text: #"""
        {"adlar":[{"konusmaci":1,"ad":" Aino ","neden":"[00:03] Sen: Kiitos, Aino."},
                  {"konusmaci":1,"ad":"Mikko","neden":"ikinci"},
                  {"konusmaci":2,"ad":"Riikka","neden":"zaten verilmiş"},
                  {"konusmaci":9,"ad":"Pekka","neden":"yok"}],
         "birlestirmeler":[{"kaynak":3,"hedef":1,"neden":"[00:20] cümleyi tamamlıyor"},
                           {"kaynak":1,"hedef":3,"neden":"tekrar"},
                           {"kaynak":2,"hedef":2,"neden":"kendisi"}],
         "supheliler":[{"zaman":"00:41","aciklama":"Sen'e cevap gibi"}]}
        """#, persons: [1, 2, 3], speakerNames: [2: "riikka"])
        #expect(review.names == [SpeakerNameSuggestion(person: 1, name: "Aino", reason: "[00:03] Sen: Kiitos, Aino.")])
        #expect(review.merges == [SpeakerMergeSuggestion(from: 3, into: 1, reason: "[00:20] cümleyi tamamlıyor")])
        #expect(review.suspicious == [SuspiciousPassage(time: "00:41", note: "Sen'e cevap gibi")])
        // Şüpheli ana tıklayınca oradan çalınır.
        #expect(timestampSeconds(text: "00:41") == 41)
        #expect(timestampSeconds(text: "[1:02:05]") == 3725)
        #expect(timestampSeconds(text: "yaklaşık 2 dk") == nil)
    }

    // Birleştirmeden sonra kalan öneriler yeni numaraya taşınır; anlamsızlaşanlar düşer.
    @Test func afterMergeRemapsRemainingSuggestions() {
        let review: SpeakerReview = SpeakerReview(
            names: [SpeakerNameSuggestion(person: 3, name: "Aino", reason: "a")],
            merges: [SpeakerMergeSuggestion(from: 3, into: 1, reason: "b"), SpeakerMergeSuggestion(from: 4, into: 3, reason: "c")],
            suspicious: []
        )
        let merged: SpeakerReview = review.afterMerge(from: 3, into: 1)
        #expect(merged.names == [SpeakerNameSuggestion(person: 1, name: "Aino", reason: "a")])
        #expect(merged.merges == [SpeakerMergeSuggestion(from: 4, into: 1, reason: "c")])
        #expect(speakerReviewRequest(segments: [stored("me-0", .me, nil, 0, "Moi.")], speakerNames: [:], userName: "Doğan") == nil)
    }
}

@Suite struct KeytermTests {
    // Ad ve terimler servis kurallarına göre temizlenir, tekilleşir, sınırlanır; uymayanlar atlanır.
    @Test func keytermsAreCleanUniqueAndLimited() {
        let note: MeetingNote = MeetingNote(title: "T", summary: "S", decisions: [], tasks: [], glossary: [
            GlossaryEntry(term: "maahanmuuttopolitiikka", meaning: "göç politikası"),
            GlossaryEntry(term: "aino", meaning: "tekrar"),
            GlossaryEntry(term: "yksi kaksi kolme neljä viisi kuusi", meaning: "çok uzun"),
            GlossaryEntry(term: "Kela; etuudet", meaning: "ayırıcı"),
        ])
        let record: MeetingRecord = MeetingRecord(
            id: "1", title: "T", startedAt: Date(), endedAt: nil, language: .finnish, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [], translations: [:], speakerNames: [2: "Aino", 1: "Mikko"], note: note,
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        #expect(meetingKeyterms(records: [record], userName: "Senol", limit: 10) == ["Senol", "Mikko", "Aino", "maahanmuuttopolitiikka", "Kela etuudet"])
        #expect(meetingKeyterms(records: [record], userName: "", limit: 2) == ["Mikko", "Aino"])
    }
}

extension CloudTests {
@Suite struct SpeakerReviewCloudTests {
    // Gerçek model: hitap edilip cevap veren kişiye ad, aynı kişinin ikiye bölünmüş cümlesine birleştirme önerir.
    @Test func reviewSuggestsNameAndMerge() async throws {
        let segments: [StoredSegment] = [
            stored("final-0", .others, 1, 0, "Hyvää huomenta kaikille, minä olen Aino ja vedän tämän palaverin."),
            stored("me-0", .me, nil, 4, "Huomenta Aino. Mikko, onko raportti valmis?"),
            stored("final-1", .others, 2, 8, "Kyllä, raportti on valmis. Lähetin sen eilen illalla, ja"),
            stored("final-2", .others, 3, 12, "kuten sanoin, minä Mikko vastaan myös budjettiosiosta."),
            stored("final-3", .others, 1, 18, "Kiitos Mikko. Sitten seuraava aihe."),
        ]
        let request: LLMRequest = try #require(speakerReviewRequest(segments: segments, speakerNames: [:], userName: "Doğan"))
        let review: SpeakerReview = try await requestStructured(provider: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))), request: request) { (text: String) throws -> SpeakerReview in
            try parseSpeakerReview(text: text, persons: [1, 2, 3], speakerNames: [:])
        }
        #expect(review.names.contains { $0.person == 1 && $0.name == "Aino" }, "adlar: \(review.names)")
        #expect(review.merges.contains { Set([$0.from, $0.into]) == [2, 3] }, "birleştirmeler: \(review.merges)")
    }
}
}
