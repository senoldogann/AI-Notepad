import CoreGraphics
import Testing
@testable import AINotepadUI

@Suite struct IslandGeometryTests {
    @Test func notchIslandCentersOnNotch() {
        let screen: ScreenGeometry = ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 660, height: 32),
            auxiliaryTopRight: CGRect(x: 852, y: 950, width: 660, height: 32)
        )
        let layout: IslandLayout = islandLayout(screen: screen, wing: 120, expansion: 64, pillHeight: 32, pillWidth: 360, pillGap: 8)
        #expect(layout.hasNotch)
        #expect(layout.frame == CGRect(x: 540, y: 886, width: 432, height: 96))
        #expect(layout.collapsedHeight == 32)
    }

    @Test func pillWithoutNotch() {
        let screen: ScreenGeometry = ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
            safeAreaTop: 0,
            auxiliaryTopLeft: .zero,
            auxiliaryTopRight: .zero
        )
        let layout: IslandLayout = islandLayout(screen: screen, wing: 120, expansion: 64, pillHeight: 32, pillWidth: 360, pillGap: 8)
        #expect(!layout.hasNotch)
        #expect(layout.frame == CGRect(x: 780, y: 951, width: 360, height: 96))
        #expect(layout.collapsedHeight == 32)
    }

    @Test func secondScreenOffsetIsRespected() {
        let screen: ScreenGeometry = ScreenGeometry(
            frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055),
            safeAreaTop: 0,
            auxiliaryTopLeft: .zero,
            auxiliaryTopRight: .zero
        )
        let layout: IslandLayout = islandLayout(screen: screen, wing: 120, expansion: 64, pillHeight: 32, pillWidth: 360, pillGap: 8)
        #expect(layout.frame.midX == CGFloat(1512 + 960))
    }

    // İkincil ekrandaki (başlangıcı 0 olmayan) çentik alanı genel koordinatlara taşınır; birincil ekranda değişmez.
    @Test func auxiliaryAreaMovesToGlobalCoordinates() {
        let secondary: CGRect = CGRect(x: -1512, y: 0, width: 1512, height: 982)
        let local: CGRect = CGRect(x: 0, y: 950, width: 660, height: 32)
        #expect(globalAuxiliaryArea(area: local, screenFrame: secondary) == CGRect(x: -1512, y: 950, width: 660, height: 32))
        let primary: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(globalAuxiliaryArea(area: local, screenFrame: primary) == local)
        #expect(globalAuxiliaryArea(area: .zero, screenFrame: secondary) == .zero)
    }

    // Küçük ekranda panel ekrana sığacak kadar küçülür; ekran dışına taşan panel içeri çekilir.
    @Test func panelFrameClampsToScreen() {
        let small: CGRect = CGRect(x: 0, y: 0, width: 1280, height: 600)
        let clamped: CGRect = clampedPanelFrame(frame: CGRect(x: 900, y: 100, width: 420, height: 660), visible: small, minSize: CGSize(width: 340, height: 300), margin: 16)
        #expect(clamped == CGRect(x: 844, y: 16, width: 420, height: 568))
        let offscreen: CGRect = clampedPanelFrame(frame: CGRect(x: 3000, y: 900, width: 420, height: 400), visible: small, minSize: CGSize(width: 340, height: 300), margin: 16)
        #expect(offscreen.maxX == 1264)
        #expect(offscreen.maxY == 584)
    }
}
