#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// ElevenLabs tarzı tasarım değerleri (elevenlabs.io stil dosyalarından): süt beyazı ("eggshell") zemin, beyaz kartlar,
/// ince çerçeveler, neredeyse siyah yazı, siyah ana düğme; koyu temada aynı düzen ters renklerle. Renkler pencerenin
/// görünümüne göre anında değişir (tema değişince yeniden açmak gerekmez).
public enum Theme {
    /// Pencere ve panel zemini.
    public static let background: Color = dynamic(light: 0xFDFCFC, dark: 0x0A0A0A)
    /// Kartlar, girişler, araç kutucukları.
    public static let card: Color = dynamic(light: 0xFFFFFF, dark: 0x141414)
    /// İnce çerçeve ve ayırıcılar.
    public static let line: Color = dynamic(light: 0xE5E5E5, dark: 0x262626)
    /// Soluk yüzey (çipler, bölüm seçici izi, hover).
    public static let soft: Color = dynamic(light: 0xF5F5F5, dark: 0x1C1C1C)
    /// Kenar çubuğunda seçili satır.
    public static let selected: Color = dynamic(light: 0xEFEEED, dark: 0x232323)
    /// Ana yazı.
    public static let ink: Color = dynamic(light: 0x0A0A0A, dark: 0xFAFAFA)
    /// Soluk yazı.
    public static let muted: Color = dynamic(light: 0x737373, dark: 0xA3A3A3)
    /// Ana düğme zemini ve üstündeki yazı.
    public static let primary: Color = dynamic(light: 0x171717, dark: 0xFAFAFA)
    public static let onPrimary: Color = dynamic(light: 0xFAFAFA, dark: 0x0A0A0A)
    /// Gömülü Inter yazı tipinin aile adı (OFL; App/Fonts).
    public static let interFamily: String = "Inter Variable"

    /// Açık ve koyu görünüm için iki renkli dinamik renk.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { (appearance: NSAppearance) -> NSColor in
            let isDark: Bool = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(srgbRed: red(hex: isDark ? dark : light), green: green(hex: isDark ? dark : light), blue: blue(hex: isDark ? dark : light), alpha: 1)
        })
        #else
        Color(uiColor: UIColor { (traits: UITraitCollection) -> UIColor in
            let hex: UInt32 = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: red(hex: hex), green: green(hex: hex), blue: blue(hex: hex), alpha: 1)
        })
        #endif
    }

    private static func red(hex: UInt32) -> CGFloat { CGFloat((hex >> 16) & 0xFF) / 255 }
    private static func green(hex: UInt32) -> CGFloat { CGFloat((hex >> 8) & 0xFF) / 255 }
    private static func blue(hex: UInt32) -> CGFloat { CGFloat(hex & 0xFF) / 255 }
}

/// Seçili yazı tipi ailesinde (varsayılan Inter) verilen boyut ve ağırlık.
private struct AppFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    func body(content: Content) -> some View {
        content.font(appearance.font(size: size, weight: weight))
    }
}

public extension View {
    /// Mac'te tıklanabilir öğede el imleci (iPhone'da imleç yok, değişmez).
    @ViewBuilder
    func linkPointer(isEnabled: Bool) -> some View {
        #if os(macOS)
        pointerStyle(isEnabled ? .link : nil)
        #else
        self
        #endif
    }

    /// Ayarlar › Görünüm'deki yazı tipi ailesinde (varsayılan Inter) yazı.
    func appFont(size: CGFloat, weight: Font.Weight) -> some View {
        modifier(AppFont(size: size, weight: weight))
    }

    /// Kart yüzeyi: zeminden ayrılan beyaz kart, ince çerçeve, çok hafif gölge.
    func cardSurface(cornerRadius: CGFloat) -> some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Theme.card, in: shape)
            .overlay(shape.strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    }
}
