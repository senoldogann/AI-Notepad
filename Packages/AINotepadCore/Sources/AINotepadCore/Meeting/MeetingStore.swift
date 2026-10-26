import Foundation

/// Toplantı dosyası adı.
public let meetingFileName: String = "meeting.json"

/// Okunamayan toplantı klasörü.
public struct MeetingLoadFailure: Sendable, Equatable {
    public let folder: String
    public let reason: String

    public init(folder: String, reason: String) {
        self.folder = folder
        self.reason = reason
    }
}

/// Tüm toplantılar ve okunamayanlar; bir bozuk dosya diğerlerini engellemez.
public struct MeetingLoadResult: Sendable, Equatable {
    public let meetings: [MeetingRecord]
    public let failures: [MeetingLoadFailure]
}

private func meetingEncoder() -> JSONEncoder {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func meetingDecoder() -> JSONDecoder {
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

/// Toplantıyı klasöründeki `meeting.json`'a atomik yazar.
public func saveMeeting(record: MeetingRecord, directory: URL) throws {
    let file: URL = directory.appending(path: meetingFileName)
    do {
        try meetingEncoder().encode(record).write(to: file, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
}

/// Bir toplantının ses dosyalarını (`.m4a`, `.caf`) siler; biri silinemezse hata fırlatır. Metin ve not kalır.
public func deleteAudioFiles(directory: URL) throws {
    for name in ["me.m4a", "others.m4a", "me.caf", "others.caf"] {
        let file: URL = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: file.path) else {
            continue
        }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            throw StorageError.deleteFailed(path: file.path, reason: error.localizedDescription)
        }
    }
}

/// `Sessions` altındaki tüm `meeting.json`'ları okur (yeniden eskiye). `meeting.json`'u olmayan klasörler atlanır.
public func loadMeetings(sessionsDirectory: URL) -> MeetingLoadResult {
    // Henüz hiç kayıt yapılmadıysa klasör yoktur: boş liste doğru sonuçtur.
    guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else {
        return MeetingLoadResult(meetings: [], failures: [])
    }
    let folders: [URL]
    do {
        folders = try FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)
    } catch {
        return MeetingLoadResult(meetings: [], failures: [MeetingLoadFailure(folder: sessionsDirectory.lastPathComponent, reason: String(describing: error))])
    }
    var meetings: [MeetingRecord] = []
    var failures: [MeetingLoadFailure] = []
    for folder in folders.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
        let file: URL = folder.appending(path: meetingFileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            continue
        }
        do {
            meetings.append(try meetingDecoder().decode(MeetingRecord.self, from: Data(contentsOf: file)))
        } catch {
            failures.append(MeetingLoadFailure(folder: folder.lastPathComponent, reason: String(describing: error)))
        }
    }
    return MeetingLoadResult(meetings: meetings, failures: failures)
}

/// Açılışta hâlâ kayıtta ya da işlemede görünen (uygulama yarıda kapanmış) toplantılar `interrupted` olur. Saf fonksiyondur.
public func staleStatusesToInterrupt(records: [MeetingRecord]) -> [MeetingRecord] {
    records
        .filter { (record: MeetingRecord) -> Bool in record.status == .recording || record.status == .processing }
        .map { (record: MeetingRecord) -> MeetingRecord in
            record.with(status: .interrupted, failureMessage: "Uygulama kayıt ya da işleme sırasında kapandı.")
        }
}

/// Saklama süresi dolmuş ve sesi henüz silinmemiş toplantıların klasör adları. Saf fonksiyondur.
public func audioToDelete(records: [MeetingRecord], now: Date, retentionDays: Int) -> [String] {
    records
        .filter { (record: MeetingRecord) -> Bool in
            !record.audioDeleted && now.timeIntervalSince(record.startedAt) > Double(retentionDays) * 86_400
        }
        .map(\.id)
}

/// Başlık, not ve transkriptte büyük/küçük harf duyarsız arama; boş sorgu hepsini döndürür. Saf fonksiyondur.
public func filterMeetings(records: [MeetingRecord], query: String) -> [MeetingRecord] {
    let needle: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else {
        return records
    }
    return records.filter { (record: MeetingRecord) -> Bool in
        let haystack: [String] = [record.title, record.note?.summary ?? ""]
            + (record.note?.decisions ?? [])
            + (record.liveSegments + record.finalSegments).map(\.text)
            + Array(record.translations.values)
        // Yerel ayardan bağımsız: Türkçe yerel ayarda "I" → "ı" olur ve Fince/İngilizce metinde "RAPORTTI" bulunamazdı.
        return haystack.contains { (text: String) -> Bool in
            text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: nil) != nil
        }
    }
}

/// Kaydedilen toplantıyı bellekteki listeye yerleştirir (varsa değiştirir), yeniden eskiye sıralı. Her kayıttan
/// sonra diskteki tüm toplantıları yeniden okumamak için. Saf fonksiyondur.
public func upsertMeeting(records: [MeetingRecord], record: MeetingRecord) -> [MeetingRecord] {
    (records.filter { $0.id != record.id } + [record])
        .sorted { (left: MeetingRecord, right: MeetingRecord) -> Bool in left.id > right.id }
}
