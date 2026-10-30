import Foundation
import Testing
@testable import AINotepadCore

func record(id: String, startedAt: Date, status: MeetingStatus, audioDeleted: Bool) -> MeetingRecord {
    MeetingRecord(
        id: id, title: "Palaveri", startedAt: startedAt, endedAt: nil, language: .finnish, status: status,
        failureMessage: nil,
        liveSegments: [StoredSegment(key: "others-0", speaker: .others, person: 1, startSec: 0, endSec: 2, text: "Hei", words: nil)],
        finalSegments: [], translations: ["others-0": "Merhaba"], speakerNames: [1: "Aino"], note: nil, audioDeleted: audioDeleted, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

@Suite struct MeetingStoreTests {
    @Test func saveThenLoadRoundTrip() throws {
        let sessions: URL = try temporaryDirectory()
        let folder: URL = sessions.appending(path: "20261026-100000", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original: MeetingRecord = record(id: "20261026-100000", startedAt: Date(timeIntervalSince1970: 1_800_000_000), status: .done, audioDeleted: false)
        try saveMeeting(record: original, directory: folder)
        let result: MeetingLoadResult = loadMeetings(sessionsDirectory: sessions)
        #expect(result.meetings == [original])
        #expect(result.failures.isEmpty)
    }

    @Test func corruptFileIsReportedNotFatal() throws {
        let sessions: URL = try temporaryDirectory()
        let good: URL = sessions.appending(path: "20261026-100000", directoryHint: .isDirectory)
        let bad: URL = sessions.appending(path: "20261026-110000", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try saveMeeting(record: record(id: "20261026-100000", startedAt: Date(), status: .done, audioDeleted: false), directory: good)
        try Data("{bozuk".utf8).write(to: bad.appending(path: "meeting.json"))
        let result: MeetingLoadResult = loadMeetings(sessionsDirectory: sessions)
        #expect(result.meetings.map(\.id) == ["20261026-100000"])
        #expect(result.failures.map(\.folder) == ["20261026-110000"])
    }

    // iCloud açıkken liste yerel + iCloud klasörünün birleşimidir; aynı toplantı ikisinde varsa yereldeki (işlemesi
    // orada süren) kullanılır.
    @Test func loadingMergesDirectoriesPreferringFirst() throws {
        let local: URL = try temporaryDirectory()
        let cloud: URL = try temporaryDirectory()
        for (root, id, title) in [(local, "20261027-090000", "Yerel"), (cloud, "20261027-090000", "Eski"), (cloud, "20261026-080000", "iCloud")] {
            let folder: URL = root.appending(path: id, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try saveMeeting(record: record(id: id, startedAt: Date(), status: .done, audioDeleted: false).with(folder: title), directory: folder)
        }
        let result: MeetingLoadResult = loadMeetings(directories: [local, cloud])
        #expect(result.meetings.map(\.folder) == ["Yerel", "iCloud"])
        #expect(result.failures.isEmpty)
        #expect(result.downloading.isEmpty)
    }

    @Test func recoveryMarksStaleRecordingsInterrupted() {
        let records: [MeetingRecord] = [
            record(id: "a", startedAt: Date(), status: .recording, audioDeleted: false),
            record(id: "b", startedAt: Date(), status: .processing, audioDeleted: false),
            record(id: "c", startedAt: Date(), status: .done, audioDeleted: false),
        ]
        let changed: [MeetingRecord] = staleStatusesToInterrupt(records: records)
        #expect(changed.map(\.id) == ["a", "b"])
        #expect(changed.allSatisfy { $0.status == .interrupted })
        // Mikrofonsuz kayıt ("Sen" bölümü yok) "Sen" son geçişi istemez.
        #expect(changed.allSatisfy { $0.meNeedsFinalPass == nil })
    }

    // Kayıt sırasında kapanan ve "Sen" bölümü olan toplantıda "Sen" kaydı da yeniden yazıya dökülür; işlemede kapanan değişmez.
    @Test func interruptedRecordingWithMicrophoneNeedsMeFinalPass() {
        let me: StoredSegment = StoredSegment(key: "me-0", speaker: .me, person: nil, startSec: 0, endSec: 1, text: "Moi", words: nil)
        let recording: MeetingRecord = record(id: "a", startedAt: Date(), status: .recording, audioDeleted: false)
        let processing: MeetingRecord = record(id: "b", startedAt: Date(), status: .processing, audioDeleted: false)
        let changed: [MeetingRecord] = staleStatusesToInterrupt(records: [
            recording.with(liveSegments: recording.liveSegments + [me]),
            processing.with(liveSegments: processing.liveSegments + [me]),
        ])
        #expect(changed.map(\.meNeedsFinalPass) == [true, nil])
    }

    @Test func retentionDeletesOnlyOldAudio() {
        let now: Date = Date(timeIntervalSince1970: 1_800_000_000)
        let records: [MeetingRecord] = [
            record(id: "old", startedAt: now.addingTimeInterval(-31 * 86_400), status: .done, audioDeleted: false),
            record(id: "gone", startedAt: now.addingTimeInterval(-40 * 86_400), status: .done, audioDeleted: true),
            record(id: "new", startedAt: now.addingTimeInterval(-29 * 86_400), status: .done, audioDeleted: false),
            // Başarısız ve yarıda kalan toplantının sesi iki kat süre kalır ("Tekrar işle" için), sonra silinir.
            record(id: "failed", startedAt: now.addingTimeInterval(-59 * 86_400), status: .failed, audioDeleted: false),
            record(id: "interrupted", startedAt: now.addingTimeInterval(-61 * 86_400), status: .interrupted, audioDeleted: false),
            record(id: "processing", startedAt: now.addingTimeInterval(-90 * 86_400), status: .processing, audioDeleted: false),
        ]
        #expect(audioToDelete(records: records, now: now, retentionDays: 30) == ["old", "interrupted"])
    }
}

@Suite struct StoredSegmentsTests {
    @Test func keepsOnlyFinalTextSegmentsWithKeys() {
        let transcript: [LiveSegment] = [
            LiveSegment(id: SegmentID(speaker: .others, index: 3), startSec: 1, endSec: 2, text: "Hei", isFinal: true, failureMessage: nil, person: 2),
            LiveSegment(id: SegmentID(speaker: .me, index: 0), startSec: 3, endSec: 4, text: "kesk", isFinal: false, failureMessage: nil, person: nil),
            LiveSegment(id: SegmentID(speaker: .others, index: 4), startSec: 5, endSec: 6, text: "", isFinal: true, failureMessage: "x", person: nil),
        ]
        #expect(storedSegments(transcript: transcript, spokenLanguages: [:]) == [StoredSegment(key: "others-3", speaker: .others, person: 2, startSec: 1, endSec: 2, text: "Hei", words: nil)])
    }
}

@Suite struct MeetingSearchTests {
    @Test func searchMatchesTitleNoteAndTranscriptCaseInsensitive() {
        let plain: MeetingRecord = record(id: "a", startedAt: Date(), status: .done, audioDeleted: false)
        let noted: MeetingRecord = MeetingRecord(
            id: "b", title: "Proje", startedAt: Date(), endedAt: nil, language: .finnish, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [StoredSegment(key: "final-0", speaker: .others, person: 1, startSec: 0, endSec: 1, text: "Raportti valmis", words: nil)],
            translations: [:], speakerNames: [:],
            note: MeetingNote(title: "Proje", summary: "Bütçe konuşuldu", decisions: [], tasks: [], glossary: []), audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        #expect(filterMeetings(records: [plain, noted], query: "").map(\.id) == ["a", "b"])
        #expect(filterMeetings(records: [plain, noted], query: "bütçe").map(\.id) == ["b"])
        #expect(filterMeetings(records: [plain, noted], query: "RAPORTTI").map(\.id) == ["b"])
        #expect(filterMeetings(records: [plain, noted], query: "hei").map(\.id) == ["a"])
        // Türkçe noktasız ı: "ışık" ve "isik" "Işık" başlığını bulur (@ seçicideki aramayla aynı).
        let light: MeetingRecord = noted.with(title: "Işık planı")
        #expect(filterMeetings(records: [plain, light], query: "ışık").map(\.id) == ["b"])
        #expect(filterMeetings(records: [plain, light], query: "isik").map(\.id) == ["b"])
    }
}

@Suite struct MeetingListTests {
    @Test func upsertReplacesAndKeepsNewestFirst() {
        let old: MeetingRecord = record(id: "20261020-090000", startedAt: Date(), status: .done, audioDeleted: false)
        let new: MeetingRecord = record(id: "20261026-090000", startedAt: Date(), status: .recording, audioDeleted: false)
        let list: [MeetingRecord] = upsertMeeting(records: [old], record: new)
        #expect(list.map(\.id) == ["20261026-090000", "20261020-090000"])
        let updated: [MeetingRecord] = upsertMeeting(records: list, record: new.with(status: .done, failureMessage: nil))
        #expect(updated.count == 2)
        #expect(updated.first?.status == .done)
        // Saat dilimi değişince klasör adı yanıltır: sıra başlangıç anına göredir.
        let abroad: MeetingRecord = record(id: "20261027-230000", startedAt: Date(timeIntervalSince1970: 1_000), status: .done, audioDeleted: false)
        let home: MeetingRecord = record(id: "20261027-220000", startedAt: Date(timeIntervalSince1970: 2_000), status: .done, audioDeleted: false)
        #expect(newestFirst(records: [abroad, home]).map(\.id) == ["20261027-220000", "20261027-230000"])
    }
}

@Suite struct MentionTests {
    // "@" bahsi: kelime başında başlar, e-postadaki "@" bahis değildir; seçilince yazılan kısım silinir.
    @Test func mentionQueryAndRemoval() {
        #expect(mentionQuery(text: "Bu toplantıda @perus") == "perus")
        #expect(mentionQuery(text: "@") == "")
        #expect(mentionQuery(text: "senol@example.com") == nil)
        #expect(mentionQuery(text: "Merhaba") == nil)
        #expect(removingMentionQuery(text: "Kararlar neler @peru") == "Kararlar neler ")
        #expect(removingMentionQuery(text: "Kararlar neler") == "Kararlar neler")
    }

    // Öneriler: başlıkta geçen (büyük/küçük ve aksan duyarsız), bitmiş, seçilmemiş toplantılar; en yeni önce.
    @Test func mentionCandidatesFilterAndOrder() {
        let old: MeetingRecord = record(id: "a", startedAt: Date(timeIntervalSince1970: 1_000), status: .done, audioDeleted: false).with(folder: nil)
        let new: MeetingRecord = record(id: "b", startedAt: Date(timeIntervalSince1970: 2_000), status: .done, audioDeleted: false)
        let processing: MeetingRecord = record(id: "c", startedAt: Date(timeIntervalSince1970: 3_000), status: .processing, audioDeleted: false)
        #expect(mentionCandidates(records: [old, new, processing], query: "PALA", excluding: [], limit: 5).map(\.id) == ["b", "a"])
        #expect(mentionCandidates(records: [old, new], query: "", excluding: ["b"], limit: 5).map(\.id) == ["a"])
        #expect(mentionCandidates(records: [old, new], query: "budjetti", excluding: [], limit: 5).isEmpty)
    }
}

@Suite struct RecipeTests {
    // "/" tarif araması: yalnızca baştaki "/"; başlıkta aksan ve büyük/küçük harf duyarsız; kullanıcı tarifi saklanır.
    @Test func recipeQueryCandidatesAndStorage() throws {
        #expect(recipeQuery(text: "/takip") == "takip")
        #expect(recipeQuery(text: "Merhaba /takip") == nil)
        let mine: Recipe = recipeFromQuestion(question: "Satış ekibinin bu çeyrekteki hedefleri ve engelleri neler?", id: "r1")
        #expect(mine.title == "Satış ekibinin bu çeyrekteki hedefleri ve…" && !mine.isBuiltIn)
        let all: [Recipe] = builtInRecipes() + [mine]
        #expect(recipeCandidates(recipes: all, query: "SATIS").map(\.id) == ["r1"])
        #expect(recipeCandidates(recipes: all, query: "").count == all.count)
        let defaults: UserDefaults = try #require(UserDefaults(suiteName: "tarif-testi-\(UUID().uuidString)"))
        try saveUserRecipes(recipes: all, defaults: defaults)
        #expect(try loadUserRecipes(defaults: defaults) == [mine])
    }
}

@Suite struct CloudMoveTests {
    private func makeMeeting(root: URL, id: String, status: MeetingStatus) throws {
        let folder: URL = root.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try saveMeeting(record: record(id: id, startedAt: Date(), status: status, audioDeleted: false), directory: folder)
    }

    // iCloud kapatılınca toplantılar kopyalanır: iCloud'dakiler yerinde kalır (diğer cihaz kaybetmez), yerelde olan atlanır.
    @Test func turningOffCopiesAndKeepsCloud() throws {
        let local: URL = try temporaryDirectory()
        let cloud: URL = try temporaryDirectory()
        try makeMeeting(root: cloud, id: "a", status: .done)
        try makeMeeting(root: cloud, id: "b", status: .done)
        try makeMeeting(root: local, id: "a", status: .done)
        let result: CloudMoveResult = try copyAllMeetingsToLocal(cloudSessions: cloud, localSessions: local)
        #expect(result.moved == ["b"] && result.failures.isEmpty)
        #expect(Set(loadMeetings(sessionsDirectory: cloud).meetings.map(\.id)) == ["a", "b"])
        #expect(Set(loadMeetings(sessionsDirectory: local).meetings.map(\.id)) == ["a", "b"])
    }

    // Taşımada kullanımdaki ve bitmemiş toplantılara dokunulmaz; iCloud'da zaten olan birleştirilir ve yerel kopyası
    // kalkar (hata sayılmaz).
    @Test func moveSkipsBusyAndUnfinishedAndMergesExisting() throws {
        let local: URL = try temporaryDirectory()
        let cloud: URL = try temporaryDirectory()
        try makeMeeting(root: local, id: "kullanimda", status: .done)
        try makeMeeting(root: local, id: "isleniyor", status: .processing)
        try makeMeeting(root: local, id: "zaten", status: .done)
        try makeMeeting(root: cloud, id: "zaten", status: .done)
        let result: CloudMoveResult = moveFinishedMeetingsToCloud(localSessions: local, cloudSessions: cloud, excluding: ["kullanimda"])
        #expect(result.moved.isEmpty && result.merged == ["zaten"] && result.failures.isEmpty)
        #expect(Set(loadMeetings(sessionsDirectory: local).meetings.map(\.id)) == ["kullanimda", "isleniyor"])
        #expect(loadMeetings(sessionsDirectory: cloud).meetings.map(\.id) == ["zaten"])
    }

    private let rapor: NoteTask = NoteTask(owner: "Sen", description: "Raporu yaz", dueDate: nil, isMine: true)
    private let butce: NoteTask = NoteTask(owner: "Aino", description: "Bütçeyi gönder", dueDate: nil, isMine: false)

    /// Görevli notu olan bitmiş toplantı (işaretler görev kimliklerine bağlıdır).
    private func notedMeeting(id: String) -> MeetingRecord {
        record(id: id, startedAt: Date(timeIntervalSince1970: 1_800_000_000), status: .done, audioDeleted: false)
            .with(note: MeetingNote(title: "Palaveri", summary: "Özet", decisions: [], tasks: [rapor, butce], glossary: []))
    }

    /// Toplantıyı klasörüne yazar ve `meeting.json`'un son yazılma anını verilen ana çeker.
    private func write(record: MeetingRecord, root: URL, modifiedAt: Date) throws -> URL {
        let folder: URL = root.appending(path: record.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try saveMeeting(record: record, directory: folder)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: folder.appending(path: meetingFileName).path)
        return folder
    }

    // Eşitleme kapalıyken yerelde düzenlenen toplantı, açılınca iCloud kopyasına yazılır: yerelin içeriği (daha yeni)
    // kalır, iCloud'da diğer cihazda konan işaretler kaybolmaz, yerel kopya kalkar (liste tek kopya gösterir).
    @Test func reEnablingWritesNewerLocalCopyToCloud() throws {
        let local: URL = try temporaryDirectory()
        let cloud: URL = try temporaryDirectory()
        let base: MeetingRecord = notedMeeting(id: "20261026-100000")
        let phone: MeetingRecord = markingReminded(record: base, task: butce).markingSent(destinationID: "slack")
        let edited: MeetingRecord = togglingTask(record: base.with(title: "Yerelde düzeltilen başlık"), task: rapor).markingSent(destinationID: "notion")
        _ = try write(record: phone, root: cloud, modifiedAt: Date(timeIntervalSince1970: 1_800_001_000))
        let localFolder: URL = try write(record: edited, root: local, modifiedAt: Date(timeIntervalSince1970: 1_800_002_000))
        let result: CloudMoveResult = moveFinishedMeetingsToCloud(localSessions: local, cloudSessions: cloud, excluding: [])
        #expect(result.merged == [base.id] && result.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: localFolder.path))
        let merged: MeetingRecord = try #require(loadMeetings(sessionsDirectory: cloud).meetings.first)
        #expect(merged.title == "Yerelde düzeltilen başlık")
        #expect(isTaskDone(record: merged, task: rapor) && isTaskReminded(record: merged, task: butce))
        #expect(Set(merged.sentDestinationIDs ?? []) == ["slack", "notion"])
        // Listede tek kopya: iCloud'daki birleşik kayıt.
        #expect(loadMeetings(directories: [local, cloud]).meetings == [merged])
    }

    // iCloud kopyası daha yeniyse içeriği kalır, yerelde konan işaret eklenir; ses yerelde silinmişse (saklama süresi
    // doldu) iCloud'daki ses de silinir ve kayıt "ses silindi" olur.
    @Test func newerCloudCopyKeepsContentAndLocalAudioDeletion() throws {
        let local: URL = try temporaryDirectory()
        let cloud: URL = try temporaryDirectory()
        let base: MeetingRecord = notedMeeting(id: "20261026-110000")
        let cloudFolder: URL = try write(record: base.with(title: "Diğer cihazda düzeltilen"), root: cloud, modifiedAt: Date(timeIntervalSince1970: 1_800_003_000))
        try Data("ses".utf8).write(to: cloudFolder.appending(path: "others.m4a"))
        let localFolder: URL = try write(record: togglingTask(record: base, task: rapor).withAudioDeleted(), root: local, modifiedAt: Date(timeIntervalSince1970: 1_800_002_000))
        let result: CloudMoveResult = moveFinishedMeetingsToCloud(localSessions: local, cloudSessions: cloud, excluding: [])
        #expect(result.merged == [base.id] && result.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: localFolder.path))
        #expect(!FileManager.default.fileExists(atPath: cloudFolder.appending(path: "others.m4a").path))
        let merged: MeetingRecord = try loadMeeting(directory: cloudFolder)
        #expect(merged.title == "Diğer cihazda düzeltilen" && merged.audioDeleted && isTaskDone(record: merged, task: rapor))
    }

    // iCloud kopyası okunamazsa yerel kopya silinmez, hata toplantıyla birlikte bildirilir.
    @Test func unreadableCloudCopyKeepsLocalCopy() throws {
        let local: URL = try temporaryDirectory()
        let cloud: URL = try temporaryDirectory()
        let localFolder: URL = try write(record: notedMeeting(id: "bozuk"), root: local, modifiedAt: Date())
        let cloudFolder: URL = cloud.appending(path: "bozuk", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cloudFolder, withIntermediateDirectories: true)
        try Data("{bozuk".utf8).write(to: cloudFolder.appending(path: meetingFileName))
        let result: CloudMoveResult = moveFinishedMeetingsToCloud(localSessions: local, cloudSessions: cloud, excluding: [])
        #expect(result.merged.isEmpty && result.failures.map(\.folder) == ["bozuk"])
        #expect(FileManager.default.fileExists(atPath: localFolder.path))
    }
}

@Suite struct CloudConflictMergeTests {
    // Diğer cihazda tamamlanan ve Anımsatıcılar'a eklenen görevler son yazılan sürüme eklenir, tekrar etmez.
    @Test func taskMarksAreUnited() {
        let base: MeetingRecord = MeetingRecord(
            id: "x", title: "T", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, language: nil, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud,
            notice: nil, meNeedsFinalPass: nil
        )
        let current: MeetingRecord = base.with(completedTasks: ["a"])
        let phone: MeetingRecord = base.with(completedTasks: ["a", "b"]).with(remindedTasks: ["c"])
        let merged: MeetingRecord = mergingUserMarks(current: current, others: [phone])
        #expect(merged.completedTasks == ["a", "b"])
        #expect(merged.remindedTasks == ["c"])
        #expect(mergingUserMarks(current: current, others: []) == current)
    }

    // Gönderim işaretleri de birleşir: hedefler ve araca gönderilen görevler (araç başına) tekrarsız, Apple Notlar ve
    // webhook anlarının en eskisi kalır; böylece çakışmadan sonra not ya da görev ikinci kez gönderilmez.
    @Test func sendMarksAreUnited() {
        let base: MeetingRecord = MeetingRecord(
            id: "x", title: "T", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, language: nil, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud,
            notice: nil, meNeedsFinalPass: nil
        )
        let task: NoteTask = NoteTask(owner: "Sen", description: "Rapor", dueDate: nil, isMine: true)
        let other: NoteTask = NoteTask(owner: "Aino", description: "Bütçe", dueDate: nil, isMine: false)
        let early: Date = Date(timeIntervalSince1970: 100)
        let late: Date = Date(timeIntervalSince1970: 200)
        let current: MeetingRecord = base.markingSent(destinationID: "slack").markingTaskSent(trackerID: "linear", task: task).with(notesSentAt: late)
        let phone: MeetingRecord = base.markingSent(destinationID: "notion").markingSent(destinationID: "slack")
            .markingTaskSent(trackerID: "linear", task: other).markingTaskSent(trackerID: "jira", task: task)
            .with(notesSentAt: early).with(webhookSentAt: late)
        let merged: MeetingRecord = mergingUserMarks(current: current, others: [phone])
        #expect(merged.sentDestinationIDs == ["slack", "notion"])
        #expect(merged.sentTaskKeys == ["linear": [taskKey(task: task), taskKey(task: other)], "jira": [taskKey(task: task)]])
        #expect(merged.notesSentAt == early)
        #expect(merged.webhookSentAt == late)
    }
}
