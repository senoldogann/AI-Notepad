import Foundation

/// Canlı oturumun arayüze bildirdiği olaylar.
public enum LiveSessionEvent: Sendable, Equatable {
    /// Yeni ya da güncellenmiş bölüm (geçici veya kesin).
    case segment(LiveSegment)
    /// Otomatik modda toplantı dili belirlendi.
    case languageLocked(MeetingLanguage)
    /// Bir konuşmacının ses akışı bitti (durduruldu ya da cihaz kayboldu).
    case captureEnded(speaker: Speaker)
    /// Ses dosyasına yazılamadı; yazıya dökme devam eder.
    case recordingFailed(speaker: Speaker, message: String)
}
