import Foundation
import MetricKit
import Observation
import os

private let crashLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "CrashReports")

/// Bildirim şeridinde gösterilip kapatılan (ya da bildirilen) raporların kimlikleri (Mac ve iPhone'da aynı anahtar).
public let crashReportsSeenKey: String = "crashReports.seen"

/// Teşhis paketini (MetricKit JSON) `CrashReports/<yyyyMMdd-HHmmss>-<rastgele>.json` olarak saklar ve kimliğini
/// döndürür. Pakette çökme ya da donma yoksa saklanmaz, nil döner. Çözülemeyen paket `StorageError.readFailed`, yazma
/// hatası `StorageError.writeFailed`.
public func saveDiagnosticPayload(payload: Data, directory: URL, receivedAt: Date) throws -> String? {
    let diagnostics: [CrashDiagnostic]
    do {
        diagnostics = try crashDiagnostics(payload: payload)
    } catch {
        throw StorageError.readFailed(path: "MXDiagnosticPayload", reason: String(describing: error))
    }
    guard !diagnostics.isEmpty else {
        return nil
    }
    let id: String = "\(AppPaths.sessionFolderName(startedAt: receivedAt))-\(UUID().uuidString.prefix(8))"
    let url: URL = directory.appending(path: "\(id).json", directoryHint: .notDirectory)
    do {
        try payload.write(to: url, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: url.path, reason: error.localizedDescription)
    }
    return id
}

/// Klasördeki raporları okur (yeniden eskiye). Çözülemeyen ya da çökme/donma içermeyen dosya `unreadableFiles`'a
/// girer, diğerlerini engellemez. Klasör okunamazsa `StorageError.readFailed`.
public func loadCrashReports(directory: URL) throws -> CrashReportLoadResult {
    let files: [URL]
    do {
        files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
    } catch {
        throw StorageError.readFailed(path: directory.path, reason: error.localizedDescription)
    }
    var reports: [CrashReport] = []
    var unreadable: [String] = []
    for file in files {
        do {
            let diagnostics: [CrashDiagnostic] = try crashDiagnostics(payload: Data(contentsOf: file))
            let receivedAt: Date? = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            guard !diagnostics.isEmpty, let receivedAt else {
                unreadable.append(file.lastPathComponent)
                continue
            }
            reports.append(CrashReport(id: file.deletingPathExtension().lastPathComponent, receivedAt: receivedAt, diagnostics: diagnostics))
        } catch {
            crashLogger.error("Çökme raporu okunamadı, dosya: \(file.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            unreadable.append(file.lastPathComponent)
        }
    }
    return CrashReportLoadResult(reports: reports.sorted { $0.receivedAt > $1.receivedAt }, unreadableFiles: unreadable.sorted())
}

/// MetricKit aboneliği: gelen teşhis paketlerini JSON olarak verir (MetricKit onları rastgele bir kuyrukta çağırır).
/// Dış sisteme (MetricKit) bağlandığı için sınıftır.
private final class DiagnosticPayloadSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    private let onPayloads: @Sendable ([Data]) -> Void

    init(onPayloads: @escaping @Sendable ([Data]) -> Void) {
        self.onPayloads = onPayloads
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        onPayloads(payloads.map { $0.jsonRepresentation() })
    }
}

/// Yerel çökme raporları (Mac ve iPhone ortak): MetricKit'in çökme ve donma teşhislerini (sistem onları genellikle
/// bir sonraki açılışta verir) Application Support'a JSON olarak saklar; hiçbir şeyi kendiliğinden göndermez. Görülmemiş
/// çökme varsa arayüz bir şerit gösterir; kullanıcı "GitHub'da bildir" ile önceden doldurulmuş konuyu açar.
@MainActor
@Observable
public final class CrashReportCenter {
    /// Saklanan raporlar, yeniden eskiye.
    public private(set) var reports: [CrashReport] = []
    /// Okuma, yazma ya da silme hatası (Ayarlar'da görünür).
    public private(set) var problem: String?
    /// Şeritte gösterilip kapatılan ya da bildirilen raporlar.
    public private(set) var seenIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: crashReportsSeenKey) ?? [])
    @ObservationIgnored private var subscriber: DiagnosticPayloadSubscriber?

    public init() {}

    /// Şeritte gösterilecek rapor: görülmemiş en yeni çökme.
    public var reportToAnnounce: CrashReport? {
        crashReportToAnnounce(reports: reports, seenIDs: seenIDs)
    }

    /// Açılışta bir kez: saklanan raporları okur ve MetricKit'e abone olur.
    public func start() {
        guard subscriber == nil else {
            return
        }
        reload()
        let subscriber: DiagnosticPayloadSubscriber = DiagnosticPayloadSubscriber { [weak self] (payloads: [Data]) -> Void in
            Task { @MainActor in
                self?.receive(payloads: payloads, receivedAt: Date())
            }
        }
        self.subscriber = subscriber
        MXMetricManager.shared.add(subscriber)
    }

    /// Raporu şeritten kaldırır (Kapat ya da bildirildi); rapor Ayarlar'da kalır.
    public func markSeen(id: String) {
        seenIDs.insert(id)
        storeSeen()
    }

    /// Raporun dosyasını siler.
    public func delete(id: String) {
        do {
            let url: URL = try AppPaths.crashReportsDirectory().appending(path: "\(id).json", directoryHint: .notDirectory)
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw StorageError.deleteFailed(path: url.path, reason: error.localizedDescription)
            }
            seenIDs.remove(id)
            storeSeen()
            crashLogger.info("Çökme raporu silindi, kimlik: \(id, privacy: .public)")
        } catch {
            crashLogger.error("Çökme raporu silinemedi, kimlik: \(id, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            problem = userFacingMessage(error: error)
        }
        reload()
    }

    /// Raporun GitHub'da önceden doldurulmuş yeni konu adresi; oluşturulamazsa nil ve neden `problem`'de.
    public func issueURL(report: CrashReport) -> URL? {
        do {
            return try crashIssueURL(diagnostic: report.primaryDiagnostic, maxLength: crashIssueURLLimit)
        } catch {
            crashLogger.error("Çökme konusu adresi oluşturulamadı, kimlik: \(report.id, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            problem = userFacingMessage(error: error)
            return nil
        }
    }

    private func receive(payloads: [Data], receivedAt: Date) {
        do {
            let directory: URL = try AppPaths.crashReportsDirectory()
            for payload in payloads {
                if let id = try saveDiagnosticPayload(payload: payload, directory: directory, receivedAt: receivedAt) {
                    crashLogger.warning("Çökme/donma raporu saklandı, kimlik: \(id, privacy: .public)")
                } else {
                    crashLogger.info("Teşhis paketinde çökme ya da donma yok; saklanmadı")
                }
            }
        } catch {
            crashLogger.error("Teşhis paketi saklanamadı, hata: \(String(describing: error), privacy: .public)")
            problem = userFacingMessage(error: error)
        }
        reload()
    }

    private func reload() {
        do {
            let result: CrashReportLoadResult = try loadCrashReports(directory: try AppPaths.crashReportsDirectory())
            reports = result.reports
            if !result.unreadableFiles.isEmpty {
                problem = String(localized: "Okunamayan çökme raporu: \(result.unreadableFiles.joined(separator: ", "))")
            }
        } catch {
            crashLogger.error("Çökme raporları okunamadı, hata: \(String(describing: error), privacy: .public)")
            problem = userFacingMessage(error: error)
        }
    }

    private func storeSeen() {
        UserDefaults.standard.set(seenIDs.sorted(), forKey: crashReportsSeenKey)
    }
}
