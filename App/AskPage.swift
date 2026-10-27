import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Toplantılarıma sor: tüm notlar ve transkriptler arasında sohbet, sade bir LLM akışı gibi: çalışırken tek satır
/// parıltılı "Düşünüyor…", cevap akarak yumuşakça gelir, altında küçük ve kapalı "Kaynaklar" ve "nasıl cevaplandı"
/// satırları; metindeki [1] işaretleri toplantıyı açar. Devam soruları önceki cevapları bağlam alır. Boşken film
/// gradyanlı giriş ve örnek sorular.
struct AskPage: View {
    let model: AppModel
    let router: MainWindowRouter
    @State private var question: String = ""
    /// `@` ile etiketlenen toplantılar: soru yalnız onlara sorulur; kaldırılana ya da yeni sohbete dek kalır.
    @State private var mentioned: [MeetingRecord] = []
    /// `@` önerilerinde klavyeyle seçili satır.
    @State private var highlighted: Int = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { (proxy: ScrollViewProxy) in
                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        if model.archiveExchanges.isEmpty {
                            AskIntro(meetings: model.meetings) { (example: String) -> Void in
                                model.askArchive(question: example, meetingIDs: [])
                            }
                        }
                        ForEach(model.archiveExchanges) { (exchange: ArchiveExchange) in
                            ExchangeView(exchange: exchange) { (passage: ArchivePassage) -> Void in
                                router.selectedMeetingID = passage.meetingID
                                router.section = .meetings
                            }
                            .id(exchange.id)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .animation(.smooth(duration: 0.35), value: model.archiveExchanges.map(\.id))
                    .padding(.horizontal, 40)
                    .padding(.top, 28)
                    .padding(.bottom, 16)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                // Cevap akarken alt kenar izlenir (yeni satırlar görünür kalsın).
                .onChange(of: model.archiveExchanges.last?.answer.text) { (_: String?, _: String?) in
                    if model.isAnsweringArchive {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: model.archiveExchanges.last?.id) { (_: UUID?, last: UUID?) in
                    if let last {
                        withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo(last, anchor: .top) }
                    }
                }
            }
            VStack(spacing: 8) {
                if mentionQuery(text: question) != nil {
                    MentionSuggestions(candidates: suggestions, highlighted: highlighted) { (record: MeetingRecord) -> Void in
                        pick(record: record)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                composer
            }
            .animation(.smooth(duration: 0.2), value: mentionQuery(text: question) != nil)
            .padding(.horizontal, 40)
            .padding(.bottom, 22)
            .frame(maxWidth: 780)
        }
        .overlay(alignment: .topTrailing) {
            if !model.archiveExchanges.isEmpty {
                Button("Yeni sohbet", systemImage: "square.and.pencil") {
                    model.clearArchiveConversation()
                    mentioned = []
                    isFocused = true
                }
                .controlSize(.small)
                .padding(16)
                .hoverHint("Önceki cevaplar bağlam olmaz", alignment: .trailing, edge: .bottom)
            }
        }
        .onAppear { isFocused = true }
    }

    private let bottomID: String = "ask-bottom"

    private var composer: some View {
        let isEmpty: Bool = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            if !mentioned.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(mentioned, id: \.id) { (record: MeetingRecord) in
                        RemovableMentionChip(title: record.note?.title ?? record.title) {
                            withAnimation(.smooth(duration: 0.2)) { mentioned.removeAll { $0.id == record.id } }
                        }
                    }
                }
                .padding(.top, 4)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    mentioned.isEmpty
                        ? (model.archiveExchanges.isEmpty ? "Toplantılarına bir şey sor… (@ ile toplantı etiketle)" : "Devam sorusu sor…")
                        : "Etiketlenen toplantılara sor…",
                    text: $question, axis: .vertical
                )
                .textFieldStyle(.plain)
                .appFont(size: 15, weight: .regular)
                .lineLimit(1...6)
                .focused($isFocused)
                .onSubmit(send)
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onKeyPress(.return) { pickHighlighted() }
                .onKeyPress(.escape) { dismissSuggestions() }
                .onChange(of: question) { (_: String, _: String) in highlighted = 0 }
                .padding(.vertical, 6)
                if model.isAnsweringArchive {
                    Button(action: model.stopArchiveAnswer) {
                        Image(systemName: "stop.fill")
                            .appFont(size: 11, weight: .bold)
                            .foregroundStyle(Theme.onPrimary)
                            .frame(width: 32, height: 32)
                            .background(Theme.primary, in: Circle())
                    }
                    .buttonStyle(.hoverCapsule)
                    .accessibilityLabel("Durdur")
                    .hoverHint("Cevabı durdur", alignment: .trailing, edge: .top)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .appFont(size: 13, weight: .bold)
                            .foregroundStyle(Theme.onPrimary)
                            .frame(width: 32, height: 32)
                            .background(isEmpty ? Theme.muted.opacity(0.5) : Theme.primary, in: Circle())
                    }
                    .buttonStyle(.hoverCapsule)
                    .disabled(isEmpty)
                    .accessibilityLabel("Sor")
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Theme.card, in: shape)
        .overlay {
            // Ajan çalışırken çerçevede yavaş dönen renkli ışık.
            if model.isAnsweringArchive {
                ThinkingRing(shape: shape)
            } else {
                shape.strokeBorder(isFocused ? Theme.ink.opacity(0.18) : Theme.line)
            }
        }
        .shadow(color: .black.opacity(0.07), radius: 18, y: 6)
        .animation(.smooth(duration: 0.25), value: model.isAnsweringArchive)
    }

    private func send() {
        guard !model.isAnsweringArchive, mentionQuery(text: question) == nil else {
            return
        }
        model.askArchive(question: question, meetingIDs: mentioned.map(\.id))
        question = ""
    }

    /// `@` önerileri (en fazla 6).
    private var suggestions: [MeetingRecord] {
        mentionCandidates(records: model.meetings, query: mentionQuery(text: question) ?? "", excluding: mentioned.map(\.id), limit: 6)
    }

    /// Toplantıyı etikete ekler; yazılan "@…" silinir.
    private func pick(record: MeetingRecord) {
        withAnimation(.smooth(duration: 0.2)) { mentioned.append(record) }
        question = removingMentionQuery(text: question)
        highlighted = 0
        isFocused = true
    }

    private func moveHighlight(by step: Int) -> KeyPress.Result {
        guard mentionQuery(text: question) != nil, !suggestions.isEmpty else {
            return .ignored
        }
        highlighted = (highlighted + step + suggestions.count) % suggestions.count
        return .handled
    }

    /// Öneriler açıkken Return seçili toplantıyı ekler (soru gönderilmez).
    private func pickHighlighted() -> KeyPress.Result {
        guard mentionQuery(text: question) != nil else {
            return .ignored
        }
        if suggestions.indices.contains(highlighted) {
            pick(record: suggestions[highlighted])
        }
        return .handled
    }

    /// Escape önerileri kapatır: yazılan "@…" silinir.
    private func dismissSuggestions() -> KeyPress.Result {
        guard mentionQuery(text: question) != nil else {
            return .ignored
        }
        question = removingMentionQuery(text: question)
        return .handled
    }
}

/// Boş sayfa: film gradyanlı giriş (arşivin büyüklüğüyle) ve örnek soru kartları.
private struct AskIntro: View {
    let meetings: [MeetingRecord]
    let onAsk: @MainActor (String) -> Void

    /// Kartların sıcak film gradyanları (temanın turuncu ailesi).
    private let examplePalettes: [FilmPalette] = [.sunset, .rose, .sunset, .rose]
    private let exampleHint: LocalizedStringKey = "Tüm toplantılarında arar"

    private let examples: [(symbol: String, text: String)] = [
        ("checklist", "Bana hangi görevler verildi?"),
        ("checkmark.seal", "Son toplantılarda alınan kararlar neler?"),
        ("eurosign.circle", "Bütçe hakkında neler konuşuldu?"),
        ("person.2", "Bu hafta kimlerle neler konuştum?"),
    ]

    var body: some View {
        let minutes: Int = meetings.compactMap { meetingDurationMinutes(record: $0) }.reduce(0, +)
        VStack(alignment: .leading, spacing: 22) {
            GradientBanner(palette: .violet, seed: "ask") {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .appFont(size: 22, weight: .medium)
                        .foregroundStyle(.white.opacity(0.9))
                    Text("Toplantılarına sor")
                        .appFont(size: 34, weight: .regular)
                        .tracking(-0.6)
                        .foregroundStyle(.white)
                    Text("Notların ve transkriptlerin (hangi dilde konuşulduysa) arasında arar, Türkçe cevaplar; her bilginin hangi toplantıdan geldiğini gösterir.")
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        IntroStat(text: Text("\(meetings.count) toplantı"))
                        IntroStat(text: Text("\(max(0, minutes / 60)) sa \(minutes % 60) dk konuşma"))
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("ÖRNEK SORULAR")
                .appFont(size: 11, weight: .semibold)
                .tracking(DesignTokens.labelTracking)
                .foregroundStyle(Theme.muted)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(examples.enumerated()), id: \.element.text) { (item: (offset: Int, element: (symbol: String, text: String))) in
                    ExampleQuestionCard(
                        symbol: item.element.symbol, question: LocalizedStringKey(item.element.text), hint: exampleHint,
                        palette: examplePalettes[item.offset % examplePalettes.count]
                    ) {
                        onAsk(String(localized: String.LocalizationValue(item.element.text)))
                    }
                }
            }
        }
    }
}

/// Giriş bannerındaki küçük cam etiket.
private struct IntroStat: View {
    let text: Text

    var body: some View {
        text
            .appFont(size: 12, weight: .medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.22)))
    }
}
