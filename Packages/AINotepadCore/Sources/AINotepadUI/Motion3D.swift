import SwiftUI

/// Fare imlecine göre 3D eğilme (paralaks): imleç görünümün hangi köşesindeyse o köşe hafifçe öne gelir, ayrılınca yay
/// ile düzlüğe döner. Sistemde "Hareketi azalt" açıksa eğilme olmaz.
private struct Tilt3D: ViewModifier {
    let maxAngle: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @State private var tilt: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(reduceMotion ? 0 : -tilt.height * maxAngle), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(reduceMotion ? 0 : tilt.width * maxAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .background {
                GeometryReader { (geometry: GeometryProxy) in
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { (phase: HoverPhase) in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                tilt = tiltAmount(phase: phase, size: geometry.size)
                            }
                        }
                }
            }
    }
}

/// İmlecin görünüm merkezine göre konumu, her eksende -1…1; imleç dışarıdaysa sıfır. Saf fonksiyondur.
func tiltAmount(phase: HoverPhase, size: CGSize) -> CGSize {
    guard case .active(let location) = phase, size.width > 0, size.height > 0 else {
        return .zero
    }
    let x: Double = min(max((location.x / size.width) * 2 - 1, -1), 1)
    let y: Double = min(max((location.y / size.height) * 2 - 1, -1), 1)
    return CGSize(width: x, height: y)
}

public extension View {
    /// Fareye göre 3D eğilme; `maxAngle` en büyük eğim (derece).
    func tilt3D(maxAngle: Double) -> some View {
        modifier(Tilt3D(maxAngle: maxAngle))
    }
}
