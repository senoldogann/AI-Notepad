import SwiftUI

/// Toplantı kapağı: kimliğinden sabit bir renk ailesinin ışıklı radyal gradyanı, altta okunurluk için kararma, ince
/// kumlu doku ve yavaşça yanıp sönen sim parçacıkları. Kartlar ve toplantı sayfasının başlığı aynı kapağı kullanır;
/// "Hareketi azalt" açıksa simler durgun.
public struct CoverBackground: View {
    let seed: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    public init(seed: String) {
        self.seed = seed
    }

    public var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            let palette: [Color] = coverPalette(seed: seed)
            ZStack {
                RadialGradient(
                    colors: palette, center: UnitPoint(x: 0.28, y: 0.3),
                    startRadius: 4, endRadius: max(proxy.size.width, proxy.size.height) * 0.85
                )
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                GrainOverlay().blendMode(.overlay)
                TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion)) { (context: TimelineViewDefaultContext) in
                    let time: Double = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                    Canvas { (graphics: inout GraphicsContext, size: CGSize) in
                        for sparkle in coverSparkles(seed: seed, count: sparkleCount(size: size)) {
                            let glow: Double = sparkleBrightness(sparkle: sparkle, time: time)
                            let center: CGPoint = CGPoint(x: sparkle.x * size.width, y: sparkle.y * size.height)
                            let halo: CGFloat = sparkle.radius * 3.2
                            graphics.fill(
                                Path(ellipseIn: CGRect(x: center.x - halo, y: center.y - halo, width: halo * 2, height: halo * 2)),
                                with: .color(.white.opacity(glow * 0.18))
                            )
                            graphics.fill(
                                Path(ellipseIn: CGRect(x: center.x - sparkle.radius, y: center.y - sparkle.radius, width: sparkle.radius * 2, height: sparkle.radius * 2)),
                                with: .color(.white.opacity(glow))
                            )
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Kapaktaki tek sim: konum (0...1), yarıçap, parlama hızı ve evresi.
struct CoverSparkle: Equatable {
    let x: Double
    let y: Double
    let radius: CGFloat
    let speed: Double
    let phase: Double
}

/// Kapağın alanına göre sim sayısı (küçük kartta seyrek, geniş başlıkta yoğun ama abartısız).
func sparkleCount(size: CGSize) -> Int {
    min(60, max(12, Int(size.width * size.height / 3200)))
}

/// Tohumdan sabit simler (her çizimde aynı yerde; yalnızca parlaklık değişir). Saf fonksiyondur.
func coverSparkles(seed: String, count: Int) -> [CoverSparkle] {
    var state: UInt64 = seed.unicodeScalars.reduce(UInt64(0x9E37_79B9_7F4A_7C15)) { ($0 ^ UInt64($1.value)) &* 0x100_0000_01B3 }
    let next: () -> Double = {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    return (0..<count).map { (_: Int) -> CoverSparkle in
        CoverSparkle(x: next(), y: next(), radius: CGFloat(0.5 + next() * 1.1), speed: 0.9 + next() * 1.6, phase: next() * 2 * .pi)
    }
}

/// Simin o anki parlaklığı (0.12...1): yavaş, yumuşak yanıp sönme. Saf fonksiyondur.
func sparkleBrightness(sparkle: CoverSparkle, time: Double) -> Double {
    let wave: Double = 0.5 + 0.5 * sin(time * sparkle.speed + sparkle.phase)
    return 0.12 + 0.88 * wave * wave
}

/// Kapak paleti: toplantı kimliğinden sabit bir renk ailesi (her açılışta aynı; açık ton, doygun ton, koyu ton).
/// Saf fonksiyondur.
public func coverPalette(seed: String) -> [Color] {
    let families: [[Color]] = [
        [Color(red: 0.49, green: 0.71, blue: 1.0), Color(red: 0.18, green: 0.36, blue: 0.88), Color(red: 0.04, green: 0.10, blue: 0.33)],
        [Color(red: 0.66, green: 0.90, blue: 0.81), Color(red: 0.24, green: 0.60, blue: 0.51), Color(red: 0.05, green: 0.23, blue: 0.20)],
        [Color(red: 0.97, green: 0.71, blue: 0.83), Color(red: 0.71, green: 0.29, blue: 0.53), Color(red: 0.23, green: 0.06, blue: 0.17)],
        [Color(red: 1.0, green: 0.74, blue: 0.48), Color(red: 0.89, green: 0.34, blue: 0.12), Color(red: 0.16, green: 0.06, blue: 0.02)],
        [Color(red: 0.80, green: 0.75, blue: 1.0), Color(red: 0.44, green: 0.33, blue: 0.86), Color(red: 0.12, green: 0.07, blue: 0.32)],
    ]
    let index: Int = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF } % families.count
    return families[index]
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
            .pointerStyle(isEnabled ? .link : nil)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == CoverGlassButtonStyle {
    static var coverGlass: CoverGlassButtonStyle { CoverGlassButtonStyle() }
}
