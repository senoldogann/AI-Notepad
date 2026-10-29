#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

// Uygulamanın tek uyarı dili: sakin, beyaz arayüzle uyumlu. Önem derecesi yalnızca küçük simgenin rengiyle ayrılır
// (doygun turuncu/kırmızı zemin yok); metin mürekkep, ikinci satır soluk, en çok bir açık eylem, ince çizgi ve yumuşak
// zemin. Üç biçim: pencerenin üstünde şerit (`NoticeBar`), sayfa içinde kart (`NoticeCard`) ve satır içi tek satır
// (`NoticeText`).

/// Uyarının önemi.
public enum NoticeSeverity: Sendable, Equatable {
    /// Bilgi (güncelleme, ipucu).
    case info
    /// Dikkat (sınıra yaklaşma, eksik ayar).
    case attention
    /// Hata (bir şey olmadı; ne yapılacağı yazılır).
    case error

    /// Simge.
    public var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    /// Simgenin rengi (açık ve koyu görünümde ayrı, doygunluğu düşük).
    public var tint: Color {
        switch self {
        case .info: noticeColor(light: 0x52657A, dark: 0x9FB3C8)
        case .attention: noticeColor(light: 0x9A5B00, dark: 0xF2B863)
        case .error: noticeColor(light: 0xB42318, dark: 0xFF8A7A)
        }
    }
}

/// Açık ve koyu görünüme göre renk (onaltılık RGB).
private func noticeColor(light: UInt32, dark: UInt32) -> Color {
    #if os(macOS)
    Color(nsColor: NSColor(name: nil) { (appearance: NSAppearance) -> NSColor in
        let isDark: Bool = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return noticePlatformColor(value: isDark ? dark : light)
    })
    #else
    Color(uiColor: UIColor { (traits: UITraitCollection) -> UIColor in
        noticePlatformColor(value: traits.userInterfaceStyle == .dark ? dark : light)
    })
    #endif
}

#if os(macOS)
private func noticePlatformColor(value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}
#else
private func noticePlatformColor(value: UInt32) -> UIColor {
    UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}
#endif

/// Uyarının içeriği: simge, başlık, isteğe bağlı ikinci satır, eylemler ve kapatma.
private struct NoticeContent<Actions: View>: View {
    let severity: NoticeSeverity
    let title: Text
    let detail: Text?
    let onDismiss: (@MainActor () -> Void)?
    let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: severity.symbol)
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(severity.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .appFont(size: 12.5, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    detail
                        .appFont(size: 11.5, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            actions
                .controlSize(.small)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(size: 10, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.hoverPlain)
                .accessibilityLabel(Text("Kapat"))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Pencerenin (ya da panelin) üstündeki şerit: tam genişlik, yumuşak zemin, altta ince çizgi.
public struct NoticeBar<Actions: View>: View {
    let severity: NoticeSeverity
    let title: Text
    let detail: Text?
    let onDismiss: (@MainActor () -> Void)?
    let actions: Actions

    public init(severity: NoticeSeverity, title: Text, detail: Text?, onDismiss: (@MainActor () -> Void)?, @ViewBuilder actions: () -> Actions) {
        self.severity = severity
        self.title = title
        self.detail = detail
        self.onDismiss = onDismiss
        self.actions = actions()
    }

    public var body: some View {
        NoticeContent(severity: severity, title: title, detail: detail, onDismiss: onDismiss, actions: actions)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.soft)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Sayfa içindeki uyarı kartı: kart zemini, ince çerçeve, yuvarlak köşe.
public struct NoticeCard<Actions: View>: View {
    let severity: NoticeSeverity
    let title: Text
    let detail: Text?
    let onDismiss: (@MainActor () -> Void)?
    let actions: Actions

    public init(severity: NoticeSeverity, title: Text, detail: Text?, onDismiss: (@MainActor () -> Void)?, @ViewBuilder actions: () -> Actions) {
        self.severity = severity
        self.title = title
        self.detail = detail
        self.onDismiss = onDismiss
        self.actions = actions()
    }

    public var body: some View {
        NoticeContent(severity: severity, title: title, detail: detail, onDismiss: onDismiss, actions: actions)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Satır içi tek uyarı (ayar satırı, form, sayfa altı): küçük renkli simge ve mürekkep metin. `Text` gibi: sabit
/// metin yerelleştirilir, `String` olduğu gibi gösterilir.
public struct NoticeText: View {
    let severity: NoticeSeverity
    let text: Text

    public init(_ key: LocalizedStringKey, severity: NoticeSeverity) {
        self.severity = severity
        self.text = Text(key)
    }

    // `Text` gibi geri planda: yoksa sabit metin `String` sayılır ve hiç yerelleştirilmez.
    @_disfavoredOverload
    public init<S: StringProtocol>(_ content: S, severity: NoticeSeverity) {
        self.severity = severity
        self.text = Text(content)
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: severity.symbol)
                .imageScale(.small)
                .foregroundStyle(severity.tint)
                .accessibilityHidden(true)
            text
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
