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

/// Pencere yüzeyi: dolu zemin, buzlu cam (masaüstü ardından hafifçe görünür) ya da daha şeffaf cam.
public enum WindowSurface: String, Sendable, CaseIterable {
    case solid
    case frosted
    case clear
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
    public let surface: WindowSurface
    /// Cam yüzeyde zemin renginin camın üstündeki opaklığı (0,35–0,95); dolu yüzeyde kullanılmaz.
    public let surfaceOpacity: Double

    public init(
        fontChoice: AppFontChoice, uiScale: Double, textSize: Double, lineSpacing: Double, bottomSpacing: Double, accent: PanelAccent,
        surface: WindowSurface, surfaceOpacity: Double
    ) {
        self.fontChoice = fontChoice
        self.uiScale = uiScale
        self.textSize = textSize
        self.lineSpacing = lineSpacing
        self.bottomSpacing = bottomSpacing
        self.accent = accent
        self.surface = surface
        self.surfaceOpacity = surfaceOpacity
    }

    /// Tasarım belgesindeki varsayılanlar (§4.3).
    public static let standard: PanelAppearance = PanelAppearance(
        fontChoice: .design(.inter), uiScale: 1, textSize: 14, lineSpacing: 4, bottomSpacing: 32, accent: .orange,
        surface: .solid, surfaceOpacity: 0.7
    )

    /// Sistem yazısının tasarımı (yuvarlak, tırnaklı, eş aralıklı); Inter ve yüklü ailede nil. `fontDesign` değiştiricisi
    /// özel yazı tiplerini de sistem yazısına çevirir: Inter ya da yüklü aile seçiliyken verilmemelidir.
    public var systemFontDesign: Font.Design? {
        switch fontChoice {
        case .design(.inter), .installed: nil
        case .design(let design): design.design
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

/// Sayfa ve kenar çubuğu zemini: dolu yüzeyde zemin rengi; camda saydam (pencerenin tek cam katmanı görünsün).
private struct PageBackground: ViewModifier {
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    func body(content: Content) -> some View {
        content.background(appearance.surface == .solid ? Theme.background : Color.clear)
    }
}

/// Pencere zemini: dolu yüzeyde zemin rengi; camda sistem camı üstüne yarı saydam zemin.
public struct WindowBackdrop: View {
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init() {}

    public var body: some View {
        ZStack {
            switch appearance.surface {
            case .solid:
                Theme.background
            case .frosted:
                Rectangle().fill(.thinMaterial)
                Theme.background.opacity(appearance.surfaceOpacity)
            case .clear:
                Rectangle().fill(.ultraThinMaterial)
                Theme.background.opacity(appearance.surfaceOpacity * 0.6)
            }
        }
        .ignoresSafeArea()
    }
}

public extension View {
    /// Sayfa ya da kenar çubuğu zemini (bkz. `PageBackground`).
    func pageBackground() -> some View {
        modifier(PageBackground())
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
            // Cam yüzey seçiliyse panel de camdan (dolu yüzeyde zemin rengi).
            .background { WindowBackdrop().clipShape(shape) }
            .overlay(shape.strokeBorder(Theme.line))
    }
}

/// Görünen ipucu: metni, bağlı olduğu düğmenin pencere içindeki çerçevesi, hangi kenarına ve altına mı üstüne mi
/// çizileceği; hangi pencerenin katmanında çizileceği (`scope`).
struct ActiveHoverHint: Equatable {
    let id: UUID
    let scope: UUID
    let text: LocalizedStringKey
    let anchor: CGRect
    let alignment: HorizontalAlignment
    let edge: VerticalEdge

    static func == (left: ActiveHoverHint, right: ActiveHoverHint) -> Bool {
        left.id == right.id && left.scope == right.scope && left.anchor == right.anchor
    }
}

/// Aynı anda tek ipucu: yeni ipucu açılınca öncekiler kapanır. Panel uygulamayı öne getirmediği için fare çıkışı
/// bazen gelmez; tek etkin ipucu ve süre sınırı olmazsa ipuçları birikip üst üste binerdi.
@MainActor
@Observable
final class HoverHintCenter {
    static let shared: HoverHintCenter = HoverHintCenter()
    /// Görünen ipucu; yoksa nil.
    var active: ActiveHoverHint?
}

/// İpucu bu kadar süre sonra kendiliğinden kapanır (fare çıkışı gelmese de).
private let hoverHintLifetime: Duration = .seconds(4)

private struct HoverHintScopeKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// İpuçlarının çizildiği pencere katmanı (`hoverHintLayer`); katman yoksa nil.
    var hoverHintScope: UUID? {
        get { self[HoverHintScopeKey.self] }
        set { self[HoverHintScopeKey.self] = newValue }
    }
}

/// Fare üstüne gelince kısa gecikmeyle açıklama gösterir. İpucu düğmenin yanında değil, pencerenin en üst katmanında
/// (`hoverHintLayer`) çizilir: komşu metnin altında kalmaz, kart ya da kaydırma alanı tarafından kesilmez ve pencere
/// kenarından taşmaz. Katman varken sistem ipucu (`help`) verilmez (iki ipucu üst üste çıkardı); metin erişilebilirlik
/// ipucu olarak kalır. Katmanı olmayan pencerede yalnız sistem ipucu kullanılır.
private struct HoverHint: ViewModifier {
    let text: LocalizedStringKey
    let alignment: HorizontalAlignment
    let edge: VerticalEdge
    @State private var id: UUID = UUID()
    /// Fare düğmenin üstünde: yalnızca bu sırada düğmenin çerçevesi ölçülür (kaydırırken yüzlerce ipucu sürekli
    /// ölçülmesin).
    @State private var isHovering: Bool = false
    @State private var delay: Task<Void, Never>?
    @Environment(\.hoverHintScope) private var scope: UUID?
    private let center: HoverHintCenter = .shared

    func body(content: Content) -> some View {
        Group {
            if scope == nil {
                content.help(text)
            } else {
                // Simgeli düğmelerin görünür adı yok: ipucu metni ekran okuyucunun okuduğu ad olur.
                content.accessibilityLabel(Text(text))
            }
        }
            .onHover { (hovering: Bool) -> Void in
                isHovering = hovering
                if !hovering {
                    delay?.cancel()
                    hide()
                }
            }
            .background {
                if isHovering {
                    GeometryReader { (proxy: GeometryProxy) in
                        Color.clear.onAppear { schedule(anchor: proxy.frame(in: .global)) }
                    }
                }
            }
            .onDisappear {
                delay?.cancel()
                hide()
            }
    }

    /// Kısa gecikmeyle ipucunu düğmenin yanında açar; süre dolunca kapatır.
    private func schedule(anchor: CGRect) {
        delay?.cancel()
        guard let scope else {
            return
        }
        delay = Task {
            do {
                try await Task.sleep(for: .milliseconds(450))
                center.active = ActiveHoverHint(id: id, scope: scope, text: text, anchor: anchor, alignment: alignment, edge: edge)
                try await Task.sleep(for: hoverHintLifetime)
            } catch {
                // Fare ayrıldı ya da başka ipucu açıldı.
                return
            }
            hide()
        }
    }

    private func hide() {
        if center.active?.id == id {
            center.active = nil
        }
    }
}

/// Pencerenin ipucu katmanı: bu penceredeki etkin ipucunu düğmesinin altında (ya da üstünde) çizer; pencere kenarına
/// taşacaksa içeri kaydırır, aşağıya sığmıyorsa üste alır.
private struct HoverHintLayer: ViewModifier {
    @State private var scope: UUID = UUID()
    @State private var bubbleSize: CGSize = .zero
    /// Etkin ipucu metninin tek satırdaki genişliği.
    @State private var textWidth: CGFloat = 0
    private let center: HoverHintCenter = .shared

    func body(content: Content) -> some View {
        content
            .environment(\.hoverHintScope, scope)
            .overlay(alignment: .topLeading) {
                GeometryReader { (proxy: GeometryProxy) in
                    if let hint = center.active, hint.scope == scope {
                        let origin: CGPoint = hoverHintOrigin(
                            anchor: hint.anchor.offsetBy(dx: -proxy.frame(in: .global).minX, dy: -proxy.frame(in: .global).minY),
                            bubble: bubbleSize, bounds: proxy.size, alignment: hint.alignment, edge: hint.edge
                        )
                        // Metin önce tek satır ölçülür; en fazla 300 pt genişlikte kırılır ve kutu yüksekliği satırlara uyar.
                        Text(hint.text)
                            .appFont(size: 11, weight: .medium)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .frame(width: min(ceil(textWidth) + 1, 300), alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .background {
                                Text(hint.text)
                                    .appFont(size: 11, weight: .medium)
                                    .fixedSize()
                                    .hidden()
                                    .onGeometryChange(for: CGFloat.self) { (label: GeometryProxy) -> CGFloat in
                                        label.size.width
                                    } action: { (width: CGFloat) -> Void in
                                        textWidth = width
                                    }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                            .fixedSize()
                            .onGeometryChange(for: CGSize.self) { (bubble: GeometryProxy) -> CGSize in
                                bubble.size
                            } action: { (size: CGSize) -> Void in
                                bubbleSize = size
                            }
                            .offset(x: origin.x, y: origin.y)
                            // Boyut ölçülene dek görünmez (ilk karede yanlış yerde çizilmesin).
                            .opacity(bubbleSize == .zero || textWidth == 0 ? 0 : 1)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: center.active)
            }
    }
}

/// İpucu kutusunun sol üst köşesi: düğmenin seçilen kenarına hizalı, altında 6 pt (`edge` üstse üstünde); pencere
/// sınırına 8 pt kala içeri kaydırılır, aşağıya sığmıyorsa üste alınır. Saf fonksiyondur.
func hoverHintOrigin(anchor: CGRect, bubble: CGSize, bounds: CGSize, alignment: HorizontalAlignment, edge: VerticalEdge) -> CGPoint {
    let margin: CGFloat = 8
    let x: CGFloat = switch alignment {
    case .trailing: anchor.maxX - bubble.width
    case .center: anchor.midX - bubble.width / 2
    default: anchor.minX
    }
    let below: CGFloat = anchor.maxY + 6
    let above: CGFloat = anchor.minY - 6 - bubble.height
    let preferred: CGFloat = edge == .bottom ? (below + bubble.height > bounds.height - margin ? above : below) : (above < margin ? below : above)
    return CGPoint(
        x: min(max(margin, x), max(margin, bounds.width - bubble.width - margin)),
        y: min(max(margin, preferred), max(margin, bounds.height - bubble.height - margin))
    )
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

    /// Pencerenin kök görünümüne: içindeki ipuçları bu katmanda, her şeyin üstünde çizilir.
    func hoverHintLayer() -> some View {
        modifier(HoverHintLayer())
    }
}
