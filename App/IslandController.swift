import AINotepadCore
import AINotepadUI
import AppKit
import Observation
import os
import SwiftUI

private let islandLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Island")

/// Adanın güncel yerleşimi; ekran değişince görünüm yeniden kurulmadan güncellenir.
@MainActor
@Observable
final class IslandLayoutState {
    var layout: IslandLayout

    init(layout: IslandLayout) {
        self.layout = layout
    }
}

/// Çentikteki adanın penceresi: menü çubuğunun üstünde, tüm masaüstlerinde, tıklamayı saydam yerlerden geçirir.
/// Kayıt yokken içerik boştur. Ekran düzeni değişince yeniden konumlanır.
@MainActor
final class IslandController {
    private let model: AppModel
    private let onTap: @MainActor () -> Void
    private var window: NSPanel?
    private var layoutState: IslandLayoutState?
    private var screenObserver: (any NSObjectProtocol)?

    init(model: AppModel, onTap: @escaping @MainActor () -> Void) {
        self.model = model
        self.onTap = onTap
    }

    /// Pencereyi kurar ve ekran değişikliklerini dinlemeye başlar. Ekran yoksa (kapak kapalı, ekran bağlı değil)
    /// ada kurulmaz; ekran gelince kurulur.
    func install() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.relayout()
            }
        }
        relayout()
        observeRecording()
    }

    private func makeWindow(layout: IslandLayout) -> NSPanel {
        let state: IslandLayoutState = IslandLayoutState(layout: layout)
        let panel: NSPanel = NSPanel(contentRect: layout.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Çentikle kaynaşsın diye gölge yok.
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = sharingType(hideFromCapture: UserDefaults.standard.bool(forKey: SettingsKey.hideFromScreenCapture))
        panel.contentView = NSHostingView(rootView: IslandHost(model: model, layoutState: state, onTap: onTap))
        panel.orderFrontRegardless()
        layoutState = state
        return panel
    }

    /// Kayıt yokken pencere fare olaylarını hiç almaz: menü çubuğu ve altındaki alan etkilenmez.
    private func applyRecordingState() {
        window?.ignoresMouseEvents = model.phase == .idle
    }

    /// Kayıt aşaması her değiştiğinde fare durumunu günceller.
    private func observeRecording() {
        applyRecordingState()
        withObservationTracking {
            _ = model.phase
        } onChange: { [weak self] in
            Task { @MainActor in
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

    /// Yerleşimi menü çubuğunun bulunduğu ekrana göre günceller; görünüm yeniden kurulmaz.
    private func relayout() {
        guard let screen = NSScreen.screens.first else {
            islandLogger.error("Ekran bulunamadı; ada ekran bağlanınca kurulacak")
            window?.orderOut(nil)
            return
        }
        let layout: IslandLayout = islandLayout(
            screen: ScreenGeometry(
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryTopLeft: globalAuxiliaryArea(area: screen.auxiliaryTopLeftArea ?? .zero, screenFrame: screen.frame),
                auxiliaryTopRight: globalAuxiliaryArea(area: screen.auxiliaryTopRightArea ?? .zero, screenFrame: screen.frame)
            ),
            wing: islandWing,
            expansion: islandExpansion,
            pillHeight: 32,
            pillWidth: 360,
            pillGap: 8
        )
        guard let window, let layoutState else {
            window = makeWindow(layout: layout)
            applyRecordingState()
            return
        }
        window.setFrame(layout.frame, display: true)
        layoutState.layout = layout
        window.orderFrontRegardless()
    }
}

/// Modeli gözler; kayıt yokken boş, varsa fareyle açılan ada.
private struct IslandHost: View {
    let model: AppModel
    let layoutState: IslandLayoutState
    let onTap: @MainActor () -> Void
    @State private var isExpanded: Bool = false

    var body: some View {
        let state: LiveViewState = model.viewState
        let layout: IslandLayout = layoutState.layout
        if state.isIslandVisible {
            IslandView(
                state: state,
                layout: layout,
                isExpanded: isExpanded,
                onTap: onTap,
                onHover: { (hovering: Bool) -> Void in isExpanded = hovering },
                onStop: { model.stopRecording() },
                onSetLanguage: { (language: MeetingLanguage) -> Void in model.setLanguage(language: language) }
            )
        } else {
            Color.clear
                .frame(width: layout.frame.width, height: layout.frame.height)
                .allowsHitTesting(false)
                // Kayıt imleç adanın üstündeyken bittiyse sonraki kayıt kapalı başlasın.
                .onAppear { isExpanded = false }
        }
    }
}
