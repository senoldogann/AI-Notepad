import AINotepadCore
import SwiftUI

/// Vurgu rengini izleyen bölüm seçici (macOS'un sistem bölüm denetimi uygulama vurgu rengini almaz).
public struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: LocalizedStringKey)]
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @Environment(\.designLook) private var look: DesignLook
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    /// Seçili kart bölümler arasında kayar (zıplamaz).
    @Namespace private var selectionSpace: Namespace.ID

    public init(selection: Binding<Value>, options: [(value: Value, title: LocalizedStringKey)]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { (item: (offset: Int, element: (value: Value, title: LocalizedStringKey))) in
                let isSelected: Bool = item.element.value == selection
                Button {
                    selection = item.element.value
                } label: {
                    Text(item.element.title)
                        .appFont(size: 12, weight: isSelected ? .semibold : .regular)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        // ElevenLabs bölüm seçicisi: soluk iz üzerinde seçili bölüm beyaz kart.
                        .background {
                            if isSelected {
                                selectedThumb
                                    .matchedGeometryEffect(id: "secili", in: selectionSpace)
                            }
                        }
                        .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
                        .contentShape(Capsule())
                }
                .buttonStyle(.hoverCapsule)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .softSurface(shape: Capsule())
        .animation(.smooth(duration: 0.25), value: selection)
    }

    /// Seçili bölüm: Standart'ta gölgeli beyaz kart; Liquid Glass'ta cam izin üstünde buzlu beyaz.
    @ViewBuilder
    private var selectedThumb: some View {
        switch look.style {
        case .standard:
            Capsule().fill(Theme.card).shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        case .liquidGlass:
            Capsule().fill(glassColors(tint: look.tint, colorScheme: colorScheme).selectionFill)
        }
    }
}

/// Çalan paragrafın metni: söylenen kelimeler tam renk, o anki kelime vurgu renginde ve kalın, gelecek kelimeler
/// soluk. Tek biçimli metin olarak üretilir (her karede kelime başına ayrı metin kurulmaz). Saf fonksiyondur.
public func karaokeText(words: [StoredWord], activeIndex: Int?, accent: Color, ink: Color) -> AttributedString {
    words.enumerated().reduce(into: AttributedString()) { (result: inout AttributedString, item: (offset: Int, element: StoredWord)) -> Void in
        var word: AttributedString = AttributedString((item.offset == 0 ? "" : " ") + item.element.text)
        switch activeIndex {
        case .some(let index) where item.offset == index:
            // Yalnızca renk: kalınlaştırmak kelimeyi genişletip satırları her kelimede yeniden kırıyor, metin titriyordu.
            word.foregroundColor = accent
        case .some(let index) where item.offset < index:
            word.foregroundColor = ink
        default:
            word.foregroundColor = ink.opacity(0.45)
        }
        result.append(word)
    }
}
