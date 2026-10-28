import SwiftUI

/// Karşılamanın film gradyanlı paneli (ElevenLabs kapakları gibi): üstte uygulama işareti, ortada adımın görseli
/// (cam kutularda simgeler), altta beyaz başlık, kısa tanıtım ve adım noktaları. Adım değişince gradyan ve içerik
/// yumuşakça geçer.
public struct OnboardingPanel: View {
    let palette: FilmPalette
    let seed: String
    let symbols: [String]
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let stepIndex: Int
    let stepCount: Int

    public init(
        palette: FilmPalette, seed: String, symbols: [String], title: LocalizedStringKey, subtitle: LocalizedStringKey,
        stepIndex: Int, stepCount: Int
    ) {
        self.palette = palette
        self.seed = seed
        self.symbols = symbols
        self.title = title
        self.subtitle = subtitle
        self.stepIndex = stepIndex
        self.stepCount = stepCount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppMark(size: 30, barsRaised: true, lineDrawn: true)
                Text(verbatim: "AI-Notepad")
                    .appFont(size: 15, weight: .semibold)
            }
            Spacer(minLength: 24)
            HStack(spacing: 14) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                    Image(systemName: item.element)
                        .appFont(size: 26, weight: .medium)
                        .frame(width: 66, height: 66)
                        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.28)))
                        .offset(y: item.offset == 1 ? -10 : 0)
                }
            }
            .frame(maxWidth: .infinity)
            .id(seed)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            Spacer(minLength: 24)
            Text(title)
                .appFont(size: 30, weight: .regular)
                .tracking(-0.6)
                .fixedSize(horizontal: false, vertical: true)
                .id("baslik-\(seed)")
                .transition(.opacity)
            Text(subtitle)
                .appFont(size: 14, weight: .regular)
                .opacity(0.85)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .id("alt-\(seed)")
                .transition(.opacity)
            HStack(spacing: 6) {
                ForEach(0..<stepCount, id: \.self) { (index: Int) in
                    Capsule()
                        .fill(.white.opacity(index == stepIndex ? 0.95 : 0.35))
                        .frame(width: index == stepIndex ? 22 : 7, height: 7)
                }
            }
            .padding(.top, 22)
            .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { FilmGradient(seed: seed, palette: palette) }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.10)))
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.45), value: seed)
    }
}

/// Özellik kartı: film gradyanlı simge kutusu, başlık ve tek cümle (karşılama ve tanıtım ekranları).
public struct FeatureTile: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    let palette: FilmPalette

    public init(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey, palette: FilmPalette) {
        self.symbol = symbol
        self.title = title
        self.text = text
        self.palette = palette
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .appFont(size: 15, weight: .semibold)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background { FilmGradient(seed: "ozellik-\(symbol)", palette: palette) }
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                Text(text)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Seçilebilir kart (ör. canlı metin motoru): başlık, açıklama; seçiliyken vurgu renginde kenar ve işaret.
public struct ChoiceCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    let isSelected: Bool
    let onSelect: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey, isSelected: Bool, onSelect: @escaping @MainActor () -> Void) {
        self.symbol = symbol
        self.title = title
        self.text = text
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    public var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol)
                        .appFont(size: 17, weight: .medium)
                        .foregroundStyle(isSelected ? appearance.accent.color : Theme.muted)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .appFont(size: 16, weight: .regular)
                        .foregroundStyle(isSelected ? appearance.accent.color : Theme.line)
                }
                Text(title)
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                Text(text)
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isSelected ? appearance.accent.color.opacity(0.06) : Theme.card, in: shape)
            .overlay(shape.strokeBorder(isSelected ? appearance.accent.color.opacity(0.7) : Theme.line, lineWidth: isSelected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}
