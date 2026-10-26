import AINotepadCore
import SwiftUI

/// Vurgu rengini izleyen bölüm seçici (macOS'un sistem bölüm denetimi uygulama vurgu rengini almaz).
public struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: LocalizedStringKey)]
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        // ElevenLabs bölüm seçicisi: soluk iz üzerinde seçili bölüm beyaz kart.
                        .background {
                            if isSelected {
                                Capsule().fill(Theme.card).shadow(color: .black.opacity(0.10), radius: 2, y: 1)
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
        .background(Theme.soft, in: Capsule())
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// Çalan paragrafın metni: söylenen kelimeler tam renk, o anki kelime vurgu renginde ve kalın, gelecek kelimeler
/// soluk. Tek biçimli metin olarak üretilir (her karede kelime başına ayrı metin kurulmaz). Saf fonksiyondur.
public func karaokeText(words: [StoredWord], activeIndex: Int?, accent: Color) -> AttributedString {
    words.enumerated().reduce(into: AttributedString()) { (result: inout AttributedString, item: (offset: Int, element: StoredWord)) -> Void in
        var word: AttributedString = AttributedString((item.offset == 0 ? "" : " ") + item.element.text)
        switch activeIndex {
        case .some(let index) where item.offset == index:
            word.foregroundColor = accent
            word.inlinePresentationIntent = .stronglyEmphasized
        case .some(let index) where item.offset < index:
            word.foregroundColor = Color.primary
        default:
            word.foregroundColor = Color.primary.opacity(0.45)
        }
        result.append(word)
    }
}
