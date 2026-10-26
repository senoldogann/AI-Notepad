import AINotepadCore
import AINotepadUI
import SwiftUI

/// Toplantılarıma sor: tüm notlar ve transkriptler arasında soru-cevap. Cevabın altında dayandığı toplantılar; tıklayınca
/// toplantı açılır. Boşken örnek sorular.
struct AskPage: View {
    let model: AppModel
    let router: MainWindowRouter
    @State private var question: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { (proxy: ScrollViewProxy) in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if model.archiveExchanges.isEmpty {
                            intro
                        }
                        ForEach(model.archiveExchanges) { (exchange: ArchiveExchange) in
                            ExchangeView(exchange: exchange) { (passage: ArchivePassage) -> Void in
                                router.selectedMeetingID = passage.meetingID
                                router.section = .meetings
                            }
                            .id(exchange.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .animation(.smooth(duration: 0.3), value: model.archiveExchanges)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.archiveExchanges.last?.id) { (_: UUID?, last: UUID?) in
                    if let last {
                        withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(last, anchor: .top) }
                    }
                }
            }
            composer
                .padding(.horizontal, 36)
                .padding(.bottom, 20)
                .frame(maxWidth: 760)
        }
        .onAppear { isFocused = true }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Toplantılarına sor")
                .appFont(size: 28, weight: .regular)
                .tracking(-0.4)
            Text("Tüm notların ve Fince/İngilizce transkriptlerin arasında arar; Türkçe cevap verir ve hangi toplantıda geçtiğini gösterir.")
                .appFont(size: 14, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(["Bana hangi görevler verildi?", "Bütçe hakkında neler konuşuldu?", "Son toplantılarda alınan kararlar neler?"], id: \.self) { (example: String) in
                    Button {
                        model.askArchive(question: String(localized: String.LocalizationValue(example)))
                    } label: {
                        Label(LocalizedStringKey(example), systemImage: "sparkles")
                    }
                    .controlSize(.small)
                }
            }
            .padding(.top, 4)
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Theme.muted)
            TextField("Örn. Aino ile proje takvimi hakkında ne konuştuk?", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .appFont(size: 15, weight: .regular)
                .lineLimit(1...4)
                .focused($isFocused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .appFont(size: 13, weight: .bold)
                    .foregroundStyle(Theme.onPrimary)
                    .frame(width: 30, height: 30)
                    .background(question.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.muted : Theme.primary, in: Circle())
            }
            .buttonStyle(.hoverCapsule)
            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Sor")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }

    private func send() {
        model.askArchive(question: question)
        question = ""
    }
}

/// Bir soru ve cevabı: soru sağda balon, cevap altında kaynak çipleriyle.
private struct ExchangeView: View {
    let exchange: ArchiveExchange
    let onOpen: @MainActor (ArchivePassage) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 60)
                Text(exchange.question)
                    .appFont(size: 14, weight: .regular)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Theme.soft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
            }
            switch exchange.state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Toplantılar taranıyor…").appFont(size: 13, weight: .regular).foregroundStyle(Theme.muted)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(.red)
            case .answered(let answer):
                VStack(alignment: .leading, spacing: 10) {
                    Text(answer.text)
                        .font(appearance.font(size: appearance.textSize + 1, weight: .regular))
                        .lineSpacing(appearance.lineSpacing + 1)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !answer.sources.isEmpty {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(answer.sources) { (source: ArchivePassage) in
                                Button {
                                    onOpen(source)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: source.kind == .note ? "doc.text" : "text.bubble")
                                        Text(sourceLabel(source: source)).lineLimit(1)
                                    }
                                    .appFont(size: 12, weight: .medium)
                                    .foregroundStyle(Theme.ink.opacity(0.85))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Theme.card, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Theme.line))
                                }
                                .buttonStyle(.hoverCapsule)
                                .hoverHint("Toplantıyı aç", alignment: .leading, edge: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    /// "Bütçe planlaması · 26 Eki · 04:12".
    private func sourceLabel(source: ArchivePassage) -> String {
        let date: String = source.meetingDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale()))
        let time: [String] = source.kind == .transcript ? [timestamp(seconds: source.startSec)] : []
        return ([source.meetingTitle, date] + time).joined(separator: " · ")
    }
}
