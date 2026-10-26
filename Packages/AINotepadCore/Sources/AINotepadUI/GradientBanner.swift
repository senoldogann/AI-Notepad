import SwiftUI

/// Vurgu renginden türeyen, yavaşça akan örgü gradyanlı ve ince kumlu dokulu banner (ana sayfanın başı). İçerik
/// ortada; "Hareketi azalt" açıksa gradyan durgun.
public struct GradientBanner<Content: View>: View {
    let accent: Color
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    public init(accent: Color, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    public var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 24, style: .continuous)
        content
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .background {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { (context: TimelineViewDefaultContext) in
                    MeshGradient(
                        width: 3, height: 3,
                        points: meshPoints(time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate),
                        colors: meshColors(accent: accent)
                    )
                }
                .overlay { GrainOverlay() }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.10)))
            .environment(\.colorScheme, .dark)
    }
}

/// Örgü noktaları: köşeler sabit, iç noktalar yavaşça dolaşır (akış hissi). Saf fonksiyondur.
func meshPoints(time: Double) -> [SIMD2<Float>] {
    let drift: (Double, Double) -> Float = { (speed: Double, phase: Double) -> Float in Float(sin(time * speed + phase) * 0.12) }
    return [
        SIMD2(0, 0), SIMD2(0.5 + drift(0.31, 0), 0), SIMD2(1, 0),
        SIMD2(0, 0.5 + drift(0.27, 1)), SIMD2(0.5 + drift(0.23, 2), 0.5 + drift(0.19, 3)), SIMD2(1, 0.5 + drift(0.29, 4)),
        SIMD2(0, 1), SIMD2(0.5 + drift(0.21, 5), 1), SIMD2(1, 1),
    ]
}

/// Vurgu renginden koyu-parlak bir palet: kenarlar gece karanlığı, ortada vurgu ve açık tonu. Saf fonksiyondur.
func meshColors(accent: Color) -> [Color] {
    let night: Color = Color(red: 0.04, green: 0.05, blue: 0.10)
    let deep: Color = accent.mix(with: night, by: 0.65)
    let glow: Color = accent.mix(with: .white, by: 0.35)
    return [
        night, deep, accent,
        deep, glow, deep,
        accent, deep, night,
    ]
}

/// İnce kumlu doku: sabit tohumlu sözde rastgele noktalar (her çizimde aynı desen; titreşmez).
private struct GrainOverlay: View {
    var body: some View {
        Canvas { (context: inout GraphicsContext, size: CGSize) in
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            let count: Int = Int(size.width * size.height / 90)
            for _ in 0..<count {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let x: CGFloat = CGFloat(seed >> 40) / CGFloat(1 << 24) * size.width
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let y: CGFloat = CGFloat(seed >> 40) / CGFloat(1 << 24) * size.height
                let light: Bool = seed & 1 == 0
                context.fill(
                    Path(CGRect(x: x, y: y, width: 1, height: 1)),
                    with: .color(light ? Color.white.opacity(0.10) : Color.black.opacity(0.18))
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// Banner üzerindeki ana düğme: beyaz kapsül, koyu yazı (ElevenLabs "Try it" gibi); el imleci, hover'da hafif parlama,
/// basılınca küçülme.
public struct BannerPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        BannerPrimaryBody(configuration: configuration)
    }
}

private struct BannerPrimaryBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled: Bool
    @State private var isHovering: Bool = false

    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.white.opacity(isHovering ? 0.88 : 1), in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: isHovering ? 10 : 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : (isHovering ? 1.03 : 1))
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { (hovering: Bool) -> Void in isHovering = hovering }
            .pointerStyle(isEnabled ? .link : nil)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == BannerPrimaryButtonStyle {
    static var bannerPrimary: BannerPrimaryButtonStyle { BannerPrimaryButtonStyle() }
}
