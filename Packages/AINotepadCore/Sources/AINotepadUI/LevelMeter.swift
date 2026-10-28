import Observation
import SwiftUI

/// Kayıt sırasında ses seviyesinin son değerleri (panelde canlı ses çubukları). İki kayıt akışından ("Sen" ve
/// "Diğerleri") beslenir: bir çubuk, `interval` boyunca gelen seviyelerin en yükseğidir (akışlar sırayla düşüp
/// çubukları tarak gibi titretmesin).
@MainActor
@Observable
public final class AudioLevels {
    /// Soldan sağa zaman sırasıyla son `count` seviye (0...1).
    public private(set) var values: [Float]
    private let count: Int
    private let interval: TimeInterval
    @ObservationIgnored private var pending: Float = 0
    @ObservationIgnored private var lastPush: Date = .distantPast
    /// Kayıt sürüyor: durduktan sonra akışlardan geç gelen seviyeler çubuklara yazılmaz.
    @ObservationIgnored private var isActive: Bool = false

    public init(count: Int, interval: TimeInterval) {
        self.count = count
        self.interval = interval
        self.values = [Float](repeating: 0, count: count)
    }

    /// Bir akıştan gelen seviye; süre dolunca en yükseği yeni çubuk olur, en eskisi düşer.
    public func record(level: Float, at now: Date) {
        guard isActive else {
            return
        }
        pending = max(pending, level)
        guard now.timeIntervalSince(lastPush) >= interval else {
            return
        }
        values = Array((values + [pending]).suffix(count))
        pending = 0
        lastPush = now
    }

    /// Kayıt başladı: çubuklar sıfırdan dolar.
    public func start() {
        values = [Float](repeating: 0, count: count)
        pending = 0
        lastPush = .distantPast
        isActive = true
    }

    /// Kayıt bitti: çubuklar sıfırlanır, geç gelen seviyeler yok sayılır.
    public func stop() {
        values = [Float](repeating: 0, count: count)
        pending = 0
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
