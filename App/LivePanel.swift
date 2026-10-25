import AppKit
import SwiftUI

/// Zoom/Teams'in üstünde duran, uygulamayı öne getirmeyen yüzen panel oluşturur.
@MainActor
func makeLivePanel(rootView: some View) -> NSPanel {
    let size: NSSize = NSSize(width: 380, height: 520)
    let panel: NSPanel = NSPanel(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
        backing: .buffered,
        defer: false
    )
    panel.title = "AI-Notepad"
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = NSHostingView(rootView: rootView)
    if let screen = NSScreen.main {
        let visible: NSRect = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16))
    }
    return panel
}

/// Ekran görüntüsü/kayıt ayarının UserDefaults anahtarı.
let hideFromScreenCaptureKey: String = "hideFromScreenCapture"

/// Panelin ekran görüntülerinde ve kayıtlarda görünürlüğü.
/// `.none` gizlemeye çalışır; macOS 15+ ScreenCaptureKit tabanlı yakalamalar bunu her zaman dikkate almaz.
func sharingType(hideFromCapture: Bool) -> NSWindow.SharingType {
    hideFromCapture ? .none : .readOnly
}

/// Canlı paneli bir kez oluşturur, gösterir ve ekran görüntüsü ayarını uygular.
@MainActor
final class LivePanelController {
    private let model: AppModel
    private var panel: NSPanel?
    private var hideFromCapture: Bool

    init(model: AppModel, hideFromCapture: Bool) {
        self.model = model
        self.hideFromCapture = hideFromCapture
    }

    func show() {
        let target: NSPanel = panel ?? makeLivePanel(rootView: LiveTranscriptView(model: model))
        target.sharingType = sharingType(hideFromCapture: hideFromCapture)
        panel = target
        target.orderFrontRegardless()
    }

    /// Ayar değişince açık panele hemen uygular.
    func setHideFromCapture(hidden: Bool) {
        hideFromCapture = hidden
        panel?.sharingType = sharingType(hideFromCapture: hidden)
    }
}
