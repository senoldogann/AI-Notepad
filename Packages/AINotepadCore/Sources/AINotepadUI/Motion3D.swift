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

/// Durgun süzülme: hafif yukarı-aşağı ve 3D sallanma (ana simge gibi tek bir vurgu öğesi için).
private struct Floating3D: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.phaseAnimator([false, true]) { (view: PlaceholderContentView<Content>, raised: Bool) in
                view
                    .offset(y: raised ? -3 : 3)
                    .rotation3DEffect(.degrees(raised ? 6 : -6), axis: (x: 0.3, y: 1, z: 0), perspective: 0.5)
            } animation: { (_: Bool) in
                .easeInOut(duration: 2.8)
            }
        }
    }
}

public extension View {
    /// Fareye göre 3D eğilme; `maxAngle` en büyük eğim (derece).
    func tilt3D(maxAngle: Double) -> some View {
        modifier(Tilt3D(maxAngle: maxAngle))
    }

    /// Durgun 3D süzülme.
    func floating3D() -> some View {
        modifier(Floating3D())
    }
}

/// Kart gibi dikey eksende dönerek giriş/çıkış (adımlar arasında geçiş): giren sağdan dönerek gelir, çıkan sola döner.
private struct Flip3D: ViewModifier {
    let angle: Double
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: angle > 0 ? .leading : .trailing, perspective: 0.5)
            .opacity(opacity)
    }
}

public extension AnyTransition {
    /// Adım geçişi: 3D dönüş + solma.
    static var flip3D: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Flip3D(angle: 35, opacity: 0), identity: Flip3D(angle: 0, opacity: 1)),
            removal: .modifier(active: Flip3D(angle: -35, opacity: 0), identity: Flip3D(angle: 0, opacity: 1))
        )
    }
}
