import CryptoKit
import Foundation
import Security

/// Abonelik uygulamasının özel adres şeması: sitedeki giriş uygulamayı
/// `com.senoldogan.ainotepad.hosted://auth/<apple|google>#idToken=…` ile açar (bkz. `hostedBrowserIdentity`).
public let hostedURLScheme: String = "com.senoldogan.ainotepad.hosted"

/// Abonelik uygulamasının Anahtar Zinciri servis adı (geliştirici sürümünün `keychainService`'inden ayrı).
public let hostedKeychainService: String = "AINotepadHosted"

/// Info.plist'teki sunucu adresini (`HOSTED_API_BASE`) çözer: http ya da https, ana bilgisayarlı, sorgusuz ve
/// parçasız olmalı; `.invalid` alan adı (yayındaki yer tutucu) ayarlanmamış sayılır. Saf fonksiyondur.
public func parseHostedBaseURL(value: String) throws -> URL {
    let trimmed: String = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
          let host = components.host, !host.isEmpty,
          components.query == nil, components.fragment == nil,
          let url = components.url else {
        throw HostedClientError.invalidBaseURL(value: trimmed)
    }
    guard !host.lowercased().hasSuffix(".invalid") else {
        throw HostedClientError.invalidBaseURL(value: trimmed)
    }
    return url
}

/// Yayın derlemesinde sunucu adresi https olmalı (jetonlar ve ses şifresiz gitmesin); değilse `insecureBaseURL`.
/// Saf fonksiyondur.
public func requireSecureHostedBaseURL(url: URL) throws {
    guard url.scheme?.lowercased() == "https" else {
        throw HostedClientError.insecureBaseURL(url: url.absoluteString)
    }
}

/// Apple ve Google ile giriş için rastgele ham nonce (32 bayt, onaltılık, CSPRNG). Ham değer sunucuya, SHA-256'sı
/// kimlik sağlayıcısına (sitedeki giriş sayfası üzerinden) verilir.
public func makeHostedNonce() throws -> String {
    var bytes: [UInt8] = [UInt8](repeating: 0, count: 32)
    let status: OSStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
        throw KeychainError.unexpectedStatus(operation: "SecRandomCopyBytes(nonce)", status: status)
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// Kimlik sağlayıcısına verilen nonce: ham nonce'un SHA-256'sı, küçük harf onaltılık (sunucu `sha256hex(nonce)` ile karşılaştırır).
/// Saf fonksiyondur.
public func hostedNonceHash(nonce: String) -> String {
    SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
}
