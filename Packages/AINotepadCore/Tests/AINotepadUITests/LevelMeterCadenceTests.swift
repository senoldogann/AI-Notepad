import AINotepadCore
import Foundation
import Testing
@testable import AINotepadUI

@MainActor
@Suite struct LevelMeterCadenceTests {
    // Seviye `levelThrottleInterval` aralığıyla (birkaç ms sapmayla) gelince çubuklar düzenli kayar: 3 sn'de 100 ms'lik
    // aralıkla ~30 kayma. Seviye çubuk aralığıyla gelseydi sapma değerleri atlatır, kayma 200 ms'ye uzar ve ölçer takılırdı.
    @Test func barsAdvanceSteadilyWithThrottledLevels() {
        let levels: AudioLevels = AudioLevels(count: 14, interval: 0.1)
        levels.start()
        let step: Double = levelThrottleInterval(barInterval: levels.interval)
        let start: Date = Date(timeIntervalSince1970: 1_000)
        var previous: [Float] = levels.values
        var pushes: Int = 0
        for index in 0..<Int(3 / step) {
            // Ana aktöre geçişin sapması: sırayla −3 ms ve +3 ms.
            let jitter: Double = index.isMultiple(of: 2) ? -0.003 : 0.003
            levels.record(level: Float(index + 1) / 1_000, at: start.addingTimeInterval(Double(index) * step + jitter))
            if levels.values != previous {
                pushes += 1
                previous = levels.values
            }
        }
        #expect(pushes >= 27)
    }
}
