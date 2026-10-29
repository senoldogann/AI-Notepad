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

    // Gerçek saat: kayma 100 ms'de bir. Değer her adımda yarılanır, sıfıra inmez: sıfır olmayan çubuk sayısı kayma
    // sayısıdır. Saat ana aktörde çalışır; paralel testler ana aktörü meşgul ettiğinde (CI'da ~2 sn) adımlar gecikir, bu
    // yüzden sabit bir bekleme yerine en az 1,05 sn geçip en az 3 kayma görülene dek (en çok 10 sn) yoklanır: alt sınır
    // oran değil "saat ilerliyor" denetimidir. Üst sınır ölçülen süreden: fazla kayma yakalanır.
    @Test func clockAdvancesSteadily() async throws {
        let levels: AudioLevels = AudioLevels(count: 60, interval: 0.1)
        let clock: ContinuousClock = ContinuousClock()
        let started: ContinuousClock.Instant = clock.now
        let deadline: ContinuousClock.Instant = started + .seconds(10)
        levels.start()
        levels.record(level: 1)
        var shifts: Int = 0
        repeat {
            try await Task.sleep(for: .milliseconds(50))
            shifts = levels.values.filter { $0 > 0 }.count
        } while (shifts < 3 || clock.now - started < .milliseconds(1_050)) && clock.now < deadline
        // Süre kayma sayısı okunduktan sonra ölçülür: üst sınır hiçbir zaman gerçek süreden dar olmaz.
        let duration: Duration = clock.now - started
        let elapsed: Double = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        levels.stop()
        let expected: Double = elapsed / 0.1
        #expect(shifts >= 3 && Double(shifts) <= expected + 1, "kayma: \(shifts), süre: \(elapsed) sn")
    }
}
