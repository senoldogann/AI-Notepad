import AINotepadCore
import AINotepadUI
import os
import SwiftUI

/// Arşiv sohbeti: soru-cevaplar ve süren cevap. Cevabı Mac'teki `askArchive` yazar (arama terimleri → parçalar → akan
/// cevap); devam soruları önceki cevapları bağlam alır. Sohbetler her cevaptan sonra bu iPhone'da saklanır (iCloud'a
/// eşitlenmez) ve geçmişten yeniden açılır.
@MainActor
@Observable
final class PhoneAsk {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneAsk")

    private(set) var exchanges: [ArchiveExchange] = []
    private(set) var isAnswering: Bool = false
    /// Saklanan sohbetler (yeniden eskiye; en fazla `askHistoryLimit`).
    private(set) var conversations: [AskConversation] = []
    /// Açık sohbetin kimliği: ilk cevap saklanınca atanır, "Yeni sohbet"te nil.
    private(set) var currentConversationID: UUID?
    /// Sohbet geçmişinin okunamama, saklanamama ya da silinememe nedeni.
    private(set) var historyError: String?
    @ObservationIgnored private let store: PhoneStore
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: PhoneStore) {
        self.store = store
    }

    /// Soruyu arşive sorar; cevap akarak gelir. `meetingIDs` boş değilse yalnız o toplantılara (`@` ile etiketlenenler).
    /// Kullanıcının kaydettiği tarifler.
    private(set) var userRecipes: [Recipe] = []
    /// Tariflerin okunamama ya da saklanamama nedeni.
    private(set) var recipeError: String?

    /// Yerleşik ve kullanıcı tarifleri.
    var recipes: [Recipe] {
        builtInRecipes() + userRecipes
    }

    /// Kayıtlı tarifleri okur.
    func loadRecipes() {
        do {
            userRecipes = try loadUserRecipes(defaults: .standard)
        } catch {
            recipeError = userFacingMessage(error: error)
        }
    }

    /// Soruyu tarif olarak kaydeder.
    func saveRecipe(question: String) {
        store(recipes: userRecipes + [recipeFromQuestion(question: question, id: UUID().uuidString)])
    }

    /// Kullanıcı tarifini siler.
    func deleteRecipe(id: String) {
        store(recipes: userRecipes.filter { $0.id != id })
    }

    private func store(recipes: [Recipe]) {
        do {
            try saveUserRecipes(recipes: recipes, defaults: .standard)
            userRecipes = recipes
        } catch {
            recipeError = userFacingMessage(error: error)
        }
    }

    func ask(question: String, meetingIDs: [String], recipeTitle: String?) {
        let trimmed: String = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else {
            return
        }
        let history: [ArchiveTurn] = archiveHistory(exchanges: exchanges)
        let id: UUID = UUID()
        let scoped: [MeetingRecord] = store.meetings.filter { meetingIDs.contains($0.id) }
        exchanges.append(ArchiveExchange(
            id: id, question: trimmed, scopeMeetingIDs: scoped.map(\.id), scopeTitles: scoped.map { $0.note?.title ?? $0.title }, recipeTitle: recipeTitle, startedAt: Date(), phase: .understanding,
            terms: [], passages: [], answer: ArchiveAnswer(text: "", sources: []), finishedAt: nil, modelName: nil
        ))
        isAnswering = true
        let records: [MeetingRecord] = store.meetings
        task = Task { [weak self] in
            do {
                let provider: LLMProvider = try await phoneLLMProvider()
                self?.update(id: id) { $0.modelName = llmModelDisplayName(provider: provider, tier: .smart) }
                let onProgress: ArchiveProgressHandler = { [weak self] (progress: ArchiveProgress) -> Void in
                    await self?.apply(progress: progress, id: id)
                }
                if scoped.isEmpty {
                    // Cihaz içi modelde dili desteklenmeyen toplantılar okunmaz; model satırında hangileri yazılır.
                    let readable: OnDeviceReadableRecords = try onDeviceAskableArchive(records: records, provider: provider, outputLanguage: phoneNoteLanguage())
                    self?.update(id: id) { $0.modelName = askModelName(provider: provider, readable: readable) }
                    _ = try await askArchive(
                        question: trimmed, history: history, records: readable.records, userName: phoneUserName(), language: phoneNoteLanguage(), llm: provider,
                        maxChars: noteLimits(provider: provider).archiveChars, now: Date(), onProgress: onProgress
                    )
                } else {
                    try requireOnDeviceLanguages(provider: provider, meetingLanguages: scoped.compactMap(\.language), outputLanguage: phoneNoteLanguage())
                    _ = try await askAboutMeetings(
                        question: trimmed, history: history, records: scoped, userName: phoneUserName(), language: phoneNoteLanguage(), llm: provider,
                        maxChars: noteLimits(provider: provider).archiveChars,
                        now: Date(), onProgress: onProgress
                    )
                }
                self?.finish(id: id, phase: .done)
                self?.saveConversation(exchangeID: id)
            } catch is CancellationError {
                self?.finish(id: id, phase: .stopped)
            } catch let error as URLError where error.code == .cancelled {
                self?.finish(id: id, phase: .stopped)
            } catch {
                Self.logger.error("Arşiv sorusu cevaplanamadı, hata: \(String(describing: error), privacy: .private)")
                self?.finish(id: id, phase: .failed(userFacingMessage(error: error)))
            }
        }
    }

    /// Akan cevabı durdurur; o ana kadar yazılan kalır.
    func stop() {
        task?.cancel()
    }

    /// Sohbeti temizler (yeni konu: önceki cevaplar bağlam olmaz); önceki sohbet geçmişte kalır.
    func clear() {
        task?.cancel()
        exchanges = []
        currentConversationID = nil
        isAnswering = false
    }

    /// Saklanan sohbetleri okur (açılışta); okunamayan dosyalar loglanır ve sayısı gösterilir.
    func loadHistory() {
        do {
            let result: AskHistoryLoadResult = try loadAskConversations(directory: try AppPaths.askHistoryDirectory())
            conversations = result.conversations
            for failure in result.failures {
                Self.logger.error("Sohbet okunamadı, dosya: \(failure.file, privacy: .public), neden: \(failure.reason, privacy: .private)")
            }
            historyError = result.failures.isEmpty ? nil : String(localized: "Sohbet geçmişinden \(result.failures.count) sohbet okunamadı.")
        } catch {
            Self.logger.error("Sohbet geçmişi okunamadı, hata: \(String(describing: error), privacy: .private)")
            historyError = String(localized: "Sohbet geçmişi okunamadı: \(userFacingMessage(error: error))")
        }
    }

    /// Saklanan sohbeti açar; devam soruları onun cevaplarını bağlam alır. Süren cevap durdurulur.
    func open(conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else {
            return
        }
        task?.cancel()
        exchanges = conversation.turns.map { (turn: AskConversationTurn) -> ArchiveExchange in archiveExchange(turn: turn) }
        currentConversationID = conversationID
        isAnswering = false
    }

    /// Sohbeti geçmişten siler; açık sohbetse sohbet boşalır.
    func delete(conversationID: UUID) {
        do {
            try deleteAskConversation(id: conversationID, directory: try AppPaths.askHistoryDirectory())
            conversations.removeAll { $0.id == conversationID }
            if currentConversationID == conversationID {
                clear()
            }
        } catch {
            Self.logger.error("Sohbet silinemedi, sohbet: \(conversationID.uuidString, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            historyError = String(localized: "Sohbet silinemedi: \(userFacingMessage(error: error))")
        }
    }

    /// Bitmiş soruyla açık sohbeti saklar (ilk cevapta yeni sohbet olur); sınırı aşan en eski sohbetler silinir.
    private func saveConversation(exchangeID: UUID) {
        // Sohbet bu arada değiştiyse (yeni sohbet, başka sohbet açıldı) cevap bu sohbete ait değildir.
        guard exchanges.contains(where: { $0.id == exchangeID && $0.phase == .done }) else {
            return
        }
        let id: UUID = currentConversationID ?? UUID()
        let turns: [AskConversationTurn] = exchanges.compactMap { (exchange: ArchiveExchange) -> AskConversationTurn? in askTurn(exchange: exchange) }
        let conversation: AskConversation = askConversation(existing: conversations.first { $0.id == id }, id: id, turns: turns, now: Date())
        do {
            let directory: URL = try AppPaths.askHistoryDirectory()
            try saveAskConversation(conversation: conversation, directory: directory)
            currentConversationID = id
            conversations = upsertAskConversation(conversations: conversations, conversation: conversation)
            for old in askConversationsBeyondLimit(conversations: conversations, limit: askHistoryLimit) {
                try deleteAskConversation(id: old.id, directory: directory)
                conversations.removeAll { $0.id == old.id }
            }
        } catch {
            Self.logger.error("Sohbet saklanamadı, sohbet: \(id.uuidString, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            historyError = String(localized: "Sohbet saklanamadı: \(userFacingMessage(error: error))")
        }
    }

    private func finish(id: UUID, phase: ArchiveExchange.Phase) {
        // Sohbet bu arada temizlendi ya da değişti: yeni sorunun durumuna dokunulmaz.
        guard exchanges.contains(where: { $0.id == id }) else {
            return
        }
        update(id: id) {
            $0.phase = phase
            $0.finishedAt = Date()
        }
        isAnswering = false
    }

    private func apply(progress: ArchiveProgress, id: UUID) {
        update(id: id) { (exchange: inout ArchiveExchange) -> Void in
            switch progress {
            case .searchTerms(let terms):
                exchange.terms = terms
                exchange.phase = .searching
            case .passages(let passages):
                exchange.passages = passages
                exchange.phase = .writing
            case .answer(let answer):
                exchange.answer = answer
            }
        }
    }

    private func update(id: UUID, change: (inout ArchiveExchange) -> Void) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&exchanges[index])
    }
}

/// Sor sekmesi: boşken örnek sorular; sohbet (Mac'teki ile aynı görünüm) ve altta soru alanı.
struct AskTab: View {
    let ask: PhoneAsk
    let store: PhoneStore
    let router: PhoneRouter
    @State private var question: String = ""
    /// `@` ile etiketlenen toplantılar: soru yalnız onlara sorulur; soru gönderilince alandan kalkar.
    @State private var mentioned: [MeetingRecord] = []
    @FocusState private var isFocused: Bool
    /// Sohbet geçmişi listesi açık (gezinme yığınında).
    @State private var isShowingHistory: Bool = false
    /// Not ve çeviri dili (Ayarlar): cevapların dili metinde adıyla geçer.
    @AppStorage(PhoneSettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue

    private let examples: [(symbol: String, text: String)] = [
        ("checklist", "Bana hangi görevler verildi?"),
        ("checkmark.seal", "Son toplantılarda alınan kararlar neler?"),
        ("eurosign.circle", "Bütçe hakkında neler konuşuldu?"),
        ("person.2", "Bu hafta kimlerle neler konuştum?"),
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { (proxy: ScrollViewProxy) in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        PhoneErrorList(messages: [ask.historyError, ask.recipeError].compactMap { $0 })
                        if ask.exchanges.isEmpty {
                            intro
                        }
                        ForEach(ask.exchanges) { (exchange: ArchiveExchange) in
                            ExchangeView(exchange: exchange) { (passage: ArchivePassage) -> Void in
                                router.open(meetingID: passage.meetingID)
                            } onSaveRecipe: { (question: String) -> Void in
                                ask.saveRecipe(question: question)
                            }
                            .id(exchange.id)
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: ask.exchanges.last?.answer.text) { (_: String?, _: String?) in
                    if ask.isAnswering {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if isMentioning {
                        MentionSuggestions(
                            candidates: mentionMatches,
                            highlighted: -1
                        ) { (record: MeetingRecord) -> Void in
                            withAnimation(.smooth(duration: 0.2)) { mentioned.append(record) }
                            question = removingMentionQuery(text: question)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if isPickingRecipe {
                        RecipeSuggestions(
                            recipes: recipeMatches, highlighted: -1
                        ) { (recipe: Recipe) -> Void in
                            guard !ask.isAnswering else {
                                return
                            }
                            ask.ask(question: recipe.prompt, meetingIDs: mentioned.map(\.id), recipeTitle: recipe.title)
                            question = ""
                            withAnimation(.smooth(duration: 0.2)) { mentioned = [] }
                            isFocused = false
                        } onDelete: { (recipe: Recipe) -> Void in
                            ask.deleteRecipe(id: recipe.id)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    composer
                }
                .animation(.smooth(duration: 0.2), value: isMentioning || isPickingRecipe)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .background(Theme.background)
            .navigationTitle("Sor")
            .navigationBarTitleDisplayMode(ask.exchanges.isEmpty ? .large : .inline)
            .toolbar {
                if !ask.conversations.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Geçmiş", systemImage: "clock.arrow.circlepath") {
                            isFocused = false
                            isShowingHistory = true
                        }
                    }
                }
                if !ask.exchanges.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Yeni sohbet", systemImage: "square.and.pencil") {
                            ask.clear()
                            mentioned = []
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $isShowingHistory) {
                AskHistoryList(ask: ask) { (id: UUID) -> Void in
                    ask.open(conversationID: id)
                    mentioned = []
                    isShowingHistory = false
                }
            }
        }
    }

    private let bottomID: String = "ask-bottom"

    private var intro: some View {
        let minutes: Int = store.meetings.compactMap { meetingDurationMinutes(record: $0) }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .appFont(size: 20, weight: .medium)
                    .foregroundStyle(Color.black.opacity(0.7))
                // Açık pastel gradyan: yazılar koyu mürekkep (Mac'teki Sor sayfası gibi).
                Text("Toplantılarına sor")
                    .appFont(size: 28, weight: .regular)
                    .tracking(-0.5)
                    .foregroundStyle(Color.black.opacity(0.8))
                Text("Notların ve transkriptlerin (hangi dilde konuşulduysa) arasında arar, \(phoneStoredNoteLanguage(value: noteLanguage).interfaceName) cevaplar; her bilginin hangi toplantıdan geldiğini gösterir.")
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Color.black.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PastelChip(text: String(localized: "\(store.meetings.count) toplantı"), systemImage: nil)
                    PastelChip(text: String(localized: "\(max(0, minutes / 60)) sa \(minutes % 60) dk konuşma"), systemImage: nil)
                }
                .padding(.top, 2)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { FilmGradient(seed: "ask", palette: .violet) }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, .light)
            PhoneSectionHeader(title: "Örnek sorular", actionTitle: nil, action: nil)
                .padding(.top, 4)
            ForEach(Array(examples.enumerated()), id: \.element.text) { (item: (offset: Int, element: (symbol: String, text: String))) in
                ExampleQuestionCard(
                    symbol: item.element.symbol, question: LocalizedStringKey(item.element.text), hint: "Tüm toplantılarında arar",
                    palette: [FilmPalette.sunset, .rose, .sunset, .rose][item.offset % 4]
                ) {
                    ask.ask(question: String(localized: String.LocalizationValue(item.element.text)), meetingIDs: [], recipeTitle: nil)
                }
                .disabled(store.meetings.isEmpty)
            }
        }
    }

    private var composer: some View {
        let isEmpty: Bool = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            if !mentioned.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(mentioned, id: \.id) { (record: MeetingRecord) in
                            RemovableMentionChip(title: record.note?.title ?? record.title) {
                                withAnimation(.smooth(duration: 0.2)) { mentioned.removeAll { $0.id == record.id } }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 10) {
            TextField(
                mentioned.isEmpty
                    ? (ask.exchanges.isEmpty ? "Sor… (@ toplantı, / tarif)" : "Devam sorusu sor…")
                    : "Etiketlenen toplantılara sor…",
                text: $question, axis: .vertical
            )
                .appFont(size: 16, weight: .regular)
                .lineLimit(1...5)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.vertical, 8)
            Button {
                if ask.isAnswering {
                    ask.stop()
                } else {
                    send()
                }
            } label: {
                Image(systemName: ask.isAnswering ? "stop.fill" : "arrow.up")
                    .appFont(size: 14, weight: .bold)
                    .foregroundStyle(Theme.onPrimary)
                    .frame(width: 34, height: 34)
                    .background(isEmpty && !ask.isAnswering ? Theme.muted.opacity(0.5) : Theme.primary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isEmpty && !ask.isAnswering)
            .accessibilityLabel(ask.isAnswering ? "Durdur" : "Sor")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background { shape.fill(Theme.card) }
        .overlay {
            if ask.isAnswering {
                ThinkingRing(shape: shape)
            } else {
                shape.strokeBorder(Theme.line)
            }
        }
        .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
    }

    private var mentionMatches: [MeetingRecord] {
        mentionCandidates(records: store.meetings, query: mentionQuery(text: question) ?? "", excluding: mentioned.map(\.id), limit: 5)
    }

    private var recipeMatches: [Recipe] {
        recipeCandidates(recipes: ask.recipes, query: recipeQuery(text: question) ?? "")
    }

    /// `@` önerileri açık: eşleşen toplantı var.
    private var isMentioning: Bool {
        mentionQuery(text: question) != nil && !mentionMatches.isEmpty
    }

    /// "/" önerileri açık: eşleşen tarif var.
    private var isPickingRecipe: Bool {
        recipeQuery(text: question) != nil && !recipeMatches.isEmpty
    }

    private func send() {
        // Öneri seçilirken gönderilmez; eşleşen öneri yoksa soru olduğu gibi gider.
        guard !ask.isAnswering, !isMentioning, !isPickingRecipe, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        ask.ask(question: question, meetingIDs: mentioned.map(\.id), recipeTitle: nil)
        question = ""
        // Etiket bu soruya aitti: sohbette sorunun üstünde kalır, soru alanından kalkar.
        withAnimation(.smooth(duration: 0.2)) { mentioned = [] }
        isFocused = false
    }
}

/// Sohbet geçmişi: yeniden eskiye sohbetler (başlık ve tarih); dokununca açılır, sola kaydırınca silinir.
private struct AskHistoryList: View {
    let ask: PhoneAsk
    let onOpen: @MainActor (UUID) -> Void

    var body: some View {
        List {
            ForEach(ask.conversations) { (conversation: AskConversation) in
                Button {
                    onOpen(conversation.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversation.title)
                            .appFont(size: 15, weight: ask.currentConversationID == conversation.id ? .semibold : .regular)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                        Text(conversation.updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))
                            .appFont(size: 12, weight: .regular)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, 2)
                }
                .swipeActions {
                    Button("Sil", role: .destructive) { ask.delete(conversationID: conversation.id) }
                }
            }
        }
        .overlay {
            if ask.conversations.isEmpty {
                Text("Saklanan sohbet yok")
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        }
        .navigationTitle("Geçmiş")
        .navigationBarTitleDisplayMode(.inline)
    }
}
