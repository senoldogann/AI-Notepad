import CryptoKit
import Foundation
import Security

/// Abonelik uygulamasının giriş dönüş şeması: sitedeki giriş `com.senoldogan.ainotepad.hosted://auth/<apple|google>#idToken=…`
/// adresine gider, ASWebAuthenticationSession bu şemayı yakalar (bkz. `hostedBrowserIdentity`). Şema Launch
/// Services'e kayıtlı değildir: dönüş yalnızca girişi başlatan oturuma gelir.
public let hostedURLScheme: String = "com.senoldogan.ainotepad.hosted"

/// Abonelik uygulamasının Anahtar Zinciri servis adını taşıyan Info.plist anahtarı: Release `AINotepadHosted`, Debug
/// `AINotepadHosted.debug` (bkz. project.yml `HOSTED_KEYCHAIN_SERVICE`). Geliştirici sürümünün `keychainService`'inden
/// ayrıdır; Debug derlemesi yayındaki oturuma dokunmaz.
public let hostedKeychainServiceInfoKey: String = "HostedKeychainService"

/// Paketin Info.plist'indeki Anahtar Zinciri servis adı; yoksa, boşsa ya da derleme ayarı çözülmemişse
/// `keychainServiceNotConfigured`.
public func hostedKeychainService(bundle: Bundle) throws -> String {
    guard let service = bundle.object(forInfoDictionaryKey: hostedKeychainServiceInfoKey) as? String,
          !service.trimmingCharacters(in: .whitespaces).isEmpty, !service.contains("$(") else {
        throw HostedClientError.keychainServiceNotConfigured(key: hostedKeychainServiceInfoKey)
    }
    return service
}

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
