import Foundation
import Testing
@testable import AINotepadCore

func stored(_ key: String, _ speaker: Speaker, _ person: Int?, _ start: Double, _ text: String) -> StoredSegment {
    StoredSegment(key: key, speaker: speaker, person: person, startSec: start, endSec: start + 2, text: text)
}

@Suite struct MeetingNoteTests {
    @Test func noteRequestHasSchemaAndUserName() throws {
        let request: ClaudeRequest = try #require(meetingNoteRequest(
            segments: [stored("final-0", .others, 1, 5, "Voisitko tehdä diat?"), stored("me-0", .me, nil, 9, "Teen ne.")],
            speakerNames: [1: "Aino"],
            userName: "Doğan"
        ))
        #expect(request.model == .opus)
        #expect(request.jsonSchema?.contains("gorevler") == true)
        #expect(request.userText.contains("[00:05] Aino: Voisitko tehdä diat?"))
        #expect(request.userText.contains("[00:09] Sen: Teen ne."))
        #expect(request.system.contains("Doğan"))
        #expect(meetingNoteRequest(segments: [], speakerNames: [:], userName: "Doğan") == nil)
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

    @Test func markdownUsesSpeakerNames() {
        let record: MeetingRecord = MeetingRecord(
            id: "20261026-100000", title: "Proje toplantısı", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil,
            language: .finnish, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [stored("final-0", .others, 1, 5, "Hyvää huomenta.")],
            translations: [:], speakerNames: [1: "Aino"],
            note: MeetingNote(title: "Proje toplantısı", summary: "Kısa.", decisions: [], tasks: [NoteTask(owner: "Sen", description: "Slaytlar", dueDate: nil, isMine: true)], glossary: []),
            audioDeleted: false
        )
        let markdown: String = meetingMarkdown(record: record)
        #expect(markdown.hasPrefix("# Proje toplantısı"))
        #expect(markdown.contains("**[00:05] Aino:** Hyvää huomenta."))
        #expect(markdown.contains("- [ ] **Sen** — Slaytlar ⭐"))
        #expect(!markdown.contains("Konuşmacı 1"))
    }
}

extension CloudTests {
@Suite struct MeetingNoteCloudTests {
    @Test func noteFromDialog() async throws {
        let request: ClaudeRequest = try #require(meetingNoteRequest(
            segments: [
                stored("final-0", .others, 1, 0, "Hyvää huomenta, aloitetaan palaveri."),
                stored("final-1", .others, 2, 3, "Kiitos. Minulla on raportti valmiina."),
                stored("final-2", .others, 1, 7, "Hienoa, esitys on perjantaina. Voisitko sinä tehdä diat?"),
                stored("me-0", .me, nil, 10, "Kyllä, teen diat torstaihin mennessä."),
            ],
            speakerNames: [1: "Aino"],
            userName: "Doğan"
        ))
        let note: MeetingNote = try parseMeetingNote(text: try await sendClaude(apiKey: try cloudKey(account: .anthropic), request: request))
        #expect(!note.title.isEmpty)
        #expect(note.tasks.contains { $0.isMine }, "görevler: \(note.tasks)")
    }
}
}
