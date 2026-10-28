import CryptoKit
import Foundation
import Security

/// Abonelik uygulamasının özel adres şeması: e-posta giriş bağlantısı uygulamayı
/// `com.senoldogan.ainotepad.hosted://auth/email?token=…` ile açar.
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

/// E-posta giriş bağlantısından tek kullanımlık jeton: `<şema>://auth/email?token=…`. Şema, yol ya da jeton
/// beklenen biçimde değilse `invalidSignInLink`. Jeton sunucunun ürettiği base64url metnidir (32 bayt → 43 karakter).
/// Saf fonksiyondur.
public func hostedEmailLinkToken(url: URL) throws -> String {
    guard url.scheme?.lowercased() == hostedURLScheme,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.host == "auth", components.path == "/email",
          let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
          (32...128).contains(token.count),
          token.allSatisfy({ (character: Character) -> Bool in character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_") }) else {
        throw HostedClientError.invalidSignInLink
    }
    return token
}

/// Apple ile giriş için rastgele ham nonce (32 bayt, onaltılık). Ham değer sunucuya, SHA-256'sı Apple'a verilir.
public func makeHostedNonce() throws -> String {
    var bytes: [UInt8] = [UInt8](repeating: 0, count: 32)
    let status: OSStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
        throw KeychainError.unexpectedStatus(operation: "SecRandomCopyBytes(nonce)", status: status)
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// Apple'a verilen nonce: ham nonce'un SHA-256'sı, küçük harf onaltılık (sunucu `sha256hex(nonce)` ile karşılaştırır).
/// Saf fonksiyondur.
public func hostedNonceHash(nonce: String) -> String {
    SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
}
