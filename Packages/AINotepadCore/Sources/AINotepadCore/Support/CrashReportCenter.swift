import Foundation
import MetricKit
import Observation
import os

private let crashLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "CrashReports")

/// Bildirim şeridinde gösterilip kapatılan (ya da gönderilen) raporların kimlikleri (Mac ve iPhone'da aynı anahtar).
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
            crashLogger.error("Çökme raporu okunamadı, dosya: \(file.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            unreadable.append(file.lastPathComponent)
        }
    }
    return CrashReportLoadResult(reports: reports.sorted { $0.receivedAt > $1.receivedAt }, unreadableFiles: unreadable.sorted())
}

/// Çökme raporunun gönderim durumu.
public enum CrashReportSendState: Sendable, Equatable {
    case sending
    case sent
    /// Gönderilemedi; kullanıcıya gösterilen neden.
    case failed(message: String)
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
/// çökme varsa arayüz bir şerit gösterir; kullanıcı "Gönder"e basarsa (açık onay) rapor geliştiricinin sunucusuna gider.
@MainActor
@Observable
public final class CrashReportCenter {
    /// Saklanan raporlar, yeniden eskiye.
    public private(set) var reports: [CrashReport] = []
    /// Son işlemin okuma, yazma ya da silme hatası ya da okunamayan dosyalar (Ayarlar'da görünür); sonraki silme ya da
    /// saklama başarılıysa kalkar.
    public private(set) var problem: String?
    /// Rapor olarak okunamayan dosyaların adları: listede görünmez, "Okunamayanları sil" ile kaldırılır.
    public private(set) var unreadableFiles: [String] = []
    /// Bu oturumda gönderilen, gönderilmekte olan ya da gönderilemeyen raporların durumu (kimliğe göre).
    public private(set) var sendStates: [String: CrashReportSendState] = [:]
    /// Şeritte gösterilip kapatılan ya da gönderilen raporlar.
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

    /// Raporu şeritten kaldırır (Kapat ya da gönderildi); rapor Ayarlar'da kalır.
    public func markSeen(id: String) {
        seenIDs.insert(id)
        storeSeen()
    }

    /// Raporun dosyasını siler.
    public func delete(id: String) {
        problem = nil
        do {
            let url: URL = try crashReportFile(id: id)
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw StorageError.deleteFailed(path: url.path, reason: error.localizedDescription)
            }
            seenIDs.remove(id)
            storeSeen()
            crashLogger.info("Çökme raporu silindi, kimlik: \(id, privacy: .public)")
        } catch {
            crashLogger.error("Çökme raporu silinemedi, kimlik: \(id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            problem = userFacingMessage(error: error)
        }
        reload()
    }

    /// Raporu kullanıcının açık isteğiyle gönderir: saklanan MetricKit JSON'u `kind: crash` olarak `destination`'ın
    /// verdiği sunucuya gider. Başarıda rapor görüldü sayılır (şeritten kalkar); hata `sendStates`'te görünür.
    public func send(report: CrashReport, destination: @MainActor () async throws -> ReportDestination) async {
        guard sendStates[report.id] != .sending else {
            return
        }
        sendStates[report.id] = .sending
        do {
            let url: URL = try crashReportFile(id: report.id)
            let payload: Data
            do {
                payload = try Data(contentsOf: url)
            } catch {
                throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
            }
            let request: ReportRequest = try crashReportRequest(payload: payload, diagnostic: report.primaryDiagnostic)
            try await submitReport(report: request, destination: try await destination())
            sendStates[report.id] = .sent
            markSeen(id: report.id)
            crashLogger.info("Çökme raporu gönderildi, kimlik: \(report.id, privacy: .public)")
        } catch {
            crashLogger.error("Çökme raporu gönderilemedi, kimlik: \(report.id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            sendStates[report.id] = .failed(message: userFacingMessage(error: error))
        }
    }

    private func crashReportFile(id: String) throws -> URL {
        try AppPaths.crashReportsDirectory().appending(path: "\(id).json", directoryHint: .notDirectory)
    }

    /// Rapor olarak okunamayan dosyaları siler (listede silinecek satırları yok); kullanıcının açık isteğiyle.
    public func deleteUnreadable() {
        problem = nil
        do {
            let directory: URL = try AppPaths.crashReportsDirectory()
            for name in unreadableFiles {
                let url: URL = directory.appending(path: name, directoryHint: .notDirectory)
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    throw StorageError.deleteFailed(path: url.path, reason: error.localizedDescription)
                }
                crashLogger.info("Okunamayan çökme raporu silindi, dosya: \(name, privacy: .public)")
            }
        } catch {
            crashLogger.error("Okunamayan çökme raporu silinemedi, hata: \(String(describing: error), privacy: .private)")
            problem = userFacingMessage(error: error)
        }
        reload()
    }

    private func receive(payloads: [Data], receivedAt: Date) {
        problem = nil
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
            crashLogger.error("Teşhis paketi saklanamadı, hata: \(String(describing: error), privacy: .private)")
            problem = userFacingMessage(error: error)
        }
        reload()
    }

    private func reload() {
        do {
            let result: CrashReportLoadResult = try loadCrashReports(directory: try AppPaths.crashReportsDirectory())
            reports = result.reports
            unreadableFiles = result.unreadableFiles
            // İşlemin kendi hatası önce gelir; yoksa okunamayan dosyalar söylenir.
            if problem == nil, !result.unreadableFiles.isEmpty {
                problem = String(localized: "Okunamayan çökme raporu: \(result.unreadableFiles.joined(separator: ", "))")
            }
        } catch {
            crashLogger.error("Çökme raporları okunamadı, hata: \(String(describing: error), privacy: .private)")
            problem = userFacingMessage(error: error)
        }
    }

    private func storeSeen() {
        UserDefaults.standard.set(seenIDs.sorted(), forKey: crashReportsSeenKey)
    }
}
