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
    /// iCloud'dan henüz inmemiş toplantı klasörleri (indirme başlatıldı; inince değişiklik bildirimiyle yeniden okunur).
    public let downloading: [String]
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

/// Toplantıyı klasöründeki `meeting.json`'a atomik yazar. Yazma dosya koordinatörüyle yapılır: klasör iCloud'daysa
/// eşitleme süreciyle çakışmaz (yerelde de zararsızdır).
public func saveMeeting(record: MeetingRecord, directory: URL) throws {
    let file: URL = directory.appending(path: meetingFileName)
    let data: Data
    do {
        data = try meetingEncoder().encode(record)
    } catch {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
    var coordinationError: NSError?
    var writeError: (any Error)?
    NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { (url: URL) -> Void in
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            writeError = error
        }
    }
    if let error = coordinationError ?? writeError {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
}

/// Bir toplantının ses dosyalarını (`.m4a`, `.caf`) siler; biri silinemezse hata fırlatır. Metin ve not kalır.
/// Toplantının klasörünü (meeting.json ve ses dosyaları) Çöp Sepeti'ne taşır: yanlışlıkla silinen toplantı Finder'dan
/// geri alınabilir. Taşınamazsa `deleteFailed`.
public func trashMeetingDirectory(directory: URL) throws {
    do {
        try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
    } catch {
        throw StorageError.deleteFailed(path: directory.path, reason: error.localizedDescription)
    }
}

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

/// Klasörlerdeki tüm toplantılar (verilen sırayla; her klasörde yeniden eskiye). Aynı toplantı iki klasörde varsa ilk
/// klasördeki kullanılır (yereldeki: kayıt ya da işleme orada sürer).
public func loadMeetings(directories: [URL]) -> MeetingLoadResult {
    directories.map { loadMeetings(sessionsDirectory: $0) }.reduce(MeetingLoadResult(meetings: [], failures: [], downloading: [])) { (result: MeetingLoadResult, next: MeetingLoadResult) -> MeetingLoadResult in
        let known: Set<String> = Set(result.meetings.map(\.id))
        return MeetingLoadResult(
            meetings: newestFirst(records: result.meetings + next.meetings.filter { !known.contains($0.id) }),
            failures: result.failures + next.failures,
            downloading: result.downloading + next.downloading.filter { !known.contains($0) }
        )
    }
}

/// `Sessions` altındaki tüm `meeting.json`'ları okur (yeniden eskiye). `meeting.json`'u olmayan klasörler atlanır.
/// iCloud'dan henüz inmemiş dosyanın indirmesi başlatılır ve `downloading`'e yazılır (okuma beklemez, arayüz donmaz).
public func loadMeetings(sessionsDirectory: URL) -> MeetingLoadResult {
    // Henüz hiç kayıt yapılmadıysa klasör yoktur: boş liste doğru sonuçtur.
    guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else {
        return MeetingLoadResult(meetings: [], failures: [], downloading: [])
    }
    let folders: [URL]
    do {
        folders = try FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)
    } catch {
        return MeetingLoadResult(meetings: [], failures: [MeetingLoadFailure(folder: sessionsDirectory.lastPathComponent, reason: String(describing: error))], downloading: [])
    }
    var meetings: [MeetingRecord] = []
    var failures: [MeetingLoadFailure] = []
    var downloading: [String] = []
    for folder in folders.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
        let file: URL = folder.appending(path: meetingFileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            continue
        }
        do {
            guard try isDownloaded(file: file) else {
                downloading.append(folder.lastPathComponent)
                continue
            }
            try resolveCloudConflicts(file: file)
            meetings.append(try meetingDecoder().decode(MeetingRecord.self, from: Data(contentsOf: file)))
        } catch {
            failures.append(MeetingLoadFailure(folder: folder.lastPathComponent, reason: String(describing: error)))
        }
    }
    return MeetingLoadResult(meetings: newestFirst(records: meetings), failures: failures, downloading: downloading)
}

/// Dosya okunabilir mi: yerel dosya ya da iCloud'dan inmiş dosya. İnmemişse indirmesi başlatılır ve false döner.
public func isDownloaded(file: URL) throws -> Bool {
    let values: URLResourceValues = try file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
    guard values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current else {
        return true
    }
    try FileManager.default.startDownloadingUbiquitousItem(at: file)
    return false
}

/// Açılışta hâlâ kayıtta ya da işlemede görünen (uygulama yarıda kapanmış) toplantılar `interrupted` olur. Saf fonksiyondur.
public func staleStatusesToInterrupt(records: [MeetingRecord]) -> [MeetingRecord] {
    records
        .filter { (record: MeetingRecord) -> Bool in record.status == .recording || record.status == .processing }
        .map { (record: MeetingRecord) -> MeetingRecord in
            let interrupted: MeetingRecord = record.with(status: .interrupted, failureMessage: String(localized: "Uygulama kayıt ya da işleme sırasında kapandı."))
            // Yarıda kalan kaydın bitişi bilinmez: son konuşmanın sonu kabul edilir (süre "–" görünmesin).
            guard record.endedAt == nil, let lastSec = (record.liveSegments + record.finalSegments).map(\.endSec).max() else {
                return interrupted
            }
            return interrupted.with(endedAt: record.startedAt.addingTimeInterval(lastSec))
        }
}

/// Saklama süresi dolmuş ve sesi henüz silinmemiş toplantıların klasör adları. Bitmiş (`done`) toplantının sesi süre
/// dolunca, başarısız ya da yarıda kalmış toplantınınki iki kat sürede silinir ("Tekrar işle" için zaman kalır, ama ses
/// sonsuza dek de kalmaz). Kayıttaki ve işlenen toplantıya dokunulmaz. Saf fonksiyondur.
public func audioToDelete(records: [MeetingRecord], now: Date, retentionDays: Int) -> [String] {
    records
        .filter { (record: MeetingRecord) -> Bool in
            let days: Int
            switch record.status {
            case .done: days = retentionDays
            case .failed, .interrupted: days = retentionDays * 2
            case .recording, .processing: return false
            }
            return !record.audioDeleted && now.timeIntervalSince(record.startedAt) > Double(days) * 86_400
        }
        .map(\.id)
}

/// Toplantı klasörünü kalıcı olarak siler (iPhone: Çöp Sepeti yok; silmeden önce onay sorulur). Silinemezse
/// `deleteFailed`.
public func deleteMeetingDirectory(directory: URL) throws {
    do {
        try FileManager.default.removeItem(at: directory)
    } catch {
        throw StorageError.deleteFailed(path: directory.path, reason: error.localizedDescription)
    }
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
    newestFirst(records: records.filter { $0.id != record.id } + [record])
}

/// Toplantılar en yeni önce: başlangıç anına göre (klasör adı yerel saattir; seyahat ya da yaz saati değişince sırası
/// bozulurdu), eşitse kimliğe göre. Saf fonksiyondur.
public func newestFirst(records: [MeetingRecord]) -> [MeetingRecord] {
    records.sorted { (left: MeetingRecord, right: MeetingRecord) -> Bool in
        left.startedAt == right.startedAt ? left.id > right.id : left.startedAt > right.startedAt
    }
}
