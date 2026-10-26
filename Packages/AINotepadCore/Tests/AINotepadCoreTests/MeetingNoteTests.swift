import Foundation
import Testing
@testable import AINotepadCore

func stored(_ key: String, _ speaker: Speaker, _ person: Int?, _ start: Double, _ text: String) -> StoredSegment {
    StoredSegment(key: key, speaker: speaker, person: person, startSec: start, endSec: start + 2, text: text, words: nil)
}

@Suite struct MeetingNoteTests {
    @Test func noteRequestHasSchemaAndUserName() throws {
        let request: LLMRequest = try #require(meetingNoteRequest(
            segments: [stored("final-0", .others, 1, 5, "Voisitko tehdä diat?"), stored("me-0", .me, nil, 9, "Teen ne.")],
            speakerNames: [1: "Aino"],
            userName: "Doğan",
            template: .general
        ))
        #expect(request.tier == .smart)
        #expect(request.jsonSchema?.contains("gorevler") == true)
        #expect(request.userText.contains("[00:05] Aino: Voisitko tehdä diat?"))
        #expect(request.userText.contains("[00:09] Sen: Teen ne."))
        #expect(request.system.contains("Doğan"))
        #expect(meetingNoteRequest(segments: [], speakerNames: [:], userName: "Doğan", template: .general) == nil)
    }

    @Test func parseMeetingNoteJSON() throws {
        let note: MeetingNote = try parseMeetingNote(text: #"""
        {"baslik":"Proje toplantısı","ozet":"Rapor konuşuldu.","kararlar":["Cuma teslim"],
         "gorevler":[{"sahip":"Sen","aciklama":"Slaytları hazırla","tarih":"Cuma","benimMi":true},
                     {"sahip":"Aino","aciklama":"Raporu gönder","tarih":"","benimMi":false}],
         "sozluk":[{"terim":"palauttaa","anlam":"teslim etmek"}]}
        """#)
        #expect(note == MeetingNote(
            title: "Proje toplantısı", summary: "Rapor konuşuldu.", decisions: ["Cuma teslim"],
            tasks: [NoteTask(owner: "Sen", description: "Slaytları hazırla", dueDate: "Cuma", isMine: true),
                    NoteTask(owner: "Aino", description: "Raporu gönder", dueDate: nil, isMine: false)],
            glossary: [GlossaryEntry(term: "palauttaa", meaning: "teslim etmek")]
        ))
    }

    // Model arada bir şemaya uyan ama yalnızca başlıklı not döndürür; kullanılamaz, yeniden istenir.
    @Test func noteWithoutSummaryIsEmpty() {
        #expect(throws: LLMError.empty) {
            try parseMeetingNote(text: #"{"baslik":"Proje","gorevler":[],"kararlar":[],"ozet":" ","sozluk":[]}"#)
        }
    }

    @Test func markdownUsesSpeakerNames() {
        let record: MeetingRecord = MeetingRecord(
            id: "20261026-100000", title: "Proje toplantısı", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil,
            language: .finnish, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [stored("final-0", .others, 1, 5, "Hyvää huomenta.")],
            translations: [:], speakerNames: [1: "Aino"],
            note: MeetingNote(title: "Proje toplantısı", summary: "Kısa.", decisions: [], tasks: [NoteTask(owner: "Sen", description: "Slaytlar", dueDate: nil, isMine: true)], glossary: []),
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let markdown: String = meetingMarkdown(record: record)
        #expect(markdown.hasPrefix("# Proje toplantısı"))
        #expect(markdown.contains("**[00:05] Aino:** Hyvää huomenta."))
        #expect(markdown.contains("## Senin görevlerin\n\n- [ ] **Sen** — Slaytlar"))
        // Görevler özetten önce: toplantıdan sonra ilk bakılacak şey.
        #expect(markdown.range(of: "Senin görevlerin")!.lowerBound < markdown.range(of: "## Özet")!.lowerBound)
        #expect(!markdown.contains("Konuşmacı 1"))
    }
}

extension CloudTests {
@Suite struct MeetingNoteCloudTests {
    @Test func noteFromDialog() async throws {
        let request: LLMRequest = try #require(meetingNoteRequest(
            segments: [
                stored("final-0", .others, 1, 0, "Hyvää huomenta, aloitetaan palaveri."),
                stored("final-1", .others, 2, 3, "Kiitos. Minulla on raportti valmiina."),
                stored("final-2", .others, 1, 7, "Hienoa, esitys on perjantaina. Voisitko sinä tehdä diat?"),
                stored("me-0", .me, nil, 10, "Kyllä, teen diat torstaihin mennessä."),
            ],
            speakerNames: [1: "Aino"],
            userName: "Doğan",
            template: .general
        ))
        // Uygulamayla aynı yol: arada bir gelen boş yanıt yeniden istenir.
        let note: MeetingNote = try await requestStructured(provider: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))), request: request) { (text: String) throws -> MeetingNote in
            try parseMeetingNote(text: text)
        }
        #expect(!note.title.isEmpty)
        #expect(note.tasks.contains { $0.isMine }, "görevler: \(note.tasks)")
    }
}
}

@Suite struct TranscriptParagraphTests {
    // Aynı konuşmacının art arda bölümleri tek paragraf; yankı ("Sen") araya girip bölmez; 60 sn'yi geçen yeni paragraf.
    @Test func paragraphsMergeSameSpeakerAndDropEchoes() {
        let record: MeetingRecord = MeetingRecord(
            id: "x", title: "T", startedAt: Date(), endedAt: nil, language: .finnish, status: .done, failureMessage: nil,
            liveSegments: [
                StoredSegment(key: "me-0", speaker: .me, person: nil, startSec: 0.2, endSec: 3, text: "Täältä lehdistä tilaisuuteen Myyhon tänään", words: nil),
                StoredSegment(key: "me-1", speaker: .me, person: nil, startSec: 90, endSec: 92, text: "Minulla on kysymys raportista", words: nil),
            ],
            finalSegments: [
                StoredSegment(key: "final-0", speaker: .others, person: 1, startSec: 0, endSec: 3, text: "Täältä lehdistötilaisuuteen. Me ollaan tänään", words: nil),
                StoredSegment(key: "final-1", speaker: .others, person: 1, startSec: 3, endSec: 7, text: "aiheena säästöt.", words: nil),
                StoredSegment(key: "final-2", speaker: .others, person: 1, startSec: 65, endSec: 70, text: "Seuraava dia.", words: nil),
                StoredSegment(key: "final-3", speaker: .others, person: 2, startSec: 80, endSec: 85, text: "Kiitos.", words: nil),
            ],
            translations: ["final-0": "Basın toplantısından.", "final-1": "Konu tasarruflar."],
            speakerNames: [2: "Riikka"], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let paragraphs: [TranscriptParagraph] = transcriptParagraphs(record: record)
        #expect(paragraphs.map(\.id) == ["final-0", "final-2", "final-3", "me-1"])
        #expect(paragraphs[0].text == "Täältä lehdistötilaisuuteen. Me ollaan tänään aiheena säästöt.")
        #expect(paragraphs[0].turkish == "Basın toplantısından. Konu tasarruflar.")
        #expect(paragraphs[0].endSec == 7)
        #expect(paragraphLabel(paragraph: paragraphs[2], speakerNames: record.speakerNames) == "Riikka")
        // Zaman çizgisi uzun sessizlikte bölünür; paylar çok konuşandan aza.
        let first: SpeakerKey = SpeakerKey(speaker: .others, person: 1)
        #expect(speakerSpans(paragraphs: paragraphs).map(\.startSec) == [0, 65, 80, 90])
        #expect(speakerShares(paragraphs: paragraphs).map(\.key) == [first, SpeakerKey(speaker: .others, person: 2), SpeakerKey(speaker: .me, person: nil)])
        #expect(speakerShares(paragraphs: paragraphs).first?.seconds == 12)
    }
}
