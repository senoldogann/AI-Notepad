import SwiftUI

/// Arayüzün tek kaynaklı ölçüleri (tasarım belgesi §4.3).
public enum DesignTokens {
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
    }

    public static let panelRadius: CGFloat = 22
    public static let chipRadius: CGFloat = 10
    /// Kesinleşmemiş metnin opaklığı: konuşulurken gelen metin okunur olsun (çok soluk metin "henüz gelmedi" gibi
    /// görünüyordu), kesinleşince tam koyulaşır.
    public static let partialOpacity: Double = 0.72
    /// "Sen" vurgu rengi.
    public static let meColor: Color = Color(hex: 0x3B5BDB)
    /// Kişi renkleri; 7. kişiden itibaren başa döner.
    /// Konuşmacı renkleri: sade arayüzde bağırmayan, aynı açıklıkta, doygunluğu düşük tonlar (adaçayı, kum, gül
    /// kurusu, alacakaranlık, arduvaz, zeytin); yalnızca küçük işaretlerde ve soluk zeminlerde kullanılır.
    public static let personPalette: [Color] = [0x5E8C78, 0xB98552, 0xAD6878, 0x7770A6, 0x5A889E, 0x878A55].map(Color.init(hex:))
    /// "Sen"in konuşmacı rengi (vurgu rengi seçeneğinden ayrı; aynı sade tonda).
    public static let meSpeakerColor: Color = Color(hex: 0x5A6EA8)
    public static let labelTracking: CGFloat = 0.6
}

/// 1 tabanlı kişi numarasının rengi.
public func personColor(person: Int) -> Color {
    let palette: [Color] = DesignTokens.personPalette
    return palette[((person - 1) % palette.count + palette.count) % palette.count]
}

public extension Color {
    /// 0xRRGGBB biçiminde sRGB renk.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
