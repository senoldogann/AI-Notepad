import AINotepadUI
import AppKit
import SwiftUI

/// Sor sayfasının soru alanında sayfaya sorulan klavye komutları.
enum AskInputCommand {
    /// Enter (Shift'siz): soruyu gönderir ya da açık öneriyi seçer.
    case submit
    /// ↑
    case moveUp
    /// ↓
    case moveDown
    /// Tab: açık öneriyi seçer.
    case complete
    /// Esc
    case cancel
}

/// Sor sayfasının çok satırlı soru alanı (AppKit metin görünümü): Enter gönderir, Shift+Enter (ve Option+Enter) yeni
/// satır ekler. Japonca/Çince gibi giriş yöntemlerinde birleştirme sürerken (işaretli metin varken) tuşlar giriş
/// yöntemine bırakılır; Enter göndermez. Alan `maxLines` satıra kadar büyür, sonra kayar. İmleç konumu (UTF-16) `@`
/// bahsini bulmak için sayfaya bildirilir. ↑, ↓, Tab ve Esc önce sayfaya sorulur (`onCommand` true dönerse işlenmiştir);
/// işlenmeyen ↑/↓ imleci taşır, Tab odağı sonraki öğeye geçirir.
struct AskInputField: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursor: Int
    let accessibilityLabel: String
    let font: NSFont
    let textColor: NSColor
    let maxLines: Int
    /// Her değiştiğinde alan odağı alır (ilk görünüşte de).
    let focusRequest: Int
    let onFocusChange: @MainActor (Bool) -> Void
    let onCommand: @MainActor (AskInputCommand) -> Bool

    func makeCoordinator() -> AskInputCoordinator {
        AskInputCoordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView: AskTextView = AskTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        let scrollView: NSScrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator: AskInputCoordinator = context.coordinator
        coordinator.parent = self
        let textView: AskTextView = askTextView(scrollView: scrollView)
        if textView.font != font {
            textView.font = font
        }
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.onFocusChange = onFocusChange
        // Metin sayfadan değiştiyse (öneri seçildi, soru gönderildi, ↑ ile geri geldi) görünüme yazılır; yazım
        // birleştirme sürerken dokunulmaz.
        if textView.string != text, !textView.hasMarkedText() {
            let length: Int = (text as NSString).length
            precondition(cursor >= 0 && cursor <= length, "Soru alanında imleç metnin dışında: \(cursor) / \(length)")
            coordinator.isApplying = true
            textView.string = text
            textView.setSelectedRange(NSRange(location: cursor, length: 0))
            textView.scrollRangeToVisible(NSRange(location: cursor, length: 0))
            coordinator.isApplying = false
        }
        if coordinator.appliedFocusRequest != focusRequest {
            coordinator.appliedFocusRequest = focusRequest
            textView.requestFocus()
        }
    }

    /// Yükseklik: metnin satırları kadar (en az bir, en fazla `maxLines` satır); fazlası kayar.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width else {
            return nil
        }
        let textView: AskTextView = askTextView(scrollView: scrollView)
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            preconditionFailure("Soru alanının metin düzeni (TextKit 1) yok")
        }
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let lineHeight: CGFloat = layoutManager.defaultLineHeight(for: font)
        let used: CGFloat = layoutManager.usedRect(for: container).height
        return CGSize(width: width, height: ceil(min(max(used, lineHeight), lineHeight * CGFloat(maxLines))))
    }

    private func askTextView(scrollView: NSScrollView) -> AskTextView {
        guard let textView = scrollView.documentView as? AskTextView else {
            preconditionFailure("Soru alanının belge görünümü AskTextView değil")
        }
        return textView
    }
}

/// Soru alanının metin görünümü: odak değişimini bildirir, pencereye eklenmeden istenen odağı eklenince alır.
final class AskTextView: NSTextView {
    var onFocusChange: (@MainActor (Bool) -> Void)?
    private var wantsFocusOnWindow: Bool = false

    /// Odağı alır; görünüm henüz pencerede değilse pencereye eklenince.
    func requestFocus() {
        guard let window else {
            wantsFocusOnWindow = true
            return
        }
        // Görünüm güncellemesi sırasında ilk yanıtlayıcı değişmesin: bir sonraki döngüde.
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            window.makeFirstResponder(self)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocusOnWindow, window != nil {
            wantsFocusOnWindow = false
            requestFocus()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became: Bool = super.becomeFirstResponder()
        if became {
            onFocusChange?(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned: Bool = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
        }
        return resigned
    }
}

/// Metin görünümünün temsilcisi: yazılanı ve imleci sayfaya taşır, tuş komutlarını sayfaya sorar.
@MainActor
final class AskInputCoordinator: NSObject, NSTextViewDelegate {
    var parent: AskInputField
    /// Sayfadan gelen metin görünüme yazılırken geri bildirim yapılmaz.
    var isApplying: Bool = false
    /// Son uygulanan odak isteği (ilk güncellemede odak alınsın diye geçersiz değerle başlar).
    var appliedFocusRequest: Int = Int.min

    init(parent: AskInputField) {
        self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplying, let textView = notification.object as? NSTextView else {
            return
        }
        parent.text = textView.string
        parent.cursor = NSMaxRange(textView.selectedRange())
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplying, let textView = notification.object as? NSTextView else {
            return
        }
        let cursor: Int = NSMaxRange(textView.selectedRange())
        if parent.cursor != cursor {
            parent.cursor = cursor
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Yazım birleştirilirken (Japonca/Çince…) Enter, oklar ve Esc giriş yöntemine aittir.
        guard !textView.hasMarkedText() else {
            return false
        }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // Shift+Enter yeni satır; Enter hiçbir zaman satır eklemez, gönderir (ya da öneriyi seçer).
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                _ = parent.onCommand(.submit)
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            return parent.onCommand(.moveUp)
        case #selector(NSResponder.moveDown(_:)):
            return parent.onCommand(.moveDown)
        case #selector(NSResponder.insertTab(_:)):
            if !parent.onCommand(.complete) {
                textView.window?.selectNextKeyView(nil)
            }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            textView.window?.selectPreviousKeyView(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
            // İşlenmeyen Esc yutulur: metin görünümünün tamamlama listesi açılmasın.
            _ = parent.onCommand(.cancel)
            return true
        default:
            return false
        }
    }
}

/// Seçili yazı ailesinde (Ayarlar › Görünüm; varsayılan gömülü Inter) AppKit yazısı; boyut arayüz ölçeğiyle çarpılır
/// (`appFont` ile aynı).
func askInputFont(appearance: PanelAppearance, size: CGFloat) -> NSFont {
    let points: CGFloat = size * appearance.uiScale
    let descriptor: NSFontDescriptor
    switch appearance.fontChoice {
    case .design(.inter):
        descriptor = NSFontDescriptor(fontAttributes: [.family: Theme.interFamily])
    case .design(let design):
        guard let designed = NSFont.systemFont(ofSize: points).fontDescriptor.withDesign(systemDesign(design: design)) else {
            preconditionFailure("Sistem yazısının tasarımı bulunamadı: \(design.rawValue)")
        }
        descriptor = designed
    case .installed(let family):
        descriptor = NSFontDescriptor(fontAttributes: [.family: family])
    }
    guard let font = NSFont(descriptor: descriptor, size: points) else {
        preconditionFailure("Soru alanının yazısı oluşturulamadı: \(appearance.fontChoice.storageValue)")
    }
    return font
}

/// SF tasarımının AppKit karşılığı. Saf fonksiyondur.
private func systemDesign(design: PanelFontDesign) -> NSFontDescriptor.SystemDesign {
    switch design {
    case .inter, .system: .default
    case .rounded: .rounded
    case .serif: .serif
    case .monospaced: .monospaced
    }
}
