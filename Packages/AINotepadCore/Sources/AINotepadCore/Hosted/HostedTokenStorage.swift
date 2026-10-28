import Foundation
import Security

/// Oturum jetonlarının saklandığı yer (dış sistem bağlantısı).
public protocol HostedTokenStorage: Sendable {
    /// Kayıtlı oturum; yoksa nil.
    func load() throws -> HostedTokens?
    func save(tokens: HostedTokens) throws
    /// Oturumu siler; zaten yoksa hata değildir.
    func clear() throws
}

/// Oturum, Anahtar Zinciri'nde tek bir öğe olarak (JSON) saklanır. Servis adı abonelik uygulamasınındır; geliştirici
/// sürümünün öğelerine dokunulmaz.
public final class HostedKeychainTokenStorage: HostedTokenStorage {
    private let service: String
    private let account: String = "hosted-session"

    public init(service: String) {
        self.service = service
    }

    public func load() throws -> HostedTokens? {
        var query: [String: Any] = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(operation: "SecItemCopyMatching(hosted)", status: status)
        }
        do {
            return try JSONDecoder().decode(HostedTokens.self, from: data)
        } catch {
            // Bozuk öğe: değer (jeton) hataya yazılmaz.
            throw KeychainError.unexpectedStatus(operation: "decode(hosted)", status: errSecDecode)
        }
    }

    public func save(tokens: HostedTokens) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(tokens)
        } catch {
            throw KeychainError.unexpectedStatus(operation: "encode(hosted)", status: errSecParam)
        }
        let updateStatus: OSStatus = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(operation: "SecItemUpdate(hosted)", status: updateStatus)
        }
        var attributes: [String: Any] = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus: OSStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(operation: "SecItemAdd(hosted)", status: addStatus)
        }
    }

    public func clear() throws {
        let status: OSStatus = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(operation: "SecItemDelete(hosted)", status: status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
