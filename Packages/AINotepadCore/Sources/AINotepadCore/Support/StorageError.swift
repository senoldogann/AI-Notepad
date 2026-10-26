import Foundation

/// Disk (toplantı dosyaları, klasörler, ses dosyaları) hataları.
public enum StorageError: Error, Equatable {
    case readFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case deleteFailed(path: String, reason: String)
    case directoryUnavailable(path: String, reason: String)
}
