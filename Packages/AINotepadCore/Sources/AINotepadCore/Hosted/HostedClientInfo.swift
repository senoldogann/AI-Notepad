import Foundation

/// Uygulamanın abonelik sunucusuna bildirdiği sürümler: her istekte `x-app-version` (ör. "0.1.10 (19)") ve
/// `x-os-version` (ör. "macOS 15.4.1") başlıkları. Sunucu sonuncuları hesabın satırına yazar (yönetim panelinde sürüm
/// benimsenmesi) ve telemetri toplamlarını uygulama sürümüyle gruplar. Hizmetin işleyişi içindir; "Anonim kullanım
/// istatistiklerini paylaş" kapalıyken de gönderilir. İçerik taşımaz.
public struct HostedClientInfo: Sendable, Equatable {
    public let appVersion: String
    public let osVersion: String

    public init(appVersion: String, osVersion: String) {
        self.appVersion = appVersion
        self.osVersion = osVersion
    }
}

/// Paket sürümlerinden istemci bilgisi: pazarlama sürümü + yapı numarası ve macOS sürümü. Biçim sunucunun kabul
/// ettiğine uymuyorsa (derleme ayarı hatası) `HostedClientError.invalidAppVersion`: geçersiz başlık her `/v1/me`'yi
/// reddettirirdi. Saf fonksiyondur.
public func hostedClientInfo(shortVersion: String, buildNumber: String, operatingSystem: OperatingSystemVersion) throws -> HostedClientInfo {
    let appVersion: String = "\(shortVersion) (\(buildNumber))"
    // `x-app-version` biçimi `server/src/clientVersions.ts` ile aynı: 2–4 bileşenli sürüm ve parantez içinde yapı numarası.
    guard appVersion.wholeMatch(of: #/[0-9]{1,4}(\.[0-9]{1,4}){1,3} \([0-9]{1,9}\)/#) != nil else {
        throw HostedClientError.invalidAppVersion(value: appVersion)
    }
    let osVersion: String = "macOS \(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)"
    return HostedClientInfo(appVersion: appVersion, osVersion: osVersion)
}

/// İsteğe sürüm başlıklarını ekler. Saf fonksiyondur.
func withHostedClientHeaders(request: URLRequest, info: HostedClientInfo) -> URLRequest {
    var updated: URLRequest = request
    updated.setValue(info.appVersion, forHTTPHeaderField: "x-app-version")
    updated.setValue(info.osVersion, forHTTPHeaderField: "x-os-version")
    return updated
}
