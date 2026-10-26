import Foundation
import Testing
@testable import AINotepadCore

@Suite struct TaskTrackingTests {
    private let calendar: Calendar = {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return calendar
    }()

    private func record(tasks: [NoteTask]) -> MeetingRecord {
        MeetingRecord(
            id: "1", title: "Toplantı", startedAt: calendar.date(from: DateComponents(year: 2026, month: 12, day: 15, hour: 10))!,
            endedAt: nil, language: .finnish, status: .done, failureMessage: nil, liveSegments: [], finalSegments: [],
            translations: [:], speakerNames: [:],
            note: MeetingNote(title: "Bütçe", summary: "S", decisions: [], tasks: tasks, glossary: []),
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
    }

    // Tamamlandı işareti, notu yeniden yazınca (boşluk/büyük harf farkıyla) aynı göreve bağlı kalır.
    @Test func completionSurvivesNoteRewrite() {
        let task: NoteTask = NoteTask(owner: "Sen", description: "Raporu  gönder", dueDate: "3.1.", isMine: true)
        let done: MeetingRecord = togglingTask(record: record(tasks: [task]), task: task)
        let rewritten: NoteTask = NoteTask(owner: "sen", description: "raporu gönder", dueDate: nil, isMine: true)
        #expect(isTaskDone(record: done, task: rewritten))
        #expect(!isTaskDone(record: togglingTask(record: done, task: rewritten), task: task))
        #expect(isTaskReminded(record: markingReminded(record: done, task: task), task: rewritten))
    }

    // Not yeniden yazılınca (sahip adlandı, açıklama farklı sözcüklerle) işaret benzer göreve geçer; benzemeyen almaz.
    @Test func marksCarryOverToRewrittenTasks() {
        let old: [NoteTask] = [
            NoteTask(owner: "Konuşmacı 2", description: "Raporu cuma gününe kadar göndermek", dueDate: nil, isMine: false),
            NoteTask(owner: "Sen", description: "Sunum slaytlarını hazırlamak", dueDate: nil, isMine: true),
        ]
        let new: [NoteTask] = [
            NoteTask(owner: "Senol", description: "Sunumun slaytlarını hazırlamak", dueDate: "Perşembe", isMine: true),
            NoteTask(owner: "Mikko", description: "Raporu cuma gününe kadar müşteriye göndermek", dueDate: nil, isMine: false),
            NoteTask(owner: "Aino", description: "Bütçeyi onaylamak", dueDate: nil, isMine: false),
        ]
        let carried: [String] = carriedTaskKeys(oldTasks: old, newTasks: new, keys: old.map(taskKey))
        #expect(Set(carried) == Set([taskKey(task: new[0]), taskKey(task: new[1])]))
        #expect(carriedTaskKeys(oldTasks: old, newTasks: [new[2]], keys: old.map(taskKey)).isEmpty)
    }

    // Serbest metin tarihleri: ISO, gün.ay.yıl, yılsız (toplantıdan önceyse gelecek yıl); göreli ve geçersizler nil.
    @Test func dueDatesParseOnlyWhenExplicit() {
        let meeting: Date = calendar.date(from: DateComponents(year: 2026, month: 12, day: 15))!
        #expect(parseDueDate(text: "2027-01-08", meetingDate: meeting, calendar: calendar) == DateComponents(year: 2027, month: 1, day: 8))
        #expect(parseDueDate(text: "perjantaihin 18.12.2026 mennessä", meetingDate: meeting, calendar: calendar) == DateComponents(year: 2026, month: 12, day: 18))
        #expect(parseDueDate(text: "3.1.", meetingDate: meeting, calendar: calendar) == DateComponents(year: 2027, month: 1, day: 3))
        #expect(parseDueDate(text: "20.12.", meetingDate: meeting, calendar: calendar) == DateComponents(year: 2026, month: 12, day: 20))
        #expect(parseDueDate(text: "perjantai", meetingDate: meeting, calendar: calendar) == nil)
        #expect(parseDueDate(text: "5 Kasım", meetingDate: meeting, calendar: calendar) == DateComponents(year: 2027, month: 11, day: 5))
        #expect(parseDueDate(text: "18 Aralık 2026'ya kadar", meetingDate: meeting, calendar: calendar) == DateComponents(year: 2026, month: 12, day: 18))
        #expect(parseDueDate(text: "Cuma", meetingDate: meeting, calendar: calendar) == nil)
        #expect(parseDueDate(text: "31.2.2027", meetingDate: meeting, calendar: calendar) == nil)
        let task: NoteTask = NoteTask(owner: "Aino", description: "Esitys", dueDate: "3.1.", isMine: false)
        let draft: ReminderDraft = reminderDraft(record: record(tasks: [task]), task: task, calendar: calendar)
        #expect(draft.title == "Esitys")
        #expect(draft.due == DateComponents(year: 2027, month: 1, day: 3))
        #expect(draft.notes.contains("Bütçe") && draft.notes.contains("Aino"))
    }
}
