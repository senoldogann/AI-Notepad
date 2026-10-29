import Foundation
import OSLog

// Uygulama içi tanılama (Ayarlar › Tanılama): sürüm, sistem, hesap, sunucuya erişim, izinler, model, güncelleme ve
// son hatalar. Arayüz ve kopyalanan metin aynı bölümlerden üretilir. Ses, metin, not, anahtar, jeton ve e-posta
// girmez; son hatalar uygulamanın kendi loglarından (yalnızca bu süreç, bellekte) okunur, yollar ve kullanıcı adları
// silinir.

/// Tanılamanın bir satırı: etiket ve değer.
public struct DiagnosticsItem: Sendable, Equatable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Tanılamanın başlıklı bölümü.
public struct DiagnosticsSection: Sendable, Equatable {
    public let title: String
    public let items: [DiagnosticsItem]

    public init(title: String, items: [DiagnosticsItem]) {
        self.title = title
        self.items = items
    }
}

/// Uygulamanın son hatalarından biri: zaman, kod (log kategorisi ve düzeyi) ve kısa, temizlenmiş mesaj.
public struct DiagnosticErrorEntry: Sendable, Equatable {
    public let date: Date
    public let code: String
    public let message: String

    public init(date: Date, code: String, message: String) {
        self.date = date
        self.code = code
        self.message = message
    }
}

/// Tanılamada tutulan en çok hata.
public let diagnosticErrorCapacity: Int = 50

/// Hata mesajının en uzun hali (karakter).
public let diagnosticMessageMaxLength: Int = 200

/// Sunucuya erişim denetiminin sonucu.
public enum APIHealth: Sendable, Equatable {
    /// `GET /v1/health` 2xx döndü.
    case reachable(latencyMs: Int)
    /// Sunucu yanıt verdi ama 2xx değil.
    case unhealthy(status: Int, latencyMs: Int)
    /// Sunucuya ulaşılamadı (ağ, DNS, zaman aşımı); neden URLError kodudur.
    case unreachable(reason: String)
}

/// Metinden kişisel ve gizli parçaları siler: dosya yolları, e-posta adresleri, bearer ve JWT biçimli jetonlar ve
/// verilen kullanıcı adları (3 karakterden kısa adlar metni bozmasın diye atlanır); sonra `diagnosticMessageMaxLength`
/// karaktere kısaltır. Saf fonksiyondur.
public func redactedDiagnosticText(text: String, userNames: [String]) -> String {
    var result: String = text
    result = result.replacing(/(?:file:\/\/)?(?:\/Users|\/private|\/var|\/Volumes|\/tmp|\/Library|~)\/\S*/, with: "‹yol›")
    result = result.replacing(/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/, with: "‹e-posta›")
    result = result.replacing(/(?i:bearer)\s+\S+/, with: "Bearer ‹jeton›")
    result = result.replacing(/eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+/, with: "‹jeton›")
    for name in userNames where name.count >= 3 {
        result = result.replacingOccurrences(of: name, with: "‹kullanıcı›", options: .caseInsensitive)
    }
    let trimmed: String = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > diagnosticMessageMaxLength ? String(trimmed.prefix(diagnosticMessageMaxLength - 1)) + "…" : trimmed
}

/// Hataları zamana göre sıralar ve en yeni `capacity` tanesini (eskiden yeniye) bırakır. Saf fonksiyondur.
public func recentDiagnosticErrors(entries: [DiagnosticErrorEntry], capacity: Int) -> [DiagnosticErrorEntry] {
    Array(entries.sorted { $0.date < $1.date }.suffix(capacity))
}

/// Bu sürecin `subsystem` loglarından son hata ve arıza kayıtları (en çok `capacity`, eskiden yeniye). Kod log
/// kategorisi ve düzeyidir; mesaj `redactedDiagnosticText` ile temizlenir. Loglarda `privacy: .private` değerler zaten
/// `<private>` olarak okunur. Kayıtlar bellekte kalır, hiçbir yere yazılmaz. Log deposu açılamazsa hata fırlar.
public func loadRecentAppErrors(subsystem: String, capacity: Int, userNames: [String]) throws -> [DiagnosticErrorEntry] {
    let store: OSLogStore = try OSLogStore(scope: .currentProcessIdentifier)
    let entries: AnySequence<OSLogEntry> = try store.getEntries(
        with: [.reverse], at: store.position(date: Date()), matching: NSPredicate(format: "subsystem == %@", subsystem)
    )
    var found: [DiagnosticErrorEntry] = []
    for entry in entries {
        guard let log = entry as? OSLogEntryLog, log.level == .error || log.level == .fault else {
            continue
        }
        let level: String = log.level == .fault ? "fault" : "error"
        found.append(DiagnosticErrorEntry(
            date: log.date, code: "\(log.category).\(level)", message: redactedDiagnosticText(text: log.composedMessage, userNames: userNames)
        ))
        if found.count >= capacity {
            break
        }
    }
    return recentDiagnosticErrors(entries: found, capacity: capacity)
}

/// Sunucunun `GET /v1/health` ucunu bir kez dener ve gecikmeyi ölçer (gecikme ölçümü olduğu için yeniden denenmez).
/// Ağ hatası `unreachable` olur; URLError dışı hata fırlar.
public func checkAPIHealth(baseURL: URL, timeoutSec: Double) async throws -> APIHealth {
    var request: URLRequest = URLRequest(url: baseURL.appending(path: "v1/health"))
    request.httpMethod = "GET"
    request.timeoutInterval = timeoutSec
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let clock: ContinuousClock = ContinuousClock()
    let started: ContinuousClock.Instant = clock.now
    let response: URLResponse
    do {
        (_, response) = try await URLSession.shared.data(for: request)
    } catch let error as URLError {
        return .unreachable(reason: "URLError \(error.code.rawValue)")
    }
    let elapsed: Duration = clock.now - started
    let latencyMs: Int = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
    return (200..<300).contains(status) ? .reachable(latencyMs: latencyMs) : .unhealthy(status: status, latencyMs: latencyMs)
}

/// Bu Mac'in model tanımı (ör. "Mac15,6"; seri numarası ya da donanım kimliği değildir). Okunamazsa `POSIXError`.
public func macModelIdentifier() throws -> String {
    var size: Int = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
    var buffer: [CChar] = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Tanılamanın düz metni (panoya ve geri bildirime): başlık, oluşturulma zamanı ve bölümler. Saf fonksiyondur.
public func diagnosticsText(sections: [DiagnosticsSection], generatedAt: Date) -> String {
    let header: String = "Diagnostics · \(generatedAt.formatted(.iso8601))"
    let body: [String] = sections.map { (section: DiagnosticsSection) -> String in
        ([section.title] + section.items.map { "- \($0.label): \($0.value)" }).joined(separator: "\n")
    }
    return ([header] + body).joined(separator: "\n\n")
}

/// Geri bildirimin mesajına tanılama metnini ekler. Sunucu mesajı `limit` karakterle (UTF-16) sınırlar: tanılama sığmazsa
/// sonundan kısaltılır; kullanıcının mesajı hiç kısaltılmaz. Ayraçla birlikte en az 100 karakterlik yer yoksa
/// `messageTooLong` (kullanıcı mesajı kısaltmalı ya da tanılamayı kapatmalı). Saf fonksiyondur.
public func appendingDiagnostics(report: ReportRequest, diagnosticsText: String, limit: Int) throws -> ReportRequest {
    let message: String = report.message ?? ""
    let separator: String = "\n\n--- Diagnostics ---\n"
    let room: Int = limit - reportMessageLength(text: message) - reportMessageLength(text: separator)
    guard room >= 100 else {
        throw ReportError.messageTooLong(count: reportMessageLength(text: message + separator + diagnosticsText), limit: limit)
    }
    let fitted: String = fittingPrefix(text: diagnosticsText, maxLength: room)
    return ReportRequest(
        kind: report.kind, message: message + separator + fitted, email: report.email,
        appVersion: report.appVersion, os: report.os, payload: report.payload
    )
}

/// Metnin `maxLength` UTF-16 birimine sığan başı; kısaltıldıysa sonu "…". Saf fonksiyondur.
private func fittingPrefix(text: String, maxLength: Int) -> String {
    guard reportMessageLength(text: text) > maxLength else {
        return text
    }
    var result: String = ""
    var length: Int = 0
    for character in text {
        let size: Int = String(character).utf16.count
        guard length + size <= maxLength - 1 else {
            break
        }
        result.append(character)
        length += size
    }
    return result + "…"
}
