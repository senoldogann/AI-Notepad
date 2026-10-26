import CoreGraphics

/// Adanın yerleşimi için gereken ekran bilgileri (AppKit `NSScreen`'den doldurulur).
public struct ScreenGeometry: Sendable, Equatable {
    public let frame: CGRect
    public let visibleFrame: CGRect
    /// Çentikli ekranda menü çubuğu yüksekliği (`safeAreaInsets.top`); çentiksizde 0.
    public let safeAreaTop: CGFloat
    /// Çentiğin solundaki ve sağındaki kullanılabilir alanlar; çentik yoksa boş.
    public let auxiliaryTopLeft: CGRect
    public let auxiliaryTopRight: CGRect

    public init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeft: CGRect, auxiliaryTopRight: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
    }
}

/// Ada penceresinin çerçevesi; pencere açılma payını da içerir.
public struct IslandLayout: Sendable, Equatable {
    public let frame: CGRect
    public let hasNotch: Bool
    /// Kapalıyken içeriğin yüksekliği (pencerenin üst şeridi).
    public let collapsedHeight: CGFloat
}

/// Çentik alanlarını genel (tüm ekranlar) koordinatlara çevirir: alan ekranın kendi koordinatlarında verilmişse
/// (ikincil ekranda çerçevenin dışında kalır) ekran başlangıcı eklenir. Saf fonksiyondur.
public func globalAuxiliaryArea(area: CGRect, screenFrame: CGRect) -> CGRect {
    guard !area.isEmpty, !screenFrame.contains(CGPoint(x: area.midX, y: area.midY)) else {
        return area
    }
    return area.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
}

/// Çentikli ekranda çentiğe yapışık ada, çentiksiz ekranda menü çubuğunun altında ortalanmış hap. Saf fonksiyondur.
public func islandLayout(
    screen: ScreenGeometry,
    wing: CGFloat,
    expansion: CGFloat,
    pillHeight: CGFloat,
    pillWidth: CGFloat,
    pillGap: CGFloat
) -> IslandLayout {
    let hasNotch: Bool = screen.safeAreaTop > 0 && !screen.auxiliaryTopLeft.isEmpty && !screen.auxiliaryTopRight.isEmpty
    guard hasNotch else {
        let top: CGFloat = screen.visibleFrame.maxY - pillGap
        let height: CGFloat = pillHeight + expansion
        return IslandLayout(
            frame: CGRect(x: screen.frame.midX - pillWidth / 2, y: top - height, width: pillWidth, height: height),
            hasNotch: false,
            collapsedHeight: pillHeight
        )
    }
    let notchMinX: CGFloat = screen.auxiliaryTopLeft.maxX
    let notchWidth: CGFloat = screen.auxiliaryTopRight.minX - notchMinX
    let height: CGFloat = screen.safeAreaTop + expansion
    return IslandLayout(
        frame: CGRect(x: notchMinX - wing, y: screen.frame.maxY - height, width: notchWidth + 2 * wing, height: height),
        hasNotch: true,
        collapsedHeight: screen.safeAreaTop
    )
}
