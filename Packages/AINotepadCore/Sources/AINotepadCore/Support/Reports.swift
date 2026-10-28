import Foundation
import os

private let reportsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Reports")

/// Geri bildirim ve çökme raporlarının gittiği sunucunun Info.plist anahtarı (geliştirici sürümü ve iPhone; abonelik
/// sürümü kendi `HostedAPIBase`'ini kullanır).
public let reportsAPIBaseInfoKey: String = "ReportsAPIBase"

/// Mesajın en uzun hali (sunucunun sınırı; JavaScript uzunluğu gibi UTF-16 birimiyle sayılır).
public let reportMessageLimit: Int = 5000

/// Teşhis paketinin (MetricKit JSON) en büyük hali, bayt (sunucunun sınırı).
public let reportPayloadLimitBytes: Int = 512 * 1024

/// E-posta adresinin en uzun hali (RFC 5321).
private let reportEmailLimit: Int = 254

/// Rapor isteğinin zaman aşımı.
private let reportRequestTimeoutSec: Double = 30

/// `POST /v1/reports` yolu.
private let reportsPath: String = "/v1/reports"

/// Raporun türü (sunucunun `kind` alanı).
public enum ReportKind: String, Encodable, Sendable, Equatable {
    case feedback
    case crash
}

/// Kullanıcının isteğiyle rapora eklenen tanılama bilgisi: sürüm ve sistem.
public struct ReportDiagnostics: Sendable, Equatable {
    /// Ör. "0.1.3 (4)".
    public let appVersion: String
    /// Ör. "macOS Version 26.1 (Build 25B78)".
    public let os: String

    public init(appVersion: String, os: String) {
        self.appVersion = appVersion
        self.os = os
    }
}

/// `POST /v1/reports` gövdesi; boş alanlar gönderilmez.
public struct ReportRequest: Encodable, Sendable, Equatable {
    public let kind: ReportKind
    public let message: String?
    /// Yanıt için e-posta (isteğe bağlı).
    public let email: String?
    public let appVersion: String?
    public let os: String?
    /// MetricKit teşhis paketi, JSON metni olarak (yalnızca çökme raporunda).
    public let payload: String?
}

/// Raporun gideceği sunucu ve (giriş yapılmışsa) erişim jetonu.
public struct ReportDestination: Sendable, Equatable {
    public let baseURL: URL
    /// Abonelik sürümünde giriş yapılmışsa bearer olarak eklenir; yoksa nil.
    public let accessToken: String?

    public init(baseURL: URL, accessToken: String?) {
        self.baseURL = baseURL
        self.accessToken = accessToken
    }
}

/// Rapor gönderilmeden önce yakalanan sorunlar.
public enum ReportError: Error, Sendable, Equatable {
    /// Geri bildirim mesajı boş.
    case emptyMessage
    /// Mesaj sunucunun sınırını aşıyor.
    case messageTooLong(count: Int, limit: Int)
    /// Yanıt e-postası geçerli bir adres değil.
    case invalidEmail
    /// Teşhis paketi sunucunun sınırını aşıyor.
    case payloadTooLarge(bytes: Int, limit: Int)
    /// Teşhis paketi UTF-8 metin değil.
    case payloadNotText
}

/// Sunucunun saydığı mesaj uzunluğu (UTF-16 birimi). Saf fonksiyondur.
public func reportMessageLength(text: String) -> Int {
    text.utf16.count
}

/// Basit e-posta denetimi: boşluksuz, tek `@`, iki yanı dolu, alan adında nokta var, en çok 254 karakter. Saf fonksiyondur.
public func isPlausibleEmail(text: String) -> Bool {
    let parts: [Substring] = text.split(separator: "@", omittingEmptySubsequences: false)
    guard text.count <= reportEmailLimit, parts.count == 2, !parts[0].isEmpty,
          !text.contains(where: { (character: Character) -> Bool in character.isWhitespace }) else {
        return false
    }
    let domain: Substring = parts[1]
    return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
}

/// Geri bildirim raporu: mesaj ve e-posta kırpılır; mesaj boşsa ya da sınırı aşıyorsa, e-posta yazılmış ama geçersizse
/// hata. Tanılama yalnızca verildiyse eklenir. Saf fonksiyondur.
public func feedbackReport(message: String, email: String, diagnostics: ReportDiagnostics?) throws -> ReportRequest {
    let trimmedMessage: String = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedEmail: String = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMessage.isEmpty else {
        throw ReportError.emptyMessage
    }
    let length: Int = reportMessageLength(text: trimmedMessage)
    guard length <= reportMessageLimit else {
        throw ReportError.messageTooLong(count: length, limit: reportMessageLimit)
    }
    guard trimmedEmail.isEmpty || isPlausibleEmail(text: trimmedEmail) else {
        throw ReportError.invalidEmail
    }
    return ReportRequest(
        kind: .feedback, message: trimmedMessage, email: trimmedEmail.isEmpty ? nil : trimmedEmail,
        appVersion: diagnostics?.appVersion, os: diagnostics?.os, payload: nil
    )
}

/// Çökme raporu: saklanan MetricKit JSON'u olduğu gibi, çöken sürüm ve sistemle. Paket sınırı aşıyorsa ya da metin
/// değilse hata. Saf fonksiyondur.
public func crashReportRequest(payload: Data, diagnostic: CrashDiagnostic) throws -> ReportRequest {
    guard payload.count <= reportPayloadLimitBytes else {
        throw ReportError.payloadTooLarge(bytes: payload.count, limit: reportPayloadLimitBytes)
    }
    guard let text = String(data: payload, encoding: .utf8) else {
        throw ReportError.payloadNotText
    }
    return ReportRequest(
        kind: .crash, message: nil, email: nil,
        appVersion: appVersionText(version: diagnostic.appVersion, build: diagnostic.appBuild), os: diagnostic.osVersion, payload: text
    )
}

/// Sürüm metni: "0.1.3 (4)". Saf fonksiyondur.
public func appVersionText(version: String, build: String) -> String {
    "\(version) (\(build))"
}

/// Bu uygulamanın sürümü ve sistemi (ör. "0.1.3 (4)", "macOS Version 26.1 (Build 25B78)"); geri bildirim formunda
/// gönderilecek haliyle gösterilir.
public func currentReportDiagnostics(bundle: Bundle, platformName: String) -> ReportDiagnostics {
    let version: String = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build: String = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return ReportDiagnostics(
        appVersion: appVersionText(version: version, build: build),
        os: "\(platformName) \(ProcessInfo.processInfo.operatingSystemVersionString)"
    )
}

/// Rapor sunucusunun adresi: geçerli ve https olmalı (değilse `HostedClientError`). Saf fonksiyondur.
public func reportsAPIBaseURL(value: String) throws -> URL {
    let url: URL = try parseHostedBaseURL(value: value)
    try requireSecureHostedBaseURL(url: url)
    return url
}

/// Hesapsız sürümlerin (geliştirici sürümü, iPhone) rapor hedefi: Info.plist'teki `ReportsAPIBase`, jetonsuz.
public func anonymousReportDestination(bundle: Bundle) throws -> ReportDestination {
    let value: String = bundle.object(forInfoDictionaryKey: reportsAPIBaseInfoKey) as? String ?? ""
    return ReportDestination(baseURL: try reportsAPIBaseURL(value: value), accessToken: nil)
}

/// Rapor gönderimi tekrarı zararlı sayılır (aynı rapor iki kez oluşur): yalnızca istek sunucuya hiç ulaşmadıysa
/// yeniden denenir. Hız sınırı (429) beklenmez, kullanıcıya hemen gösterilir. Saf fonksiyondur.
public func isRetryableReportRequest(failure: HostedAttemptFailure) -> Bool {
    switch failure {
    case .network(let code):
        isSafeToRetryPost(code: code)
    case .server:
        false
    }
}

/// Raporu `POST /v1/reports` ile gönderir (sunucu 202 döner); jeton varsa bearer eklenir. 2xx dışı yanıt
/// `HostedAPIError`, ağ hatası `HostedClientError.network`. İçerik loglanmaz.
public func submitReport(report: ReportRequest, destination: ReportDestination) async throws {
    let request: URLRequest = try hostedJSONRequest(
        baseURL: destination.baseURL, path: reportsPath, method: "POST", body: try JSONEncoder().encode(report),
        accessToken: destination.accessToken, timeoutSec: reportRequestTimeoutSec
    )
    let response: (data: Data, status: Int) = try await sendHostedRequest(path: reportsPath, isRetryable: isRetryableReportRequest) {
        try await URLSession.shared.data(for: request)
    }
    reportsLogger.info("Rapor gönderildi, tür: \(report.kind.rawValue, privacy: .public), durum: \(response.status, privacy: .public), hesaplı: \(destination.accessToken != nil, privacy: .public)")
}

/// Rapor hatasının kullanıcıya gösterilen metni. Saf fonksiyondur.
public func reportErrorMessage(error: ReportError) -> String {
    switch error {
    case .emptyMessage:
        String(localized: "Mesaj boş; ne olduğunu birkaç cümleyle yaz.")
    case .messageTooLong(let count, let limit):
        String(localized: "Mesaj çok uzun (\(count) / \(limit) karakter); kısaltıp yeniden gönder.")
    case .invalidEmail:
        String(localized: "E-posta adresi geçersiz; düzelt ya da boş bırak.")
    case .payloadTooLarge(let bytes, let limit):
        String(localized: "Çökme raporu gönderilemeyecek kadar büyük (\(bytes / 1024) KB, sınır \(limit / 1024) KB).")
    case .payloadNotText:
        String(localized: "Çökme raporu okunamadı (metin değil); raporu silip yenisini bekle.")
    }
}
