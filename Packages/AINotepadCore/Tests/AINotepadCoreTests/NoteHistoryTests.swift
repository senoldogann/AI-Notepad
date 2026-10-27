import Foundation
import Testing
@testable import AINotepadCore

@Suite struct NoteHistoryTests {
    private func note(title: String) -> MeetingNote {
        MeetingNote(title: title, summary: "Özet \(title)", decisions: [], tasks: [], glossary: [])
    }

    private func record(note: MeetingNote?) -> MeetingRecord {
        MeetingRecord(
            id: "1", title: note?.title ?? "Toplantı", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil, language: .finnish,
            status: .done, failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: note,
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
    }

    // Not değişince eski not en yeni sürüm olarak başa eklenir; geçmiş en fazla 10 sürüm tutar (en eskisi düşer).
    @Test func previousNoteIsPushedNewestFirstAndCapped() {
        let start: MeetingRecord = record(note: note(title: "0"))
        let final: MeetingRecord = (1...12).reduce(start) { (current: MeetingRecord, step: Int) -> MeetingRecord in
            withNoteVersion(
                updated: current.with(note: note(title: "\(step)")), previous: current, reason: "Not yenilendi",
                savedAt: Date(timeIntervalSince1970: Double(step))
            )
        }
        #expect(final.note?.title == "12")
        #expect(final.noteHistory?.count == noteHistoryLimit)
        #expect(final.noteHistory?.map(\.note.title) == ["11", "10", "9", "8", "7", "6", "5", "4", "3", "2"])
        #expect(final.noteHistory?.first?.savedAt == Date(timeIntervalSince1970: 12))
    }

    // Not değişmediyse (ör. yenileme başarısız, eski not kaldı) ya da önceki not yoksa geçmiş değişmez.
    @Test func unchangedOrMissingNoteAddsNoVersion() {
        let current: MeetingRecord = record(note: note(title: "A"))
        #expect(withNoteVersion(updated: current, previous: current, reason: "Not yenilendi", savedAt: Date()).noteHistory == nil)
        let first: MeetingRecord = record(note: nil)
        let written: MeetingRecord = first.with(note: note(title: "A"))
        #expect(withNoteVersion(updated: written, previous: first, reason: "Tekrar işlendi", savedAt: Date()).noteHistory == nil)
    }

    // Geri yükleme seçilen sürümü not yapar, onu geçmişten çıkarır ve şimdiki notu geçmişe ekler: geri yükleme de geri
    // alınabilir.
    @Test func restoreIsItselfUndoable() throws {
        let original: MeetingRecord = record(note: note(title: "A"))
        let edited: MeetingRecord = withNoteVersion(
            updated: original.with(note: note(title: "B")), previous: original, reason: "Düzenlendi: özeti kısalt", savedAt: Date(timeIntervalSince1970: 1)
        )
        let restored: MeetingRecord = try restoringNoteVersion(record: edited, index: 0, reason: "Geri yüklendi", savedAt: Date(timeIntervalSince1970: 2))
        #expect(restored.note?.title == "A")
        #expect(restored.title == "A")
        #expect(restored.noteHistory == [NoteVersion(savedAt: Date(timeIntervalSince1970: 2), reason: "Geri yüklendi", note: note(title: "B"))])
        let again: MeetingRecord = try restoringNoteVersion(record: restored, index: 0, reason: "Geri yüklendi", savedAt: Date(timeIntervalSince1970: 3))
        #expect(again.note?.title == "B")
        #expect(again.noteHistory?.map(\.note.title) == ["A"])
    }

    // Olmayan sürüm sessizce yok sayılmaz: hangi sıranın istendiği ve geçmişin uzunluğu hatada.
    @Test func restoringMissingVersionThrows() {
        #expect(throws: NoteHistoryError.versionNotFound(index: 0, count: 0)) {
            try restoringNoteVersion(record: record(note: note(title: "A")), index: 0, reason: "Geri yüklendi", savedAt: Date())
        }
    }

    // Eski toplantı dosyalarında (geçmiş alanı yok) okuma bozulmaz; geçmiş kaydedilip geri okunur.
    @Test func historyRoundTripsAndOldFilesDecode() throws {
        let original: MeetingRecord = record(note: note(title: "A"))
        let edited: MeetingRecord = withNoteVersion(
            updated: original.with(note: note(title: "B")), previous: original, reason: "Not yenilendi", savedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded: MeetingRecord = try meetingDecoder().decode(MeetingRecord.self, from: encoder.encode(edited))
        #expect(decoded == edited)
        let old: MeetingRecord = try meetingDecoder().decode(MeetingRecord.self, from: encoder.encode(original))
        #expect(old.noteHistory == nil)
    }
}
