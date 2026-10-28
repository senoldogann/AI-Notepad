import Foundation
import Testing
@testable import AINotepadUI

@MainActor
@Suite struct LevelMeterCadenceTests {
    // Her adımda tam bir kayma: aralıkta gelen seviyelerin en yükseği yeni çubuk olur; seviye gelmeyen adımda (yalnız
    // mikrofonun ~100 ms'lik parçaları ya da duraklatma) son çubuk yarıya inerek söner, adım atlanmaz.
    @Test func eachStepShiftsOneBar() {
        let levels: AudioLevels = AudioLevels(count: 4, interval: 0.1)
        levels.start()
        levels.record(level: 0.2)
        levels.record(level: 0.8)
        levels.advance()
        #expect(levels.values == [0, 0, 0, 0.8])
        levels.advance()
        #expect(levels.values == [0, 0, 0.8, 0.4])
        levels.record(level: 0.6)
        levels.advance()
        #expect(levels.values == [0, 0.8, 0.4, 0.6])
        levels.stop()
        levels.record(level: 0.9)
        levels.advance()
        #expect(levels.values == [0, 0, 0, 0])
    }

    // Gerçek saat: kayma sayısı geçen süreyle orantılı (100 ms'de bir). Değer her adımda yarılanır, sıfıra inmez: sıfır
    // olmayan çubuk sayısı kayma sayısıdır. Beklenen sayı ölçülen süreden hesaplanır: yüklü makinede (CI) uyku uzasa da
    // test kırılmaz, saat durursa ya da fazla kayarsa yakalanır.
    @Test func clockAdvancesSteadily() async throws {
        let levels: AudioLevels = AudioLevels(count: 60, interval: 0.1)
        let clock: ContinuousClock = ContinuousClock()
        let started: ContinuousClock.Instant = clock.now
        levels.start()
        levels.record(level: 1)
        try await Task.sleep(for: .milliseconds(1_050))
        let shifts: Int = levels.values.filter { $0 > 0 }.count
        let duration: Duration = clock.now - started
        let elapsed: Double = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        levels.stop()
        let expected: Double = elapsed / 0.1
        #expect(Double(shifts) >= expected * 0.5 && Double(shifts) <= expected + 1, "kayma: \(shifts), süre: \(elapsed) sn")
    }
}
