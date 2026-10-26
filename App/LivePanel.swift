import AINotepadUI
import AppKit
import SwiftUI

/// Ekran görüntüsü/kayıt ayarının UserDefaults anahtarı.
let hideFromScreenCaptureKey: String = "hideFromScreenCapture"

/// Panelin ve adanın ekran görüntülerinde ve kayıtlarda görünürlüğü.
/// `.none` gizlemeye çalışır; macOS 15+ ScreenCaptureKit tabanlı yakalamalar bunu her zaman dikkate almaz.
func sharingType(hideFromCapture: Bool) -> NSWindow.SharingType {
    hideFromCapture ? .none : .readOnly
}

/// Kenarlıksız, saydam, arka planından taşınabilen, uygulamayı öne getirmeyen yüzen panel.
/// Cam görünüm içerikteki `TranscriptPanel`'den gelir.
@MainActor
func makeLivePanel(rootView: some View) -> NSPanel {
    let size: NSSize = NSSize(width: 380, height: 520)
    let panel: NSPanel = NSPanel(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless, .nonactivatingPanel, .resizable],
        backing: .buffered,
        defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.minSize = NSSize(width: 300, height: 240)
    panel.contentView = NSHostingView(rootView: rootView)
    if let screen = NSScreen.screens.first {
        let visible: NSRect = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16))
    }
    return panel
}

/// Paneli bir kez oluşturur; gösterir, gizler, ekran görüntüsü ayarını uygular.
@MainActor
final class LivePanelController {
    private let model: AppModel
    private var panel: NSPanel?
    private var hideFromCapture: Bool

    init(model: AppModel, hideFromCapture: Bool) {
        self.model = model
        self.hideFromCapture = hideFromCapture
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func show() {
        let target: NSPanel = panel ?? makeLivePanel(rootView: PanelHost(model: model, onHide: { [weak self] in self?.hide() }))
        target.invalidateShadow()
        target.sharingType = sharingType(hideFromCapture: hideFromCapture)
        panel = target
        target.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Ayar değişince açık panele hemen uygular.
    func setHideFromCapture(hidden: Bool) {
        hideFromCapture = hidden
        panel?.sharingType = sharingType(hideFromCapture: hidden)
    }
}

/// Modeli gözleyip `TranscriptPanel`'e değer olarak veren ince kabuk.
private struct PanelHost: View {
    let model: AppModel
    let onHide: @MainActor () -> Void

    var body: some View {
        TranscriptPanel(state: model.viewState, onHide: onHide, onStop: { model.stopRecording() })
    }
}
