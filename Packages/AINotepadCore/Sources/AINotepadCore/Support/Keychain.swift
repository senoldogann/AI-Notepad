import Foundation
import Security

/// API anahtarlarının Keychain'deki hesap adları.
public enum SecretAccount: String, Sendable, CaseIterable {
    case deepgram
    case elevenlabs
    case anthropic
    /// OpenAI uyumlu LLM sağlayıcısının anahtarı (OpenAI, OpenCode Go…); Ollama'da gerekmez.
    case openai
    /// Not hazır olunca gönderilen webhook adresi (Slack, Teams, Discord, Zapier, Make, n8n); adreste gizli anahtar var.
    case webhook
    /// Hesapla kurulan kanal bağlantısı (Slack ya da Teams jetonları ve seçilen kanal; JSON, bkz. `ChannelConnection`).
    case channel
}

/// Uygulamanın Keychain servis adı.
public let keychainService: String = "AINotepad"

/// Keychain erişim hataları. Anahtar değeri hiçbir zaman hataya girmez.
public enum KeychainError: Error, Equatable {
    case notFound(service: String, account: String)
    case unexpectedStatus(operation: String, status: Int32)
}

/// Kayıtlı anahtarı okur; yoksa `.notFound`. iPhone'da önce cihazda girilen, yoksa Mac'ten iCloud Anahtar Zinciri ile
/// gelen kopya okunur.
public func readSecret(service: String, account: SecretAccount) throws -> String {
    #if os(iOS)
    do {
        return try readSecret(query: baseQuery(service: service, account: account), service: service, account: account)
    } catch KeychainError.notFound {
        return try readSecret(query: syncedQuery(service: service, account: account), service: service, account: account)
    }
    #else
    return try readSecret(query: baseQuery(service: service, account: account), service: service, account: account)
    #endif
}

private func readSecret(query base: [String: Any], service: String, account: SecretAccount) throws -> String {
    var query: [String: Any] = base
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
        throw KeychainError.notFound(service: service, account: account.rawValue)
    }
    guard status == errSecSuccess, let data = result as? Data else {
        throw KeychainError.unexpectedStatus(operation: "SecItemCopyMatching", status: status)
    }
    return String(decoding: data, as: UTF8.self)
}

/// Okumayı arka planda yapar: Keychain izin penceresi açıkken (ör. `security` aracıyla eklenmiş anahtar)
/// arayüz donmasın.
public func readSecretInBackground(service: String, account: SecretAccount) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
        try readSecret(service: service, account: account)
    }.value
}

/// Kayıtlı değilse nil; diğer Keychain hataları fırlatılır (yok sayılmaz).
public func optionalSecretInBackground(service: String, account: SecretAccount) async throws -> String? {
    do {
        return try await readSecretInBackground(service: service, account: account)
    } catch KeychainError.notFound {
        return nil
    }
}

/// Anahtarı kaydeder; varsa üzerine yazar.
public func saveSecret(service: String, account: SecretAccount, value: String) throws {
    let data: Data = Data(value.utf8)
    let updateStatus: OSStatus = SecItemUpdate(
        baseQuery(service: service, account: account) as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess {
        return
    }
    guard updateStatus == errSecItemNotFound else {
        throw KeychainError.unexpectedStatus(operation: "SecItemUpdate", status: updateStatus)
    }
    var attributes: [String: Any] = baseQuery(service: service, account: account)
    attributes[kSecValueData as String] = data
    let addStatus: OSStatus = SecItemAdd(attributes as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
        throw KeychainError.unexpectedStatus(operation: "SecItemAdd", status: addStatus)
    }
}

/// Anahtarı siler; zaten yoksa hata değildir.
public func deleteSecret(service: String, account: SecretAccount) throws {
    let status: OSStatus = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainError.unexpectedStatus(operation: "SecItemDelete", status: status)
    }
}

private func baseQuery(service: String, account: SecretAccount) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account.rawValue,
    ]
}

/// iCloud Anahtar Zinciri ile eşitlenen kopya: veri koruma anahtar zinciri, uygulamanın varsayılan erişim grubu
/// (`TAKIM.com.senoldogan.AINotepad`; Mac ve iPhone uygulamasının kimliği aynı olduğu için ikisi de okur).
private func syncedQuery(service: String, account: SecretAccount) -> [String: Any] {
    baseQuery(service: service, account: account).merging([
        kSecAttrSynchronizable as String: true,
        kSecUseDataProtectionKeychain as String: true,
    ]) { (_: Any, new: Any) -> Any in new }
}

/// Anahtarın iPhone'da da kullanılması için iCloud Anahtar Zinciri ile eşitlenen kopyasını yazar (varsa üzerine).
/// Yerel öğeye dokunmaz. Uygulama iCloud'lu profille imzalanmamışsa `unexpectedStatus` (-34018).
public func saveSyncedSecret(service: String, account: SecretAccount, value: String) throws {
    let data: Data = Data(value.utf8)
    let updateStatus: OSStatus = SecItemUpdate(syncedQuery(service: service, account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updateStatus == errSecSuccess {
        return
    }
    guard updateStatus == errSecItemNotFound else {
        throw KeychainError.unexpectedStatus(operation: "SecItemUpdate(synced)", status: updateStatus)
    }
    var attributes: [String: Any] = syncedQuery(service: service, account: account)
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let addStatus: OSStatus = SecItemAdd(attributes as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
        throw KeychainError.unexpectedStatus(operation: "SecItemAdd(synced)", status: addStatus)
    }
}

/// Eşitlenen kopyayı siler (tüm cihazlardan kalkar); zaten yoksa hata değildir.
public func deleteSyncedSecret(service: String, account: SecretAccount) throws {
    let status: OSStatus = SecItemDelete(syncedQuery(service: service, account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainError.unexpectedStatus(operation: "SecItemDelete(synced)", status: status)
    }
}

/// Bu cihazdaki (eşitlenmeyen) öğe var mı. Değeri okumaz.
public func localSecretExists(service: String, account: SecretAccount) throws -> Bool {
    try exists(query: baseQuery(service: service, account: account), operation: "SecItemCopyMatching(local)")
}

/// Anahtar değişince eşitlenen kopya da güncellenir (iPhone eskimiş anahtarla kalmasın); kopya yoksa bir şey yapmaz.
public func updateSyncedSecretIfShared(service: String, account: SecretAccount, value: String) throws {
    if try syncedSecretExists(service: service, account: account) {
        try saveSyncedSecret(service: service, account: account, value: value)
    }
}

/// Eşitlenen kopya var mı. Değeri okumaz.
public func syncedSecretExists(service: String, account: SecretAccount) throws -> Bool {
    try exists(query: syncedQuery(service: service, account: account), operation: "SecItemCopyMatching(synced)")
}

/// Anahtarın kayıtlı olup olmadığı (iPhone'da eşitlenen kopya da sayılır). Değeri okumadığı için Keychain izin
/// penceresi açmaz.
public func secretExists(service: String, account: SecretAccount) throws -> Bool {
    #if os(iOS)
    return try exists(query: baseQuery(service: service, account: account), operation: "SecItemCopyMatching(attributes)")
        || syncedSecretExists(service: service, account: account)
    #else
    return try exists(query: baseQuery(service: service, account: account), operation: "SecItemCopyMatching(attributes)")
    #endif
}

private func exists(query base: [String: Any], operation: String) throws -> Bool {
    var query: [String: Any] = base
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess: return true
    case errSecItemNotFound: return false
    default: throw KeychainError.unexpectedStatus(operation: operation, status: status)
    }
}
