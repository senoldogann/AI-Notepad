import Foundation
import Testing
@testable import AINotepadCore

func record(id: String, startedAt: Date, status: MeetingStatus, audioDeleted: Bool) -> MeetingRecord {
    MeetingRecord(
        id: id, title: "Palaveri", startedAt: startedAt, endedAt: nil, language: .finnish, status: status,
        failureMessage: nil,
        liveSegments: [StoredSegment(key: "others-0", speaker: .others, person: 1, startSec: 0, endSec: 2, text: "Hei")],
        finalSegments: [], translations: ["others-0": "Merhaba"], speakerNames: [1: "Aino"], note: nil, audioDeleted: audioDeleted
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
        ]
        #expect(audioToDelete(records: records, now: now, retentionDays: 30) == ["old"])
    }
}

@Suite struct StoredSegmentsTests {
    @Test func keepsOnlyFinalTextSegmentsWithKeys() {
        let transcript: [LiveSegment] = [
            LiveSegment(id: SegmentID(speaker: .others, index: 3), startSec: 1, endSec: 2, text: "Hei", isFinal: true, failureMessage: nil, person: 2),
            LiveSegment(id: SegmentID(speaker: .me, index: 0), startSec: 3, endSec: 4, text: "kesk", isFinal: false, failureMessage: nil, person: nil),
            LiveSegment(id: SegmentID(speaker: .others, index: 4), startSec: 5, endSec: 6, text: "", isFinal: true, failureMessage: "x", person: nil),
        ]
        #expect(storedSegments(transcript: transcript) == [StoredSegment(key: "others-3", speaker: .others, person: 2, startSec: 1, endSec: 2, text: "Hei")])
    }
}

@Suite struct MeetingSearchTests {
    @Test func searchMatchesTitleNoteAndTranscriptCaseInsensitive() {
        let plain: MeetingRecord = record(id: "a", startedAt: Date(), status: .done, audioDeleted: false)
        let noted: MeetingRecord = MeetingRecord(
            id: "b", title: "Proje", startedAt: Date(), endedAt: nil, language: .finnish, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [StoredSegment(key: "final-0", speaker: .others, person: 1, startSec: 0, endSec: 1, text: "Raportti valmis")],
            translations: [:], speakerNames: [:],
            note: MeetingNote(title: "Proje", summary: "Bütçe konuşuldu", decisions: [], tasks: [], glossary: []), audioDeleted: false
        )
        #expect(filterMeetings(records: [plain, noted], query: "").map(\.id) == ["a", "b"])
        #expect(filterMeetings(records: [plain, noted], query: "bütçe").map(\.id) == ["b"])
        #expect(filterMeetings(records: [plain, noted], query: "RAPORTTI").map(\.id) == ["b"])
        #expect(filterMeetings(records: [plain, noted], query: "hei").map(\.id) == ["a"])
    }
}
