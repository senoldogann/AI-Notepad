import Foundation
import Security

/// API anahtarlarının Keychain'deki hesap adları.
public enum SecretAccount: String, Sendable {
    case deepgram
    case elevenlabs
}

/// Uygulamanın Keychain servis adı.
public let keychainService: String = "AINotepad"

/// Keychain erişim hataları. Anahtar değeri hiçbir zaman hataya girmez.
public enum KeychainError: Error, Equatable {
    case notFound(service: String, account: String)
    case unexpectedStatus(operation: String, status: Int32)
}

/// Kayıtlı anahtarı okur; yoksa `.notFound`.
public func readSecret(service: String, account: SecretAccount) throws -> String {
    var query: [String: Any] = baseQuery(service: service, account: account)
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
