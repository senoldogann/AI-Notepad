import AINotepadCore
import AINotepadUI
import os
import SwiftUI

/// Arşiv sohbeti: soru-cevaplar ve süren cevap. Cevabı Mac'teki `askArchive` yazar (arama terimleri → parçalar → akan
/// cevap); devam soruları önceki cevapları bağlam alır.
@MainActor
@Observable
final class PhoneAsk {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneAsk")

    private(set) var exchanges: [ArchiveExchange] = []
    private(set) var isAnswering: Bool = false
    @ObservationIgnored private let store: PhoneStore
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: PhoneStore) {
        self.store = store
    }

    /// Soruyu arşive sorar; cevap akarak gelir.
    func ask(question: String) {
        let trimmed: String = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else {
            return
        }
        let history: [ArchiveTurn] = exchanges.compactMap { (exchange: ArchiveExchange) -> ArchiveTurn? in
            exchange.phase == .done ? ArchiveTurn(question: exchange.question, answer: exchange.answer.text, sources: exchange.answer.sources) : nil
        }
        let id: UUID = UUID()
        exchanges.append(ArchiveExchange(
            id: id, question: trimmed, startedAt: Date(), phase: .understanding, terms: [], passages: [],
            answer: ArchiveAnswer(text: "", sources: []), finishedAt: nil, modelName: nil
        ))
        isAnswering = true
        let records: [MeetingRecord] = store.meetings
        task = Task { [weak self] in
            do {
                let provider: LLMProvider = try await phoneLLMProvider()
                self?.update(id: id) { $0.modelName = llmModelDisplayName(provider: provider, tier: .smart) }
                _ = try await askArchive(
                    question: trimmed, history: history, records: records, userName: phoneUserName(), llm: provider, maxChars: 60_000, now: Date()
                ) { [weak self] (progress: ArchiveProgress) -> Void in
                    await self?.apply(progress: progress, id: id)
                }
                self?.finish(id: id, phase: .done)
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

    /// Sohbeti temizler (yeni konu: önceki cevaplar bağlam olmaz).
    func clear() {
        task?.cancel()
        exchanges = []
    }

    private func finish(id: UUID, phase: ArchiveExchange.Phase) {
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
    @FocusState private var isFocused: Bool

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
                        if ask.exchanges.isEmpty {
                            intro
                        }
                        ForEach(ask.exchanges) { (exchange: ArchiveExchange) in
                            ExchangeView(exchange: exchange) { (passage: ArchivePassage) -> Void in
                                router.open(meetingID: passage.meetingID)
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
                composer
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            .background(Theme.background)
            .navigationTitle("Sor")
            .navigationBarTitleDisplayMode(ask.exchanges.isEmpty ? .large : .inline)
            .toolbar {
                if !ask.exchanges.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Yeni sohbet", systemImage: "square.and.pencil") {
                            ask.clear()
                        }
                    }
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
                    .foregroundStyle(.white.opacity(0.9))
                Text("Toplantılarına sor")
                    .appFont(size: 28, weight: .regular)
                    .tracking(-0.5)
                    .foregroundStyle(.white)
                Text("Notların ve transkriptlerin (hangi dilde konuşulduysa) arasında arar, Türkçe cevaplar; her bilginin hangi toplantıdan geldiğini gösterir.")
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    GlassChip(text: String(localized: "\(store.meetings.count) toplantı"), systemImage: nil)
                    GlassChip(text: String(localized: "\(max(0, minutes / 60)) sa \(minutes % 60) dk konuşma"), systemImage: nil)
                }
                .padding(.top, 2)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { LivingFilmGradient(seed: "ask", palette: .violet) }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, .dark)
            PhoneSectionHeader(title: "Örnek sorular", actionTitle: nil, action: nil)
                .padding(.top, 4)
            ForEach(examples, id: \.text) { (example: (symbol: String, text: String)) in
                Button {
                    ask.ask(question: String(localized: String.LocalizationValue(example.text)))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: example.symbol)
                            .appFont(size: 15, weight: .medium)
                            .foregroundStyle(Theme.muted)
                            .frame(width: 22)
                        Text(LocalizedStringKey(example.text))
                            .appFont(size: 15, weight: .regular)
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .appFont(size: 11, weight: .semibold)
                            .foregroundStyle(Theme.muted.opacity(0.7))
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
                }
                .buttonStyle(PressableCardStyle())
                .disabled(store.meetings.isEmpty)
            }
        }
    }

    private var composer: some View {
        let isEmpty: Bool = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return HStack(alignment: .bottom, spacing: 10) {
            TextField(ask.exchanges.isEmpty ? "Toplantılarına bir şey sor…" : "Devam sorusu sor…", text: $question, axis: .vertical)
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

    private func send() {
        guard !ask.isAnswering else {
            return
        }
        ask.ask(question: question)
        question = ""
        isFocused = false
    }
}
