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

@Suite struct HighlightTests {
    // İşaret, düğmeye basılmadan önceki sözü (20 sn) ve hemen sonrasını kapsar; paragrafta açılıp kapanır.
    @Test func highlightsMarkNearbySegmentsAndToggle() {
        let segments: [StoredSegment] = [stored("final-0", .others, 1, 0, "Alku"), stored("final-1", .others, 1, 40, "Tärkeä päätös"), stored("final-2", .others, 1, 100, "Loppu")]
        let marked: [StoredSegment] = markingHighlights(segments: segments, highlights: [Highlight(startSec: 55)])
        #expect(marked.map(\.text) == ["Alku", "★ Tärkeä päätös", "Loppu"])
        let paragraph: TranscriptParagraph = TranscriptParagraph(id: "p", speaker: .others, person: 1, startSec: 40, endSec: 42, text: "Tärkeä päätös", turkish: nil, words: [])
        let on: [Highlight] = togglingHighlight(highlights: [], paragraph: paragraph)
        #expect(isHighlighted(paragraph: paragraph, highlights: on))
        #expect(togglingHighlight(highlights: on, paragraph: paragraph).isEmpty)
    }
}

extension CloudTests {
@Suite struct HighlightCloudTests {
    // Gerçek model: kullanıcının işaretlediği küçük ayrıntı (kahve makinesi) özette yer alır.
    @Test func bookmarkedDetailReachesSummary() async throws {
        let segments: [StoredSegment] = [
            stored("final-0", .others, 1, 0, "Huomenta. Käydään läpi ensi vuoden budjetti, se kasvaa kymmenen prosenttia."),
            stored("final-1", .others, 2, 8, "Markkinointi saa suurimman osan lisäyksestä, ja rekrytoimme kaksi uutta myyjää."),
            stored("final-2", .others, 1, 16, "Ai niin, kahvikone vaihdetaan ensi kuussa uuteen."),
            stored("final-3", .others, 2, 22, "Selvä. Sitten seuraava palaveri on perjantaina."),
        ]
        let note: MeetingNote = try #require(try await writeMeetingNote(
            segments: markingHighlights(segments: segments, highlights: [Highlight(startSec: 20)]), speakerNames: [:], userName: "Senol",
            template: .general, llm: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic)))
        ))
        let text: String = (note.summary + " " + note.decisions.joined(separator: " ")).lowercased()
        #expect(text.contains("kahve"), "\(text)")
    }
}
}
