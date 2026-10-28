import CoreGraphics
import SwiftUI

/// Film gradyanının renk ailesi (ElevenLabs gradyanları gibi: açık, pastel, fotoğrafik ışık). Her ailede pastel zemin
/// ve bulutlar; koyu gölge yok, ışık krem beyazı.
public enum FilmPalette: CaseIterable, Sendable {
    case sunset
    case coral
    case ocean
    case mint
    case rose
    case violet

    /// Zemin, sonra bulutlar: açık ton, krem ışık, karşıt pastel, derin (ama yine açık) ton.
    var colors: (base: Color, clouds: [Color]) {
        switch self {
        case .sunset: (rgb(0xF0AE92), [rgb(0xF7CDB8), rgb(0xFFF3E6), rgb(0xC9A3E0), rgb(0xE9896A)])
        case .coral: (rgb(0xF0C49B), [rgb(0xF7DCC0), rgb(0xFFF6E8), rgb(0xF2A7B4), rgb(0xE0A36F)])
        case .ocean: (rgb(0xA9BCEE), [rgb(0xCBD6F6), rgb(0xF4F1FF), rgb(0xE9B9D6), rgb(0x8EA3E6)])
        case .mint: (rgb(0xA9CDB8), [rgb(0xCCE3D4), rgb(0xF6F7EA), rgb(0xE9D7A8), rgb(0x7FB096)])
        case .rose: (rgb(0xEBA7B5), [rgb(0xF6CBD4), rgb(0xFFF1EC), rgb(0xB9C9F0), rgb(0xDE8AA3)])
        case .violet: (rgb(0xC7B3EC), [rgb(0xDED1F5), rgb(0xFFF4EE), rgb(0xF4C0A8), rgb(0xA98BDB)])
        }
    }
}

/// Bir bulut: konum ve boyut (0...1, alana göre), dönüş, renk ve küçük konum kayması evresi.
struct FilmCloud: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let angle: Double
    let colorIndex: Int
    let opacity: Double
    let phase: Double
}

/// Film düzeni: biçim, büyük bulutlar ve doku tutamları.
struct FilmLayout: Equatable {
    let style: FilmStyle
    let clouds: [FilmCloud]
    let wisps: [FilmCloud]
}

/// Bulutların biçimi: yumuşak bulutlar ya da çapraz ışık süzmeleri (hareket bulanıklığı gibi).
enum FilmStyle: Equatable {
    case clouds
    case streaks
}

/// Tohumdan sabit film düzeni (her çizimde aynı). Bulutların rolleri sabit,
/// yerleri tohuma göre: kenarda büyük koyu gölge, karşı tarafta küçük açık ışık, üstte derin renk, arada açık ton —
/// zemin doygun kalır, açık renkler alanı kaplamaz (ElevenLabs kapaklarındaki gibi). Saf fonksiyondur.
func filmLayout(seed: String, palette: FilmPalette) -> FilmLayout {
    var state: UInt64 = seed.unicodeScalars.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1.value)) &* 0x100_0000_01B3 }
    let next: () -> Double = {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    let style: FilmStyle = next() < 0.35 ? .streaks : .clouds
    // Gölge solda mı sağda mı; ışık karşı tarafta.
    let shadowLeft: Bool = next() < 0.5
    let side: (Double) -> Double = { (offset: Double) -> Double in shadowLeft ? offset : 1 - offset }
    let drift: () -> Double = { next() * 2 * .pi }
    // Doku tutamları: küçük, yarı saydam, açık ve derin tonlar karışık; her biçimde aynı.
    let wisps: [FilmCloud] = (0..<10).map { (index: Int) -> FilmCloud in
        let phase: Double = drift()
        return FilmCloud(
            x: next(), y: next(), width: 0.22 + next() * 0.25, height: 0.07 + next() * 0.1, angle: next() * .pi,
            colorIndex: [0, 3, 1, 0, 3, 2, 0, 3, 1, 0][index], opacity: 0.14 + next() * 0.16, phase: phase
        )
    }
    switch style {
    case .clouds:
        let roles: [(x: Double, y: Double, width: Double, height: Double, color: Int, opacity: Double)] = [
            // Derin renk üstte, geniş.
            (0.35 + next() * 0.3, -0.05 + next() * 0.25, 0.7, 0.55, 3, 0.85),
            // Açık ton ortada.
            (side(0.55 + next() * 0.2), 0.45 + next() * 0.3, 0.45, 0.4, 0, 0.7),
            // Işık: küçük, gölgenin karşısında.
            (side(0.78 + next() * 0.15), 0.25 + next() * 0.35, 0.3, 0.3, 1, 0.8),
            // Gölge: büyük, alt köşede.
            (side(0.02 + next() * 0.12), 0.75 + next() * 0.3, 0.75, 0.6, 2, 0.9),
        ]
        return FilmLayout(style: style, clouds: roles.map { (role: (x: Double, y: Double, width: Double, height: Double, color: Int, opacity: Double)) -> FilmCloud in
            let phase: Double = drift()
            return FilmCloud(x: role.x, y: role.y, width: role.width, height: role.height, angle: next() * .pi, colorIndex: role.color, opacity: role.opacity, phase: phase)
        }, wisps: wisps)
    case .streaks:
        // Çapraz ışık süzmeleri: aynı eğim, altta koyu şerit, ortada ince açık şerit, üstte derin şerit.
        let tilt: Double = (shadowLeft ? -1 : 1) * (0.45 + next() * 0.2)
        let roles: [(y: Double, height: Double, color: Int, opacity: Double)] = [
            (0.15 + next() * 0.15, 0.35, 3, 0.85),
            (0.45 + next() * 0.1, 0.14, 1, 0.75),
            (0.6 + next() * 0.1, 0.12, 0, 0.6),
            (0.95 + next() * 0.15, 0.45, 2, 0.9),
        ]
        return FilmLayout(style: style, clouds: roles.map { (role: (y: Double, height: Double, color: Int, opacity: Double)) -> FilmCloud in
            let phase: Double = drift()
            return FilmCloud(x: 0.5, y: role.y, width: 1.8, height: role.height, angle: tilt, colorIndex: role.color, opacity: role.opacity, phase: phase)
        }, wisps: wisps)
    }
}

/// Kimlikten aile (toplantı kapakları: her toplantı hep aynı aile). Saf fonksiyondur.
public func filmPalette(seed: String) -> FilmPalette {
    let index: Int = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF } % FilmPalette.allCases.count
    return FilmPalette.allCases[index]
}

/// Film gradyanı (ElevenLabs gradyanlarının görünümü): pastel zeminde büyük, çok bulanık renk bulutları ya da çapraz
/// ışık süzmeleri, krem ışık, ince film greni ve çok hafif sıcak kenar kararması.
/// Durgundur: akan sürüm her karede ekran dışı yüzey açıp sistemi yoruyordu (boşta bile yüksek işlemci).
public struct FilmGradient: View {
    let seed: String
    let palette: FilmPalette

    public init(seed: String, palette: FilmPalette) {
        self.seed = seed
        self.palette = palette
    }

    public var body: some View {
        FilmLayers(seed: seed, palette: palette)
    }
}

/// Bulanık bulut katmanı bu kat küçük çizilip büyütülür: bulanıklığın bedeli piksel sayısıyla büyür, bulanık görüntüde
/// çözünürlük kaybı görünmez (16 kat daha ucuz).
let cloudDownscale: CGFloat = 4

/// Katmanlar: bulanık bulutlar → soluklaştırma → gren → kenar kararması.
private struct FilmLayers: View {
    let seed: String
    let palette: FilmPalette

    /// Bulutları (konum, dönüş, evreye göre küçük kayma) verilen bağlama çizer.
    private func drawClouds(context: GraphicsContext, clouds: [FilmCloud], size: CGSize, heightScale: Double) {
        let colors: [Color] = palette.colors.clouds
        for cloud in clouds {
            let drift: Double = sin(cloud.phase)
            var layer: GraphicsContext = context
            layer.translateBy(x: (cloud.x + drift * 0.08) * size.width, y: (cloud.y + cos(cloud.phase) * 0.06) * size.height)
            layer.rotate(by: .radians(cloud.angle + drift * 0.05))
            let width: Double = cloud.width * size.width
            let height: Double = cloud.height * heightScale
            layer.fill(
                Path(ellipseIn: CGRect(x: -width / 2, y: -height / 2, width: width, height: height)),
                with: .color(colors[cloud.colorIndex].opacity(cloud.opacity))
            )
        }
    }

    var body: some View {
        let layout: FilmLayout = filmLayout(seed: seed, palette: palette)
        let colors: (base: Color, clouds: [Color]) = palette.colors
        ZStack {
            GeometryReader { (geometry: GeometryProxy) in
                let small: CGSize = CGSize(width: max(1, geometry.size.width / cloudDownscale), height: max(1, geometry.size.height / cloudDownscale))
                Canvas { (context: inout GraphicsContext, size: CGSize) in
                    // Bulut konumları ve bulanıklık yarıçapı boyuta göreli: küçük tuvalde aynı görüntü çıkar.
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colors.base))
                    let shortSide: Double = min(size.width, size.height)
                    var large: GraphicsContext = context
                    large.addFilter(.blur(radius: shortSide * (layout.style == .clouds ? 0.26 : 0.1)))
                    drawClouds(context: large, clouds: layout.clouds, size: size, heightScale: layout.style == .clouds ? size.width : size.height)
                    // Bulut dokusu: daha az bulanık küçük tutamlar (düz lekeler yerine dalgalı, bulutumsu yapı).
                    if layout.style == .clouds {
                        var wisps: GraphicsContext = context
                        wisps.addFilter(.blur(radius: shortSide * 0.14))
                        drawClouds(context: wisps, clouds: layout.wisps, size: size, heightScale: size.width)
                    }
                }
                .frame(width: small.width, height: small.height)
                .drawingGroup()
                .scaleEffect(cloudDownscale, anchor: .topLeading)
            }
            FilmGrain()
            // Fotoğraf objektifi gibi çok hafif, sıcak kenar kararması.
            RadialGradient(colors: [.clear, rgb(0x5A3A2A).opacity(0.12)], center: .center, startRadius: 60, endRadius: 720)
                .blendMode(.multiply)
        }
        .saturation(0.94)
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

/// İnce film greni: önceden üretilmiş gri gürültü dokusu döşenir (her karede yeniden çizilmez, titreşmez).
struct FilmGrain: View {
    var body: some View {
        Rectangle()
            .fill(ImagePaint(image: Image(decorative: filmGrainImage, scale: 2)))
            .blendMode(.overlay)
            .opacity(0.42)
            .allowsHitTesting(false)
    }
}

/// 256×256 gri gürültü dokusu (sabit tohum).
let filmGrainImage: CGImage = {
    let side: Int = 256
    var state: UInt64 = 0x2545_F491_4F6C_DD1D
    var pixels: [UInt8] = [UInt8](repeating: 0, count: side * side * 4)
    for index in 0..<(side * side) {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        // Ortası gri, iki yöne dağılan değerler (overlay'de hem aydınlatır hem karartır).
        let value: UInt8 = UInt8(truncatingIfNeeded: 128 + Int(state % 121) - 60)
        pixels[index * 4] = value
        pixels[index * 4 + 1] = value
        pixels[index * 4 + 2] = value
        pixels[index * 4 + 3] = 255
    }
    let provider: CGDataProvider = CGDataProvider(data: Data(pixels) as CFData)!
    // Sabit boyutlu, geçerli bir RGBA tamponu: oluşturma başarısız olamaz.
    return CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
}()

/// 0xRRGGBB sRGB renk.
private func rgb(_ hex: UInt32) -> Color {
    Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
}
