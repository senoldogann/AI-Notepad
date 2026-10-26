import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Panelin ve adanın ekran görüntülerinde ve kayıtlarda görünürlüğü.
/// `.none` gizlemeye çalışır; macOS 15+ ScreenCaptureKit tabanlı yakalamalar bunu her zaman dikkate almaz.
func sharingType(hideFromCapture: Bool) -> NSWindow.SharingType {
    hideFromCapture ? .none : .readOnly
}

/// Kenarlıksız panel normalde anahtar pencere olamaz; soru alanına, ayarlara yazılabilmesi ve metin seçimi için olabilir.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

/// Panelin en küçük boyutu; tüm sayfalar bu boyuta kadar düzenini korur.
let panelMinSize: NSSize = NSSize(width: 340, height: 300)

/// Kenarlıksız, saydam, arka planından taşınabilen, uygulamayı öne getirmeyen yüzen panel.
/// Cam görünüm içerikteki `panelSurface()`'ten gelir.
@MainActor
func makeLivePanel(rootView: some View) -> NSPanel {
    // Küçük ekranda panel ekrana sığacak boyutta açılır.
    let visible: CGRect = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 420, height: 660)
    let size: NSSize = clampedPanelFrame(
        frame: CGRect(x: visible.maxX - 436, y: visible.maxY - 676, width: 420, height: 660),
        visible: visible, minSize: panelMinSize, margin: 16
    ).size
    let panel: NSPanel = KeyablePanel(
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
    panel.minSize = panelMinSize
    // İçerik panelin köşe yarıçapıyla maskelenir: köşeler tamamen saydam kalır, pencere gölgesi ve kenar çizgisi
    // dikdörtgen değil yuvarlak çıkar.
    let container: NSView = NSView(frame: NSRect(origin: .zero, size: size))
    container.wantsLayer = true
    container.layer?.cornerRadius = DesignTokens.panelRadius
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = true
    let hosting: NSHostingView = NSHostingView(rootView: rootView)
    hosting.frame = container.bounds
    hosting.autoresizingMask = [.width, .height]
    container.addSubview(hosting)
    panel.contentView = container
    panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16))
    return panel
}

/// Uygulamanın tek penceresi olan paneli bir kez oluşturur; sayfa açar, gösterir, gizler, ekran görüntüsü
/// ayarını uygular.
@MainActor
final class LivePanelController {
    private let model: AppModel
    private let router: PanelRouter = PanelRouter()
    private let player: MeetingAudioPlayer = MeetingAudioPlayer()
    private var panel: NSPanel?
    private var hideFromCapture: Bool
    private var shortcuts: ShortcutController?
    private var onStart: (@MainActor () -> Void)?

    init(model: AppModel, hideFromCapture: Bool) {
        self.model = model
        self.hideFromCapture = hideFromCapture
        // Ekran değişince (monitör çıkarıldı, çözünürlük değişti) panel görünür alanın içine çekilir.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.keepOnScreen()
            }
        }
    }

    private var screenObserver: (any NSObjectProtocol)?

    /// Paneli bulunduğu (yoksa ana) ekranın görünür alanına sığdırır.
    private func keepOnScreen() {
        guard let panel, let screen = panel.screen ?? NSScreen.screens.first else {
            return
        }
        let frame: CGRect = clampedPanelFrame(frame: panel.frame, visible: screen.visibleFrame, minSize: panelMinSize, margin: 8)
        if frame != panel.frame {
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    /// Kısayollar ve kayıt başlatma eylemi panelden sonra kurulduğu için ilk gösterimden önce bağlanır.
    func attach(shortcuts: ShortcutController, onStart: @escaping @MainActor () -> Void) {
        self.shortcuts = shortcuts
        self.onStart = onStart
        observeFinishedMeetings()
    }

    /// Kayıt bitince panel (gizli olsa da) o toplantının sayfasında açılır: toplantıdan çıkınca ilk bakılacak şey
    /// kime ne düştüğüdür.
    private func observeFinishedMeetings() {
        withObservationTracking {
            _ = model.lastFinishedMeetingID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else {
                    return
                }
                if let id = self.model.lastFinishedMeetingID {
                    self.show(page: .meeting(id: id))
                }
                self.observeFinishedMeetings()
            }
        }
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Paneli gösterir (açık sayfa değişmez).
    func show() {
        guard let shortcuts, let onStart else {
            preconditionFailure("Panel, attach(shortcuts:onStart:) çağrılmadan gösterildi")
        }
        let target: NSPanel = panel ?? makeLivePanel(rootView: PanelHost(
            model: model, router: router, shortcuts: shortcuts, player: player, onStart: onStart,
            onHide: { [weak self] in self?.hide() }
        ))
        target.sharingType = sharingType(hideFromCapture: hideFromCapture)
        panel = target
        target.orderFrontRegardless()
        // Gölge içerik çizildikten sonra (yuvarlak köşelerle) yeniden hesaplanır.
        DispatchQueue.main.async {
            target.invalidateShadow()
        }
    }

    /// Paneli belirtilen sayfada gösterir; yazı alanları için anahtar pencere yapar.
    func show(page: PanelPage) {
        router.page = page
        show()
        panel?.makeKey()
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
