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

    // Not yeniden yazılınca araca gönderildi işareti de (araç başına) benzer yeni göreve geçer: görev Linear'da ikinci
    // kez açılmaz. Değişmeyen görev kendi kimliğini korur.
    @Test func sentTaskMarksSurviveRewrite() {
        let old: [NoteTask] = [
            NoteTask(owner: "Sen", description: "Sunum slaytlarını hazırlamak", dueDate: nil, isMine: true),
            NoteTask(owner: "Aino", description: "Bütçeyi onaylamak", dueDate: nil, isMine: false),
        ]
        let new: [NoteTask] = [
            NoteTask(owner: "Senol", description: "Sunumun slaytlarını hazırlamak", dueDate: "Perşembe", isMine: true),
            old[1],
        ]
        let marked: MeetingRecord = record(tasks: old)
            .markingTaskSent(trackerID: "linear", task: old[0])
            .markingTaskSent(trackerID: "jira", task: old[1])
        let rewritten: MeetingRecord = record(tasks: new)
        let carried: MeetingRecord = withCarriedTaskMarks(old: marked, new: rewritten)
        #expect(carried.sentTaskKeys == ["linear": [taskKey(task: new[0])], "jira": [taskKey(task: old[1])]])
        #expect(withCarriedTaskMarks(old: rewritten, new: rewritten).sentTaskKeys == nil)
    }

    // Uzun not işi sürerken diğer cihazda konan işaretler (eski notun görevlerine) işin sonucuna taşınır; gönderim
    // işaretleri eklenir, Apple Notlar anının en eskisi kalır.
    @Test func jobResultKeepsMarksMadeDuringJob() {
        let oldTask: NoteTask = NoteTask(owner: "Sen", description: "Sunum slaytlarını hazırlamak", dueDate: nil, isMine: true)
        let newTask: NoteTask = NoteTask(owner: "Senol", description: "Sunumun slaytlarını hazırlamak", dueDate: nil, isMine: true)
        let start: MeetingRecord = record(tasks: [oldTask])
        let early: Date = Date(timeIntervalSince1970: 1_000)
        let onDisk: MeetingRecord = togglingTask(record: start, task: oldTask)
            .markingSent(destinationID: "slack")
            .markingTaskSent(trackerID: "linear", task: oldTask)
            .with(notesSentAt: early)
        let result: MeetingRecord = record(tasks: [newTask]).with(notesSentAt: Date(timeIntervalSince1970: 2_000))
        let saved: MeetingRecord = withJobMarks(old: onDisk, result: result)
        #expect(saved.note?.tasks == [newTask])
        #expect(saved.completedTasks == [taskKey(task: newTask)])
        #expect(saved.sentTaskKeys == ["linear": [taskKey(task: newTask)]])
        #expect(saved.sentDestinationIDs == ["slack"])
        #expect(saved.notesSentAt == early)
    }

    // İş sürerken diğer cihazda kaldırılan işaret işin sonucunda geri gelmez: diskteki kayıt esastır.
    @Test func jobResultKeepsMarkRemovedDuringJob() {
        let task: NoteTask = NoteTask(owner: "Sen", description: "Sunum slaytlarını hazırlamak", dueDate: nil, isMine: true)
        let start: MeetingRecord = togglingTask(record: record(tasks: [task]), task: task)
        let onDisk: MeetingRecord = togglingTask(record: start, task: task)
        let saved: MeetingRecord = withJobMarks(old: onDisk, result: record(tasks: [task]))
        #expect(saved.completedTasks ?? [] == [])
    }

    // iCloud çakışması: iPhone eski notun görevini işaretleyip gönderirken Mac notu yeniden yazdı. İşaretler yeni notun
    // benzer görevine taşınır, notun gönderim işaretleri kalır.
    @Test func conflictCarriesMarksOntoRewrittenNote() {
        let oldTask: NoteTask = NoteTask(owner: "Sen", description: "Sunum slaytlarını hazırlamak", dueDate: nil, isMine: true)
        let newTask: NoteTask = NoteTask(owner: "Senol", description: "Sunumun slaytlarını hazırlamak", dueDate: nil, isMine: true)
        let phone: MeetingRecord = togglingTask(record: record(tasks: [oldTask]), task: oldTask)
            .markingTaskSent(trackerID: "linear", task: oldTask)
            .markingSent(destinationID: "slack")
        let mac: MeetingRecord = record(tasks: [newTask])
        let merged: MeetingRecord = mergingConflictVersions(current: mac, others: [phone])
        #expect(merged.note?.tasks == [newTask])
        #expect(merged.completedTasks == [taskKey(task: newTask)])
        #expect(merged.sentTaskKeys == ["linear": [taskKey(task: newTask)]])
        #expect(merged.sentDestinationIDs == ["slack"])
    }

    // Serbest metin tarihleri: ISO, gün.ay.yıl, yılsız (toplantıdan önceyse gelecek yıl); göreli ve geçersizler nil.
    @Test func dueDatesParseOnlyWhenExplicit() {
        let meeting: Date = calendar.date(from: DateComponents(year: 2026, month: 12, day: 15))!
        #expect(parseDueDate(text: "2027-01-08", meetingDate: meeting, calendar: calendar, language: .turkish) == DateComponents(year: 2027, month: 1, day: 8))
        #expect(parseDueDate(text: "perjantaihin 18.12.2026 mennessä", meetingDate: meeting, calendar: calendar, language: .turkish) == DateComponents(year: 2026, month: 12, day: 18))
        #expect(parseDueDate(text: "3.1.", meetingDate: meeting, calendar: calendar, language: .turkish) == DateComponents(year: 2027, month: 1, day: 3))
        #expect(parseDueDate(text: "20.12.", meetingDate: meeting, calendar: calendar, language: .turkish) == DateComponents(year: 2026, month: 12, day: 20))
        #expect(parseDueDate(text: "perjantai", meetingDate: meeting, calendar: calendar, language: .turkish) == nil)
        #expect(parseDueDate(text: "5 Kasım", meetingDate: meeting, calendar: calendar, language: .turkish) == DateComponents(year: 2027, month: 11, day: 5))
        #expect(parseDueDate(text: "18 Aralık 2026'ya kadar", meetingDate: meeting, calendar: calendar, language: .turkish) == DateComponents(year: 2026, month: 12, day: 18))
        #expect(parseDueDate(text: "Cuma", meetingDate: meeting, calendar: calendar, language: .turkish) == nil)
        #expect(parseDueDate(text: "31.2.2027", meetingDate: meeting, calendar: calendar, language: .turkish) == nil)
        // Ay adları notun dilinde okunur: İngilizce ay-gün, Fince çekimli ay adı.
        #expect(parseDueDate(text: "by November 5, 2027", meetingDate: meeting, calendar: calendar, language: .english) == DateComponents(year: 2027, month: 11, day: 5))
        #expect(parseDueDate(text: "5 Dec", meetingDate: meeting, calendar: calendar, language: .english) == DateComponents(year: 2027, month: 12, day: 5))
        #expect(parseDueDate(text: "18. joulukuuta", meetingDate: meeting, calendar: calendar, language: .finnish) == DateComponents(year: 2026, month: 12, day: 18))
        #expect(parseDueDate(text: "5 Kasım", meetingDate: meeting, calendar: calendar, language: .english) == nil)
        let task: NoteTask = NoteTask(owner: "Aino", description: "Esitys", dueDate: "3.1.", isMine: false)
        let draft: ReminderDraft = reminderDraft(record: record(tasks: [task]), task: task, language: .turkish, calendar: calendar)
        #expect(draft.title == "Esitys")
        #expect(draft.due == DateComponents(year: 2027, month: 1, day: 3))
        #expect(draft.notes.contains("Bütçe") && draft.notes.contains("Aino"))
    }
}

@Suite struct HighlightTests {
    // Kayıttaki işaret basılmadan önceki sözü (20 sn) kapsar; paragraf işareti yalnızca o paragrafa düşer, komşusuna
    // taşmaz ve kapatınca komşunun işaretini silmez.
    @Test func highlightsMarkNearbySegmentsAndToggle() {
        let segments: [StoredSegment] = [stored("final-0", .others, 1, 0, "Alku"), stored("final-1", .others, 1, 40, "Tärkeä päätös"), stored("final-2", .others, 1, 100, "Loppu")]
        let marked: [StoredSegment] = markingHighlights(segments: segments, highlights: [Highlight(startSec: 55, endSec: nil)])
        #expect(marked.map(\.text) == ["Alku", "★ Tärkeä päätös", "Loppu"])
        let first: TranscriptParagraph = TranscriptParagraph(id: "a", speaker: .others, person: 1, startSec: 30, endSec: 38, text: "Ensin", turkish: nil, words: [])
        let second: TranscriptParagraph = TranscriptParagraph(id: "b", speaker: .others, person: 2, startSec: 40, endSec: 42, text: "Tärkeä päätös", turkish: nil, words: [])
        let paragraphs: [TranscriptParagraph] = [first, second]
        let on: [Highlight] = togglingHighlight(highlights: [], paragraphs: paragraphs, paragraph: second)
        #expect(highlightedParagraphIDs(paragraphs: paragraphs, highlights: on) == ["b"])
        let both: [Highlight] = togglingHighlight(highlights: on, paragraphs: paragraphs, paragraph: first)
        #expect(togglingHighlight(highlights: both, paragraphs: paragraphs, paragraph: first) == on)
        #expect(markingHighlights(segments: [stored("x", .others, 1, 30, "Ensin"), stored("y", .others, 2, 40, "Päätös")], highlights: on).map(\.text) == ["Ensin", "★ Päätös"])
    }
}

extension CloudTests {
@Suite struct NoteResumeCloudTests {
    // Uzun not kaldığı yerden sürer: tüm parçalar kayıtlıysa yalnız başlık ve özet istenir; kayıtlı görevler notta
    // kalır, ilerleme dosyası not bitince silinir.
    @Test func resumesFromSavedProgress() async throws {
        let sentence: String = "Käydään läpi budjetti ja markkinoinnin suunnitelma ensi vuodelle, ja sovitaan aikataulusta. "
        let segments: [StoredSegment] = (0..<300).map { (index: Int) -> StoredSegment in
            stored("final-\(index)", .others, index % 2 + 1, Double(index * 10), sentence)
        }
        let file: URL = try temporaryDirectory().appending(path: "note-progress.json")
        let parts: Int = noteChunks(segments: segments, maxChars: noteChunkMaxChars).count
        let saved: ChunkedNoteState = ChunkedNoteState(
            partSummaries: ["[00:00–50:00] Budjetti ja markkinointisuunnitelma käytiin läpi; aikataulu sovittiin."],
            decisions: ["Markkinointibudjetti kasvaa 10 %."],
            tasks: [NoteTask(owner: "Senol", description: "Aikataulun lähettäminen tiimille", dueDate: "perjantai", isMine: true)],
            glossary: []
        )
        let fingerprint: String = noteFingerprint(segments: segments, speakerNames: [:], userName: "Senol", template: .general, language: .turkish)
        try JSONEncoder().encode(ChunkedNoteProgress(fingerprint: fingerprint, completedParts: parts, state: saved)).write(to: file)
        let note: MeetingNote = try #require(try await writeMeetingNote(
            segments: segments, speakerNames: [:], userName: "Senol", template: .general, myNotes: "",
            language: .turkish, llm: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))), progressFile: file
        ))
        #expect(parts > 1)
        #expect(note.tasks.map(\.description) == ["Aikataulun lähettäminen tiimille"])
        #expect(note.decisions == ["Markkinointibudjetti kasvaa 10 %."])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite struct MyNotesCloudTests {
    // Gerçek model: kullanıcının kendi notundaki madde (park yeri) nota girer; notundaki iş görev olur.
    @Test func myNotesShapeTheNote() async throws {
        let segments: [StoredSegment] = [
            stored("final-0", .others, 1, 0, "Huomenta. Käydään läpi ensi vuoden budjetti, se kasvaa kymmenen prosenttia."),
            stored("final-1", .others, 2, 8, "Markkinointi saa suurimman osan lisäyksestä."),
            stored("final-2", .others, 1, 16, "Ai niin, parkkipaikat vähenevät ensi kuussa remontin takia."),
            stored("final-3", .others, 2, 22, "Selvä. Seuraava palaveri on perjantaina."),
        ]
        let note: MeetingNote = try #require(try await writeMeetingNote(
            segments: segments, speakerNames: [:], userName: "Senol", template: .general,
            myNotes: "## Bana önemli\n- park yeri azalıyor → kiralık yer sor", language: .turkish, llm: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))),
            progressFile: try temporaryDirectory().appending(path: "note-progress.json")
        ))
        let text: String = (note.summary + " " + note.decisions.joined(separator: " ") + " " + note.tasks.map(\.description).joined(separator: " ")).lowercased()
        #expect(text.contains("park"), "\(note)")
        #expect(note.tasks.contains { $0.isMine && $0.description.lowercased().contains("park") }, "\(note.tasks)")
    }
}

@Suite struct NoteEditCloudTests {
    // Gerçek model: "özeti tek cümleye indir" yalnız özeti kısaltır; görev (ve tamamlandı işareti) korunur.
    @Test func editShortensSummaryKeepsTasks() async throws {
        let task: NoteTask = NoteTask(owner: "Senol", description: "Sunumu hazırlamak", dueDate: "Perşembe", isMine: true)
        let note: MeetingNote = MeetingNote(
            title: "Bütçe toplantısı",
            summary: "Ekip gelecek yılın bütçesini konuştu. Pazarlama bütçesi yüzde on artacak. Satış ekibine iki kişi alınacak. Sunum perşembe hazırlanacak ve cuma yönetime sunulacak.",
            decisions: ["Pazarlama bütçesi %10 artacak.", "Satışa iki kişi alınacak."], tasks: [task], glossary: []
        )
        let record: MeetingRecord = MeetingRecord(
            id: "e1", title: "Toplantı", startedAt: Date(), endedAt: nil, language: .finnish, status: .done, failureMessage: nil, liveSegments: [],
            finalSegments: [stored("final-0", .others, 1, 0, "Budjetti kasvaa kymmenen prosenttia ja myyntiin palkataan kaksi.")],
            translations: [:], speakerNames: [:], note: note, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        ).with(completedTasks: [taskKey(task: task)])
        let edited: MeetingRecord = try await editMeetingNote(
            record: record, instruction: "Özeti tek cümleye indir.", llm: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))),
            userName: "Senol"
        )
        let newNote: MeetingNote = try #require(edited.note)
        #expect(newNote.summary.count < note.summary.count, "\(newNote.summary)")
        #expect(newNote.tasks.contains { $0.isMine && $0.description.lowercased().contains("sunum") }, "\(newNote.tasks)")
        #expect(newNote.tasks.contains { isTaskDone(record: edited, task: $0) })
    }
}

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
            segments: markingHighlights(segments: segments, highlights: [Highlight(startSec: 20, endSec: nil)]), speakerNames: [:], userName: "Senol",
            template: .general, myNotes: "", language: .turkish, llm: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))), progressFile: try temporaryDirectory().appending(path: "note-progress.json")
        ))
        let text: String = (note.summary + " " + note.decisions.joined(separator: " ")).lowercased()
        #expect(text.contains("kahve"), "\(text)")
    }
}
}
