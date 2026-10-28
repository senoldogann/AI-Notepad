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

    // Gerçek saat: ~1 sn'de 100 ms'lik aralıkla ~10 kayma (seviye yalnız başta gelse de). Değer her adımda yarılanır,
    // sıfıra inmez: sıfır olmayan çubuk sayısı kayma sayısıdır. Yüklü makinede sapmaya pay bırakılır.
    @Test func clockAdvancesSteadily() async throws {
        let levels: AudioLevels = AudioLevels(count: 40, interval: 0.1)
        levels.start()
        levels.record(level: 1)
        try await Task.sleep(for: .milliseconds(1_050))
        let shifts: Int = levels.values.filter { $0 > 0 }.count
        levels.stop()
        #expect((8...11).contains(shifts))
    }
}
