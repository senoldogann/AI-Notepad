import Foundation
import Observation
import os

/// Mac ve iPhone uygulamalarının ortak iCloud Drive kapsayıcısı.
public let iCloudContainerIdentifier: String = "iCloud.com.senoldogan.AINotepad"

/// Toplantıların saklandığı yer. Kayıt ve işleme her zaman yerelde yapılır (yarım ses dosyası eşitlenmez); iCloud
/// seçiliyse biten toplantı iCloud'a taşınır ve oradaki toplantılar da listelenir.
public enum StorageLocation: String, Sendable {
    case local
    case iCloud
}

/// Saklama yeri ayarının anahtarı (iki uygulamada aynı).
public let storageLocationKey: String = "storage.location"

private let cloudLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "CloudStorage")

/// Kayıtlı saklama yeri; hiç seçilmemişse yerel. Tanınmayan değer yerel sayılır ve hata loglanır.
public func storedStorageLocation() -> StorageLocation {
    guard let raw = UserDefaults.standard.string(forKey: storageLocationKey) else {
        return .local
    }
    guard let location = StorageLocation(rawValue: raw) else {
        cloudLogger.error("Saklama yeri tanınmadı, değer: \(raw, privacy: .public)")
        return .local
    }
    return location
}

public extension AppPaths {
    /// iCloud Drive kapsayıcısındaki toplantı klasörü: `<kapsayıcı>/Documents/Sessions`. iCloud'a giriş yapılmamışsa,
    /// iCloud Drive kapalıysa ya da uygulamanın iCloud yetkisi yoksa `StorageError.iCloudUnavailable`. İlk çağrı
    /// yavaş olabilir; uygulama açılırken arka planda bir kez çağrılır.
    static func cloudSessionsDirectory() throws -> URL {
        try cloudDocumentsSubdirectory(name: "Sessions")
    }

    /// Bağlantıyla paylaşılan dışa aktarımların (PDF) iCloud Drive klasörü: `<kapsayıcı>/Documents/Shared`. iCloud
    /// kullanılamıyorsa `StorageError.iCloudUnavailable` (yerel klasöre düşülmez). İlk çağrı yavaş olabilir; ana iş
    /// parçacığında çağrılmaz.
    static func cloudSharedDirectory() throws -> URL {
        try cloudDocumentsSubdirectory(name: "Shared")
    }

    /// iCloud kapsayıcısının `Documents` altındaki klasörü; yoksa oluşturur.
    private static func cloudDocumentsSubdirectory(name: String) throws -> URL {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: iCloudContainerIdentifier) else {
            throw StorageError.iCloudUnavailable
        }
        let directory: URL = container.appending(path: "Documents", directoryHint: .isDirectory).appending(path: name, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StorageError.directoryUnavailable(path: directory.path, reason: error.localizedDescription)
        }
        return directory
    }

    /// Toplantıların okunduğu klasörler: yerel her zaman (önce); iCloud seçiliyse iCloud'daki de.
    static func meetingDirectories(location: StorageLocation) throws -> [URL] {
        switch location {
        case .local: [try sessionsDirectory()]
        case .iCloud: [try sessionsDirectory(), try cloudSessionsDirectory()]
        }
    }

    /// Toplantının klasörü: yerelde varsa orası (kayıt, işleme ya da henüz taşınmamış); yoksa iCloud seçiliyse
    /// iCloud'daki. İkisinde de yoksa yerel klasörün yolu döner.
    static func meetingDirectory(id: String, location: StorageLocation) throws -> URL {
        let local: URL = try sessionsDirectory().appending(path: id, directoryHint: .isDirectory)
        guard location == .iCloud, !FileManager.default.fileExists(atPath: local.path) else {
            return local
        }
        let cloud: URL = try cloudSessionsDirectory().appending(path: id, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: cloud.path) ? cloud : local
    }
}

/// Taşıma ya da kopyalamanın sonucu: işlenen toplantılar ve işlenemeyenler (biri diğerlerini engellemez).
public struct CloudMoveResult: Sendable, Equatable {
    public let moved: [String]
    public let failures: [MeetingLoadFailure]
}

/// Yerel klasördeki bitmiş (`done`) toplantıları iCloud'a taşır. Kayıtta, işlemede, yarıda kalmış ya da başarısız
/// toplantı yerelde kalır (sesi yeniden işlenebilsin); `excluding` (düzenlenen, çalan, kilitli) toplantılara dokunulmaz.
/// iCloud'da aynı kimlik zaten varsa (ör. eşitleme kapatılıp açıldı) yerel kopya kalır, liste yereli gösterir. Her
/// toplantı ayrı denenir. Ana iş parçacığında çağrılmaz.
public func moveFinishedMeetingsToCloud(localSessions: URL, cloudSessions: URL, excluding: Set<String>) -> CloudMoveResult {
    var moved: [String] = []
    var failures: [MeetingLoadFailure] = []
    for record in loadMeetings(sessionsDirectory: localSessions).meetings where record.status == .done && !excluding.contains(record.id) {
        guard !FileManager.default.fileExists(atPath: cloudSessions.appending(path: record.id, directoryHint: .isDirectory).path) else {
            continue
        }
        do {
            _ = try moveMeetingToCloud(directory: localSessions.appending(path: record.id, directoryHint: .isDirectory), cloudSessions: cloudSessions)
            moved.append(record.id)
        } catch {
            failures.append(MeetingLoadFailure(folder: record.id, reason: userFacingMessage(error: error)))
        }
    }
    return CloudMoveResult(moved: moved, failures: failures)
}

/// iCloud'daki toplantıları bu cihaza kopyalar (iCloud eşitlemesi kapatılınca): iCloud'dakiler yerinde kalır, böylece
/// diğer cihaz kendi toplantılarını kaybetmez. Bu cihazda zaten olanlar atlanır. Okuma dosya koordinatörüyle yapılır;
/// inmemiş dosyalar okunurken iner. Ana iş parçacığında çağrılmaz.
public func copyAllMeetingsToLocal(cloudSessions: URL, localSessions: URL) throws -> CloudMoveResult {
    let folders: [URL]
    do {
        folders = try FileManager.default.contentsOfDirectory(at: cloudSessions, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
    } catch {
        throw StorageError.readFailed(path: cloudSessions.path, reason: error.localizedDescription)
    }
    var copied: [String] = []
    var failures: [MeetingLoadFailure] = []
    for folder in folders {
        let destination: URL = localSessions.appending(path: folder.lastPathComponent, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            continue
        }
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: folder, options: [], error: &coordinationError) { (url: URL) -> Void in
            do {
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            failures.append(MeetingLoadFailure(folder: folder.lastPathComponent, reason: error.localizedDescription))
        } else {
            copied.append(folder.lastPathComponent)
        }
    }
    cloudLogger.info("iCloud'daki toplantılar bu cihaza kopyalandı, sayı: \(copied.count, privacy: .public), başarısız: \(failures.count, privacy: .public)")
    return CloudMoveResult(moved: copied, failures: failures)
}

/// iCloud'daki toplantı klasörünü bu cihaza taşır (gerekirse indirir); yeni yolu döndürür. Hedefte aynı adlı klasör
/// varsa `alreadyExists`. Ana iş parçacığında çağrılmaz.
public func moveMeetingToLocal(directory: URL, localSessions: URL) throws -> URL {
    let destination: URL = localSessions.appending(path: directory.lastPathComponent, directoryHint: .isDirectory)
    try moveUbiquitous(from: directory, to: destination, makeUbiquitous: false)
    cloudLogger.info("Toplantı iCloud'dan bu cihaza taşındı, toplantı: \(directory.lastPathComponent, privacy: .public)")
    return destination
}

/// Toplantı klasörünü iCloud'a taşır (`setUbiquitous`); yeni yolu döndürür. Hedefte aynı adlı klasör varsa
/// `alreadyExists` (üzerine yazılmaz). Ana iş parçacığında çağrılmaz.
public func moveMeetingToCloud(directory: URL, cloudSessions: URL) throws -> URL {
    let destination: URL = cloudSessions.appending(path: directory.lastPathComponent, directoryHint: .isDirectory)
    try moveUbiquitous(from: directory, to: destination, makeUbiquitous: true)
    cloudLogger.info("Toplantı iCloud'a taşındı, toplantı: \(directory.lastPathComponent, privacy: .public)")
    return destination
}

/// `FileManager.setUbiquitous` ile taşır: iCloud'a (`makeUbiquitous`) ya da iCloud'dan yerele. İki yönü tek yerde
/// tutar (hedef kontrolü ve hata türleri aynı).
private func moveUbiquitous(from source: URL, to destination: URL, makeUbiquitous: Bool) throws {
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw StorageError.alreadyExists(path: destination.path)
    }
    do {
        try FileManager.default.setUbiquitous(makeUbiquitous, itemAt: source, destinationURL: destination)
    } catch {
        throw StorageError.moveFailed(path: source.path, reason: error.localizedDescription)
    }
}

/// iCloud'daki toplantı dosyalarının değişimini izler (başka cihazda kaydedilen, değişen ya da inen `meeting.json`).
/// Değişince `onChange` çağrılır; çağıran toplantıları yeniden okur. Dış sisteme (iCloud) bağlandığı için sınıftır.
@MainActor
public final class ICloudMeetingWatcher {
    /// Her başlatmada yeni sorgu: durdurulmuş `NSMetadataQuery` yeniden başlatılamaz.
    private var query: NSMetadataQuery?
    private var observers: [any NSObjectProtocol] = []
    /// Art arda gelen bildirimler birleştirilir (bir eşitleme turunda onlarca güncelleme gelir).
    private var pending: Task<Void, Never>?

    public init() {}

    /// İzlemeyi başlatır; zaten çalışıyorsa bir şey yapmaz.
    public func start(onChange: @escaping @MainActor () -> Void) {
        guard observers.isEmpty else {
            return
        }
        let query: NSMetadataQuery = NSMetadataQuery()
        self.query = query
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, meetingFileName)
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] (_: Notification) -> Void in
                MainActor.assumeIsolated {
                    self?.schedule(onChange: onChange)
                }
            })
        }
        if !query.start() {
            cloudLogger.error("iCloud değişiklik izleme başlatılamadı")
        }
    }

    /// İzlemeyi durdurur.
    public func stop() {
        query?.stop()
        query = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        pending?.cancel()
        pending = nil
    }

    private func schedule(onChange: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                // Yeni bildirim geldi: bekleme yeniden başlar.
                return
            }
            onChange()
        }
    }
}

/// Yerel klasördeki bitmiş toplantıları arka planda iCloud'a taşır (bkz. `moveFinishedMeetingsToCloud`). iCloud
/// kullanılamıyorsa `iCloudUnavailable`.
public func moveFinishedMeetingsToCloudInBackground(excluding: Set<String>) async throws -> CloudMoveResult {
    try await Task.detached(priority: .utility) {
        moveFinishedMeetingsToCloud(localSessions: try AppPaths.sessionsDirectory(), cloudSessions: try AppPaths.cloudSessionsDirectory(), excluding: excluding)
    }.value
}

/// iCloud'daki toplantıları arka planda bu cihaza kopyalar (bkz. `copyAllMeetingsToLocal`).
public func copyAllMeetingsToLocalInBackground() async throws -> CloudMoveResult {
    try await Task.detached(priority: .userInitiated) {
        try copyAllMeetingsToLocal(cloudSessions: try AppPaths.cloudSessionsDirectory(), localSessions: try AppPaths.sessionsDirectory())
    }.value
}

/// iCloud kapsayıcısını arka planda çözer (ilk çağrı yavaştır; sonra ana iş parçacığındaki çağrılar hızlıdır).
/// iCloud kullanılamıyorsa `iCloudUnavailable`.
public func prepareCloudStorage() async throws {
    _ = try await Task.detached(priority: .utility) {
        try AppPaths.cloudSessionsDirectory()
    }.value
}

/// Çakışan sürümlerin kullanıcı işaretlerini birleştirir: son yazılan sürüm temeldir, diğer cihazda tamamlanan ya da
/// Anımsatıcılar'a eklenen görevler kaybolmaz (ör. iPhone'da işaretlenen görev, Mac notu yeniden yazarken). Saf
/// fonksiyondur.
public func mergedConflictRecord(current: MeetingRecord, others: [MeetingRecord]) -> MeetingRecord {
    let union: ([String]?, [[String]?]) -> [String] = { (base: [String]?, extra: [[String]?]) -> [String] in
        extra.reduce(base ?? []) { (result: [String], keys: [String]?) -> [String] in result + (keys ?? []).filter { !result.contains($0) } }
    }
    let completed: [String] = union(current.completedTasks, others.map(\.completedTasks))
    let reminded: [String] = union(current.remindedTasks, others.map(\.remindedTasks))
    return current.with(completedTasks: completed).with(remindedTasks: reminded)
}

/// Toplantı dosyasındaki iCloud çakışmalarını çözer: son yazılan sürüm kalır, diğer sürümlerdeki görev işaretleri ona
/// eklenir (bkz. `mergedConflictRecord`), diğer sürümler kaldırılır ve loglanır. Çakışma yoksa bir şey yapmaz.
public func resolveCloudConflicts(file: URL) throws {
    guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: file), !conflicts.isEmpty else {
        return
    }
    do {
        let current: MeetingRecord = try meetingDecoder().decode(MeetingRecord.self, from: Data(contentsOf: file))
        let others: [MeetingRecord] = try conflicts.map { (version: NSFileVersion) throws -> MeetingRecord in
            try meetingDecoder().decode(MeetingRecord.self, from: Data(contentsOf: version.url))
        }
        let merged: MeetingRecord = mergedConflictRecord(current: current, others: others)
        if merged != current {
            try saveMeeting(record: merged, directory: file.deletingLastPathComponent())
        }
    } catch let error as StorageError {
        throw error
    } catch {
        throw StorageError.readFailed(path: file.path, reason: error.localizedDescription)
    }
    for version in conflicts {
        version.isResolved = true
    }
    do {
        try NSFileVersion.removeOtherVersionsOfItem(at: file)
    } catch {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
    cloudLogger.warning("iCloud çakışması çözüldü (son yazılan kaldı), dosya: \(file.deletingLastPathComponent().lastPathComponent, privacy: .public), sürüm: \(conflicts.count, privacy: .public)")
}

/// Uzun süren bir eşitleme işinin (iCloud'a taşıma, anahtar kopyalama) durumu; ayarlarda görünür.
public enum SyncWorkState: Equatable, Sendable {
    case idle
    case working
    case failed(String)
}

/// iCloud eşitlemesinin durumu ve akışı (Mac ve iPhone ortak): açılışta kapsayıcıyı arka planda hazırlar ve
/// değişiklikleri izler; açınca bitmiş toplantıları iCloud'a taşır, kapatınca iCloud'dakileri bu cihaza kopyalar
/// (diğer cihazınkiler iCloud'da kalır); her toplantı bitince bekleyenleri taşır. Taşımalar sırayla yapılır: kapatma,
/// süren taşımanın bitmesini bekler. Toplantılar değişince verilen `onChange` çağrılır (uygulama listeyi yeniden okur).
@MainActor
@Observable
public final class CloudSyncController {
    /// Seçili saklama yeri.
    public private(set) var location: StorageLocation = storedStorageLocation()
    /// Açma, kapatma ya da taşıma sürüyor ya da başarısız oldu.
    public private(set) var state: SyncWorkState = .idle
    /// Kapsayıcı hazırlandı (ilk çözüm yavaştır; hazır olana dek yalnız yerel okunur).
    public private(set) var isReady: Bool = false
    @ObservationIgnored private let watcher: ICloudMeetingWatcher = ICloudMeetingWatcher()
    /// Süren taşıma (kapatma bunu bekler; iki taşıma üst üste binmez).
    @ObservationIgnored private var currentMove: Task<Void, Never>?

    public init() {}

    /// Okuma ve klasör çözümünde kullanılacak yer: iCloud seçili ve hazırsa iCloud, değilse yerel.
    public var activeLocation: StorageLocation {
        location == .iCloud && isReady ? .iCloud : .local
    }

    /// Açılışta: iCloud seçiliyse kapsayıcıyı hazırlar, izlemeye başlar, listeyi yeniletir ve bekleyen toplantıları taşır.
    public func start(excluding: Set<String>, onChange: @escaping @MainActor () -> Void) async {
        guard location == .iCloud else {
            return
        }
        do {
            try await prepareCloudStorage()
        } catch {
            cloudLogger.error("iCloud hazırlanamadı, hata: \(String(describing: error), privacy: .public)")
            state = .failed(userFacingMessage(error: error))
            return
        }
        becomeReady(onChange: onChange)
        await moveFinishedMeetings(excluding: excluding, onChange: onChange)
    }

    /// iCloud eşitlemesini açar ya da kapatır; başarısız olursa ayar değişmez ve neden `state`'te görünür.
    public func setEnabled(_ enabled: Bool, excluding: Set<String>, onChange: @escaping @MainActor () -> Void) async {
        guard state != .working, enabled != (location == .iCloud) else {
            return
        }
        state = .working
        await currentMove?.value
        do {
            if enabled {
                try await prepareCloudStorage()
                save(location: .iCloud)
                becomeReady(onChange: onChange)
                let result: CloudMoveResult = try await moveFinishedMeetingsToCloudInBackground(excluding: excluding)
                cloudLogger.info("iCloud eşitlemesi açıldı, taşınan: \(result.moved.count, privacy: .public)")
                state = result.failures.isEmpty ? .idle : .failed(failureSummary(failures: result.failures))
            } else {
                let result: CloudMoveResult = try await copyAllMeetingsToLocalInBackground()
                watcher.stop()
                isReady = false
                save(location: .local)
                cloudLogger.info("iCloud eşitlemesi kapatıldı, kopyalanan: \(result.moved.count, privacy: .public)")
                state = result.failures.isEmpty ? .idle : .failed(failureSummary(failures: result.failures))
            }
        } catch {
            cloudLogger.error("iCloud eşitlemesi değiştirilemedi, hata: \(String(describing: error), privacy: .public)")
            state = .failed(userFacingMessage(error: error))
        }
        onChange()
    }

    /// iCloud açık ve hazırsa yerelde bekleyen bitmiş toplantıları taşır (her toplantı bitince); `excluding`
    /// toplantılara (düzenlenen, çalan) dokunulmaz. Önceki taşıma bitmeden yenisi başlamaz.
    public func moveFinishedMeetings(excluding: Set<String>, onChange: @escaping @MainActor () -> Void) async {
        guard activeLocation == .iCloud else {
            return
        }
        let previous: Task<Void, Never>? = currentMove
        let move: Task<Void, Never> = Task {
            await previous?.value
            // Bekleme sırasında eşitleme kapatılmış olabilir.
            guard self.activeLocation == .iCloud else {
                return
            }
            do {
                let result: CloudMoveResult = try await moveFinishedMeetingsToCloudInBackground(excluding: excluding)
                if !result.moved.isEmpty {
                    cloudLogger.info("Toplantılar iCloud'a taşındı, sayı: \(result.moved.count, privacy: .public)")
                    onChange()
                }
                if !result.failures.isEmpty {
                    self.state = .failed(failureSummary(failures: result.failures))
                }
            } catch {
                cloudLogger.error("Toplantı iCloud'a taşınamadı, hata: \(String(describing: error), privacy: .public)")
                self.state = .failed(userFacingMessage(error: error))
            }
        }
        currentMove = move
        await move.value
    }

    private func becomeReady(onChange: @escaping @MainActor () -> Void) {
        isReady = true
        watcher.start(onChange: onChange)
        onChange()
    }

    private func save(location newLocation: StorageLocation) {
        location = newLocation
        UserDefaults.standard.set(newLocation.rawValue, forKey: storageLocationKey)
    }
}

/// Taşınamayan toplantıların özeti (ayarlarda gösterilir). Saf fonksiyondur.
func failureSummary(failures: [MeetingLoadFailure]) -> String {
    String(localized: "\(failures.count) toplantı taşınamadı: \(failures.first?.reason ?? "")")
}

public extension AppPaths {
    /// Bu cihazın yerel klasöründeki toplantıların kimlikleri (iCloud'daki başka cihazınkiler değil). Açılıştaki
    /// "yarıda kaldı" işaretleme, yeniden işleme ve ses saklama yalnızca bunlara uygulanır: diğer cihazın işlediği ya
    /// da sesini sakladığı toplantıya dokunulmaz.
    static func localMeetingIDs() throws -> Set<String> {
        let sessions: URL = try sessionsDirectory()
        do {
            return Set(try FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil).map(\.lastPathComponent))
        } catch {
            throw StorageError.readFailed(path: sessions.path, reason: error.localizedDescription)
        }
    }
}
