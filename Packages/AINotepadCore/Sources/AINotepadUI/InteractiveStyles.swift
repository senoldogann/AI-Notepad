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
                    .fill(highlight)
                    .padding(-hoverOutset)
            }
            // Devre dışıyken soluk: tıklanabilir görünmesin.
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { (hovering: Bool) -> Void in isHovering = hovering }
            .linkPointer(isEnabled: isEnabled)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    /// Hover'da soluk yüzey, basılıyken seçili satır tonu (ElevenLabs).
    private var highlight: Color {
        guard isEnabled else {
            return .clear
        }
        if isPressed {
            return Theme.selected
        }
        return isHovering ? Theme.soft : .clear
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
            // Basılınca hafifçe küçülür (tıklama hissedilsin).
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == HoverPlainButtonStyle {
    /// Satır ve simge düğmeleri.
    static var hoverPlain: HoverPlainButtonStyle { HoverPlainButtonStyle(cornerRadius: 7) }
}

/// Liquid Glass'ta kapsül düğmenin gövdesi: fare üstündeyken ya da basılıyken arkasında etkileşimli cam belirir
/// (boştayken cam yok: düğmenin kendi zemini görünür). El imleci ve devre dışı soluklaşma Standart'taki gibi.
private struct GlassHoverCapsuleBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled: Bool
    @Environment(\.designLook) private var look: DesignLook
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var isHovering: Bool = false

    var body: some View {
        let isActive: Bool = isEnabled && (isHovering || configuration.isPressed)
        configuration.label
            .contentShape(Capsule())
            // Cam içerikten biraz büyük çizilir; yerleşim değişmez (dolgu eklenip geri alınır).
            .padding(hoverOutset)
            .glassEffect(isActive ? look.interactiveGlass(colorScheme: colorScheme) : .identity, in: Capsule())
            .padding(-hoverOutset)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { (hovering: Bool) -> Void in isHovering = hovering }
            .linkPointer(isEnabled: isEnabled)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Kapsül ve yuvarlak düğmeler (vurgu hapları, oynat düğmesi, seçici bölümleri): vurgu da kapsül biçiminde. Standart'ta
/// `hoverPlain` ile aynı davranış; Liquid Glass'ta fare üstündeyken etkileşimli cam.
public struct HoverCapsuleButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HoverCapsuleBody(configuration: configuration)
    }
}

/// Kapsül düğmenin gövdesi: stile göre Standart vurgu ya da cam.
private struct HoverCapsuleBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.designLook) private var look: DesignLook

    var body: some View {
        switch look.style {
        case .standard:
            // Yarıçap yüksekliğin yarısını aşınca köşeler tam yuvarlanır.
            HoverPlainButtonStyle(cornerRadius: 1000).makeBody(configuration: configuration)
        case .liquidGlass:
            GlassHoverCapsuleBody(configuration: configuration)
        }
    }
}

public extension ButtonStyle where Self == HoverCapsuleButtonStyle {
    /// Kapsül ve yuvarlak düğmeler (bkz. `HoverCapsuleButtonStyle`).
    static var hoverCapsule: HoverCapsuleButtonStyle { HoverCapsuleButtonStyle() }
}

/// Hap düğmenin boyutu: denetim boyutuna göre dolgu ve yazı.
private struct PillMetrics {
    let horizontal: CGFloat
    let vertical: CGFloat
    let size: CGFloat
}

/// Denetim boyutunun hap ölçüleri. Saf fonksiyondur.
private func pillMetrics(controlSize: ControlSize) -> PillMetrics {
    switch controlSize {
    case .mini, .small: PillMetrics(horizontal: 11, vertical: 5, size: 12)
    case .large, .extraLarge: PillMetrics(horizontal: 18, vertical: 10, size: 15)
    default: PillMetrics(horizontal: 14, vertical: 7, size: 13)
    }
}

/// Hap düğmenin gövdesi (ElevenLabs): ikincil beyaz zemin + ince çerçeve, ana düğme siyah (koyu temada beyaz).
/// Fare üstündeyken zemin hafif değişir, basılınca küçülür, el imleci gösterir; etkin değilse soluk.
private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isPrimary: Bool
    @Environment(\.isEnabled) private var isEnabled: Bool
    @Environment(\.controlSize) private var controlSize: ControlSize
    @Environment(\.designLook) private var look: DesignLook
    @State private var isHovering: Bool = false

    var body: some View {
        switch look.style {
        case .standard:
            standardBody
        case .liquidGlass:
            GlassPillBody(configuration: configuration, isPrimary: isPrimary)
        }
    }

    private var standardBody: some View {
        let metrics: PillMetrics = pillMetrics(controlSize: controlSize)
        return configuration.label
            .appFont(size: metrics.size, weight: .medium)
            .foregroundStyle(foreground)
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(isPrimary ? Color.clear : Theme.line))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled || isPrimary ? 1 : 0.45)
            .onHover { (hovering: Bool) -> Void in isHovering = hovering }
            .linkPointer(isEnabled: isEnabled)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    // Pasif ana düğme soluk griye döner (yarı saydam siyah bulanık bir leke gibi duruyordu).
    private var background: Color {
        if isPrimary {
            return isEnabled ? Theme.primary.opacity(isHovering ? 0.85 : 1) : Theme.soft
        }
        return isEnabled && isHovering ? Theme.soft : Theme.card
    }

    private var foreground: Color {
        if isPrimary {
            return isEnabled ? Theme.onPrimary : Theme.muted
        }
        return configuration.role == .destructive ? Color(red: 0.86, green: 0.15, blue: 0.15) : Theme.ink
    }
}

/// Liquid Glass hap düğme: etkileşimli cam kapsül (basınca cam tepki verir). İkincil düğme cam renginde, ana düğme
/// ana renkle (siyah; koyu temada beyaz) tonlanmış cam; yazılar Standart'taki renklerde kalır.
private struct GlassPillBody: View {
    let configuration: ButtonStyleConfiguration
    let isPrimary: Bool
    @Environment(\.isEnabled) private var isEnabled: Bool
    @Environment(\.controlSize) private var controlSize: ControlSize
    @Environment(\.designLook) private var look: DesignLook
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    var body: some View {
        let metrics: PillMetrics = pillMetrics(controlSize: controlSize)
        configuration.label
            .appFont(size: metrics.size, weight: .medium)
            .foregroundStyle(foreground)
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .contentShape(Capsule())
            // Ana düğmede dolgu düz kalır, cam üstte kenar ve parıltı olur: camı ana renkle tonlamak (yarı saydam)
            // siyahı açık griye çeviriyor, beyaz yazı okunmuyordu.
            .background(isPrimary && isEnabled ? Theme.primary : Color.clear, in: Capsule())
            .glassEffect(look.interactiveGlass(colorScheme: colorScheme), in: Capsule())
            .opacity(isEnabled || isPrimary ? 1 : 0.45)
            .linkPointer(isEnabled: isEnabled)
    }

    private var foreground: Color {
        if isPrimary {
            return isEnabled ? Theme.onPrimary : Theme.muted
        }
        return configuration.role == .destructive ? Color(red: 0.86, green: 0.15, blue: 0.15) : Theme.ink
    }
}

/// İkincil düğme (varsayılan; panel ve ana pencerenin kökünde verilir): beyaz hap, ince çerçeve.
public struct PillButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, isPrimary: false)
    }
}

/// Ana eylem ("Kaydı başlat", "İleri"): siyah hap (koyu temada beyaz).
public struct PrimaryPillButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, isPrimary: true)
    }
}

public extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
}

public extension ButtonStyle where Self == PrimaryPillButtonStyle {
    static var pillPrimary: PrimaryPillButtonStyle { PrimaryPillButtonStyle() }
}
