import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Toplantılarıma sor: tüm notlar ve transkriptler arasında sohbet, sade bir LLM akışı gibi: çalışırken tek satır
/// parıltılı "Düşünüyor…", cevap akarak yumuşakça gelir, altında küçük ve kapalı "Kaynaklar" ve "nasıl cevaplandı"
/// satırları; metindeki [1] işaretleri toplantıyı açar. Devam soruları önceki cevapları bağlam alır. Boşken film
/// gradyanlı giriş ve örnek sorular. Sohbetler saklanır; "Geçmiş" soldaki ince sütunda açılır (yeniden aç, sil).
///
/// Soru alanı: Enter gönderir, Shift+Enter yeni satır. `@` yazınca alanın üstünde toplantı önerileri açılır (yazdıkça
/// süzülür; ↑/↓ gezinir, Tab ya da Enter seçer, Esc kapatır); seçilen toplantı alanda kaldırılabilir etiket olur ve soru
/// yalnız etiketli toplantılara sorulur. Boş alanda ↑ son soruyu düzenlemeye getirir; öneri kapalıyken Esc alanı temizler.
struct AskPage: View {
    let model: AppModel
    let router: MainWindowRouter
    @State private var question: String = ""
    /// Soru alanında imlecin konumu (UTF-16): `@` bahsi imlecin önünde aranır.
    @State private var cursor: Int = 0
    /// `@` ile etiketlenen toplantılar: soru yalnız onlara sorulur; soru gönderilince alandan kalkar.
    @State private var mentioned: [MeetingRecord] = []
    /// `@` ya da "/" önerilerinde klavyeyle seçili satır.
    @State private var highlighted: Int = 0
    /// Esc ile kapatılan `@` bahsinin başlangıcı: aynı bahiste öneriler yeniden açılmaz (yeni `@` açar).
    @State private var dismissedMentionStart: Int?
    /// "/" önerileri Esc ile kapatıldı: soru "/" ile başladıkça yeniden açılmaz.
    @State private var isRecipeDismissed: Bool = false
    @State private var isFocused: Bool = false
    /// Arttıkça soru alanı odağı alır.
    @State private var focusRequest: Int = 0
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    /// Soldaki sohbet geçmişi sütunu açık (düğmesi pencerenin üst çubuğunda).
    @AppStorage(SettingsKey.askHistoryVisible) private var isShowingHistory: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if isShowingHistory, !model.askConversations.isEmpty {
                AskHistoryColumn(model: model) { (id: UUID) -> Void in
                    model.openConversation(id: id)
                    mentioned = []
                    focusRequest += 1
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            chat
        }
        .animation(.smooth(duration: 0.25), value: isShowingHistory)
        #if DEBUG
        .task { await applyDemoDraft() }
        #endif
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
                        // Liste kısaldı: seçili satır listenin dışında kalmasın.
                        highlighted = 0
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
                Text("Enter gönderir · Shift+Enter yeni satır · @ toplantı seç")
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(Theme.muted.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .animation(.smooth(duration: 0.2), value: isMentioning || isPickingRecipe)
            .padding(.horizontal, 40)
            .padding(.bottom, 14)
            .frame(maxWidth: 780)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                if !model.archiveExchanges.isEmpty {
                    Button("Yeni sohbet", systemImage: "square.and.pencil") {
                        model.clearArchiveConversation()
                        mentioned = []
                        focusRequest += 1
                    }
                    .controlSize(.small)
                    .hoverHint("Önceki cevaplar bağlam olmaz; bu sohbet geçmişte kalır", alignment: .trailing, edge: .bottom)
                }
            }
            .padding(16)
        }
        .onChange(of: question) { (_: String, _: String) in
            highlighted = 0
            resetDismissedSuggestions()
        }
        .onChange(of: cursor) { (_: Int, _: Int) in
            // İmleç başka bir bahse geçince liste değişir: seçili satır baştan başlar.
            highlighted = 0
            resetDismissedSuggestions()
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

    /// Soru alanının yer tutucusu (ve VoiceOver etiketi).
    private var placeholder: String {
        if !mentioned.isEmpty {
            return String(localized: "Etiketlenen toplantılara sor…")
        }
        return model.archiveExchanges.isEmpty
            ? String(localized: "Toplantılarına bir şey sor… (@ toplantı, / tarif)")
            : String(localized: "Devam sorusu sor…")
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
                            focusRequest += 1
                        }
                    }
                }
                .padding(.top, 4)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Etiketlenen toplantılar")
            }
            HStack(alignment: .bottom, spacing: 10) {
                AskInputField(
                    text: $question, cursor: $cursor, accessibilityLabel: placeholder, font: askInputFont(appearance: appearance, size: 15),
                    textColor: NSColor(Theme.ink), maxLines: 6, focusRequest: focusRequest
                ) { (focused: Bool) -> Void in
                    isFocused = focused
                } onCommand: { (command: AskInputCommand) -> Bool in
                    handle(command: command)
                }
                .overlay(alignment: .topLeading) {
                    if question.isEmpty {
                        Text(placeholder)
                            .appFont(size: 15, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
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

    /// Soru alanının tuş komutu; true dönerse işlendi (işlenmeyen ↑/↓ imleci taşır, Tab odağı geçirir).
    private func handle(command: AskInputCommand) -> Bool {
        switch command {
        case .submit:
            submit()
            return true
        case .moveUp:
            guard isMentioning || isPickingRecipe else {
                return recallLastQuestion()
            }
            moveHighlight(by: -1)
            return true
        case .moveDown:
            guard isMentioning || isPickingRecipe else {
                return false
            }
            moveHighlight(by: 1)
            return true
        case .complete:
            guard isMentioning else {
                return false
            }
            pick(record: suggestions[highlighted])
            return true
        case .cancel:
            return cancel()
        }
    }

    /// Enter: öneri açıksa seçili satırı seçer (soru gönderilmez), değilse soruyu gönderir.
    private func submit() {
        if isMentioning {
            pick(record: suggestions[highlighted])
        } else if isPickingRecipe {
            run(recipe: recipeMatches[highlighted])
        } else {
            send()
        }
    }

    private func send() {
        // Öneri seçilirken gönderilmez; eşleşen öneri yoksa ("@Mikko ne dedi?") soru olduğu gibi gider.
        guard !model.isAnsweringArchive, !isMentioning, !isPickingRecipe, unavailableReason == nil,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        #if HOSTED_EDITION
        // Hakkı yoksa soru alanı temizlenmez (abone olunca yeniden gönderilebilsin); teklif açılır.
        if HostedAccount.shared.requiresSubscription {
            HostedAccount.shared.requestSubscription()
            return
        }
        #endif
        model.askArchive(question: question, meetingIDs: mentioned.map(\.id), recipeTitle: nil)
        clearInput()
    }

    /// Soru alanını ve etiketleri boşaltır (etiket bu soruya aitti: sohbette sorunun üstünde kalır).
    private func clearInput() {
        cursor = 0
        question = ""
        highlighted = 0
        withAnimation(.smooth(duration: 0.2)) { mentioned = [] }
    }

    /// Boş alanda ↑: sohbetteki son soru düzenlemeye gelir (imleç sonda). Alan doluysa ya da soru yoksa işlenmez.
    private func recallLastQuestion() -> Bool {
        guard question.isEmpty, let last = lastAskedQuestion(exchanges: model.archiveExchanges) else {
            return false
        }
        cursor = last.utf16.count
        question = last
        return true
    }

    /// Esc: önce açık öneriyi kapatır (yazılan metin kalır), öneri yoksa alanı ve etiketleri temizler.
    private func cancel() -> Bool {
        if isMentioning, let mention = mentionQuery(text: question, cursor: cursor) {
            dismissedMentionStart = mention.start
            return true
        }
        if isPickingRecipe {
            isRecipeDismissed = true
            return true
        }
        guard !question.isEmpty || !mentioned.isEmpty else {
            return false
        }
        clearInput()
        return true
    }

    /// Kapatılan öneri, bahsi ya da "/" silinince unutulur (yeniden yazılınca açılsın).
    private func resetDismissedSuggestions() {
        if let dismissed = dismissedMentionStart, mentionQuery(text: question, cursor: cursor)?.start != dismissed {
            dismissedMentionStart = nil
        }
        if isRecipeDismissed, recipeQuery(text: question) == nil {
            isRecipeDismissed = false
        }
    }

    /// `@` önerileri açık: imlecin önünde (Esc ile kapatılmamış) bahse eşleşen toplantı var.
    private var isMentioning: Bool {
        !suggestions.isEmpty
    }

    /// "/" önerileri açık: eşleşen tarif var.
    private var isPickingRecipe: Bool {
        !recipeMatches.isEmpty
    }

    /// "/" ile eşleşen tarifler; "/" yoksa ya da Esc ile kapatıldıysa boş.
    private var recipeMatches: [Recipe] {
        guard !isRecipeDismissed, let query = recipeQuery(text: question) else {
            return []
        }
        return recipeCandidates(recipes: model.recipes, query: query)
    }

    /// Tarifi çalıştırır: etiketli toplantılar varsa onlara, yoksa tüm arşive.
    private func run(recipe: Recipe) {
        guard !model.isAnsweringArchive, unavailableReason == nil else {
            return
        }
        model.askArchive(question: recipe.prompt, meetingIDs: mentioned.map(\.id), recipeTitle: recipe.title)
        clearInput()
    }

    /// `@` önerileri (en fazla 6): imlecin önündeki bahse eşleşen toplantılar; bahis yoksa ya da Esc ile kapatıldıysa boş.
    private var suggestions: [MeetingRecord] {
        guard let mention = mentionQuery(text: question, cursor: cursor), mention.start != dismissedMentionStart else {
            return []
        }
        return mentionCandidates(records: model.meetings, query: mention.query, excluding: mentioned.map(\.id), limit: 6)
    }

    /// Toplantıyı etikete ekler; yazılan "@…" silinir, imleç onun yerine gelir.
    private func pick(record: MeetingRecord) {
        guard let edit = removingMention(text: question, cursor: cursor) else {
            preconditionFailure("Toplantı önerisi seçildi ama imlecin önünde @ bahsi yok")
        }
        withAnimation(.smooth(duration: 0.2)) { mentioned.append(record) }
        cursor = edit.cursor
        question = edit.text
        highlighted = 0
        focusRequest += 1
    }

    private func moveHighlight(by step: Int) {
        let count: Int = isMentioning ? suggestions.count : recipeMatches.count
        highlighted = (highlighted + step + count) % count
    }

    #if DEBUG
    /// Tanıtım modunda (`--tanitim-soru`, `--tanitim-etiket`) soru alanına taslak ve etiketler yazılır (görsel kontrol).
    private func applyDemoDraft() async {
        guard isDemoMode, let draft = demoAskDraft(arguments: CommandLine.arguments) else {
            return
        }
        for _ in 0..<40 where model.meetings.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
        mentioned = Array(mentionCandidates(records: model.meetings, query: "", excluding: [], limit: draft.chips))
        cursor = draft.question.utf16.count
        question = draft.question
    }
    #endif
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
