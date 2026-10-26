import Foundation
import Testing
@testable import AINotepadCore

@Suite struct PeopleTests {
    // Aynı ad iki toplantıda tek kişi; konuşma süreleri, adına görevler ve kayıtlı sesi; kullanıcı listede yok.
    @Test func directoryGroupsByNameAcrossMeetings() {
        let note: (String) -> MeetingNote = { (owner: String) -> MeetingNote in
            MeetingNote(title: "Not", summary: "S", decisions: [], tasks: [NoteTask(owner: owner, description: "Raporu gönder", dueDate: nil, isMine: false)], glossary: [])
        }
        let older: MeetingRecord = MeetingRecord(
            id: "1", title: "T", startedAt: Date(timeIntervalSince1970: 100), endedAt: nil, language: .finnish, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [stored("final-0", .others, 1, 0, "Moi"), stored("final-1", .others, 2, 10, "Hei")],
            translations: [:], speakerNames: [1: "Aino", 2: "Senol"], note: note("aino"), audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let newer: MeetingRecord = MeetingRecord(
            id: "2", title: "T", startedAt: Date(timeIntervalSince1970: 200), endedAt: nil, language: .finnish, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [stored("final-0", .others, 3, 0, "Terve")],
            translations: [:], speakerNames: [3: "AINO"], note: note("Mikko"), audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let voice: RegisteredVoice = RegisteredVoice(name: "Aino", voiceprint: Voiceprint(embedding: [1], seconds: 30), updatedAt: Date())
        let people: [PersonSummary] = peopleDirectory(records: [older, newer], voices: [voice], userName: "senol")
        #expect(people.map(\.name) == ["AINO"])
        #expect(people.first?.meetings.map(\.meetingID) == ["2", "1"])
        #expect(people.first?.totalSeconds == 4)
        #expect(people.first?.tasks.map(\.meetingID) == ["1"])
        #expect(people.first?.hasVoiceprint == true)
    }
}
