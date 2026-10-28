import Foundation
import Testing
@testable import AINotepadCore

/// Yarım saatlik gerçekçi bir toplantı: 120 bölüm, her bölümde 12 zamanlı kelime, çeviriler ve not.
private func syntheticMeeting(index: Int) -> MeetingRecord {
    let words: [String] = ["projekti", "aikataulu", "budjetti", "asiakas", "raportti", "viikko", "testaus", "julkaisu", "palaveri", "tehtävä", "sopimus", "tiimi"]
    let segments: [StoredSegment] = (0..<120).map { (segment: Int) -> StoredSegment in
        let start: Double = Double(segment) * 15
        let stored: [StoredWord] = (0..<12).map { (word: Int) -> StoredWord in
            StoredWord(text: words[(segment + word) % words.count], startSec: start + Double(word), endSec: start + Double(word) + 0.8)
        }
        return StoredSegment(
            key: "final-\(segment)", speaker: segment % 3 == 0 ? .me : .others, person: segment % 3 == 0 ? nil : segment % 4,
            startSec: start, endSec: start + 12, text: stored.map(\.text).joined(separator: " "), words: stored
        )
    }
    let translations: [String: String] = Dictionary(uniqueKeysWithValues: segments.map { ($0.key, "Toplantı \(index) bölüm \($0.key) çevirisi") })
    let note: MeetingNote = MeetingNote(
        title: "Haftalık toplantı \(index)", summary: "Proje takvimi, bütçe ve sürüm planı konuşuldu.",
        decisions: ["Sürüm cuma çıkar", "Testler perşembe biter"],
        tasks: [
            NoteTask(owner: "Sen", description: "Raporu gönder \(index)", dueDate: "2026-11-02", isMine: true),
            NoteTask(owner: "Aino", description: "Bütçeyi güncelle", dueDate: nil, isMine: false),
        ],
        glossary: [GlossaryEntry(term: "julkaisu", meaning: "sürüm")]
    )
    return MeetingRecord(
        id: String(format: "2026%04d-100000", index), title: "Palaveri \(index)",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400), endedAt: Date(timeIntervalSince1970: 1_700_001_800 + Double(index) * 86_400),
        language: .finnish, status: .done, failureMessage: nil, liveSegments: [], finalSegments: segments, translations: translations,
        speakerNames: [1: "Aino"], note: note, audioDeleted: true, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

/// 500 toplantılık arşivi geçici klasöre yazar.
private func writeSyntheticArchive(count: Int) throws -> (directory: URL, records: [MeetingRecord]) {
    let sessions: URL = try temporaryDirectory()
    let records: [MeetingRecord] = (0..<count).map { (index: Int) -> MeetingRecord in syntheticMeeting(index: index) }
    for record in records {
        let folder: URL = sessions.appending(path: record.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try saveMeeting(record: record, directory: folder)
    }
    return (sessions, records)
}

/// Saniye cinsinden geçen süre.
private func seconds(duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// İşin `runs` denemedeki en kısa süresi (sn): tüm test takımı paralel koşarken anlık yük ölçümü bozmasın.
private func fastestRun(runs: Int, work: () -> Void) -> Double {
    let clock: ContinuousClock = ContinuousClock()
    return (0..<runs).map { (_: Int) -> Double in seconds(duration: clock.measure(work)) }.min() ?? .infinity
}

// Büyük arşiv: yükleme ve arama arayüzü bekletmeyecek kadar hızlı kalmalı. Sınırlar geliştirme Mac'inde (Debug,
// takım tek başına) ölçülen sürenin yaklaşık üç katıdır: yükleme ~0,7 sn (paralel okumadan önce ~2,1 sn), eşleşmeyen
// arama ~0,27 sn (katlamadan önce ~1,4 sn). Tüm testler birlikte koşarken süre yükseldiği için en iyi deneme alınır.
@Suite(.serialized) struct MeetingArchivePerformanceTests {
    @Test func loadingFiveHundredMeetingsIsFast() throws {
        let archive: (directory: URL, records: [MeetingRecord]) = try writeSyntheticArchive(count: 500)
        defer {
            do {
                try FileManager.default.removeItem(at: archive.directory)
            } catch {
                Issue.record("geçici klasör silinemedi: \(error)")
            }
        }
        var result: MeetingLoadResult = MeetingLoadResult(meetings: [], failures: [], downloading: [])
        let elapsed: Double = fastestRun(runs: 3) {
            result = loadMeetings(directories: [archive.directory])
        }
        print("500 toplantı yükleme: \(elapsed) sn")
        #expect(result.meetings == newestFirst(records: archive.records))
        #expect(result.failures.isEmpty)
        #expect(elapsed < 2.5)
    }

    @Test func filteringFiveHundredMeetingsIsFast() throws {
        let records: [MeetingRecord] = (0..<500).map { (index: Int) -> MeetingRecord in syntheticMeeting(index: index) }
        var matches: [MeetingRecord] = []
        // Arama her tuşta yeniden çalışır: eşleşmeyen sorgu tüm metni tarar (en kötü durum).
        let elapsed: Double = fastestRun(runs: 3) {
            matches = filterMeetings(records: records, query: "olmayan-sözcük")
        }
        print("500 toplantıda arama: \(elapsed) sn")
        #expect(matches.isEmpty)
        #expect(filterMeetings(records: records, query: "raporu GÖNDER 499").map(\.id) == [records[499].id])
        #expect(elapsed < 1.0)
    }
}

/// Yeniden okuma denemesinin sayaçları (ana aktörde).
@MainActor
private final class ReloadProbe {
    var loads: Int = 0
    var applied: [Int] = []
}

@MainActor @Suite struct MeetingReloaderTests {
    // Okuma sürerken gelen istekler tek bir ek okumada birleşir; her çağıran son okuma bitince döner.
    @Test func rapidRequestsCoalesce() async throws {
        let reloader: MeetingReloader = MeetingReloader()
        let probe: ReloadProbe = ReloadProbe()
        let load: @MainActor () async throws -> MeetingLoadResult = { () async throws -> MeetingLoadResult in
            probe.loads += 1
            try await Task.sleep(for: .milliseconds(100))
            return MeetingLoadResult(meetings: [], failures: [], downloading: ["\(probe.loads)"])
        }
        let request: @MainActor () -> Task<Void, Never> = { () -> Task<Void, Never> in
            Task { () async -> Void in
                await reloader.reload(load: load, apply: { (result: MeetingLoadResult) -> Void in
                    probe.applied.append(Int(result.downloading[0]) ?? -1)
                }, fail: { (error: any Error) -> Void in
                    Issue.record("beklenmeyen hata: \(error)")
                })
            }
        }
        // İlk okuma başlar; o sürerken beş istek daha gelir.
        let first: Task<Void, Never> = request()
        try await Task.sleep(for: .milliseconds(30))
        let requests: [Task<Void, Never>] = [first] + (0..<5).map { (_: Int) -> Task<Void, Never> in request() }
        for request in requests {
            await request.value
        }
        #expect(probe.loads == 2)
        #expect(probe.applied == [1, 2])
    }

    // Okuma sürerken yerelde yazılan toplantı varsa o okumanın (eski) sonucu uygulanmaz, liste yeniden okunur.
    @Test func staleResultIsDropped() async {
        let reloader: MeetingReloader = MeetingReloader()
        let probe: ReloadProbe = ReloadProbe()
        await reloader.reload(load: { () async throws -> MeetingLoadResult in
            probe.loads += 1
            if probe.loads == 1 {
                reloader.invalidate()
            }
            return MeetingLoadResult(meetings: [], failures: [], downloading: ["\(probe.loads)"])
        }, apply: { (result: MeetingLoadResult) -> Void in
            probe.applied.append(Int(result.downloading[0]) ?? -1)
        }, fail: { (error: any Error) -> Void in
            Issue.record("beklenmeyen hata: \(error)")
        })
        #expect(probe.loads == 2)
        #expect(probe.applied == [2])
    }
}
