import Observation
import SwiftUI

/// Kayıt sırasında ses seviyesinin son değerleri (panelde canlı ses çubukları). İki kayıt akışından ("Sen" ve
/// "Diğerleri") beslenir. Çubuklar kendi sabit saatiyle her `interval`'da bir kayar: o aralıkta gelen seviyelerin en
/// yükseği yeni çubuk olur. Seviye geldikçe kaydırılsaydı akışın parça aralığı (ör. yalnız mikrofonda ~100 ms) çubuk
/// aralığıyla çakışınca bazı adımlar 200 ms'ye uzar, ölçer takılarak akardı.
@MainActor
@Observable
public final class AudioLevels {
    /// Soldan sağa zaman sırasıyla son `count` seviye (0...1).
    public private(set) var values: [Float]
    private let count: Int
    /// Çubukların kayma aralığı.
    public let interval: TimeInterval
    @ObservationIgnored private var pending: Float = 0
    @ObservationIgnored private var hasPending: Bool = false
    /// Kayıt sürüyor: durduktan sonra akışlardan geç gelen seviyeler çubuklara yazılmaz.
    @ObservationIgnored private var isActive: Bool = false
    /// Çubukları kaydıran saat; kayıt bitince durur (boştayken hiçbir şey çalışmaz).
    @ObservationIgnored private var clock: Task<Void, Never>?

    public init(count: Int, interval: TimeInterval) {
        self.count = count
        self.interval = interval
        self.values = [Float](repeating: 0, count: count)
    }

    /// Bir akıştan gelen seviye; sıradaki çubuk adımına dek en yükseği tutulur.
    public func record(level: Float) {
        guard isActive else {
            return
        }
        pending = max(pending, level)
        hasPending = true
    }

    /// Bir çubuk adımı: aralıkta gelen en yüksek seviye yeni çubuk olur, en eskisi düşer. Seviye gelmediyse (ör.
    /// duraklatıldı) son çubuk yarıya inerek söner; çubuklar donmaz.
    public func advance() {
        guard isActive else {
            return
        }
        let next: Float = hasPending ? pending : (values.last ?? 0) * 0.5
        values = Array((values + [next]).suffix(count))
        pending = 0
        hasPending = false
    }

    /// Kayıt başladı: çubuklar sıfırdan dolar, saat başlar.
    public func start() {
        values = [Float](repeating: 0, count: count)
        pending = 0
        hasPending = false
        isActive = true
        clock?.cancel()
        let step: Duration = .milliseconds(Int((interval * 1000).rounded()))
        clock = Task { [weak self] in
            // Mutlak zamanlı adımlar: uyanma gecikmesi birikmez, kayma aralığı sabit kalır.
            var next: ContinuousClock.Instant = .now + step
            while !Task.isCancelled {
                do {
                    try await Task.sleep(until: next, clock: .continuous)
                } catch {
                    return
                }
                self?.advance()
                next = max(next + step, .now)
            }
        }
    }

    /// Örnek çubuklar (önizleme ve ekran görüntüsü kipi): saat başlamaz, değerler olduğu gibi kalır.
    public func showSample(values sample: [Float]) {
        values = Array(([Float](repeating: 0, count: count) + sample).suffix(count))
    }

    /// Kayıt bitti: saat durur, çubuklar sıfırlanır, geç gelen seviyeler yok sayılır.
    public func stop() {
        clock?.cancel()
        clock = nil
        values = [Float](repeating: 0, count: count)
        pending = 0
        hasPending = false
        isActive = false
    }
}

/// Canlı ses çubukları: sesi duyduğunu gösterir (Otter'ın kayıt çubuğundaki gibi); sessizde alçak.
public struct LevelMeter: View {
    let levels: AudioLevels
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(levels: AudioLevels) {
        self.levels = levels
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.values.enumerated()), id: \.offset) { (item: (offset: Int, element: Float)) in
                Capsule()
                    .fill(appearance.accent.color.opacity(0.35 + Double(item.element) * 0.65))
                    .frame(width: 2.5, height: 3 + CGFloat(item.element) * 13)
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: levels.values)
        .accessibilityHidden(true)
    }
}

/// Paneldeki ses ölçerin büyük eşi (kayıt ekranının ortası): aynı canlı seviyeler, kalın yuvarlak çubuklar, ortadan
/// büyür; sessizlikte ince bir çizgi kalır.
public struct LargeLevelMeter: View {
    let levels: AudioLevels
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(levels: AudioLevels) {
        self.levels = levels
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 7) {
            ForEach(Array(levels.values.enumerated()), id: \.offset) { (item: (offset: Int, element: Float)) in
                Capsule()
                    .fill(appearance.accent.color.opacity(0.4 + Double(item.element) * 0.6))
                    .frame(width: 7, height: 8 + CGFloat(item.element) * 82)
            }
        }
        .frame(height: 90)
        .animation(.easeOut(duration: 0.12), value: levels.values)
        .accessibilityHidden(true)
    }
}
