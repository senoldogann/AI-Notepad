import SwiftUI

/// Gradyan pano: durgun, açık tonlu film gradyanı (ElevenLabs gradyanları gibi); içerik koyu yazıyla, her temada açık
/// görünümde çizilir.
public struct GradientBanner<Content: View>: View {
    let palette: FilmPalette
    let seed: String
    let content: Content

    public init(palette: FilmPalette, seed: String, @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.seed = seed
        self.content = content()
    }

    public var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 24, style: .continuous)
        content
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .background { FilmGradient(seed: seed, palette: palette) }
            .clipShape(shape)
            .environment(\.colorScheme, .light)
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
            .appFont(size: 14, weight: .semibold)
            .foregroundStyle(Color.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.white.opacity(isHovering ? 0.88 : 1), in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: isHovering ? 10 : 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : (isHovering ? 1.03 : 1))
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { (hovering: Bool) -> Void in isHovering = hovering }
            .linkPointer(isEnabled: isEnabled)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == BannerPrimaryButtonStyle {
    static var bannerPrimary: BannerPrimaryButtonStyle { BannerPrimaryButtonStyle() }
}
