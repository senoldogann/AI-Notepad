import SwiftUI

/// Boş durum kartı: solda yumuşak daire içinde simge, yanında başlık ve (varsa) açıklama. Sayfa içindeki bölümler
/// için (görev yok, not yok…).
public struct EmptyStateCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?

    public init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey?) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 14) {
            EmptyStateIcon(symbol: symbol, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                if let message {
                    Text(message)
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }
}

/// Alanın ortasında büyük boş durum: simge, başlık, açıklama (liste sütunu gibi tüm alanı kaplayan yerler için).
public struct EmptyStatePlaceholder: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?

    public init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey?) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 10) {
            EmptyStateIcon(symbol: symbol, size: 52)
            Text(title)
                .appFont(size: 15, weight: .medium)
                .foregroundStyle(Theme.ink)
            if let message {
                Text(message)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignTokens.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Boş durum simgesi: ince çerçeveli soluk daire içinde vektör simge (SF Symbol).
private struct EmptyStateIcon: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Theme.muted)
            .frame(width: size, height: size)
            .background(Theme.soft, in: Circle())
            .overlay(Circle().strokeBorder(Theme.line))
            .accessibilityHidden(true)
    }
}
