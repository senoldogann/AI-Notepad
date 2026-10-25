import Foundation

/// Uygulamanın diskte kullandığı klasörler. Her fonksiyon klasörü yoksa oluşturur.
public enum AppPaths {
    /// `~/Library/Application Support/AINotepad`
    public static func applicationSupport() throws -> URL {
        let base: URL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try ensureDirectory(url: base.appending(path: "AINotepad", directoryHint: .isDirectory))
    }

    /// WhisperKit modellerinin indirildiği klasör.
    public static func modelsDirectory() throws -> URL {
        try ensureDirectory(url: applicationSupport().appending(path: "Models", directoryHint: .isDirectory))
    }

    /// Yeni bir kayıt oturumu klasörü: `Sessions/<yyyyMMdd-HHmmss>`.
    public static func newSessionDirectory(startedAt: Date) throws -> URL {
        let sessions: URL = try applicationSupport().appending(path: "Sessions", directoryHint: .isDirectory)
        return try ensureDirectory(url: sessions.appending(path: sessionFolderName(startedAt: startedAt), directoryHint: .isDirectory))
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
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
