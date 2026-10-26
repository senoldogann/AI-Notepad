import Observation
import SwiftUI

/// Kayıt sırasında ses seviyesinin son değerleri (panelde canlı ses çubukları). Kayıt akışlarından beslenir.
@MainActor
@Observable
public final class AudioLevels {
    /// En yeniden eskiye değil, soldan sağa zaman sırasıyla son `count` seviye (0...1).
    public private(set) var values: [Float]
    private let count: Int

    public init(count: Int) {
        self.count = count
        self.values = [Float](repeating: 0, count: count)
    }

    /// Yeni seviye ekler, en eskisi düşer.
    public func push(level: Float) {
        values = Array((values + [level]).suffix(count))
    }

    /// Kayıt bitti: çubuklar sıfırlanır.
    public func reset() {
        values = [Float](repeating: 0, count: count)
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
