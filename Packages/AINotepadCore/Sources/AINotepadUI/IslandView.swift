import AINotepadCore
import SwiftUI

/// Adanın açılma payı (tasarım belgesi §4.3).
public let islandExpansion: CGFloat = 64
/// Ada kanadının genişliği.
public let islandWing: CGFloat = 120

/// Çentiğe yapışık siyah ada (çentiksiz ekranda hap). Kapalıyken kanatlarda süre ve dil; açıkken son
/// "Diğerleri" cümlesi. Pencere açılma payını içerir; saydam kısım tıklamaları geçirir.
public struct IslandView: View {
    let state: LiveViewState
    let layout: IslandLayout
    let isExpanded: Bool
    let onTap: @MainActor () -> Void
    /// Fare adanın (saydam pay değil) üstüne gelince/çıkınca çağrılır.
    let onHover: @MainActor (Bool) -> Void

    public init(
        state: LiveViewState,
        layout: IslandLayout,
        isExpanded: Bool,
        onTap: @escaping @MainActor () -> Void,
        onHover: @escaping @MainActor (Bool) -> Void
    ) {
        self.state = state
        self.layout = layout
        self.isExpanded = isExpanded
        self.onTap = onTap
        self.onHover = onHover
    }

    public var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(width: layout.frame.width, height: layout.frame.height, alignment: .top)
    }

    private var island: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.s) {
                StatusLabel(state: state)
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(state.languageText)
                    .font(DesignTokens.statusFont)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignTokens.Spacing.l)
            .frame(height: layout.collapsedHeight)
            if isExpanded {
                Text(state.latestOthersSentence ?? "Henüz konuşma yok")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(state.latestOthersSentence == nil ? 0.5 : 0.95))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Spacing.l)
                    .padding(.bottom, DesignTokens.Spacing.m)
                    .frame(height: islandExpansion, alignment: .top)
                    .transition(.opacity)
            }
        }
        .frame(width: layout.frame.width, height: isExpanded ? layout.collapsedHeight + islandExpansion : layout.collapsedHeight, alignment: .top)
        .background(.black, in: islandShape)
        .contentShape(islandShape)
        .onTapGesture { onTap() }
        .onHover { (hovering: Bool) -> Void in onHover(hovering) }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isExpanded)
    }

    /// Çentikte üst köşeler ekrana yapışık (düz), çentiksiz hapta tüm köşeler yuvarlak.
    private var islandShape: UnevenRoundedRectangle {
        let top: CGFloat = layout.hasNotch ? 0 : 16
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: top)
    }
}
