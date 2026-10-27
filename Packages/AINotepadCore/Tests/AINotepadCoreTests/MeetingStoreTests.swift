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
        #expect(storedSegments(transcript: transcript) == [StoredSegment(key: "others-3", speaker: .others, person: 2, startSec: 1, endSec: 2, text: "Hei", words: nil)])
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
