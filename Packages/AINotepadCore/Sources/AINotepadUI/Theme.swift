#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Observation
import SwiftUI

/// Bir tema takımının renkleri (tek görünüm için: açık ya da koyu).
public struct ThemeColorSet: Equatable, Sendable {
    public let background: UInt32
    public let card: UInt32
    public let line: UInt32
    public let soft: UInt32
    public let selected: UInt32
    public let ink: UInt32
    public let muted: UInt32
    public let primary: UInt32
    public let onPrimary: UInt32

    public init(background: UInt32, card: UInt32, line: UInt32, soft: UInt32, selected: UInt32, ink: UInt32, muted: UInt32, primary: UInt32, onPrimary: UInt32) {
        self.background = background
        self.card = card
        self.line = line
        self.soft = soft
        self.selected = selected
        self.ink = ink
        self.muted = muted
        self.primary = primary
        self.onPrimary = onPrimary
    }

    /// ElevenLabs açık: süt beyazı zemin, beyaz kart, neredeyse siyah yazı.
    public static let light: ThemeColorSet = ThemeColorSet(
        background: 0xFDFCFC, card: 0xFFFFFF, line: 0xE5E5E5, soft: 0xF5F5F5, selected: 0xEFEEED, ink: 0x0A0A0A, muted: 0x737373, primary: 0x171717, onPrimary: 0xFAFAFA
    )
    /// ElevenLabs koyu: aynı düzen ters renklerle.
    public static let dark: ThemeColorSet = ThemeColorSet(
        background: 0x0A0A0A, card: 0x141414, line: 0x262626, soft: 0x1C1C1C, selected: 0x232323, ink: 0xFAFAFA, muted: 0xA3A3A3, primary: 0xFAFAFA, onPrimary: 0x0A0A0A
    )
    /// Kâğıt: krem zemin, sıcak kahve yazı (uzun okuma).
    public static let paper: ThemeColorSet = ThemeColorSet(
        background: 0xF6F1E8, card: 0xFCF9F3, line: 0xE2DACC, soft: 0xEFE8DB, selected: 0xE8DFD0, ink: 0x2B2520, muted: 0x8A7E70, primary: 0x2B2520, onPrimary: 0xFCF9F3
    )
    /// Kum: taş grisi zemin, serin nötr yazı.
    public static let sand: ThemeColorSet = ThemeColorSet(
        background: 0xF1F0EC, card: 0xFAFAF8, line: 0xDCDAD4, soft: 0xE9E7E1, selected: 0xE1DFD8, ink: 0x1C1B19, muted: 0x74726C, primary: 0x1C1B19, onPrimary: 0xFAFAF8
    )
    /// Gece: lacivert siyah zemin, buz beyazı yazı.
    public static let midnight: ThemeColorSet = ThemeColorSet(
        background: 0x0B0F1A, card: 0x131A29, line: 0x222B3E, soft: 0x182033, selected: 0x1D2738, ink: 0xF2F4F8, muted: 0x9AA3B5, primary: 0xF2F4F8, onPrimary: 0x0B0F1A
    )
    /// Grafit: ılık koyu gri zemin, yumuşak beyaz yazı (saf siyahtan daha az sert).
    public static let graphite: ThemeColorSet = ThemeColorSet(
        background: 0x1A1A1C, card: 0x242427, line: 0x333337, soft: 0x2A2A2E, selected: 0x303035, ink: 0xF5F5F4, muted: 0xA9A9A6, primary: 0xF5F5F4, onPrimary: 0x1A1A1C
    )
}

/// Tema takımları: Sistem (ElevenLabs açık/koyu, sistemi izler), Açık, Koyu ve kendi renk takımı olan temalar. Mac ve
/// iPhone aynı ayarı (`appearance.theme`) kullanır.
public enum AppTheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark
    case paper
    case sand
    case midnight
    case graphite

    /// Takımın görünümü koyu mu (Sistem'de nil: sistemi izler). Saf fonksiyondur.
    public var isDark: Bool? {
        switch self {
        case .system: nil
        case .light, .paper, .sand: false
        case .dark, .midnight, .graphite: true
        }
    }

    /// Açık ve koyu görünüm için renk takımları; sabit görünümlü temalarda ikisi de aynıdır. Saf fonksiyondur.
    public var colorSets: (light: ThemeColorSet, dark: ThemeColorSet) {
        switch self {
        case .system: (.light, .dark)
        case .light: (.light, .light)
        case .dark: (.dark, .dark)
        case .paper: (.paper, .paper)
        case .sand: (.sand, .sand)
        case .midnight: (.midnight, .midnight)
        case .graphite: (.graphite, .graphite)
        }
    }

    /// Arayüzdeki adı.
    public var displayName: String {
        switch self {
        case .system: String(localized: "Sistem")
        case .light: String(localized: "Açık")
        case .dark: String(localized: "Koyu")
        case .paper: String(localized: "Kâğıt")
        case .sand: String(localized: "Kum")
        case .midnight: String(localized: "Gece")
        case .graphite: String(localized: "Grafit")
        }
    }
}

/// Seçili tema takımı: açık ve koyu görünüm için birer renk takımı. Uygulama Ayarlar › Görünüm'den değiştirir;
/// `Theme` renklerini okuyan her görünüm gözlemle yeniden çizilir.
@MainActor
@Observable
public final class ThemeStore {
    public static let shared: ThemeStore = ThemeStore()

    public private(set) var light: ThemeColorSet = .light
    public private(set) var dark: ThemeColorSet = .dark
    /// Takımın rolleri için oluşturulmuş renkler. Her erişimde yeni dinamik renk oluşturulsaydı SwiftUI eski ve yeni
    /// rengi hiç eşit bulmaz, rengi okuyan her görünümü her güncellemede yeniden işlerdi (çalma sırasında saniyede
    /// onlarca kez tüm pencerenin yerleşimi). Takım değişince boşaltılır.
    @ObservationIgnored private var colors: [KeyPath<ThemeColorSet, UInt32>: Color] = [:]

    private init() {}

    /// Takımları değiştirir (ör. Kâğıt: ikisi de kâğıt; Sistem: ElevenLabs açık ve koyu).
    public func set(light: ThemeColorSet, dark: ThemeColorSet) {
        colors = [:]
        self.light = light
        self.dark = dark
    }

    /// Rolün açık ve koyu görünüme göre değişen rengi; takım başına bir kez oluşturulur. Takımlar her erişimde okunur
    /// (gözlem): takım değişince rengi okuyan görünümler yenilenir.
    func color(role: KeyPath<ThemeColorSet, UInt32>) -> Color {
        let lightHex: UInt32 = light[keyPath: role]
        let darkHex: UInt32 = dark[keyPath: role]
        if let cached = colors[role] {
            return cached
        }
        let made: Color = dynamicColor(light: lightHex, dark: darkHex)
        colors[role] = made
        return made
    }
}

/// Açık ve koyu görünüm için iki renkli dinamik renk.
private func dynamicColor(light: UInt32, dark: UInt32) -> Color {
    #if os(macOS)
    return Color(nsColor: NSColor(name: nil) { (appearance: NSAppearance) -> NSColor in
        let hex: UInt32 = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: hexRed(hex), green: hexGreen(hex), blue: hexBlue(hex), alpha: 1)
    })
    #else
    return Color(uiColor: UIColor { (traits: UITraitCollection) -> UIColor in
        let hex: UInt32 = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: hexRed(hex), green: hexGreen(hex), blue: hexBlue(hex), alpha: 1)
    })
    #endif
}

private func hexRed(_ hex: UInt32) -> CGFloat { CGFloat((hex >> 16) & 0xFF) / 255 }
private func hexGreen(_ hex: UInt32) -> CGFloat { CGFloat((hex >> 8) & 0xFF) / 255 }
private func hexBlue(_ hex: UInt32) -> CGFloat { CGFloat(hex & 0xFF) / 255 }

/// ElevenLabs tarzı tasarım değerleri (elevenlabs.io stil dosyalarından): süt beyazı ("eggshell") zemin, beyaz kartlar,
/// ince çerçeveler, neredeyse siyah yazı, siyah ana düğme; koyu temada aynı düzen ters renklerle. Renkler pencerenin
/// görünümüne göre anında değişir; takım `ThemeStore` ile seçilir (Kâğıt, Gece, Grafit…).
@MainActor
public enum Theme {
    /// Pencere ve panel zemini.
    public static var background: Color { dynamic(\.background) }
    /// Kartlar, girişler, araç kutucukları.
    public static var card: Color { dynamic(\.card) }
    /// İnce çerçeve ve ayırıcılar.
    public static var line: Color { dynamic(\.line) }
    /// Soluk yüzey (çipler, bölüm seçici izi, hover).
    public static var soft: Color { dynamic(\.soft) }
    /// Kenar çubuğunda seçili satır.
    public static var selected: Color { dynamic(\.selected) }
    /// Ana yazı.
    public static var ink: Color { dynamic(\.ink) }
    /// Soluk yazı.
    public static var muted: Color { dynamic(\.muted) }
    /// Ana düğme zemini ve üstündeki yazı.
    public static var primary: Color { dynamic(\.primary) }
    public static var onPrimary: Color { dynamic(\.onPrimary) }
    /// Gömülü Inter yazı tipinin aile adı (OFL; App/Fonts).
    nonisolated public static let interFamily: String = "Inter Variable"

    /// Seçili takımların verilen rolü (bkz. `ThemeStore.color`).
    private static func dynamic(_ role: KeyPath<ThemeColorSet, UInt32>) -> Color {
        ThemeStore.shared.color(role: role)
    }
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
}
