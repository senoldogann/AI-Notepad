import Observation
import SwiftUI

/// Panel metninin yazı tipi ailesi (SF tasarımları; her Mac'te var).
public enum PanelFontDesign: String, Sendable, CaseIterable {
    /// Inter (uygulamaya gömülü; ElevenLabs'in gövde yazısı). Varsayılan.
    case inter
    case system
    case rounded
    case serif
    case monospaced

    public var design: Font.Design {
        switch self {
        case .inter, .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

/// Uygulamanın yazı tipi seçimi: Inter ya da SF tasarımları, veya Mac'te yüklü herhangi bir aile (ör. Avenir Next).
public enum AppFontChoice: Sendable, Equatable, Hashable {
    case design(PanelFontDesign)
    case installed(family: String)

    /// Ayarlarda saklanan değer: tasarımın adı (`inter`) ya da `family:<aile>`.
    public var storageValue: String {
        switch self {
        case .design(let design): design.rawValue
        case .installed(let family): installedFontPrefix + family
        }
    }

    /// Saklanan değerden seçim; tanınmıyorsa nil. Saf fonksiyondur.
    public static func parse(storage: String) -> AppFontChoice? {
        if let design = PanelFontDesign(rawValue: storage) {
            return .design(design)
        }
        guard storage.hasPrefix(installedFontPrefix), storage.count > installedFontPrefix.count else {
            return nil
        }
        return .installed(family: String(storage.dropFirst(installedFontPrefix.count)))
    }
}

private let installedFontPrefix: String = "family:"

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

/// Panelin kullanıcı tarafından ayarlanan görünümü.
public struct PanelAppearance: Equatable, Sendable {
    public let fontChoice: AppFontChoice
    /// Arayüzün tamamındaki yazıların ölçeği (1 = tasarımdaki boyutlar).
    public let uiScale: Double
    /// Transkript metninin punto değeri.
    public let textSize: Double
    public let lineSpacing: Double
    /// Transkriptin en altındaki boşluk (son satır kenara yapışmasın).
    public let bottomSpacing: Double
    public let accent: PanelAccent

    public init(fontChoice: AppFontChoice, uiScale: Double, textSize: Double, lineSpacing: Double, bottomSpacing: Double, accent: PanelAccent) {
        self.fontChoice = fontChoice
        self.uiScale = uiScale
        self.textSize = textSize
        self.lineSpacing = lineSpacing
        self.bottomSpacing = bottomSpacing
        self.accent = accent
    }

    /// Tasarım belgesindeki varsayılanlar (§4.3).
    public static let standard: PanelAppearance = PanelAppearance(
        fontChoice: .design(.inter), uiScale: 1, textSize: 14, lineSpacing: 4, bottomSpacing: 32, accent: .orange
    )

    /// Sistem denetimlerinin tasarımı (yüklü ailede varsayılan).
    public var fontDesign: PanelFontDesign {
        switch fontChoice {
        case .design(let design): design
        case .installed: .system
        }
    }

    /// Arayüz yazısı: seçili ailede (Inter, sistem tasarımı ya da yüklü aile) verilen boyut arayüz ölçeğiyle çarpılır.
    public func font(size: CGFloat, weight: Font.Weight) -> Font {
        familyFont(size: size * uiScale, weight: weight)
    }

    /// Okuma metni (transkript, özet, cevap): boyut "Metin boyutu"ndan gelir, arayüz ölçeğiyle çarpılmaz (ayarda
    /// görünen punto gerçek boyuttur).
    public func readingFont(size: CGFloat, weight: Font.Weight) -> Font {
        familyFont(size: size, weight: weight)
    }

    private func familyFont(size: CGFloat, weight: Font.Weight) -> Font {
        switch fontChoice {
        case .design(.inter): .custom(Theme.interFamily, size: size).weight(weight)
        case .design(let design): .system(size: size, weight: weight, design: design.design)
        case .installed(let family): .custom(family, size: size).weight(weight)
        }
    }

    /// Transkript metni.
    public var bodyFont: Font {
        readingFont(size: textSize, weight: .regular)
    }

    /// İki dilde soluk orijinal ve kart metinleri: gövdeden bir punto küçük.
    public var secondaryFont: Font {
        readingFont(size: max(10, textSize - 1), weight: .regular)
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

/// Panelin yüzeyi (ElevenLabs): süt beyazı zemin (koyu temada koyu), ince çerçeve, yuvarlak köşeler; dolgular
/// köşelerden taşmaz.
private struct PanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: DesignTokens.panelRadius, style: .continuous)
        content
            .foregroundStyle(Theme.ink)
            .clipShape(shape)
            .background(Theme.background, in: shape)
            .overlay(shape.strokeBorder(Theme.line))
    }
}

/// Aynı anda tek ipucu: yeni ipucu açılınca öncekiler kapanır. Panel uygulamayı öne getirmediği için fare çıkışı
/// bazen gelmez; tek etkin ipucu ve süre sınırı olmazsa ipuçları birikip üst üste binerdi.
@MainActor
@Observable
final class HoverHintCenter {
    static let shared: HoverHintCenter = HoverHintCenter()
    /// Görünen ipucunun kimliği; yoksa nil.
    var activeID: UUID?
}

/// İpucu bu kadar süre sonra kendiliğinden kapanır (fare çıkışı gelmese de).
private let hoverHintLifetime: Duration = .seconds(4)

/// Fare üstüne gelince kısa gecikmeyle açıklama gösterir. Panel uygulamayı öne getirmediği için sistem ipuçları
/// (`help`) her zaman görünmez; bu ipucu panelin içinde, kardeş görünümlerin üstünde ve opak çizilir. Erişilebilirlik
/// için `help` de verilir.
private struct HoverHint: ViewModifier {
    let text: LocalizedStringKey
    let alignment: HorizontalAlignment
    let edge: VerticalEdge
    @State private var id: UUID = UUID()
    @State private var delay: Task<Void, Never>?
    private let center: HoverHintCenter = .shared

    private var isVisible: Bool {
        center.activeID == id
    }

    func body(content: Content) -> some View {
        content
            .help(text)
            .onHover { (hovering: Bool) -> Void in
                delay?.cancel()
                guard hovering else {
                    hide()
                    return
                }
                delay = Task {
                    do {
                        try await Task.sleep(for: .milliseconds(450))
                        center.activeID = id
                        try await Task.sleep(for: hoverHintLifetime)
                    } catch {
                        // Fare ayrıldı ya da başka ipucu açıldı.
                        return
                    }
                    hide()
                }
            }
            .onDisappear {
                delay?.cancel()
                hide()
            }
            .overlay(alignment: Alignment(horizontal: alignment, vertical: edge == .bottom ? .bottom : .top)) {
                if isVisible {
                    Text(text)
                        .appFont(size: 11, weight: .medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(white: 0.12), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                        .fixedSize()
                        .offset(y: edge == .bottom ? 28 : -28)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            // Görünürken kardeşlerinin üstünde çizilir (alttaki düğme ya da satır ipucunu örtmesin).
            .zIndex(isVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isVisible)
    }

    private func hide() {
        if center.activeID == id {
            center.activeID = nil
        }
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
