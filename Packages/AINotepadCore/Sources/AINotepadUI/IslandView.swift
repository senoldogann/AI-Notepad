import AINotepadCore
import SwiftUI

/// Adanın açılma payı: konuşmacı satırı, iki satır Türkçe ve bir satır orijinal (tasarım belgesi §4.3).
public let islandExpansion: CGFloat = 88
/// Ada kanadının genişliği (açıkken metin satırı bu genişlikte).
public let islandWing: CGFloat = 150

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
    /// Sağ tık menüsünden toplantı dilini değiştirme.
    let onSetLanguage: @MainActor (MeetingLanguage) -> Void

    public init(
        state: LiveViewState,
        layout: IslandLayout,
        isExpanded: Bool,
        onTap: @escaping @MainActor () -> Void,
        onHover: @escaping @MainActor (Bool) -> Void,
        onStop: @escaping @MainActor () -> Void,
        onSetLanguage: @escaping @MainActor (MeetingLanguage) -> Void
    ) {
        self.state = state
        self.layout = layout
        self.isExpanded = isExpanded
        self.onTap = onTap
        self.onHover = onHover
        self.onStop = onStop
        self.onSetLanguage = onSetLanguage
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
                        .appFont(size: 11, weight: .semibold)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Hata var")
                }
                Text(state.languageText)
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignTokens.Spacing.l)
            .frame(height: layout.collapsedHeight)
            if isExpanded {
                expandedContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Spacing.l)
                    .padding(.top, 2)
                    .padding(.bottom, DesignTokens.Spacing.m)
                    .frame(height: islandExpansion, alignment: .top)
                    .transition(.opacity)
            }
        }
        .frame(width: layout.frame.width, height: isExpanded ? layout.collapsedHeight + islandExpansion : layout.collapsedHeight, alignment: .top)
        .background(.black, in: islandShape)
        .contentShape(islandShape)
        .onTapGesture { onTap() }
        .linkPointer(isEnabled: true)
        .contextMenu {
            Button("Kaydı durdur", systemImage: "stop.circle") { onStop() }
                .disabled(!state.isRecording)
            Menu("Dili değiştir", systemImage: "globe") {
                LanguageMenuItems(onSetLanguage: onSetLanguage)
            }
            .disabled(!state.isRecording)
            Button("Paneli göster / gizle", systemImage: "rectangle.on.rectangle") { onTap() }
        }
        // VoiceOver: ada tek düğme; durum, dil ve son cümle okunur.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("AI-Notepad")
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint("Paneli gösterir ya da gizler")
        .accessibilityAction(named: "Kaydı durdur") { onStop() }
        .onHover { (hovering: Bool) -> Void in onHover(hovering) }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isExpanded)
    }

    /// Açık ada: kim konuşuyor (renkli nokta + ad), ne dedi (Türkçesi, iki satır), şu an ne diyor (orijinal, tek
    /// satır, soluk). En yeni kelimeler görünsün diye satırlar baştan kısaltılır. Hata varsa orijinal yerine hata satırı.
    @ViewBuilder
    private var expandedContent: some View {
        if let line = state.islandLine {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(line.person.map { personColor(person: $0) } ?? Color.white.opacity(0.6))
                        .frame(width: 6, height: 6)
                    Text(speakerLabel(speaker: line.speaker, person: line.person).uppercased(with: interfaceLocale()))
                        .appFont(size: 11, weight: .semibold)
                        .tracking(DesignTokens.labelTracking)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(line.primary)
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(.white.opacity(line.primaryIsOriginal ? 0.75 : 0.98))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = state.errors.last {
                    Text(error)
                        .appFont(size: 11, weight: .regular)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if let secondary = line.secondary {
                    Text(secondary)
                        .appFont(size: 11.5, weight: .regular)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("Henüz konuşma yok")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(.white.opacity(0.5))
                if let error = state.errors.last {
                    Text(error)
                        .appFont(size: 11, weight: .regular)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    private var accessibilitySummary: String {
        let status: String = switch state.phase {
        case .recording: String(localized: "Kayıtta")
        case .finishing: String(localized: "Bitiriliyor")
        case .idle: state.statusText
        }
        return [status, state.languageText, state.latestOthersSentence ?? "", state.errors.last ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// Çentikte üst köşeler ekrana yapışık (düz), çentiksiz hapta tüm köşeler yuvarlak.
    private var islandShape: UnevenRoundedRectangle {
        let top: CGFloat = layout.hasNotch ? 0 : 16
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: top)
    }
}
