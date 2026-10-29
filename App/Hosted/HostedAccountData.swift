import AINotepadCore
import Foundation
import os

// Abonelik sürümünde yerel veri hesap başınadır: her hesap yalnızca kendi toplantılarını, Sor geçmişini, kişilerini, ses
// izlerini, klasörlerini, Sor tariflerini, notların gittiği yerleri (kanallar, Notion, webhook, Apple Notlar, Markdown
// klasörü) ve görev araçlarını görür (bkz. AINotepadCore `AccountData.swift`). Bir süreç tek bir hesabın verisini yükler;
// başka hesapla giriş yapılınca uygulama (kayıt ve işleme yokken) yeniden başlar.

private let accountDataLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedAccountData")

/// Bu süreçte yüklü hesap verisinin durumu.
enum HostedDataState: Equatable {
    /// Hesap verisi yüklenmedi (açılışta oturum yoktu; giriş yapılınca yüklenir).
    case notLoaded
    /// Bu hesabın verisi yüklü.
    case loaded(accountKey: String)
    /// Hesabın verisi hazırlanamadı (ör. önceki toplantılar hesaba taşınamadı); veri yerinde kalır, neden gösterilir.
    case failed(message: String)
    /// Başka bir hesapla giriş yapıldı: kayıt ve işleme bitince uygulama yeniden başlar ve o hesabın verisini yükler.
    case relaunchRequired(accountKey: String)
}

/// Eski (hesapsız) düzende standart ayarlarda duran kullanıcı içeriği: hesaba taşınır (bkz. `userContentDefaults`).
/// Markdown klasörü ve kendiliğinden gönderim ayarları da hesabındır: B hesabının notları A'nın seçtiği klasöre ya da
/// Apple Notlar'a gitmesin.
private let legacyUserContentDefaultsKeys: [String] = [
    SettingsKey.folders, userRecipesKey, SettingsKey.markdownFolder, SettingsKey.markdownAutoExport, SettingsKey.appleNotesAutoSend,
]

/// Eski düzende uygulamanın Anahtar Zinciri servisinde duran kullanıcı bağlantıları (not hedefleri, görev araçları):
/// hesabın servisine taşınır (bkz. `userContentKeychainService`).
private let legacyUserContentSecretAccounts: [SecretAccount] = [.destinations, .taskTrackers]

/// Hesabın kendi ayar alanı (klasörler, Sor tarifleri, dışa aktarma ayarları, açık sunucu oturumları):
/// `<paket kimliği>.account.<anahtar>`.
func hostedAccountDefaults(accountKey: String) throws -> UserDefaults {
    guard isValidAccountDataKey(key: accountKey) else {
        throw StorageError.invalidAccountKey(key: accountKey)
    }
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
        throw StorageError.writeFailed(path: Bundle.main.bundlePath, reason: "paket kimliği yok, hesabın ayar alanı adlandırılamadı")
    }
    let suite: String = "\(bundleIdentifier).account.\(accountKey)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw StorageError.writeFailed(path: suite, reason: "hesabın ayar alanı açılamadı")
    }
    return defaults
}

/// Yüklü hesabın ayar alanı; hesap yüklenmediyse `accountNotSelected`.
func hostedActiveAccountDefaults() throws -> UserDefaults {
    guard let key = AppPaths.activeAccountKey() else {
        throw StorageError.accountNotSelected
    }
    return try hostedAccountDefaults(accountKey: key)
}

/// Hesabın kendi Anahtar Zinciri servisi (not hedefleri, görev araçları): `<uygulamanın servisi>.account.<anahtar>`.
/// Oturum jetonu uygulamanın servisinde kalır (hesaptan önce okunur).
func hostedAccountKeychainService(accountKey: String) throws -> String {
    guard isValidAccountDataKey(key: accountKey) else {
        throw StorageError.invalidAccountKey(key: accountKey)
    }
    return "\(appKeychainService).account.\(accountKey)"
}

/// Yüklü hesabın Anahtar Zinciri servisi; hesap yüklenmediyse `accountNotSelected`.
func hostedActiveAccountKeychainService() throws -> String {
    guard let key = AppPaths.activeAccountKey() else {
        throw StorageError.accountNotSelected
    }
    return try hostedAccountKeychainService(accountKey: key)
}

/// Giriş yapan hesabın verisini bu süreç için hazırlar ve yükler: önceki (hesapsız) veri kimse sahiplenmediyse ya da bu
/// hesabınsa hesaba taşınır (bekleyen kayıtlar sahiplerine; bkz. `migrateLegacyUserData`), standart ayarlardaki
/// klasörler, Sor tarifleri ve dışa aktarma ayarları hesabın ayar alanına, Anahtar Zinciri'ndeki not hedefleri ve görev
/// araçları hesabın servisine geçer, sonra hesap yüklenir. Taşıma başarısız olursa hata fırlar, hesap yüklenmez ve veri
/// yerinde kalır (hiçbir şey kaybolmaz; sonraki denemede kaldığı yerden sürer).
func prepareHostedAccountData(userId: String) throws -> String {
    let key: String = accountDataKey(userId: userId)
    let ownerKeys: [String: String] = loadHostedRecordOwners().mapValues { (owner: String) -> String in accountDataKey(userId: owner) }
    let result: LegacyMigrationResult = try migrateLegacyUserData(dataRoot: try AppPaths.applicationSupport(), accountKey: key, recordOwnerKeys: ownerKeys)
    switch result.claim {
    case .claim, .resume:
        moveLegacyUserContentDefaults(destination: try hostedAccountDefaults(accountKey: key))
        try moveLegacyUserContentSecrets(destinationService: try hostedAccountKeychainService(accountKey: key))
    case .ownedByAnotherAccount:
        break
    }
    try AppPaths.activateAccount(key: key)
    accountDataLogger.info("Hesap verisi yüklendi, eski veri: \(String(describing: result.claim), privacy: .public), taşınan: \(result.moves.count, privacy: .public)")
    return key
}

/// Standart ayarlardaki kullanıcı içeriğini (klasörler, Sor tarifleri) hesabın ayar alanına taşır. Hesapta o anahtar
/// zaten varsa hiçbir şeyin üzerine yazılmaz: standart ayardaki değer yerinde kalır (silinmez; abonelik sürümü onu artık
/// okumaz) ve uyarı loglanır.
private func moveLegacyUserContentDefaults(destination: UserDefaults) {
    for key in legacyUserContentDefaultsKeys {
        guard let value = UserDefaults.standard.object(forKey: key) else {
            continue
        }
        guard destination.object(forKey: key) == nil else {
            accountDataLogger.warning("Ayar hesapta zaten var, eski değer yerinde bırakıldı, anahtar: \(key, privacy: .public)")
            continue
        }
        destination.set(value, forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        accountDataLogger.info("Ayar hesaba taşındı, anahtar: \(key, privacy: .public)")
    }
}

/// Uygulamanın Anahtar Zinciri servisindeki kullanıcı bağlantılarını (not hedefleri, görev araçları) hesabın servisine
/// taşır: önce hesaba yazılır, sonra eskisi silinir (yarıda kalırsa sonraki denemede sürer). Hesapta o öğe zaten varsa
/// hiçbir şeyin üzerine yazılmaz: eski öğe yerinde kalır (abonelik sürümü onu artık okumaz) ve uyarı loglanır. Anahtar
/// Zinciri hatası fırlatılır.
private func moveLegacyUserContentSecrets(destinationService: String) throws {
    for account in legacyUserContentSecretAccounts {
        let value: String
        do {
            value = try readSecret(service: appKeychainService, account: account)
        } catch KeychainError.notFound {
            continue
        }
        guard try !localSecretExists(service: destinationService, account: account) else {
            accountDataLogger.warning("Bağlantılar hesapta zaten var, eski öğe yerinde bırakıldı, hesap: \(account.rawValue, privacy: .public)")
            continue
        }
        try saveSecret(service: destinationService, account: account, value: value)
        try deleteSecret(service: appKeychainService, account: account)
        accountDataLogger.info("Bağlantılar hesaba taşındı, öğe: \(account.rawValue, privacy: .public)")
    }
}

// MARK: MCP

/// MCP sunucusunun okuduğu arşiv: sunucu açıldığında giriş yapmış hesabın toplantı klasörü (klasör oluşturulmaz,
/// eski veri taşınmaz; bunları uygulama yapar).
struct HostedMCPArchive {
    let accountKey: String
    let sessionsDirectory: URL
}

/// Kayıtlı oturumun hesabının arşivi; oturum yoksa nil.
func hostedMCPArchive(bundle: Bundle) throws -> HostedMCPArchive? {
    guard let userId = try hostedStoredUserID(bundle: bundle) else {
        return nil
    }
    let key: String = accountDataKey(userId: userId)
    return HostedMCPArchive(accountKey: key, sessionsDirectory: AppPaths.accountSessionsDirectory(dataRoot: try AppPaths.applicationSupport(), accountKey: key))
}

/// MCP araç çağrısının reddi (her çağrıda oturum yeniden okunur): çıkış yapıldıysa, başka bir hesapla giriş yapıldıysa ya
/// da hesabın arşivi bu Mac'te henüz hazır değilse neden; okunabiliyorsa nil.
func hostedMCPAccessDenial(archive: HostedMCPArchive, bundle: Bundle) -> String? {
    let currentKey: String?
    do {
        currentKey = try hostedStoredUserID(bundle: bundle).map { (userId: String) -> String in accountDataKey(userId: userId) }
    } catch {
        return userFacingMessage(error: error)
    }
    let exists: Bool = FileManager.default.fileExists(atPath: archive.sessionsDirectory.path)
    switch accountArchiveAccess(startedKey: archive.accountKey, currentKey: currentKey, archiveExists: exists) {
    case .allowed:
        return nil
    case .signedOut:
        return String(localized: "Önce uygulamayı açıp giriş yap.")
    case .accountChanged:
        return String(localized: "Uygulamada başka bir hesapla giriş yapıldı. O hesabın toplantıları için MCP istemcisini yeniden başlat.")
    case .notPrepared:
        return String(localized: "Bu hesabın toplantıları bu Mac'te henüz yok. Uygulamayı bir kez açıp bu hesapla giriş yap.")
    }
}
