import AINotepadUI
import AppKit
import Observation
import SwiftUI

/// Bildirimin isteğe bağlı düğmesi.
enum ToastAction: Equatable {
    /// Dosyayı Finder'da seçili gösterir.
    case revealInFinder(URL)
}

/// Kısa başarı bildirimi: başlık, isteğe bağlı ikinci satır ve düğme.
struct AppToast: Equatable, Identifiable {
    let id: UUID
    let title: String
    let detail: String?
    let action: ToastAction?
}

/// Bildirimin ekranda kaldığı süre (saniye); fare üstündeyken süre işlemez.
private let toastVisibleSec: Double = 3

/// Ana pencerenin sağ altındaki kısa başarı bildirimleri (kaydedildi, kopyalandı, gönderildi): tek bildirim görünür,
/// yenisi eskisinin yerini alır; `toastVisibleSec` sonra kendiliğinden kaybolur, fare üstündeyken bekler. Hatalar
/// bildirim değildir: oldukları yerde kalır.
@MainActor
@Observable
final class ToastCenter {
    static let shared: ToastCenter = ToastCenter()

    private(set) var current: AppToast?
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    private init() {}

    /// Bildirimi gösterir ve kaybolma süresini başlatır.
    func show(title: String, detail: String?, action: ToastAction?) {
        current = AppToast(id: UUID(), title: title, detail: detail, action: action)
        scheduleDismissal()
    }

    /// Fare bildirimin üstüne geldi: kaybolma durur; ayrılınca süre baştan başlar.
    func setHovering(hovering: Bool) {
        if hovering {
            dismissal?.cancel()
            dismissal = nil
        } else {
            scheduleDismissal()
        }
    }

    /// Bildirimi hemen kaldırır.
    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        current = nil
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        guard let shownID = current?.id else {
            return
        }
        dismissal = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(toastVisibleSec))
            } catch {
                return
            }
            guard let self, self.current?.id == shownID else {
                return
            }
            self.current = nil
        }
    }
}

/// Sağ alttaki bildirim kartı: onay simgesi, başlık, ikinci satır, düğme ve kapatma.
struct ToastView: View {
    let toast: AppToast
    let center: ToastCenter

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: toast.title)
                    .appFont(size: 13, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                if let detail = toast.detail {
                    Text(verbatim: detail)
                        .appFont(size: 11.5, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if let action = toast.action {
                Button(actionTitle(action: action)) {
                    perform(action: action)
                    center.dismiss()
                }
                .buttonStyle(.pill)
                .controlSize(.small)
                .fixedSize()
            }
            Button {
                center.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .appFont(size: 10, weight: .semibold)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.hoverPlain)
            .accessibilityLabel(Text("Kapat"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 360)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: Color.black.opacity(0.14), radius: 18, y: 8)
        .onHover { (hovering: Bool) -> Void in center.setHovering(hovering: hovering) }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }

    private func actionTitle(action: ToastAction) -> LocalizedStringKey {
        switch action {
        case .revealInFinder: "Finder'da göster"
        }
    }

    private func perform(action: ToastAction) {
        switch action {
        case .revealInFinder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
