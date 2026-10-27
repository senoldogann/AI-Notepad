import Foundation

/// Disk (toplantı dosyaları, klasörler, ses dosyaları) hataları.
public enum StorageError: Error, Equatable {
    case readFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case deleteFailed(path: String, reason: String)
    case directoryUnavailable(path: String, reason: String)
    /// iCloud'a giriş yapılmamış ya da iCloud Drive kapalı (ya da uygulamanın iCloud yetkisi yok).
    case iCloudUnavailable
    /// Taşıma hedefinde aynı adlı klasör var (üzerine yazılmaz).
    case alreadyExists(path: String)
    case moveFailed(path: String, reason: String)
}
