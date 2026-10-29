import SwiftUI

/// Üstüne beyaz yazı konan toplantı kapağı (iPhone kartları, görev grupları): kimliğinden sabit renk ailesiyle durgun
/// film gradyanı ve yazı okunsun diye altta kararma. Yazısı kapağın altında olan kartlar `CoverImage` kullanır.
public struct CoverBackground: View {
    let seed: String

    public init(seed: String) {
        self.seed = seed
    }

    public var body: some View {
        FilmGradient(seed: seed, palette: filmPalette(seed: seed))
            .dimmedInDarkTheme()
            .overlay { LinearGradient(colors: [.clear, .black.opacity(0.38)], startPoint: .top, endPoint: .bottom) }
    }
}

/// Yalnızca görsel kapak (yazı altında): kimliğinden sabit renk ailesiyle durgun film gradyanı, kararma yok.
public struct CoverImage: View {
    let seed: String

    public init(seed: String) {
        self.seed = seed
    }

    public var body: some View {
        FilmGradient(seed: seed, palette: filmPalette(seed: seed))
            .dimmedInDarkTheme()
    }
}

/// Koyu temada kapağın karartması (0...1): pastel kapak siyah zeminde parlamasın, rengini yine korusun.
let darkCoverDimming: Double = 0.34

/// Koyu temada kapağın doygunluğu (1: değişmez).
let darkCoverSaturation: Double = 0.85

public extension View {
    /// Kapağı koyu temada kısar (bkz. `DarkCoverDimming`).
    func dimmedInDarkTheme() -> some View {
        modifier(DarkCoverDimming())
    }
}

/// Kapağı koyu temada kısar: durgun bir karartma ve biraz daha az doygunluk (canlandırılmaz; açık temada kapak olduğu
/// gibi kalır). Yalnız büyük kapaklarda (toplantı kapakları, ana sayfadaki kayıt kartı): marka kutuları ve gradyan
/// panolarındaki koyu simge ve yazılar karartmayla okunmaz olurdu.
private struct DarkCoverDimming: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    func body(content: Content) -> some View {
        if colorScheme == .dark {
            content
                .saturation(darkCoverSaturation)
                .overlay { Color.black.opacity(darkCoverDimming).allowsHitTesting(false) }
        } else {
            content
        }
    }
}

/// Kapağın ortasındaki ses dalgası: toplantıya özgü çubuklar (kimlikten sabit), kapağın renk ailesinin koyu tonunda,
/// gradyanla ton üstüne ton. Durgundur.
public struct CoverWaveform: View {
    let seed: String

    public init(seed: String) {
        self.seed = seed
    }

    public var body: some View {
        let heights: [Double] = coverWaveHeights(seed: seed, count: 23)
        let tone: Color = filmPalette(seed: seed).colors.clouds[3]
        Canvas { (context: inout GraphicsContext, size: CGSize) in
            let gap: Double = 3
            let barWidth: Double = (size.width - gap * Double(heights.count - 1)) / Double(heights.count)
            for (index, height) in heights.enumerated() {
                let barHeight: Double = max(barWidth, height * size.height)
                let rect: CGRect = CGRect(x: Double(index) * (barWidth + gap), y: (size.height - barHeight) / 2, width: barWidth, height: barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(tone.mix(with: .black, by: 0.2)))
            }
        }
        .frame(width: 112, height: 44)
        .opacity(0.62)
        .blendMode(.multiply)
        .accessibilityHidden(true)
    }
}

/// Ses dalgasının çubuk yükseklikleri (0...1): kimlikten sabit, ortası yüksek, kenarlara doğru alçalan, komşularla
/// yumuşak geçişli. Saf fonksiyondur.
func coverWaveHeights(seed: String, count: Int) -> [Double] {
    var state: UInt64 = seed.unicodeScalars.reduce(UInt64(0x9E37_79B9_7F4A_7C15)) { ($0 ^ UInt64($1.value)) &* 0x100_0000_01B3 }
    let next: () -> Double = {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    let raw: [Double] = (0..<count).map { _ in next() }
    return (0..<count).map { (index: Int) -> Double in
        let neighbours: [Double] = [raw[max(0, index - 1)], raw[index], raw[min(count - 1, index + 1)]]
        let smooth: Double = (neighbours[0] + 2 * neighbours[1] + neighbours[2]) / 4
        let center: Double = 1 - abs(Double(index) / Double(count - 1) - 0.5) * 1.3
        return 0.18 + 0.82 * smooth * center
    }
}
