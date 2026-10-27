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
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: iCloudContainerIdentifier) else {
            throw StorageError.iCloudUnavailable
        }
        let sessions: URL = container.appending(path: "Documents", directoryHint: .isDirectory).appending(path: "Sessions", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        } catch {
            throw StorageError.directoryUnavailable(path: sessions.path, reason: error.localizedDescription)
        }
        return sessions
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

/// Yerel klasördeki bitmiş (`done`) toplantıları iCloud'a taşır; taşınanların kimliklerini döndürür. Kayıtta, işlemede,
/// yarıda kalmış ya da başarısız toplantı yerelde kalır (sesi yeniden işlenebilsin). Bir toplantı taşınamazsa hata
/// fırlatılır; o ana kadar taşınanlar iCloud'da kalır. Ana iş parçacığında çağrılmaz.
public func moveFinishedMeetingsToCloud(localSessions: URL, cloudSessions: URL) throws -> [String] {
    try loadMeetings(sessionsDirectory: localSessions).meetings
        .filter { $0.status == .done }
        .map { (record: MeetingRecord) -> String in
            _ = try moveMeetingToCloud(directory: localSessions.appending(path: record.id, directoryHint: .isDirectory), cloudSessions: cloudSessions)
            return record.id
        }
}

/// iCloud'daki tüm toplantıları yerel klasöre geri indirip taşır (iCloud eşitlemesi kapatılınca); taşınanların
/// kimliklerini döndürür. Ana iş parçacığında çağrılmaz.
public func moveAllMeetingsToLocal(cloudSessions: URL, localSessions: URL) throws -> [String] {
    let folders: [URL]
    do {
        folders = try FileManager.default.contentsOfDirectory(at: cloudSessions, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
    } catch {
        throw StorageError.readFailed(path: cloudSessions.path, reason: error.localizedDescription)
    }
    return try folders.map { (folder: URL) -> String in
        _ = try moveMeetingToLocal(directory: folder, localSessions: localSessions)
        return folder.lastPathComponent
    }
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
    private let query: NSMetadataQuery = NSMetadataQuery()
    private var observers: [any NSObjectProtocol] = []
    /// Art arda gelen bildirimler birleştirilir (bir eşitleme turunda onlarca güncelleme gelir).
    private var pending: Task<Void, Never>?

    public init() {}

    /// İzlemeyi başlatır; zaten çalışıyorsa bir şey yapmaz.
    public func start(onChange: @escaping @MainActor () -> Void) {
        guard observers.isEmpty else {
            return
        }
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, meetingFileName)
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] (_: Notification) -> Void in
                MainActor.assumeIsolated {
                    self?.schedule(onChange: onChange)
                }
            })
        }
        query.start()
    }

    /// İzlemeyi durdurur.
    public func stop() {
        query.stop()
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

/// Yerel klasördeki bitmiş toplantıları arka planda iCloud'a taşır (iCloud seçilince ve her toplantı bitince);
/// taşınanların kimliklerini döndürür. iCloud kullanılamıyorsa `iCloudUnavailable`.
public func moveFinishedMeetingsToCloudInBackground() async throws -> [String] {
    try await Task.detached(priority: .utility) {
        try moveFinishedMeetingsToCloud(localSessions: try AppPaths.sessionsDirectory(), cloudSessions: try AppPaths.cloudSessionsDirectory())
    }.value
}

/// iCloud'daki tüm toplantıları arka planda bu cihaza geri taşır (iCloud eşitlemesi kapatılınca).
public func moveAllMeetingsToLocalInBackground() async throws -> [String] {
    try await Task.detached(priority: .userInitiated) {
        try moveAllMeetingsToLocal(cloudSessions: try AppPaths.cloudSessionsDirectory(), localSessions: try AppPaths.sessionsDirectory())
    }.value
}

/// iCloud kapsayıcısını arka planda çözer (ilk çağrı yavaştır; sonra ana iş parçacığındaki çağrılar hızlıdır).
/// iCloud kullanılamıyorsa `iCloudUnavailable`.
public func prepareCloudStorage() async throws {
    _ = try await Task.detached(priority: .utility) {
        try AppPaths.cloudSessionsDirectory()
    }.value
}

/// Toplantı dosyasındaki iCloud çakışmalarını çözer: son yazılan sürüm kalır, diğer sürümler kaldırılır ve loglanır.
/// Çakışma yoksa bir şey yapmaz.
public func resolveCloudConflicts(file: URL) throws {
    guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: file), !conflicts.isEmpty else {
        return
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
/// değişiklikleri izler; açınca bitmiş toplantıları iCloud'a, kapatınca iCloud'dakileri bu cihaza taşır; her toplantı
/// bitince bekleyenleri taşır. Toplantılar değişince verilen `onChange` çağrılır (uygulama listeyi yeniden okur).
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

    public init() {}

    /// Okuma ve klasör çözümünde kullanılacak yer: iCloud seçili ve hazırsa iCloud, değilse yerel.
    public var activeLocation: StorageLocation {
        location == .iCloud && isReady ? .iCloud : .local
    }

    /// Açılışta: iCloud seçiliyse kapsayıcıyı hazırlar, izlemeye başlar, listeyi yeniletir ve bekleyen toplantıları taşır.
    public func start(onChange: @escaping @MainActor () -> Void) async {
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
        await moveFinishedMeetings(onChange: onChange)
    }

    /// iCloud eşitlemesini açar ya da kapatır; başarısız olursa ayar değişmez ve neden `state`'te görünür.
    public func setEnabled(_ enabled: Bool, onChange: @escaping @MainActor () -> Void) async {
        guard state != .working, enabled != (location == .iCloud) else {
            return
        }
        state = .working
        do {
            if enabled {
                try await prepareCloudStorage()
                save(location: .iCloud)
                becomeReady(onChange: onChange)
                let moved: [String] = try await moveFinishedMeetingsToCloudInBackground()
                cloudLogger.info("iCloud eşitlemesi açıldı, taşınan: \(moved.count, privacy: .public)")
            } else {
                let moved: [String] = try await moveAllMeetingsToLocalInBackground()
                watcher.stop()
                isReady = false
                save(location: .local)
                cloudLogger.info("iCloud eşitlemesi kapatıldı, geri taşınan: \(moved.count, privacy: .public)")
            }
            state = .idle
        } catch {
            cloudLogger.error("iCloud eşitlemesi değiştirilemedi, hata: \(String(describing: error), privacy: .public)")
            state = .failed(userFacingMessage(error: error))
        }
        onChange()
    }

    /// iCloud açık ve hazırsa yerelde bekleyen bitmiş toplantıları taşır (her toplantı bitince).
    public func moveFinishedMeetings(onChange: @MainActor () -> Void) async {
        guard activeLocation == .iCloud else {
            return
        }
        do {
            let moved: [String] = try await moveFinishedMeetingsToCloudInBackground()
            if !moved.isEmpty {
                cloudLogger.info("Toplantılar iCloud'a taşındı, sayı: \(moved.count, privacy: .public)")
                onChange()
            }
        } catch {
            cloudLogger.error("Toplantı iCloud'a taşınamadı, hata: \(String(describing: error), privacy: .public)")
            state = .failed(userFacingMessage(error: error))
        }
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
