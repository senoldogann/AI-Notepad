import Foundation
import Synchronization

/// Son yazılan logdan bu yana `intervalSec` geçtiyse (ya da hiç yazılmadıysa) yeniden yazılır. Saf fonksiyondur.
public func shouldLog(last: ContinuousClock.Instant?, now: ContinuousClock.Instant, intervalSec: Double) -> Bool {
    guard let last else {
        return true
    }
    return now - last >= .seconds(intervalSec)
}

/// Ses thread'inde her tamponda tekrarlanan hata logunu seyreltir (ör. dakikada bir). Thread-safe.
public final class LogThrottle: Sendable {
    private let intervalSec: Double
    private let lastLoggedAt: Mutex<ContinuousClock.Instant?> = Mutex(nil)

    public init(intervalSec: Double) {
        self.intervalSec = intervalSec
    }

    /// Şimdi log yazılmalı mı; yazılmalıysa zamanı kaydeder.
    public func allow() -> Bool {
        lastLoggedAt.withLock { (last: inout ContinuousClock.Instant?) -> Bool in
            let now: ContinuousClock.Instant = .now
            guard shouldLog(last: last, now: now, intervalSec: intervalSec) else {
                return false
            }
            last = now
            return true
        }
    }
}
