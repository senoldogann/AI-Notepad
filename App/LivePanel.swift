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
    // Ekran paylaşımında gizlenmeye çalışır; macOS 15+ ScreenCaptureKit bunu her zaman dikkate almaz.
    panel.sharingType = .none
    panel.contentView = NSHostingView(rootView: rootView)
    if let screen = NSScreen.main {
        let visible: NSRect = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16))
    }
    return panel
}

/// Canlı paneli bir kez oluşturur ve gösterir.
@MainActor
final class LivePanelController {
    private let model: AppModel
    private var panel: NSPanel?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let target: NSPanel = panel ?? makeLivePanel(rootView: LiveTranscriptView(model: model))
        panel = target
        target.orderFrontRegardless()
    }
}
