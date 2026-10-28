import SwiftUI

/// Arayüzün tasarım stili: Standart (beyaz kartlar, ince çerçeveler) ya da Apple'ın Liquid Glass camı. Mac ve iPhone
/// aynı ayarı (`appearance.designStyle`) kullanır.
public enum DesignStyle: String, CaseIterable, Sendable {
    case standard
    case liquidGlass
}

/// Liquid Glass'ın cam rengi: zemin gradyanı ve camın tonu bu renkten gelir.
public enum GlassTint: String, CaseIterable, Sendable {
    /// Buz: beyaz, buz mavisi ışıklı cam (varsayılan).
    case ice
    case sky
    case mint
    case lavender
    case rose
    case amber
    /// Duman: koyu temalar için isli grafit.
    case smoke

    /// Arayüzdeki adı.
    public var displayName: String {
        switch self {
        case .ice: String(localized: "Buz")
        case .sky: String(localized: "Gök")
        case .mint: String(localized: "Nane")
        case .lavender: String(localized: "Lavanta")
        case .rose: String(localized: "Gül")
        case .amber: String(localized: "Kehribar")
        case .smoke: String(localized: "Duman")
        }
    }

    /// Açık ve koyu görünüm için renk değerleri (0xRRGGBB). Saf fonksiyondur.
    public var hexColors: (light: GlassTintHex, dark: GlassTintHex) {
        switch self {
        case .ice: (
            GlassTintHex(top: 0xF7FAFD, bottom: 0xE4EDF6, band: 0xFFFFFF, glow: 0xD8E9F7, deep: 0xC4D8EC, tint: 0xFFFFFF, tintOpacity: 0.45),
            GlassTintHex(top: 0x1A2129, bottom: 0x0E1318, band: 0x3A4A5A, glow: 0x2A3A4C, deep: 0x1E2D3E, tint: 0xFFFFFF, tintOpacity: 0.08)
        )
        case .sky: (
            GlassTintHex(top: 0xEEF6FD, bottom: 0xD3E7F8, band: 0xFFFFFF, glow: 0xBFDDF6, deep: 0x9CC7EE, tint: 0x7FB8EA, tintOpacity: 0.22),
            GlassTintHex(top: 0x0F1D2C, bottom: 0x0A121C, band: 0x2E5577, glow: 0x1F4466, deep: 0x173352, tint: 0x4D8FCC, tintOpacity: 0.18)
        )
        case .mint: (
            GlassTintHex(top: 0xEFFAF5, bottom: 0xD3EFE2, band: 0xFFFFFF, glow: 0xC0E8D5, deep: 0x9AD6BC, tint: 0x7CCCA9, tintOpacity: 0.22),
            GlassTintHex(top: 0x0F211B, bottom: 0x0A1511, band: 0x2C5E4C, glow: 0x1E4A3A, deep: 0x163A2D, tint: 0x3FA37F, tintOpacity: 0.16)
        )
        case .lavender: (
            GlassTintHex(top: 0xF5F2FC, bottom: 0xE3DAF5, band: 0xFFFFFF, glow: 0xD6C9F2, deep: 0xBBA6E8, tint: 0xA98FE0, tintOpacity: 0.22),
            GlassTintHex(top: 0x1B1628, bottom: 0x110E1A, band: 0x4A3B72, glow: 0x382C5E, deep: 0x2A2148, tint: 0x8A6FD6, tintOpacity: 0.18)
        )
        case .rose: (
            GlassTintHex(top: 0xFCF1F4, bottom: 0xF4D9E1, band: 0xFFFFFF, glow: 0xF2C6D3, deep: 0xE6A3B7, tint: 0xE596AE, tintOpacity: 0.22),
            GlassTintHex(top: 0x26141B, bottom: 0x180C11, band: 0x6B3449, glow: 0x552839, deep: 0x401D2B, tint: 0xD06A8A, tintOpacity: 0.16)
        )
        case .amber: (
            GlassTintHex(top: 0xFDF6EA, bottom: 0xF6E3C1, band: 0xFFFFFF, glow: 0xF5D69E, deep: 0xEBBE73, tint: 0xE8B25C, tintOpacity: 0.22),
            GlassTintHex(top: 0x261D10, bottom: 0x18120A, band: 0x6E5126, glow: 0x5A411B, deep: 0x433012, tint: 0xD99A3E, tintOpacity: 0.16)
        )
        // Açık temada da koyu yazı okunsun diye açık isli gri; asıl görünümü koyu temadaki grafittir.
        case .smoke: (
            GlassTintHex(top: 0xE9EAEC, bottom: 0xCDD0D5, band: 0xF7F7F8, glow: 0xDADCE0, deep: 0xA9ADB4, tint: 0x8A8F98, tintOpacity: 0.18),
            GlassTintHex(top: 0x1C1D20, bottom: 0x111214, band: 0x3A3C41, glow: 0x2B2D31, deep: 0x222327, tint: 0x2A2C30, tintOpacity: 0.35)
        )
        }
    }
}

/// Bir cam renginin tek görünümdeki (açık ya da koyu) değerleri: zemin gradyanının üstü ve altı, ışık bandı, köşe
/// parıltısı, derin ton ve camın tonu (opaklığıyla).
public struct GlassTintHex: Equatable, Sendable {
    public let top: UInt32
    public let bottom: UInt32
    public let band: UInt32
    public let glow: UInt32
    public let deep: UInt32
    public let tint: UInt32
    public let tintOpacity: Double

    public init(top: UInt32, bottom: UInt32, band: UInt32, glow: UInt32, deep: UInt32, tint: UInt32, tintOpacity: Double) {
        self.top = top
        self.bottom = bottom
        self.band = band
        self.glow = glow
        self.deep = deep
        self.tint = tint
        self.tintOpacity = tintOpacity
    }
}

/// Bir cam renginin oluşturulmuş renkleri (tek görünüm için). Bir kez oluşturulur (`glassColorCache`): her erişimde
/// yeni renk oluşturulmaz.
public struct GlassColors: Sendable {
    public let top: Color
    public let bottom: Color
    public let band: Color
    public let glow: Color
    public let deep: Color
    /// Camın tonu (opaklığı uygulanmış).
    public let tint: Color
    /// Ayarlardaki örnek kutucuğun rengi.
    public let swatch: Color
    /// Cam yüzeyin içindeki çiplerin buzlu dolgusu (cam üstüne cam konmaz).
    public let chipFill: Color
    /// Cam yüzeyde seçili satırın dolgusu.
    public let selectionFill: Color
}

/// Değerlerden renkler. Saf fonksiyondur.
private func makeGlassColors(hex: GlassTintHex, isDark: Bool) -> GlassColors {
    GlassColors(
        top: Color(hex: hex.top),
        bottom: Color(hex: hex.bottom),
        band: Color(hex: hex.band),
        glow: Color(hex: hex.glow),
        deep: Color(hex: hex.deep),
        tint: Color(hex: hex.tint).opacity(hex.tintOpacity),
        swatch: Color(hex: isDark ? hex.band : hex.deep),
        chipFill: Color.white.opacity(isDark ? 0.10 : 0.55),
        selectionFill: Color.white.opacity(isDark ? 0.14 : 0.7)
    )
}

/// Tüm cam renklerinin açık ve koyu renkleri; ilk erişimde bir kez oluşturulur.
private let glassColorCache: [GlassTint: (light: GlassColors, dark: GlassColors)] = Dictionary(
    uniqueKeysWithValues: GlassTint.allCases.map { (tint: GlassTint) -> (GlassTint, (light: GlassColors, dark: GlassColors)) in
        let hex: (light: GlassTintHex, dark: GlassTintHex) = tint.hexColors
        return (tint, (makeGlassColors(hex: hex.light, isDark: false), makeGlassColors(hex: hex.dark, isDark: true)))
    }
)

/// Cam renginin verilen görünümdeki (önbellekteki) renkleri.
public func glassColors(tint: GlassTint, colorScheme: ColorScheme) -> GlassColors {
    // Önbellek her rengi içerir (tüm durumlardan kurulur).
    let pair: (light: GlassColors, dark: GlassColors) = glassColorCache[tint]!
    return colorScheme == .dark ? pair.dark : pair.light
}

/// Seçili tasarım: stil ve cam rengi. Kökte `designLook(_:)` ile verilir; bileşenler ortamdan okur.
public struct DesignLook: Equatable, Sendable {
    public let style: DesignStyle
    public let tint: GlassTint

    public init(style: DesignStyle, tint: GlassTint) {
        self.style = style
        self.tint = tint
    }

    /// Varsayılan: Standart (cam rengi Buz, cam seçilince kullanılır).
    public static let standard: DesignLook = DesignLook(style: .standard, tint: .ice)

    /// Yüzeyler cam mı.
    public var usesGlass: Bool {
        style == .liquidGlass
    }

    /// Kartların, kenar çubuğunun ve çubukların camı: düzenli cam, cam rengiyle tonlanmış.
    public func surfaceGlass(colorScheme: ColorScheme) -> Glass {
        .regular.tint(glassColors(tint: tint, colorScheme: colorScheme).tint)
    }

    /// Düğmelerin camı: dokununca ve basınca tepki veren cam.
    public func interactiveGlass(colorScheme: ColorScheme) -> Glass {
        surfaceGlass(colorScheme: colorScheme).interactive()
    }
}

private struct DesignLookKey: EnvironmentKey {
    static let defaultValue: DesignLook = .standard
}

public extension EnvironmentValues {
    /// Tasarım stili ve cam rengi; uygulama Ayarlar'daki değerlerle verir (`designLook(_:)`).
    var designLook: DesignLook {
        get { self[DesignLookKey.self] }
        set { self[DesignLookKey.self] = newValue }
    }
}

/// Tasarımı ortama verir; "Saydamlığı azalt" açıksa Standart yüzeyler kullanılır.
private struct DesignLookEnvironment: ViewModifier {
    let look: DesignLook
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency: Bool

    func body(content: Content) -> some View {
        content.environment(\.designLook, reduceTransparency ? DesignLook(style: .standard, tint: look.tint) : look)
    }
}

/// Liquid Glass'ın pencere zemini: cam renginin soluk gradyanı, köşelerde yumuşak parıltı ve çapraz ışık bantları.
/// Durgundur (zaman çizelgesi, animasyon, bulanıklık yok): yalnızca gradyanlar, bir kez çizilir.
public struct GlassBackdrop: View {
    let tint: GlassTint
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    public init(tint: GlassTint) {
        self.tint = tint
    }

    public var body: some View {
        let colors: GlassColors = glassColors(tint: tint, colorScheme: colorScheme)
        ZStack {
            LinearGradient(colors: [colors.top, colors.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Sağ üstte ışık, sol altta derin ton.
            EllipticalGradient(colors: [colors.glow, colors.glow.opacity(0)], center: UnitPoint(x: 0.9, y: 0.02), startRadiusFraction: 0, endRadiusFraction: 0.7)
            EllipticalGradient(colors: [colors.deep.opacity(0.6), colors.deep.opacity(0)], center: UnitPoint(x: 0.04, y: 1), startRadiusFraction: 0, endRadiusFraction: 0.75)
            // Çapraz, yumuşak iki ışık bandı (camın kırdığı bir şey olsun).
            LinearGradient(
                stops: [
                    Gradient.Stop(color: colors.band.opacity(0), location: 0.16),
                    Gradient.Stop(color: colors.band.opacity(0.55), location: 0.3),
                    Gradient.Stop(color: colors.band.opacity(0), location: 0.44),
                    Gradient.Stop(color: colors.band.opacity(0), location: 0.58),
                    Gradient.Stop(color: colors.band.opacity(0.4), location: 0.68),
                    Gradient.Stop(color: colors.band.opacity(0), location: 0.8),
                ],
                startPoint: UnitPoint(x: 0, y: 0.1), endPoint: UnitPoint(x: 1, y: 0.9)
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Cam rengi örneği (Ayarlar › Görünüm, Mac ve iPhone): rengin durgun zemini üstünde küçük bir cam mercek; seçili olan
/// vurgu rengiyle çerçeveli. Fare üstündeyken adı görünür.
public struct GlassTintSwatch: View {
    let tint: GlassTint
    let isSelected: Bool
    let accent: Color
    let onSelect: @MainActor () -> Void
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    public init(tint: GlassTint, isSelected: Bool, accent: Color, onSelect: @escaping @MainActor () -> Void) {
        self.tint = tint
        self.isSelected = isSelected
        self.accent = accent
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: onSelect) {
            ZStack {
                GlassBackdrop(tint: tint)
                Color.clear
                    .glassEffect(DesignLook(style: .liquidGlass, tint: tint).surfaceGlass(colorScheme: colorScheme), in: Circle())
                    .padding(7)
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(isSelected ? accent : Theme.line, lineWidth: isSelected ? 2 : 1))
            .padding(2)
            .contentShape(Circle())
        }
        .buttonStyle(.hoverPlain)
        .hoverHint(LocalizedStringKey(tint.displayName), alignment: .center, edge: .bottom)
        .accessibilityLabel(Text(verbatim: tint.displayName))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Kart yüzeyi: Standart'ta beyaz kart, ince çerçeve ve çok hafif gölge; Liquid Glass'ta tonlu cam.
private struct CardSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.designLook) private var look: DesignLook
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    func body(content: Content) -> some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch look.style {
        case .standard:
            // Gölge yalnızca sabit zemine: içeriğe uygulansaydı içerik her değiştiğinde (ör. çalma çubuğu saniyede
            // onlarca kez) gölge baştan hesaplanır, pencere sunucusu boşuna yorulurdu.
            content
                .background {
                    shape.fill(Theme.card).shadow(color: .black.opacity(0.04), radius: 10, y: 4)
                }
                .overlay(shape.strokeBorder(Theme.line))
        case .liquidGlass:
            content.glassEffect(look.surfaceGlass(colorScheme: colorScheme), in: shape)
        }
    }
}

/// Çerçeveli kart: Standart'ta beyaz zemin ve ince çerçeve (gölgesiz); Liquid Glass'ta tonlu cam.
private struct OutlinedCard: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.designLook) private var look: DesignLook
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    func body(content: Content) -> some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch look.style {
        case .standard:
            content
                .background(Theme.card, in: shape)
                .overlay(shape.strokeBorder(Theme.line))
        case .liquidGlass:
            content.glassEffect(look.surfaceGlass(colorScheme: colorScheme), in: shape)
        }
    }
}

/// Kendi başına duran soluk yüzey (denetim kapsülü, bölüm seçici izi, dil çipi): Standart'ta soluk zemin; Liquid
/// Glass'ta tonlu cam.
private struct SoftSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.designLook) private var look: DesignLook
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    func body(content: Content) -> some View {
        switch look.style {
        case .standard:
            content.background(Theme.soft, in: shape)
        case .liquidGlass:
            content.glassEffect(look.surfaceGlass(colorScheme: colorScheme), in: shape)
        }
    }
}

/// Kart içindeki çip ve rozet: Standart'ta soluk zemin; Liquid Glass'ta buzlu beyaz dolgu (cam üstüne cam konmaz).
private struct ChipSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.designLook) private var look: DesignLook
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    func body(content: Content) -> some View {
        switch look.style {
        case .standard:
            content.background(Theme.soft, in: shape)
        case .liquidGlass:
            content.background(glassColors(tint: look.tint, colorScheme: colorScheme).chipFill, in: shape)
        }
    }
}

/// Seçili satırın zemini: Standart'ta seçili satır tonu; Liquid Glass'ta buzlu beyaz. Seçili değilse boş.
private struct SelectionSurface<S: Shape>: ViewModifier {
    let isSelected: Bool
    let shape: S
    @Environment(\.designLook) private var look: DesignLook
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    func body(content: Content) -> some View {
        let fill: Color = switch look.style {
        case .standard: Theme.selected
        case .liquidGlass: glassColors(tint: look.tint, colorScheme: colorScheme).selectionFill
        }
        content.background(isSelected ? fill : Color.clear, in: shape)
    }
}

/// Ana eylem zemini (siyah kapsül, koyu temada beyaz): Liquid Glass'ta ana renkle tonlanmış etkileşimli cam.
private struct PrimarySurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.designLook) private var look: DesignLook

    func body(content: Content) -> some View {
        switch look.style {
        case .standard:
            content.background(Theme.primary, in: shape)
        case .liquidGlass:
            content.glassEffect(.regular.tint(Theme.primary).interactive(), in: shape)
        }
    }
}

/// Yalnızca Liquid Glass'ta: içeriği dolgulu bir cam kartta toplar (ayar satırları, kayıt ekranı). Standart'ta
/// değişmez.
private struct LiquidGlassGroup: ViewModifier {
    let cornerRadius: CGFloat
    let padding: EdgeInsets
    @Environment(\.designLook) private var look: DesignLook
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    func body(content: Content) -> some View {
        switch look.style {
        case .standard:
            content
        case .liquidGlass:
            content
                .padding(padding)
                .glassEffect(look.surfaceGlass(colorScheme: colorScheme), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// Yalnızca Liquid Glass'ta: yakın cam öğeleri tek `GlassEffectContainer`'da çizer (Apple'ın önerisi: birlikte
/// karışır, daha az işlem). `spacing` öğeler arasındaki boşluk kadar verilir: duran öğeler birbirine akmaz.
private struct GlassGroupContainer: ViewModifier {
    let spacing: CGFloat
    @Environment(\.designLook) private var look: DesignLook

    func body(content: Content) -> some View {
        switch look.style {
        case .standard:
            content
        case .liquidGlass:
            GlassEffectContainer(spacing: spacing) {
                content
            }
        }
    }
}

/// Kenar çubuğu yüzeyi: Standart'ta sayfa zemini ve sağda ince çizgi; Liquid Glass'ta kenarlardan içeride yüzen cam.
private struct SidebarSurface: ViewModifier {
    @Environment(\.designLook) private var look: DesignLook
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    func body(content: Content) -> some View {
        switch look.style {
        case .standard:
            content
                .pageBackground()
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
        case .liquidGlass:
            content.background {
                Color.clear
                    .glassEffect(look.surfaceGlass(colorScheme: colorScheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(6)
            }
        }
    }
}

/// Ekran zemini (iPhone sekmeleri): Standart'ta temanın zemin rengi; Liquid Glass'ta cam renginin durgun zemini.
private struct ScreenBackground: ViewModifier {
    @Environment(\.designLook) private var look: DesignLook

    func body(content: Content) -> some View {
        switch look.style {
        case .standard:
            content.background(Theme.background)
        case .liquidGlass:
            content.background { GlassBackdrop(tint: look.tint).ignoresSafeArea() }
        }
    }
}

public extension View {
    /// Tasarımı (stil ve cam rengi) ortama verir; pencerelerin kökünde kullanılır (bkz. `DesignLookEnvironment`).
    func designLook(_ look: DesignLook) -> some View {
        modifier(DesignLookEnvironment(look: look))
    }

    /// Kart yüzeyi (bkz. `CardSurface`).
    func cardSurface(cornerRadius: CGFloat) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius))
    }

    /// Gölgesiz çerçeveli kart (bkz. `OutlinedCard`).
    func outlinedCard(cornerRadius: CGFloat) -> some View {
        modifier(OutlinedCard(cornerRadius: cornerRadius))
    }

    /// Kendi başına duran soluk yüzey (bkz. `SoftSurface`).
    func softSurface(shape: some Shape) -> some View {
        modifier(SoftSurface(shape: shape))
    }

    /// Kart içindeki çip zemini (bkz. `ChipSurface`).
    func chipSurface(shape: some Shape) -> some View {
        modifier(ChipSurface(shape: shape))
    }

    /// Seçili satırın zemini (bkz. `SelectionSurface`).
    func selectionSurface(isSelected: Bool, shape: some Shape) -> some View {
        modifier(SelectionSurface(isSelected: isSelected, shape: shape))
    }

    /// Ana eylem zemini (bkz. `PrimarySurface`).
    func primarySurface(shape: some Shape) -> some View {
        modifier(PrimarySurface(shape: shape))
    }

    /// Yalnızca Liquid Glass'ta dolgulu cam kart (bkz. `LiquidGlassGroup`).
    func liquidGlassGroup(cornerRadius: CGFloat, padding: EdgeInsets) -> some View {
        modifier(LiquidGlassGroup(cornerRadius: cornerRadius, padding: padding))
    }

    /// Yalnızca Liquid Glass'ta cam kabı (bkz. `GlassGroupContainer`).
    func glassGroup(spacing: CGFloat) -> some View {
        modifier(GlassGroupContainer(spacing: spacing))
    }

    /// Kenar çubuğu yüzeyi (bkz. `SidebarSurface`).
    func sidebarSurface() -> some View {
        modifier(SidebarSurface())
    }

    /// Ekran zemini (bkz. `ScreenBackground`).
    func screenBackground() -> some View {
        modifier(ScreenBackground())
    }
}
