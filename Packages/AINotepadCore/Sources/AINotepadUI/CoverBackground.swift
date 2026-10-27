import SwiftUI

/// Toplantı kapağı (kartlar): kimliğinden sabit renk ailesiyle durgun film gradyanı ve yazı okunsun diye altta hafif
/// kararma. Toplantı sayfasının başlığı hareketli sürümü (`LivingCoverBackground`) kullanır.
public struct CoverBackground: View {
    let seed: String

    public init(seed: String) {
        self.seed = seed
    }

    public var body: some View {
        FilmGradient(seed: seed, palette: filmPalette(seed: seed))
            .overlay { LinearGradient(colors: [.clear, .black.opacity(0.32)], startPoint: .center, endPoint: .bottom) }
    }
}

/// Toplantı sayfasının kapağı: kartla aynı aile ve düzen, yavaşça akar.
public struct LivingCoverBackground: View {
    let seed: String

    public init(seed: String) {
        self.seed = seed
    }

    public var body: some View {
        LivingFilmGradient(seed: seed, palette: filmPalette(seed: seed))
            .overlay { LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .center, endPoint: .bottom) }
    }
}

/// Kapak üstündeki ikincil düğme: yarı saydam beyaz cam hap, beyaz yazı; el imleci, hover'da biraz daha parlak,
/// basılınca küçülme. Pasifken soluk.
public struct CoverGlassButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        CoverGlassBody(configuration: configuration)
    }
}

private struct CoverGlassBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled: Bool
    @State private var isHovering: Bool = false

    var body: some View {
        configuration.label
            .appFont(size: 13, weight: .medium)
            .foregroundStyle(configuration.role == .destructive ? Color(red: 1, green: 0.62, blue: 0.62) : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(isEnabled && isHovering ? 0.24 : 0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.24)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { (hovering: Bool) -> Void in isHovering = hovering }
            .linkPointer(isEnabled: isEnabled)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == CoverGlassButtonStyle {
    static var coverGlass: CoverGlassButtonStyle { CoverGlassButtonStyle() }
}
