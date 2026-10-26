import SwiftUI

/// Hover arka planının taşma payı: vurgu, içerikten biraz büyük çizilir (yerleşimi değiştirmeden nefes alsın).
private let hoverOutset: CGFloat = 3

/// Tıklanabilir öğenin ortak davranışı: el imleci, fare üstündeyken hafif arka plan, basılıyken biraz koyusu.
/// Etkin değilse ikisi de yok.
private struct HoverSurface: ViewModifier {
    let cornerRadius: CGFloat
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled: Bool
    @State private var isHovering: Bool = false

    func body(content: Content) -> some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(highlightOpacity))
                    .padding(-hoverOutset)
            }
            // Devre dışıyken soluk: tıklanabilir görünmesin.
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { (hovering: Bool) -> Void in isHovering = hovering }
            .pointerStyle(isEnabled ? .link : nil)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var highlightOpacity: Double {
        guard isEnabled else {
            return 0
        }
        if isPressed {
            return 0.14
        }
        return isHovering ? 0.08 : 0
    }
}

public extension View {
    /// Düğme olmayan tıklanabilir öğe (ör. dokununca çalan paragraf): el imleci ve hover arka planı.
    func hoverHighlight(cornerRadius: CGFloat) -> some View {
        modifier(HoverSurface(cornerRadius: cornerRadius, isPressed: false))
    }
}

/// Çerçevesiz düğme (satırlar, simgeler, metin bağlantıları): el imleci ve fare üstündeyken hafif arka plan.
public struct HoverPlainButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(HoverSurface(cornerRadius: cornerRadius, isPressed: configuration.isPressed))
    }
}

public extension ButtonStyle where Self == HoverPlainButtonStyle {
    /// Satır ve simge düğmeleri.
    static var hoverPlain: HoverPlainButtonStyle { HoverPlainButtonStyle(cornerRadius: 7) }
    /// Kapsül ve yuvarlak düğmeler (vurgu hapları, oynat düğmesi, seçici bölümleri): vurgu da kapsül biçiminde
    /// (yarıçap yüksekliğin yarısını aşınca köşeler tam yuvarlanır).
    static var hoverCapsule: HoverPlainButtonStyle { HoverPlainButtonStyle(cornerRadius: 1000) }
}

/// Liquid Glass düğmenin boyutu: denetim boyutuna göre dolgu ve yazı.
private struct GlassMetrics {
    let horizontal: CGFloat
    let vertical: CGFloat
    let font: Font
}

/// Denetim boyutunun cam düğme ölçüleri. Saf fonksiyondur.
private func glassMetrics(controlSize: ControlSize) -> GlassMetrics {
    switch controlSize {
    case .mini, .small:
        GlassMetrics(horizontal: 10, vertical: 4, font: .system(size: 12, weight: .medium))
    case .large, .extraLarge:
        GlassMetrics(horizontal: 18, vertical: 10, font: .system(size: 15, weight: .semibold))
    default:
        GlassMetrics(horizontal: 13, vertical: 6, font: .system(size: 13, weight: .medium))
    }
}

/// Cam düğmenin gövdesi: etkileşimli Liquid Glass kapsül; `tint` varsa o renkte (ana eylem). Fare üstündeyken hafif
/// aydınlanır, basılıyken küçülür, el imleci gösterir; etkin değilse soluk.
private struct GlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled: Bool
    @Environment(\.controlSize) private var controlSize: ControlSize
    @State private var isHovering: Bool = false

    var body: some View {
        let metrics: GlassMetrics = glassMetrics(controlSize: controlSize)
        configuration.label
            .font(metrics.font)
            .foregroundStyle(foreground)
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .background {
                Capsule().fill((tint == nil ? Color.primary : Color.white).opacity(isEnabled && isHovering ? 0.10 : 0))
            }
            .glassEffect(glass, in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { (hovering: Bool) -> Void in isHovering = hovering }
            .pointerStyle(isEnabled ? .link : nil)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var glass: Glass {
        tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive()
    }

    private var foreground: AnyShapeStyle {
        if tint != nil {
            return AnyShapeStyle(Color.white)
        }
        return configuration.role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary)
    }
}

/// Varsayılan düğme: etkileşimli Liquid Glass kapsül (panel ve ana pencerenin kökünde verilir).
public struct GlassActionButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, tint: nil)
    }
}

/// Ana eylem (ör. "Kaydı başlat"): vurgu renginde Liquid Glass kapsül.
public struct GlassProminentButtonStyle: ButtonStyle {
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, tint: appearance.accent.color)
    }
}

public extension ButtonStyle where Self == GlassActionButtonStyle {
    static var glassAction: GlassActionButtonStyle { GlassActionButtonStyle() }
}

public extension ButtonStyle where Self == GlassProminentButtonStyle {
    static var glassProminentAction: GlassProminentButtonStyle { GlassProminentButtonStyle() }
}
