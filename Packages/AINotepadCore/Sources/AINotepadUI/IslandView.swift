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
    /// Sağ tık menüsündeki "Kaydı durdur" (ada menü çubuğu ikonlarını örtebildiği için).
    let onStop: @MainActor () -> Void

    public init(
        state: LiveViewState,
        layout: IslandLayout,
        isExpanded: Bool,
        onTap: @escaping @MainActor () -> Void,
        onHover: @escaping @MainActor (Bool) -> Void,
        onStop: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.layout = layout
        self.isExpanded = isExpanded
        self.onTap = onTap
        self.onHover = onHover
        self.onStop = onStop
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
                if !state.errors.isEmpty {
                    // Panel gizliyken de sorun fark edilsin.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                        .accessibilityLabel("Hata var")
                }
                Text(state.languageText)
                    .font(DesignTokens.statusFont)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignTokens.Spacing.l)
            .frame(height: layout.collapsedHeight)
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    // Cümle hep görünür; hata varsa altında tek satır kırmızı. En yeni kelimeler için baştan kısaltılır.
                    Text(state.latestOthersSentence ?? "Henüz konuşma yok")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(state.latestOthersSentence == nil ? 0.5 : 0.95))
                        .lineLimit(state.errors.isEmpty ? 2 : 1)
                        .truncationMode(.head)
                    if let error = state.errors.last {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
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
        .contextMenu {
            Button("Kaydı durdur", systemImage: "stop.circle") { onStop() }
            Button("Paneli göster / gizle", systemImage: "rectangle.on.rectangle") { onTap() }
        }
        .onHover { (hovering: Bool) -> Void in onHover(hovering) }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isExpanded)
    }

    /// Çentikte üst köşeler ekrana yapışık (düz), çentiksiz hapta tüm köşeler yuvarlak.
    private var islandShape: UnevenRoundedRectangle {
        let top: CGFloat = layout.hasNotch ? 0 : 16
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: top)
    }
}
