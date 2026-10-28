import Foundation
import Synchronization

/// Çubukların kayma aralığına göre seviyenin ana aktöre geçme aralığı: aralığın dörtte biri. Gösterge çubuğu kendi
/// aralığında kaydırır; seviye aynı aralıkla gelseydi iki saat birbirinin altına düşünce (ör. 98 ms) değer atlanır,
/// çubuk 200 ms sonra kayar ve ölçer takılarak akardı. Dörtte birlik aralıkla kayma en çok çeyrek aralık sapar.
/// Saf fonksiyondur.
public func levelThrottleInterval(barInterval: Double) -> Double {
    barInterval / 4
}

/// Ses seviyelerinin en yükseğini biriktirip en fazla `intervalSec`'te bir veren kutu. Thread-safe.
///
/// Seviye her ses parçasında (iki akışta saniyede ~90 kez) gelir; her biri için ana aktöre ayrı görev açmak yerine
/// en yüksek değer burada tutulur ve ana aktöre en fazla `intervalSec`'te bir geçilir.
public final class LevelThrottle: Sendable {
    private struct State {
        var peak: Float
        var lastEmit: ContinuousClock.Instant?
    }

    private let intervalSec: Double
    private let state: Mutex<State> = Mutex(State(peak: 0, lastEmit: nil))

    public init(intervalSec: Double) {
        self.intervalSec = intervalSec
    }

    /// Seviyeyi ekler; süre dolduysa biriken en yüksek seviyeyi döndürür (ve sıfırlar), dolmadıysa nil.
    public func add(level: Float) -> Float? {
        state.withLock { (current: inout State) -> Float? in
            current.peak = max(current.peak, level)
            let now: ContinuousClock.Instant = .now
            guard shouldLog(last: current.lastEmit, now: now, intervalSec: intervalSec) else {
                return nil
            }
            let peak: Float = current.peak
            current.peak = 0
            current.lastEmit = now
            return peak
        }
    }
}
