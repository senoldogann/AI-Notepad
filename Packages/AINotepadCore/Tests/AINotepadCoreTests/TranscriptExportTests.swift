import AINotepadCore
import Foundation
import Testing

/// İki konuşmacılı (biri adlı) ve "Sen"li kısa toplantı; ilk saat dolmuş bir paragraf da var.
private func exportRecord() -> MeetingRecord {
    MeetingRecord(
        id: "x", title: "T", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil, language: .finnish,
        status: .done, failureMessage: nil,
        liveSegments: [
            StoredSegment(key: "me-0", speaker: .me, person: nil, startSec: 12.25, endSec: 14.5, text: "Selvä,\nkiitos.", words: nil),
        ],
        finalSegments: [
            StoredSegment(key: "final-0", speaker: .others, person: 1, startSec: 0, endSec: 4.0004, text: "Hei kaikki.", words: nil),
            StoredSegment(key: "final-1", speaker: .others, person: 2, startSec: 5, endSec: 9, text: "Aloitetaan.", words: nil),
            StoredSegment(key: "final-2", speaker: .others, person: 2, startSec: 3725.5, endSec: 3730, text: "Loppu.", words: nil),
        ],
        translations: ["final-0": "Herkese merhaba."], speakerNames: [1: "Aino"], note: nil, audioDeleted: false,
        engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

private func emptyRecord() -> MeetingRecord {
    MeetingRecord(
        id: "y", title: "T", startedAt: Date(), endedAt: nil, language: nil, status: .done, failureMessage: nil,
        liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false,
        engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

@Suite struct TranscriptExportTests {
    // Düz metin: paragraf başına "[zaman] Ad: metin"; adlar sayfadakiyle aynı, satır sonları tek satıra iner.
    @Test func plainTextUsesTranscriptNames() {
        #expect(transcriptText(record: exportRecord()) == """
            [00:00] Aino: Hei kaikki.

            [00:05] Konuşmacı 2: Aloitetaan.

            [00:12] Sen: Selvä, kiitos.

            [1:02:05] Konuşmacı 2: Loppu.
            """)
    }

    // SRT: numaralı ipuçları, milisaniyeli saat:dakika:saniye, konuşmacı adı metnin başında.
    @Test func srtHasNumberedCues() {
        #expect(transcriptSRT(record: exportRecord()) == """
            1
            00:00:00,000 --> 00:00:04,000
            Aino: Hei kaikki.

            2
            00:00:05,000 --> 00:00:09,000
            Konuşmacı 2: Aloitetaan.

            3
            00:00:12,250 --> 00:00:14,500
            Sen: Selvä, kiitos.

            4
            01:02:05,500 --> 01:02:10,000
            Konuşmacı 2: Loppu.

            """)
    }

    @Test func srtTimestampRoundsAndClamps() {
        #expect(srtTimestamp(seconds: 0.0006) == "00:00:00,001")
        #expect(srtTimestamp(seconds: -3) == "00:00:00,000")
        #expect(srtTimestamp(seconds: 36_000.999_6) == "10:00:01,000")
    }

    @Test func emptyTranscriptExportsNothing() {
        #expect(transcriptText(record: emptyRecord()).isEmpty)
        #expect(transcriptSRT(record: emptyRecord()).isEmpty)
    }
}

@Suite struct MeetingListFilterTests {
    // Süzgeç: görevim olanlar yalnız "Sen"e görev düşenler; sorunlular hata veren ve yarıda kalanlar; sıra korunur.
    @Test func filtersKeepOrder() {
        let base: MeetingRecord = emptyRecord()
        let mine: MeetingRecord = base.with(note: MeetingNote(
            title: "A", summary: "", decisions: [], tasks: [NoteTask(owner: "Sen", description: "Yaz", dueDate: nil, isMine: true)], glossary: []
        ))
        let others: MeetingRecord = base.with(note: MeetingNote(
            title: "B", summary: "", decisions: [], tasks: [NoteTask(owner: "Aino", description: "Gönder", dueDate: nil, isMine: false)], glossary: []
        ))
        let failed: MeetingRecord = base.with(status: .failed, failureMessage: "x")
        let interrupted: MeetingRecord = base.with(status: .interrupted, failureMessage: nil)
        let records: [MeetingRecord] = [mine, others, failed, interrupted]
        #expect(filterMeetings(records: records, listFilter: .all) == records)
        #expect(filterMeetings(records: records, listFilter: .myTasks) == [mine])
        #expect(filterMeetings(records: records, listFilter: .problems) == [failed, interrupted])
    }
}
