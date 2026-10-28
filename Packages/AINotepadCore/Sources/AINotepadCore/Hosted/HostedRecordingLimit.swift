import Foundation

/// Süre sınırından bu kadar saniye önce kayıtta uyarı gösterilir.
public let hostedLimitWarningLeadSec: Double = 300

/// Kaydın bitmesi gereken an: sunucunun bildirdiği bitiş (`expiresAt`) ile isteğin gönderildiği andan en çok süre
/// sonrasının erkeni. İstek sunucunun başlangıcından önce gönderildiği için yerel hesap hiçbir zaman geç kalmaz; saat
/// farkı varsa kayıt sunucudan önce biter, sonra değil. Saf fonksiyondur.
public func hostedRecordingDeadline(requestedAt: Date, maxDurationMinutes: Int, serverEndsAt: Date) -> Date {
    min(requestedAt.addingTimeInterval(Double(maxDurationMinutes) * 60), serverEndsAt)
}

/// Kaydın süre sınırına göre durumu.
public enum HostedRecordingLimitState: Sendable, Equatable {
    /// Sınır uzakta.
    case running
    /// Sınıra `warningLeadSec`'ten az kaldı: kayıt sürer, uyarı görünür.
    case warning
    /// Sınıra ulaşıldı: kayıt bitirilir.
    case reached
}

/// Şimdiki anın sınıra göre durumu. Saf fonksiyondur.
public func hostedRecordingLimitState(now: Date, deadline: Date, warningLeadSec: Double) -> HostedRecordingLimitState {
    let remaining: Double = deadline.timeIntervalSince(now)
    if remaining <= 0 {
        return .reached
    }
    return remaining <= warningLeadSec ? .warning : .running
}
