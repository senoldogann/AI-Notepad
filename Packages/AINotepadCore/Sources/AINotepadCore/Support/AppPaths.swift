import Foundation

/// Uygulamanın diskte kullandığı klasörler. Her fonksiyon klasörü yoksa oluşturur.
public enum AppPaths {
    /// `~/Library/Application Support/AINotepad`
    public static func applicationSupport() throws -> URL {
        let base: URL
        do {
            base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        } catch {
            throw StorageError.directoryUnavailable(path: "~/Library/Application Support", reason: error.localizedDescription)
        }
        return try ensureDirectory(url: base.appending(path: "AINotepad", directoryHint: .isDirectory))
    }

    /// WhisperKit modellerinin indirildiği klasör.
    public static func modelsDirectory() throws -> URL {
        try ensureDirectory(url: applicationSupport().appending(path: "Models", directoryHint: .isDirectory))
    }

    /// Tüm toplantıların klasörü: `Sessions`.
    public static func sessionsDirectory() throws -> URL {
        try ensureDirectory(url: applicationSupport().appending(path: "Sessions", directoryHint: .isDirectory))
    }

    /// Sor sohbetlerinin geçmişi: `AskHistory` (her sohbet bir JSON dosyası; iCloud'a eşitlenmez).
    public static func askHistoryDirectory() throws -> URL {
        try ensureDirectory(url: applicationSupport().appending(path: "AskHistory", directoryHint: .isDirectory))
    }

    /// MetricKit çökme ve donma raporları: `CrashReports` (her teşhis paketi bir JSON dosyası; yalnız bu cihazda kalır,
    /// iCloud'a eşitlenmez ve kendiliğinden hiçbir yere gönderilmez).
    public static func crashReportsDirectory() throws -> URL {
        try ensureDirectory(url: applicationSupport().appending(path: "CrashReports", directoryHint: .isDirectory))
    }

    /// Yeni bir kayıt oturumu klasörü: `Sessions/<yyyyMMdd-HHmmss>`. Klasör yalnızca yoksa oluşturulur (aynı saniyedeki
    /// bir içe aktarmayla paylaşılmasın); o ad alınmışsa sonraki saniyeler denenir. İçe aktarma geriye gittiği için ikisi
    /// aynı adı istemez.
    public static func newSessionDirectory(startedAt: Date) throws -> URL {
        try claimSessionDirectory(startedAt: startedAt, stepSec: 1).url
    }

    /// İçe aktarma için yeni oturum klasörü: klasör yalnızca yoksa oluşturulur; o saniyede başka toplantı varsa bir önceki
    /// saniye denenir (geriye gidilir: o anda başlayacak bir kayıtla çakışmasın). Klasör ve başlangıç zamanını döndürür.
    public static func newExclusiveSessionDirectory(startedAt: Date) throws -> (url: URL, startedAt: Date) {
        try claimSessionDirectory(startedAt: startedAt, stepSec: -1)
    }

    /// `startedAt`'ten başlayıp `stepSec` adımlarla ilerleyen ilk boş oturum klasörünü oluşturur (yalnızca yoksa).
    private static func claimSessionDirectory(startedAt: Date, stepSec: Double) throws -> (url: URL, startedAt: Date) {
        let sessions: URL = try sessionsDirectory()
        for offset in 0..<600 {
            let candidate: Date = startedAt.addingTimeInterval(Double(offset) * stepSec)
            let url: URL = sessions.appending(path: sessionFolderName(startedAt: candidate), directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return (url: url, startedAt: candidate)
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                throw StorageError.directoryUnavailable(path: url.path, reason: error.localizedDescription)
            }
        }
        throw StorageError.directoryUnavailable(path: sessions.path, reason: "boş oturum klasörü adı bulunamadı")
    }

    /// Oturum klasörü adını üretir (yerel saat dilimi).
    static func sessionFolderName(startedAt: Date) -> String {
        let formatter: DateFormatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: startedAt)
    }

    /// Klasörü (ara klasörlerle birlikte) oluşturur ve aynı URL'yi döndürür.
    private static func ensureDirectory(url: URL) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw StorageError.directoryUnavailable(path: url.path, reason: error.localizedDescription)
        }
        return url
    }
}
