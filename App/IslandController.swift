import AINotepadUI
import AppKit
import SwiftUI

/// Çentikteki adanın penceresi: menü çubuğunun üstünde, tüm masaüstlerinde, tıklamayı saydam yerlerden geçirir.
/// Kayıt yokken içerik boştur. Ekran düzeni değişince yeniden konumlanır.
@MainActor
final class IslandController {
    private let model: AppModel
    private let onTap: @MainActor () -> Void
    private var window: NSPanel?
    private var screenObserver: (any NSObjectProtocol)?

    init(model: AppModel, onTap: @escaping @MainActor () -> Void) {
        self.model = model
        self.onTap = onTap
    }

    /// Pencereyi kurar ve ekran değişikliklerini dinlemeye başlar.
    func install(hideFromCapture: Bool) {
        let layout: IslandLayout = currentLayout()
        let panel: NSPanel = NSPanel(contentRect: layout.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Çentikle kaynaşsın diye gölge yok.
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = sharingType(hideFromCapture: hideFromCapture)
        panel.contentView = NSHostingView(rootView: IslandHost(model: model, layout: layout, onTap: onTap))
        panel.orderFrontRegardless()
        window = panel
        applyRecordingState()
        observeRecording()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.relayout()
            }
        }
    }

    /// Kayıt yokken pencere fare olaylarını hiç almaz: menü çubuğu ve altındaki alan etkilenmez.
    private func applyRecordingState() {
        window?.ignoresMouseEvents = !model.isRecording
    }

    /// `isRecording` her değiştiğinde fare durumunu günceller.
    private func observeRecording() {
        withObservationTracking {
            _ = model.isRecording
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyRecordingState()
                self?.observeRecording()
            }
        }
    }

    func setHideFromCapture(hidden: Bool) {
        window?.sharingType = sharingType(hideFromCapture: hidden)
    }

    func show() {
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func relayout() {
        guard let window else {
            return
        }
        let layout: IslandLayout = currentLayout()
        window.setFrame(layout.frame, display: true)
        window.contentView = NSHostingView(rootView: IslandHost(model: model, layout: layout, onTap: onTap))
    }

    /// Menü çubuğunun bulunduğu birincil ekrana göre yerleşim.
    private func currentLayout() -> IslandLayout {
        let screen: NSScreen? = NSScreen.screens.first
        return islandLayout(
            screen: ScreenGeometry(
                frame: screen?.frame ?? .zero,
                visibleFrame: screen?.visibleFrame ?? .zero,
                safeAreaTop: screen?.safeAreaInsets.top ?? 0,
                auxiliaryTopLeft: screen?.auxiliaryTopLeftArea ?? .zero,
                auxiliaryTopRight: screen?.auxiliaryTopRightArea ?? .zero
            ),
            wing: islandWing,
            expansion: islandExpansion,
            pillHeight: 32,
            pillWidth: 360,
            pillGap: 8
        )
    }
}

/// Modeli gözler; kayıt yokken boş, varsa fareyle açılan ada.
private struct IslandHost: View {
    let model: AppModel
    let layout: IslandLayout
    let onTap: @MainActor () -> Void
    @State private var isExpanded: Bool = false

    var body: some View {
        let state: LiveViewState = model.viewState
        if state.isIslandVisible {
            IslandView(
                state: state,
                layout: layout,
                isExpanded: isExpanded,
                onTap: onTap,
                onHover: { (hovering: Bool) -> Void in isExpanded = hovering }
            )
        } else {
            Color.clear
                .frame(width: layout.frame.width, height: layout.frame.height)
                .allowsHitTesting(false)
        }
    }
}
