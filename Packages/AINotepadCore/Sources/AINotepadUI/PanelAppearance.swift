import SwiftUI

/// Panel metninin yazı tipi ailesi (SF tasarımları; her Mac'te var).
public enum PanelFontDesign: String, Sendable, CaseIterable {
    case system
    case rounded
    case serif
    case monospaced

    var design: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

/// Vurgu rengi: düğmeler ve "senden istenenler" vurguları ("Sen"in kendi rengi değişmez).
public enum PanelAccent: String, Sendable, CaseIterable {
    case blue
    case green
    case purple
    case orange
    case pink

    public var color: Color {
        switch self {
        case .blue: DesignTokens.meColor
        case .green: Color(red: 0x0C / 255, green: 0xA6 / 255, blue: 0x78 / 255)
        case .purple: Color(red: 0x70 / 255, green: 0x48 / 255, blue: 0xE8 / 255)
        case .orange: Color(red: 0xE8 / 255, green: 0x59 / 255, blue: 0x0C / 255)
        case .pink: Color(red: 0xD6 / 255, green: 0x33 / 255, blue: 0x6C / 255)
        }
    }
}

/// Panelin arka planı: cam, koyulaştırılmış cam (hareketli duvar kağıdında okunaklı) ya da opak.
public enum PanelBackground: String, Sendable, CaseIterable {
    case glass
    case tintedGlass
    case solid
}

/// Panelin kullanıcı tarafından ayarlanan görünümü.
public struct PanelAppearance: Equatable, Sendable {
    public let fontDesign: PanelFontDesign
    /// Transkript metninin punto değeri.
    public let textSize: Double
    public let lineSpacing: Double
    /// Transkriptin en altındaki boşluk (son satır kenara yapışmasın).
    public let bottomSpacing: Double
    public let accent: PanelAccent
    public let background: PanelBackground

    public init(fontDesign: PanelFontDesign, textSize: Double, lineSpacing: Double, bottomSpacing: Double, accent: PanelAccent, background: PanelBackground) {
        self.fontDesign = fontDesign
        self.textSize = textSize
        self.lineSpacing = lineSpacing
        self.bottomSpacing = bottomSpacing
        self.accent = accent
        self.background = background
    }

    /// Tasarım belgesindeki varsayılanlar (§4.3).
    public static let standard: PanelAppearance = PanelAppearance(
        fontDesign: .system, textSize: 14, lineSpacing: 4, bottomSpacing: 32, accent: .blue, background: .glass
    )

    /// Transkript metni.
    public var bodyFont: Font {
        .system(size: textSize, design: fontDesign.design)
    }

    /// İki dilde soluk orijinal ve kart metinleri: gövdeden bir punto küçük.
    public var secondaryFont: Font {
        .system(size: max(10, textSize - 1), design: fontDesign.design)
    }
}

private struct PanelAppearanceKey: EnvironmentKey {
    static let defaultValue: PanelAppearance = .standard
}

public extension EnvironmentValues {
    /// Panel görünümü; uygulama Ayarlar'daki değerlerle verir.
    var panelAppearance: PanelAppearance {
        get { self[PanelAppearanceKey.self] }
        set { self[PanelAppearanceKey.self] = newValue }
    }
}

/// Panelin yüzeyi: seçilen arka plan, yuvarlak köşeler; dolgular köşelerden taşmaz.
private struct PanelSurface: ViewModifier {
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    func body(content: Content) -> some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: DesignTokens.panelRadius, style: .continuous)
        switch appearance.background {
        case .glass:
            content.clipShape(shape).glassEffect(.regular, in: shape)
        case .tintedGlass:
            content.clipShape(shape).glassEffect(.regular.tint(Color.black.opacity(0.35)), in: shape)
        case .solid:
            content.clipShape(shape).background(Color(nsColor: .windowBackgroundColor), in: shape)
        }
    }
}

/// Fare üstüne gelince kısa gecikmeyle açıklama gösterir. Panel uygulamayı öne getirmediği için sistem ipuçları
/// (`help`) her zaman görünmez; bu ipucu panelin içinde çizilir. Erişilebilirlik için `help` de verilir.
private struct HoverHint: ViewModifier {
    let text: LocalizedStringKey
    let alignment: HorizontalAlignment
    let edge: VerticalEdge
    @State private var isVisible: Bool = false
    @State private var delay: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .help(text)
            .onHover { (hovering: Bool) -> Void in
                delay?.cancel()
                guard hovering else {
                    isVisible = false
                    return
                }
                delay = Task {
                    do {
                        try await Task.sleep(for: .milliseconds(450))
                    } catch {
                        // Fare ayrıldı; ipucu gösterilmez.
                        return
                    }
                    isVisible = true
                }
            }
            .overlay(alignment: Alignment(horizontal: alignment, vertical: edge == .bottom ? .bottom : .top)) {
                if isVisible {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.82), in: Capsule())
                        .fixedSize()
                        .offset(y: edge == .bottom ? 28 : -28)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isVisible)
    }
}

public extension View {
    /// Panelin yüzeyi (bkz. `PanelSurface`); tüm sayfalar aynı yüzeyi kullanır.
    func panelSurface() -> some View {
        modifier(PanelSurface())
    }

    /// Fare üstüne gelince görünen açıklama; `alignment` ipucunun düğmenin hangi kenarına, `edge` altına mı üstüne mi
    /// çizileceği (panel kenarındaki düğmelerde taşmasın diye).
    func hoverHint(_ text: LocalizedStringKey, alignment: HorizontalAlignment, edge: VerticalEdge) -> some View {
        modifier(HoverHint(text: text, alignment: alignment, edge: edge))
    }
}
