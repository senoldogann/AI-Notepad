import CryptoKit
import Darwin
import Foundation
import os
import Synchronization

// Hesap başına veri (yalnız abonelik sürümü): aynı Mac'te iki hesapla (ör. Google ve Apple) giriş yapılınca her hesap
// yalnızca kendi toplantılarını, Sor geçmişini, kişilerini ve ses izlerini görür. Veri `<veri klasörü>/Accounts/<anahtar>/`
// altındadır; anahtar sunucudaki kullanıcı kimliğinin SHA-256 özetinden türer (kimlik diskte açık yazılmaz). Modeller
// (`Models`) ve çökme raporları (`CrashReports`) kullanıcı içeriği olmadığı için kökte paylaşılır. Güncellemeden önceki
// (hesapsız) veri, güncellemeden sonra ilk giriş yapan hesaba taşınır (bkz. `migrateLegacyUserData`).

private let accountDataLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AccountData")

/// Info.plist anahtarı: kullanıcı verisi giriş yapan hesaba göre ayrı klasörlerde mi. Yalnızca abonelik sürümü `true`
/// yazar; anahtar yoksa veri klasörün kökündedir (geliştirici sürümü ve iPhone, değişmeden).
public let accountScopedDataInfoKey: String = "AINotepadAccountScopedData"

/// Hesap klasörlerinin üst klasörünün adı: `<veri klasörü>/Accounts`.
public let accountsFolderName: String = "Accounts"

/// Eski verinin hangi hesaba verildiğini tutan dosyanın adı (`Accounts` içinde; içeriği hesap anahtarı).
public let legacyClaimFileName: String = "legacy-owner"

/// Hesaba ait toplantı klasörünün adı (eski düzende de aynı: `Sessions`).
public let sessionsFolderName: String = "Sessions"

/// Hesaba ait Sor geçmişi klasörünün adı (eski düzende de aynı: `AskHistory`).
public let askHistoryFolderName: String = "AskHistory"

/// Eski düzende veri klasörünün kökünde duran, hesaba taşınan dosyalar: kişiler defteri ve ses izleri.
public let legacyRootFileNames: [String] = ["People.json", "Voices.json"]

/// Hesap anahtarı: kullanıcı kimliğinin SHA-256 özetinin ilk 16 baytı, küçük harfli onaltılık (32 karakter). Aynı
/// kimlik her zaman aynı anahtarı verir; kimlik anahtardan geri çıkarılamaz. Saf fonksiyondur.
public func accountDataKey(userId: String) -> String {
    SHA256.hash(data: Data(userId.utf8)).prefix(16).map { (byte: UInt8) -> String in String(format: "%02x", byte) }.joined()
}

/// Anahtar `accountDataKey`'in ürettiği biçimde mi (32 küçük harfli onaltılık karakter): klasör adı olarak güvenli.
/// Saf fonksiyondur.
public func isValidAccountDataKey(key: String) -> Bool {
    key.count == 32 && key.allSatisfy { (character: Character) -> Bool in character.isHexDigit && !character.isUppercase }
}

/// Bu süreçte yüklü hesabın anahtarı. Bir kez atanır; başka bir hesaba geçmek için uygulama yeniden başlar (bellekteki
/// toplantılar, kişiler ve süren işlemeler eski hesabın klasörüne yazmaya devam etmesin).
private let activeAccountKeyStore: Mutex<String?> = Mutex(nil)

public extension AppPaths {
    /// Uygulama kullanıcı verisini hesap başına mı ayırıyor (Info.plist, bkz. `accountScopedDataInfoKey`).
    static func isAccountScoped(bundle: Bundle) -> Bool {
        bundle.object(forInfoDictionaryKey: accountScopedDataInfoKey) as? Bool == true
    }

    /// Hesap klasörlerinin üst klasörü: `<veri klasörü>/Accounts`. Saf fonksiyondur.
    static func accountsDirectory(dataRoot: URL) -> URL {
        dataRoot.appending(path: accountsFolderName, directoryHint: .isDirectory)
    }

    /// Hesabın veri klasörü: `<veri klasörü>/Accounts/<anahtar>`. Saf fonksiyondur.
    static func accountDataDirectory(dataRoot: URL, accountKey: String) -> URL {
        accountsDirectory(dataRoot: dataRoot).appending(path: accountKey, directoryHint: .isDirectory)
    }

    /// Hesabın toplantı klasörü: `<veri klasörü>/Accounts/<anahtar>/Sessions`. Saf fonksiyondur.
    static func accountSessionsDirectory(dataRoot: URL, accountKey: String) -> URL {
        accountDataDirectory(dataRoot: dataRoot, accountKey: accountKey).appending(path: sessionsFolderName, directoryHint: .isDirectory)
    }

    /// Eski verinin sahibini tutan dosya: `<veri klasörü>/Accounts/legacy-owner`. Saf fonksiyondur.
    static func legacyClaimFile(dataRoot: URL) -> URL {
        accountsDirectory(dataRoot: dataRoot).appending(path: legacyClaimFileName, directoryHint: .notDirectory)
    }

    /// Bu süreçte yüklü hesabın anahtarı; hesap yüklenmediyse nil.
    static func activeAccountKey() -> String? {
        activeAccountKeyStore.withLock { (key: inout String?) -> String? in key }
    }

    /// Hesabı bu süreç için yükler: sonraki tüm kullanıcı verisi okuma ve yazmaları onun klasörüne gider. Aynı hesap
    /// yeniden yüklenirse bir şey olmaz; başka bir hesap zaten yüklüyse `accountSwitchRequiresRelaunch` (uygulama
    /// yeniden başlamalı). Anahtar geçersizse `invalidAccountKey`.
    static func activateAccount(key: String) throws {
        guard isValidAccountDataKey(key: key) else {
            throw StorageError.invalidAccountKey(key: key)
        }
        try activeAccountKeyStore.withLock { (active: inout String?) throws -> Void in
            if let current = active, current != key {
                throw StorageError.accountSwitchRequiresRelaunch(active: current, requested: key)
            }
            active = key
        }
    }

    /// Kullanıcı verisinin (toplantılar, Sor geçmişi, kişiler, ses izleri) kökü. Hesap başına veri kapalıysa veri
    /// klasörünün kendisi (geliştirici sürümü, iPhone); açıksa yüklü hesabın klasörü, hesap yüklenmediyse
    /// `accountNotSelected` (eski ortak klasöre asla düşülmez).
    static func userDataDirectory() throws -> URL {
        guard isAccountScoped(bundle: .main) else {
            return try applicationSupport()
        }
        guard let key = activeAccountKey() else {
            throw StorageError.accountNotSelected
        }
        let directory: URL = accountDataDirectory(dataRoot: try applicationSupport(), accountKey: key)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StorageError.directoryUnavailable(path: directory.path, reason: error.localizedDescription)
        }
        return directory
    }
}

/// Bu süreçte yüklü hesap ile giriş yapan hesaba göre yapılacak iş.
public enum AccountDataTransition: Equatable, Sendable {
    /// Değişiklik yok: giriş yok (çıkışta yerel veri yüklü kalır, giriş kapısı gizler) ya da aynı hesap.
    case keep
    /// Henüz hesap yüklenmedi: giriş yapan hesabın verisi bu süreçte yüklenir.
    case activate(accountKey: String)
    /// Başka bir hesabın verisi yüklü: uygulama (kayıt ve işleme yokken) yeniden başlar ve yeni hesabınkini yükler.
    case relaunch(accountKey: String)
}

/// Yüklü hesap (`loadedKey`) ve giriş yapan hesaba (`signedInKey`) göre yapılacak iş. Saf fonksiyondur.
public func accountDataTransition(loadedKey: String?, signedInKey: String?) -> AccountDataTransition {
    guard let signedInKey else {
        return .keep
    }
    guard let loadedKey else {
        return .activate(accountKey: signedInKey)
    }
    return loadedKey == signedInKey ? .keep : .relaunch(accountKey: signedInKey)
}

/// MCP sunucusunun (dış istemcinin başlattığı ayrı süreç) arşive erişimi.
public enum AccountArchiveAccess: Equatable, Sendable {
    /// Sunucu açıldığındaki hesap hâlâ giriş yapmış ve arşivi bu Mac'te hazır.
    case allowed
    /// Oturum yok (çıkış yapıldı).
    case signedOut
    /// Sunucu açıldıktan sonra başka bir hesapla giriş yapıldı: eski hesabın arşivi okunmaz.
    case accountChanged
    /// Hesabın arşivi bu Mac'te henüz yok (uygulama güncellemeden sonra bu hesapla hiç açılmadı).
    case notPrepared
}

/// MCP araç çağrısında arşive erişim: sunucunun açıldığı hesap (`startedKey`), şu anki oturumun hesabı (`currentKey`)
/// ve hesabın arşiv klasörü var mı. Saf fonksiyondur.
public func accountArchiveAccess(startedKey: String, currentKey: String?, archiveExists: Bool) -> AccountArchiveAccess {
    guard let currentKey else {
        return .signedOut
    }
    guard currentKey == startedKey else {
        return .accountChanged
    }
    return archiveExists ? .allowed : .notPrepared
}

// MARK: Eski verinin taşınması

/// Eski verinin sahipliği karşısında bu hesabın durumu.
public enum LegacyDataClaim: Equatable, Sendable {
    /// Eski veri henüz kimsenin değil: bu hesap sahiplenir, eski veri bu hesaba taşınır.
    case claim
    /// Eski veri zaten bu hesabın: yerinde kalan (yarıda kalmış taşıma) varsa taşınır.
    case resume
    /// Eski veri başka bir hesabın: bu hesap boş başlar, eski veriye dokunulmaz.
    case ownedByAnotherAccount
}

/// Sahiplik kaydına (`claimOwner`; yoksa nil) göre bu hesabın (`accountKey`) durumu. Saf fonksiyondur.
public func legacyDataClaim(claimOwner: String?, accountKey: String) -> LegacyDataClaim {
    guard let claimOwner else {
        return .claim
    }
    return claimOwner == accountKey ? .resume : .ownedByAnotherAccount
}

/// Eski (hesapsız) düzende veri klasörünün kökünde kalan kullanıcı verisi: toplantı klasörleri, Sor sohbet dosyaları ve
/// kökteki dosyalar (`legacyRootFileNames`). Gizli dosyalar (`.DS_Store`) sayılmaz ve yerinde kalır.
public struct LegacyUserData: Equatable, Sendable {
    public let sessionEntries: [String]
    public let askHistoryEntries: [String]
    public let rootFiles: [String]

    public init(sessionEntries: [String], askHistoryEntries: [String], rootFiles: [String]) {
        self.sessionEntries = sessionEntries
        self.askHistoryEntries = askHistoryEntries
        self.rootFiles = rootFiles
    }

    /// Taşınacak bir şey yok.
    public var isEmpty: Bool {
        sessionEntries.isEmpty && askHistoryEntries.isEmpty && rootFiles.isEmpty
    }
}

/// Tek bir taşıma: aynı disk içinde yeniden adlandırma (kopyalanmaz).
public struct DataMove: Equatable, Sendable {
    public let source: URL
    public let destination: URL

    public init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }
}

/// Eski verinin taşınma planı. Toplantılar sahiplerine gider: `recordOwnerKeys`'te (kayıt kimliği → hesap anahtarı)
/// başka bir hesaba yazılmış bekleyen kayıt (çevrimdışı kaydedilmiş ya da içe aktarılmış) o hesabın klasörüne, diğer
/// her şey sahiplenen hesaba (`claimantKey`). Sırası: toplantılar, Sor geçmişi, kökteki dosyalar (girdilerin sırasıyla).
/// Saf fonksiyondur.
public func legacyDataMoves(dataRoot: URL, legacy: LegacyUserData, claimantKey: String, recordOwnerKeys: [String: String]) -> [DataMove] {
    let legacySessions: URL = dataRoot.appending(path: sessionsFolderName, directoryHint: .isDirectory)
    let legacyAskHistory: URL = dataRoot.appending(path: askHistoryFolderName, directoryHint: .isDirectory)
    let sessionMoves: [DataMove] = legacy.sessionEntries.map { (name: String) -> DataMove in
        let owner: String = recordOwnerKeys[name] ?? claimantKey
        return DataMove(
            source: legacySessions.appending(path: name, directoryHint: .isDirectory),
            destination: AppPaths.accountSessionsDirectory(dataRoot: dataRoot, accountKey: owner).appending(path: name, directoryHint: .isDirectory)
        )
    }
    let claimantRoot: URL = AppPaths.accountDataDirectory(dataRoot: dataRoot, accountKey: claimantKey)
    let askMoves: [DataMove] = legacy.askHistoryEntries.map { (name: String) -> DataMove in
        DataMove(
            source: legacyAskHistory.appending(path: name, directoryHint: .notDirectory),
            destination: claimantRoot.appending(path: askHistoryFolderName, directoryHint: .isDirectory).appending(path: name, directoryHint: .notDirectory)
        )
    }
    let rootMoves: [DataMove] = legacy.rootFiles.map { (name: String) -> DataMove in
        DataMove(
            source: dataRoot.appending(path: name, directoryHint: .notDirectory),
            destination: claimantRoot.appending(path: name, directoryHint: .notDirectory)
        )
    }
    return sessionMoves + askMoves + rootMoves
}

/// Veri klasörünün kökünde kalan eski kullanıcı verisini okur (yalnızca adlar; içerik okunmaz). Klasör yoksa boş sayılır.
public func readLegacyUserData(dataRoot: URL) throws -> LegacyUserData {
    LegacyUserData(
        sessionEntries: try visibleEntries(directory: dataRoot.appending(path: sessionsFolderName, directoryHint: .isDirectory)),
        askHistoryEntries: try visibleEntries(directory: dataRoot.appending(path: askHistoryFolderName, directoryHint: .isDirectory)),
        rootFiles: legacyRootFileNames.filter { (name: String) -> Bool in
            FileManager.default.fileExists(atPath: dataRoot.appending(path: name, directoryHint: .notDirectory).path)
        }
    )
}

/// Klasördeki gizli olmayan girdilerin adları (sıralı); klasör yoksa boş.
private func visibleEntries(directory: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return []
    }
    do {
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
    } catch {
        throw StorageError.readFailed(path: directory.path, reason: error.localizedDescription)
    }
}

/// Eski verinin sahibi (hesap anahtarı); kimse sahiplenmediyse nil. Kayıt bozuksa (`invalidAccountKey`) hata: tahminle
/// başka bir hesaba verilmez.
public func readLegacyClaimOwner(dataRoot: URL) throws -> String? {
    let file: URL = AppPaths.legacyClaimFile(dataRoot: dataRoot)
    guard FileManager.default.fileExists(atPath: file.path) else {
        return nil
    }
    let owner: String
    do {
        owner = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        throw StorageError.readFailed(path: file.path, reason: error.localizedDescription)
    }
    guard isValidAccountDataKey(key: owner) else {
        throw StorageError.invalidAccountKey(key: owner)
    }
    return owner
}

/// Eski veriyi hesaba yazar: dosya yalnızca yoksa oluşturulur (iki süreç aynı anda sahiplenemez).
private func writeLegacyClaim(dataRoot: URL, accountKey: String) throws {
    let file: URL = AppPaths.legacyClaimFile(dataRoot: dataRoot)
    do {
        try FileManager.default.createDirectory(at: AppPaths.accountsDirectory(dataRoot: dataRoot), withIntermediateDirectories: true)
        try Data(accountKey.utf8).write(to: file, options: .withoutOverwriting)
    } catch {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
}

/// Eski verinin taşınmasının sonucu.
public struct LegacyMigrationResult: Equatable, Sendable {
    public let claim: LegacyDataClaim
    public let moves: [DataMove]
    /// Hedefte aynı adlı öğe olduğu için taşınmayan, eski yerinde bırakılan öğeler.
    public let skipped: [DataMove]
}

/// Güncellemeden önceki (hesapsız) veriyi hesaba taşır. Kimse sahiplenmediyse bu hesap sahiplenir (kayıt taşımadan önce
/// yazılır: taşıma yarıda kalsa da veri bu hesabındır, ikinci hesap boş başlar); zaten bu hesabınsa yerinde kalanlar
/// taşınır; başka hesabınsa hiçbir şeye dokunulmaz. Bekleyen kayıtlar `recordOwnerKeys`'teki sahiplerine gider (bkz.
/// `legacyDataMoves`). Taşıma aynı disk içinde atomik yeniden adlandırmadır (`renamex_np`, `RENAME_EXCL`): kopyalanmaz,
/// hedefteki hiçbir şeyin üzerine yazılmaz, hiçbir şey silinmez. Hedefinde aynı adlı öğe olanlar taşınmaz, eski yerinde
/// kalır ve uyarı loglanır (`skipped`; ör. taşımadan sonra eski bir sürüm eski yere yeni dosya yazdı): tek bir öğe hesabı
/// kilitlemez. Bir taşıma başarısız olursa `legacyDataMoveFailed` (taşınmamış olanlar yerinde kalır, sonraki denemede
/// kaldığı yerden sürer).
public func migrateLegacyUserData(dataRoot: URL, accountKey: String, recordOwnerKeys: [String: String]) throws -> LegacyMigrationResult {
    guard isValidAccountDataKey(key: accountKey) else {
        throw StorageError.invalidAccountKey(key: accountKey)
    }
    for owner in Set(recordOwnerKeys.values) where !isValidAccountDataKey(key: owner) {
        throw StorageError.invalidAccountKey(key: owner)
    }
    let claim: LegacyDataClaim = legacyDataClaim(claimOwner: try readLegacyClaimOwner(dataRoot: dataRoot), accountKey: accountKey)
    switch claim {
    case .ownedByAnotherAccount:
        return LegacyMigrationResult(claim: claim, moves: [], skipped: [])
    case .claim:
        try writeLegacyClaim(dataRoot: dataRoot, accountKey: accountKey)
        accountDataLogger.info("Eski veri hesaba yazıldı")
    case .resume:
        break
    }
    let planned: [DataMove] = legacyDataMoves(
        dataRoot: dataRoot, legacy: try readLegacyUserData(dataRoot: dataRoot), claimantKey: accountKey, recordOwnerKeys: recordOwnerKeys
    )
    let skipped: [DataMove] = planned.filter { FileManager.default.fileExists(atPath: $0.destination.path) }
    let moves: [DataMove] = planned.filter { !FileManager.default.fileExists(atPath: $0.destination.path) }
    for conflict in skipped {
        accountDataLogger.warning("Eski veri öğesi taşınmadı, hedefte aynı adlı öğe var, öğe: \(conflict.source.lastPathComponent, privacy: .private)")
    }
    for (index, move) in moves.enumerated() {
        try renameExclusively(move: move, movedSoFar: index)
    }
    if !moves.isEmpty {
        accountDataLogger.info("Eski veri hesaba taşındı, öğe: \(moves.count, privacy: .public)")
    }
    return LegacyMigrationResult(claim: claim, moves: moves, skipped: skipped)
}

/// Öğeyi aynı disk içinde atomik olarak yeniden adlandırır; hedef varsa ya da başka diske düşüyorsa hata (kopyalanmaz).
private func renameExclusively(move: DataMove, movedSoFar: Int) throws {
    let parent: URL = move.destination.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    } catch {
        throw StorageError.legacyDataMoveFailed(
            source: move.source.path, destination: move.destination.path, reason: error.localizedDescription, movedSoFar: movedSoFar
        )
    }
    guard renamex_np(move.source.path, move.destination.path, UInt32(RENAME_EXCL)) == 0 else {
        let reason: String = String(cString: strerror(errno))
        throw StorageError.legacyDataMoveFailed(source: move.source.path, destination: move.destination.path, reason: reason, movedSoFar: movedSoFar)
    }
}
