import Foundation
import Synchronization

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

func meetingDecoder() -> JSONDecoder {
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

/// Klasördeki `meeting.json`'u dosya koordinatörüyle okur: başka cihazdan (iCloud) gelmiş en güncel hali. Bellekteki
/// kopyanın üzerine yazmadan önce değişiklik buna uygulanır.
public func loadMeeting(directory: URL) throws -> MeetingRecord {
    let file: URL = directory.appending(path: meetingFileName)
    var coordinationError: NSError?
    var result: Result<Data, any Error> = .failure(StorageError.readFailed(path: file.path, reason: "okunmadı"))
    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file, options: [], error: &coordinationError) { (url: URL) -> Void in
        result = Result { try Data(contentsOf: url) }
    }
    if let coordinationError {
        throw StorageError.readFailed(path: file.path, reason: coordinationError.localizedDescription)
    }
    do {
        return try meetingDecoder().decode(MeetingRecord.self, from: try result.get())
    } catch {
        throw StorageError.readFailed(path: file.path, reason: error.localizedDescription)
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
        try coordinatedRemoveItem(at: file)
    }
}

/// Dosyayı ya da klasörü dosya koordinasyonuyla siler: iCloud'daki öğe başka cihazda yazılırken ya da eşitlenirken
/// silme çakışmasın.
func coordinatedRemoveItem(at url: URL) throws {
    var coordinationError: NSError?
    var removeError: (any Error)?
    NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { (target: URL) -> Void in
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            removeError = error
        }
    }
    if let failure = coordinationError ?? removeError.map({ $0 as NSError }) {
        throw StorageError.deleteFailed(path: url.path, reason: failure.localizedDescription)
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
/// Klasörler paralel okunur (büyük arşivde çözümleme süresi çekirdeklere bölünür); sonuçların sırası klasör sırasıdır.
/// Ana iş parçacığında çağrılmaz (bkz. `loadMeetingsInBackground`).
public func loadMeetings(sessionsDirectory: URL) -> MeetingLoadResult {
    // Henüz hiç kayıt yapılmadıysa klasör yoktur: boş liste doğru sonuçtur.
    guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else {
        return MeetingLoadResult(meetings: [], failures: [], downloading: [])
    }
    let folders: [URL]
    do {
        folders = try FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)
            .sorted { (left: URL, right: URL) -> Bool in left.lastPathComponent > right.lastPathComponent }
    } catch {
        return MeetingLoadResult(meetings: [], failures: [MeetingLoadFailure(folder: sessionsDirectory.lastPathComponent, reason: String(describing: error))], downloading: [])
    }
    let outcomes: Mutex<[FolderLoadOutcome]> = Mutex(Array(repeating: FolderLoadOutcome.skipped, count: folders.count))
    DispatchQueue.concurrentPerform(iterations: folders.count) { (index: Int) -> Void in
        let outcome: FolderLoadOutcome = loadMeetingFolder(folder: folders[index])
        outcomes.withLock { (values: inout [FolderLoadOutcome]) -> Void in values[index] = outcome }
    }
    let ordered: [FolderLoadOutcome] = outcomes.withLock { (values: inout [FolderLoadOutcome]) -> [FolderLoadOutcome] in values }
    return MeetingLoadResult(
        meetings: newestFirst(records: ordered.compactMap { (outcome: FolderLoadOutcome) -> MeetingRecord? in
            if case .meeting(let record) = outcome { record } else { nil }
        }),
        failures: ordered.compactMap { (outcome: FolderLoadOutcome) -> MeetingLoadFailure? in
            if case .failure(let failure) = outcome { failure } else { nil }
        },
        downloading: ordered.compactMap { (outcome: FolderLoadOutcome) -> String? in
            if case .downloading(let folder) = outcome { folder } else { nil }
        }
    )
}

/// Bir toplantı klasörünün okuma sonucu.
private enum FolderLoadOutcome: Sendable {
    case meeting(MeetingRecord)
    case failure(MeetingLoadFailure)
    /// iCloud'dan iniyor (indirmesi başlatıldı); değer klasör adıdır.
    case downloading(String)
    /// `meeting.json`'u olmayan klasör.
    case skipped
}

/// Tek bir toplantı klasörünü okur: inmemiş iCloud dosyasının indirmesini başlatır, iCloud çakışmalarını birleştirir.
private func loadMeetingFolder(folder: URL) -> FolderLoadOutcome {
    let file: URL = folder.appending(path: meetingFileName)
    guard FileManager.default.fileExists(atPath: file.path) else {
        // iPhone'da inmemiş iCloud dosyası yerine ".meeting.json.icloud" yer tutucusu durur: indirmesi başlatılır
        // (yoksa Mac'in toplantısı iPhone'da hiç görünmüyordu).
        guard FileManager.default.fileExists(atPath: cloudPlaceholder(file: file).path) else {
            return .skipped
        }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: file)
            return .downloading(folder.lastPathComponent)
        } catch {
            return .failure(MeetingLoadFailure(folder: folder.lastPathComponent, reason: String(describing: error)))
        }
    }
    do {
        guard try isDownloaded(file: file) else {
            return .downloading(folder.lastPathComponent)
        }
        try resolveCloudConflicts(file: file)
        return .meeting(try meetingDecoder().decode(MeetingRecord.self, from: Data(contentsOf: file)))
    } catch {
        return .failure(MeetingLoadFailure(folder: folder.lastPathComponent, reason: String(describing: error)))
    }
}

/// Toplantıları ana iş parçacığını bekletmeden okur: klasörler (iCloud kapsayıcısının yolu dahil; ilk çözümü yavaş
/// olabilir) ve dosyalar arka planda okunur. Sonuç `loadMeetings(directories:)` ile aynıdır. Klasör çözülemezse
/// (ör. iCloud kullanılamıyor) hata fırlatır.
public func loadMeetingsInBackground(location: StorageLocation) async throws -> MeetingLoadResult {
    try await Task.detached(priority: .userInitiated) { () throws -> MeetingLoadResult in
        loadMeetings(directories: try AppPaths.meetingDirectories(location: location))
    }.value
}

/// iCloud'dan inmemiş dosyanın iPhone'daki yer tutucusu (".ad.icloud"). Saf fonksiyondur.
public func cloudPlaceholder(file: URL) -> URL {
    file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).icloud")
}

/// Toplantı klasöründeki inmemiş ses kayıtlarının indirmesini başlatır; inen kayıt varsa true (çalmadan önce
/// "iniyor" gösterilir).
public func startDownloadingCloudAudio(directory: URL) throws -> Bool {
    var started: Bool = false
    for name in ["others.m4a", "me.m4a"] {
        let file: URL = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: cloudPlaceholder(file: file).path) {
            try FileManager.default.startDownloadingUbiquitousItem(at: file)
            started = true
        } else if FileManager.default.fileExists(atPath: file.path), try !isDownloaded(file: file) {
            started = true
        }
    }
    return started
}

/// Dosya okunabilir mi: yerel dosya ya da iCloud'dan inmiş dosya. Sunucuda daha yeni sürümü olan dosya (`.downloaded`)
/// da okunabilir: yeni sürümün indirmesi arka planda başlatılır ve true döner (toplantı listeden kaybolmaz; yeni sürüm
/// inince değişiklik bildirimiyle yeniden okunur). Hiç inmemişse indirmesi başlatılır ve false döner.
public func isDownloaded(file: URL) throws -> Bool {
    let values: URLResourceValues = try file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
    guard values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current else {
        return true
    }
    try FileManager.default.startDownloadingUbiquitousItem(at: file)
    return values.ubiquitousItemDownloadingStatus == .downloaded
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
    try coordinatedRemoveItem(at: directory)
}

/// Aramada alanları ayıran karakter (birim ayırıcı): kullanıcının sorgusunda bulunmaz.
private let searchFieldSeparator: String = "\u{1F}"

/// Aramada katlama: büyük/küçük harf ve aksan duyarsız. Yerel ayardan bağımsız (`locale: nil`): Türkçe yerel ayarda
/// "I" → "ı" olur ve Fince/İngilizce metinde "RAPORTTI" bulunamazdı.
private let searchFolding: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

/// Başlık, not ve transkriptte büyük/küçük harf duyarsız arama; boş sorgu hepsini döndürür. Saf fonksiyondur.
public func filterMeetings(records: [MeetingRecord], query: String) -> [MeetingRecord] {
    let needle: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else {
        return records
    }
    let folded: String = needle.folding(options: searchFolding, locale: nil)
    return records.filter { (record: MeetingRecord) -> Bool in
        // Listede görünen başlık notun başlığıdır; görevler, konuşmacı adları ve kendi notların da aranır.
        let haystack: [String] = [record.title, record.note?.title ?? "", record.note?.summary ?? "", record.myNotes ?? ""]
            + (record.note?.decisions ?? [])
            + (record.note?.tasks ?? []).flatMap { [$0.owner, $0.description] }
            + Array(record.speakerNames.values)
            + (record.liveSegments + record.finalSegments).map(\.text)
            + Array(record.translations.values)
        // Alanlar tek metinde birleşir, büyük/küçük harf ve aksanlar bir kez katlanır, sonra düz karşılaştırılır
        // (her bölümde ayrı harf duyarsız arama 500 toplantıda tuş başına saniyeyi aşıyordu). Ayırıcı sorguda
        // bulunmayan bir denetim karakteridir, eşleşme iki alanın sınırını aşamaz.
        return haystack.joined(separator: searchFieldSeparator)
            .folding(options: searchFolding, locale: nil)
            .range(of: folded, options: .literal) != nil
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
