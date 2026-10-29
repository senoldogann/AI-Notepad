import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Toplantılarıma sor: tüm notlar ve transkriptler arasında sohbet, sade bir LLM akışı gibi: çalışırken tek satır
/// parıltılı "Düşünüyor…", cevap akarak yumuşakça gelir, altında küçük ve kapalı "Kaynaklar" ve "nasıl cevaplandı"
/// satırları; metindeki [1] işaretleri toplantıyı açar. Devam soruları önceki cevapları bağlam alır. Boşken film
/// gradyanlı giriş ve örnek sorular. Sohbetler saklanır; "Geçmiş" soldaki ince sütunda açılır (yeniden aç, sil).
struct AskPage: View {
    let model: AppModel
    let router: MainWindowRouter
    @State private var question: String = ""
    /// `@` ile etiketlenen toplantılar: soru yalnız onlara sorulur; soru gönderilince alandan kalkar.
    @State private var mentioned: [MeetingRecord] = []
    /// `@` önerilerinde klavyeyle seçili satır.
    @State private var highlighted: Int = 0
    @FocusState private var isFocused: Bool
    /// Soldaki sohbet geçmişi sütunu açık (düğmesi pencerenin üst çubuğunda).
    @AppStorage(SettingsKey.askHistoryVisible) private var isShowingHistory: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if isShowingHistory, !model.askConversations.isEmpty {
                AskHistoryColumn(model: model) { (id: UUID) -> Void in
                    model.openConversation(id: id)
                    mentioned = []
                    isFocused = true
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            chat
        }
        .animation(.smooth(duration: 0.25), value: isShowingHistory)
        .onAppear { isFocused = true }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { (proxy: ScrollViewProxy) in
                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        if model.archiveExchanges.isEmpty {
                            AskIntro(meetings: model.meetings) { (example: String) -> Void in
                                guard unavailableReason == nil else {
                                    return
                                }
                                model.askArchive(question: example, meetingIDs: [], recipeTitle: nil)
                            }
                        }
                        ForEach(model.archiveExchanges) { (exchange: ArchiveExchange) in
                            ExchangeView(exchange: exchange) { (passage: ArchivePassage) -> Void in
                                router.selectedMeetingID = passage.meetingID
                                router.section = .meetings
                            } onSaveRecipe: { (question: String) -> Void in
                                model.saveRecipe(question: question)
                            }
                            .id(exchange.id)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .animation(.smooth(duration: 0.35), value: model.archiveExchanges.map(\.id))
                    .padding(.horizontal, 40)
                    // Sağ üstteki "Yeni sohbet" düğmesi görünürken ilk soru balonu onun altında kalmasın.
                    .padding(.top, hasCornerButtons ? 76 : 28)
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
                if isMentioning {
                    MentionSuggestions(candidates: suggestions, highlighted: highlighted) { (record: MeetingRecord) -> Void in
                        pick(record: record)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if isPickingRecipe {
                    RecipeSuggestions(recipes: recipeMatches, highlighted: highlighted) { (recipe: Recipe) -> Void in
                        run(recipe: recipe)
                    } onDelete: { (recipe: Recipe) -> Void in
                        model.deleteRecipe(id: recipe.id)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let unavailableReason {
                    Label(unavailableReason, systemImage: "info.circle")
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                composer
            }
            .animation(.smooth(duration: 0.2), value: isMentioning || isPickingRecipe)
            .padding(.horizontal, 40)
            .padding(.bottom, 22)
            .frame(maxWidth: 780)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                if !model.archiveExchanges.isEmpty {
                    Button("Yeni sohbet", systemImage: "square.and.pencil") {
                        model.clearArchiveConversation()
                        mentioned = []
                        isFocused = true
                    }
                    .controlSize(.small)
                    .hoverHint("Önceki cevaplar bağlam olmaz; bu sohbet geçmişte kalır", alignment: .trailing, edge: .bottom)
                }
            }
            .padding(16)
        }
    }

    private let bottomID: String = "ask-bottom"

    /// Sor şu an kullanılamıyorsa nedeni (sunucu çağrılmadan): abonelikte denemesi henüz başlamamış hesap toplantı dışı
    /// yapay zekâyı kullanamaz (sunucu `trial_not_started` derdi).
    private var unavailableReason: String? {
        #if HOSTED_EDITION
        hostedAskUnavailableReason(account: .shared)
        #else
        nil
        #endif
    }

    /// Sağ üst köşede "Yeni sohbet" düğmesi var mı.
    private var hasCornerButtons: Bool {
        !model.archiveExchanges.isEmpty
    }

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
                        ? (model.archiveExchanges.isEmpty ? "Toplantılarına bir şey sor… (@ toplantı, / tarif)" : "Devam sorusu sor…")
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
                    .disabled(isEmpty || unavailableReason != nil)
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
        // Öneri seçilirken gönderilmez; eşleşen öneri yoksa ("@Mikko ne dedi?") soru olduğu gibi gider.
        guard !model.isAnsweringArchive, !isMentioning, !isPickingRecipe, unavailableReason == nil,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        model.askArchive(question: question, meetingIDs: mentioned.map(\.id), recipeTitle: nil)
        question = ""
        // Etiket bu soruya aitti: sohbette sorunun üstünde kalır, soru alanından kalkar.
        withAnimation(.smooth(duration: 0.2)) { mentioned = [] }
    }

    /// `@` önerileri açık: sondaki `@` bahsine eşleşen toplantı var.
    private var isMentioning: Bool {
        mentionQuery(text: question) != nil && !suggestions.isEmpty
    }

    /// "/" önerileri açık: eşleşen tarif var.
    private var isPickingRecipe: Bool {
        recipeQuery(text: question) != nil && !recipeMatches.isEmpty
    }

    /// "/" ile eşleşen tarifler.
    private var recipeMatches: [Recipe] {
        recipeCandidates(recipes: model.recipes, query: recipeQuery(text: question) ?? "")
    }

    /// Tarifi çalıştırır: etiketli toplantılar varsa onlara, yoksa tüm arşive.
    private func run(recipe: Recipe) {
        guard !model.isAnsweringArchive else {
            return
        }
        model.askArchive(question: recipe.prompt, meetingIDs: mentioned.map(\.id), recipeTitle: recipe.title)
        question = ""
        highlighted = 0
        withAnimation(.smooth(duration: 0.2)) { mentioned = [] }
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
        let count: Int = isMentioning ? suggestions.count : (isPickingRecipe ? recipeMatches.count : 0)
        guard count > 0 else {
            return .ignored
        }
        highlighted = (highlighted + step + count) % count
        return .handled
    }

    /// Öneriler açıkken Return seçili toplantıyı ekler (soru gönderilmez).
    private func pickHighlighted() -> KeyPress.Result {
        if isPickingRecipe {
            if recipeMatches.indices.contains(highlighted) {
                run(recipe: recipeMatches[highlighted])
            }
            return .handled
        }
        guard isMentioning else {
            return .ignored
        }
        if suggestions.indices.contains(highlighted) {
            pick(record: suggestions[highlighted])
        }
        return .handled
    }

    /// Escape önerileri kapatır: yazılan "@…" silinir.
    private func dismissSuggestions() -> KeyPress.Result {
        if isPickingRecipe {
            question = ""
            return .handled
        }
        guard isMentioning else {
            return .ignored
        }
        question = removingMentionQuery(text: question)
        return .handled
    }
}

/// Sohbet geçmişi: soldaki ince sütunda yeniden eskiye sohbetler (başlık ve tarih); açık sohbet gri hap. Üzerine gelince
/// çöp simgesi çıkar; ilk tık "Sil" onayına döner, ikinci tık siler (açılır pencere yok).
private struct AskHistoryColumn: View {
    let model: AppModel
    let onOpen: @MainActor (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("GEÇMİŞ")
                .appFont(size: 11, weight: .semibold)
                .tracking(DesignTokens.labelTracking)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.askConversations) { (conversation: AskConversation) in
                        AskHistoryRow(conversation: conversation, isSelected: model.currentConversationID == conversation.id) {
                            onOpen(conversation.id)
                        } onDelete: {
                            model.deleteConversation(id: conversation.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 248)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }
}

/// Geçmişte bir sohbet satırı: başlık (iki satıra kadar) ve son güncelleme tarihi; üzerine gelince silme.
private struct AskHistoryRow: View {
    let conversation: AskConversation
    let isSelected: Bool
    let onOpen: @MainActor () -> Void
    let onDelete: @MainActor () -> Void
    @State private var isHovering: Bool = false
    @State private var isConfirmingDelete: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title)
                        .appFont(size: 13, weight: isSelected ? .medium : .regular)
                        .foregroundStyle(Theme.ink.opacity(isSelected ? 1 : 0.85))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(conversation.updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))
                        .appFont(size: 11, weight: .regular)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isHovering || isConfirmingDelete {
                Button {
                    if isConfirmingDelete {
                        onDelete()
                    } else {
                        isConfirmingDelete = true
                    }
                } label: {
                    Group {
                        if isConfirmingDelete {
                            Text("Sil").appFont(size: 11, weight: .semibold).foregroundStyle(.red)
                        } else {
                            Image(systemName: "trash").appFont(size: 11, weight: .medium).foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(minWidth: 22, minHeight: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .accessibilityLabel("Sohbeti sil")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { (hovering: Bool) -> Void in
            isHovering = hovering
            if !hovering {
                isConfirmingDelete = false
            }
        }
        .contextMenu {
            Button("Sohbeti sil", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

/// Boş sayfa: film gradyanlı giriş (arşivin büyüklüğüyle) ve örnek soru kartları.
private struct AskIntro: View {
    let meetings: [MeetingRecord]
    let onAsk: @MainActor (String) -> Void
    /// Not ve çeviri dili (Ayarlar › Genel): cevapların dili metinde adıyla geçer.
    @AppStorage(SettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue

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
                        .foregroundStyle(Color.black.opacity(0.7))
                    Text("Toplantılarına sor")
                        .appFont(size: 32, weight: .semibold)
                        .tracking(-0.8)
                        .foregroundStyle(Color.black)
                    Text("Notların ve transkriptlerin (hangi dilde konuşulduysa) arasında arar, \(storedNoteLanguage(value: noteLanguage).interfaceName) cevaplar; her bilginin hangi toplantıdan geldiğini gösterir.")
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Color.black.opacity(0.66))
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
            .foregroundStyle(Color.black.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.55), in: Capsule())
    }
}
