import Foundation

/// Ses yakalama, dönüştürme ve kaydetme hataları.
public enum AudioCaptureError: Error, Equatable {
    case microphonePermissionDenied
    /// Mikrofon motoru (`AVAudioEngine`) başlatılamadı.
    case microphoneStartFailed(code: Int32)
    /// `start()` yakalama zaten çalışırken çağrıldı.
    case alreadyRunning(source: String)
    case converterCreationFailed(inputDescription: String)
    case conversionFailed(reason: String)
    /// Bir Core Audio çağrısı `noErr` dışında bir durum döndürdü.
    case coreAudio(operation: String, status: Int32)
    case recorderFailed(path: String, reason: String)
    /// iOS'ta çalma için ses oturumu açılamadı.
    case playbackSessionFailed(code: Int32)
}
