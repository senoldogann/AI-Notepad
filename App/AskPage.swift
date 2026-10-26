import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Toplantılarıma sor: tüm notlar ve transkriptler arasında sohbet. Her cevabın üstünde ajanın adımları (arama
/// terimleri, okunan toplantılar, yazan model ve süre), cevap akarak yumuşakça gelir; metindeki [1] işaretleri ve
/// altındaki kaynak kartları toplantıyı açar. Devam soruları önceki cevapları bağlam alır. Boşken film gradyanlı giriş
/// ve örnek sorular.
struct AskPage: View {
    let model: AppModel
    let router: MainWindowRouter
    @State private var question: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { (proxy: ScrollViewProxy) in
                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        if model.archiveExchanges.isEmpty {
                            AskIntro(meetings: model.meetings) { (example: String) -> Void in
                                model.askArchive(question: example)
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
            composer
                .padding(.horizontal, 40)
                .padding(.bottom, 22)
                .frame(maxWidth: 780)
        }
        .overlay(alignment: .topTrailing) {
            if !model.archiveExchanges.isEmpty {
                Button("Yeni sohbet", systemImage: "square.and.pencil") {
                    model.clearArchiveConversation()
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
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    model.archiveExchanges.isEmpty ? "Toplantılarına bir şey sor…" : "Devam sorusu sor…",
                    text: $question, axis: .vertical
                )
                .textFieldStyle(.plain)
                .appFont(size: 15, weight: .regular)
                .lineLimit(1...6)
                .focused($isFocused)
                .onSubmit(send)
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
        guard !model.isAnsweringArchive else {
            return
        }
        model.askArchive(question: question)
        question = ""
    }
}

/// Ajan çalışırken giriş alanının çerçevesinde dönen yumuşak renk halkası.
private struct ThinkingRing: View {
    let shape: RoundedRectangle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { (context: TimelineViewDefaultContext) in
            let angle: Double = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 360
            shape.strokeBorder(
                AngularGradient(
                    colors: [Color(red: 0.95, green: 0.55, blue: 0.35), Color(red: 0.62, green: 0.48, blue: 0.95), Color(red: 0.35, green: 0.65, blue: 0.95), Color(red: 0.95, green: 0.55, blue: 0.35)],
                    center: .center, angle: .degrees(angle)
                ),
                lineWidth: 1.5
            )
        }
        .allowsHitTesting(false)
    }
}

/// Boş sayfa: film gradyanlı giriş (arşivin büyüklüğüyle) ve örnek soru kartları.
private struct AskIntro: View {
    let meetings: [MeetingRecord]
    let onAsk: @MainActor (String) -> Void

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
                    Text("Notların ve Fince/İngilizce transkriptlerin arasında arar, Türkçe cevaplar; her bilginin hangi toplantıdan geldiğini gösterir.")
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
                ForEach(examples, id: \.text) { (example: (symbol: String, text: String)) in
                    Button {
                        onAsk(String(localized: String.LocalizationValue(example.text)))
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: example.symbol)
                                .appFont(size: 14, weight: .medium)
                                .foregroundStyle(Theme.muted)
                                .frame(width: 20)
                            Text(LocalizedStringKey(example.text))
                                .appFont(size: 14, weight: .regular)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .appFont(size: 11, weight: .semibold)
                                .foregroundStyle(Theme.muted.opacity(0.7))
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                        .cardSurface(cornerRadius: 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverPlain)
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

/// Bir soru ve cevabı: soru sağda, altında ajanın adımları, akan cevap (kaynak işaretleriyle) ve kaynak kartları.
private struct ExchangeView: View {
    let exchange: ArchiveExchange
    let onOpen: @MainActor (ArchivePassage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer(minLength: 80)
                Text(exchange.question)
                    .appFont(size: 15, weight: .regular)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.soft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
            AgentTrace(exchange: exchange)
            if !exchange.answer.text.isEmpty {
                StreamingAnswer(exchange: exchange) { (number: Int) -> Void in
                    if exchange.answer.sources.indices.contains(number - 1) {
                        onOpen(exchange.answer.sources[number - 1])
                    }
                }
            }
            switch exchange.phase {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            case .stopped:
                Label("Durduruldu", systemImage: "stop.circle")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.muted)
            case .understanding, .searching, .writing, .done:
                EmptyView()
            }
            if !exchange.answer.sources.isEmpty {
                SourceCards(sources: exchange.answer.sources, onOpen: onOpen)
            }
            if exchange.phase == .done {
                AnswerActions(exchange: exchange)
            }
        }
    }
}

/// Ajanın adımları: soruyu anlama (terimler), arşivi tarama (okunan toplantılar), cevabı yazma (model). Çalışırken
/// açık; bitince tek satıra katlanır ("3 adım · 5 toplantı · 4,2 sn"), tıklayınca açılır.
private struct AgentTrace: View {
    let exchange: ArchiveExchange
    @State private var isExpanded: Bool = false
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    private var isWorking: Bool {
        [.understanding, .searching, .writing].contains(exchange.phase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isWorking || isExpanded {
                steps
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !isWorking {
                Button {
                    withAnimation(.smooth(duration: 0.3)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text(summary)
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, isExpanded ? 10 : 0)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
            }
        }
        .animation(.smooth(duration: 0.3), value: exchange.phase)
    }

    /// "Nasıl cevapladım · 5 toplantı, 12 parça · 4,2 sn".
    private var summary: String {
        let meetings: Int = Set(exchange.passages.map(\.meetingID)).count
        let seconds: Double = (exchange.finishedAt ?? Date()).timeIntervalSince(exchange.startedAt)
        let duration: String = seconds.formatted(.number.precision(.fractionLength(1)).locale(interfaceLocale()))
        return String(localized: "Nasıl cevapladım · \(meetings) toplantı, \(exchange.passages.count) parça · \(duration) sn")
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            TraceStep(
                symbol: "text.magnifyingglass", title: "Soruyu anlıyor", doneTitle: "Arama terimleri",
                state: stepState(order: 0), isLast: false
            ) {
                if !exchange.terms.isEmpty {
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(Array(exchange.terms.prefix(14).enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                            Text(item.element)
                                .appFont(size: 11, weight: .medium)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.soft, in: Capsule())
                        }
                        if exchange.terms.count > 14 {
                            Text(verbatim: "+\(exchange.terms.count - 14)")
                                .appFont(size: 11, weight: .medium)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            TraceStep(
                symbol: "tray.full", title: "Arşivi tarıyor", doneTitle: "Okunan toplantılar",
                state: stepState(order: 1), isLast: false
            ) {
                if !exchange.passages.isEmpty {
                    let titles: [String] = exchange.passages.reduce(into: [String]()) { (result: inout [String], passage: ArchivePassage) -> Void in
                        if !result.contains(passage.meetingTitle) {
                            result.append(passage.meetingTitle)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(titles.prefix(6).enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                            Label(item.element, systemImage: "doc.text")
                                .appFont(size: 12, weight: .regular)
                                .foregroundStyle(Theme.ink.opacity(0.8))
                                .lineLimit(1)
                        }
                        if titles.count > 6 {
                            Text("ve \(titles.count - 6) toplantı daha")
                                .appFont(size: 12, weight: .regular)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            TraceStep(
                symbol: "pencil.line", title: "Cevabı yazıyor", doneTitle: "Cevap",
                state: stepState(order: 2), isLast: true
            ) {
                if let name = exchange.modelName {
                    Text(name)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    /// Adımın durumu: sırası gelmedi, sürüyor, bitti.
    private func stepState(order: Int) -> TraceStepState {
        let current: Int = switch exchange.phase {
        case .understanding: 0
        case .searching: 1
        case .writing: 2
        case .done, .stopped, .failed: 3
        }
        return order < current ? .done : (order == current ? .active : .waiting)
    }
}

/// Ajan adımının durumu.
private enum TraceStepState {
    case waiting
    case active
    case done
}

/// Ajanın tek adımı: solda durum simgesi ve dikey çizgi, sağda başlık ve ayrıntı.
private struct TraceStep<Detail: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let doneTitle: LocalizedStringKey
    let state: TraceStepState
    let isLast: Bool
    let detail: Detail

    init(symbol: String, title: LocalizedStringKey, doneTitle: LocalizedStringKey, state: TraceStepState, isLast: Bool, @ViewBuilder detail: () -> Detail) {
        self.symbol = symbol
        self.title = title
        self.doneTitle = doneTitle
        self.state = state
        self.isLast = isLast
        self.detail = detail()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(state == .waiting ? Theme.soft : Theme.card)
                        .overlay(Circle().strokeBorder(state == .waiting ? Color.clear : Theme.line))
                        .frame(width: 24, height: 24)
                    switch state {
                    case .waiting:
                        Image(systemName: symbol).appFont(size: 10, weight: .medium).foregroundStyle(Theme.muted.opacity(0.6))
                    case .active:
                        ProgressView().controlSize(.mini)
                    case .done:
                        Image(systemName: "checkmark").appFont(size: 10, weight: .bold).foregroundStyle(Theme.ink)
                    }
                }
                if !isLast {
                    Rectangle().fill(Theme.line).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ShimmerText(text: Text(state == .done ? doneTitle : title), isActive: state == .active)
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(state == .waiting ? Theme.muted.opacity(0.7) : Theme.ink)
                if state != .waiting {
                    detail
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
            Spacer(minLength: 0)
        }
    }
}

/// Çalışan adımın başlığında soldan sağa kayan parıltı.
private struct ShimmerText: View {
    let text: Text
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        if isActive, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { (context: TimelineViewDefaultContext) in
                let phase: Double = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                text.overlay {
                    GeometryReader { (geometry: GeometryProxy) in
                        LinearGradient(colors: [.clear, Theme.background.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.5)
                            .offset(x: (phase * 1.6 - 0.3) * geometry.size.width)
                    }
                    .mask(text)
                    .allowsHitTesting(false)
                }
            }
        } else {
            text
        }
    }
}

/// Akan cevap: gelen metin harf harf yumuşakça açılır (parça büyükse daha hızlı yetişir), yazarken sonda imleç.
/// Markdown (kalın, italik, maddeler) ve tıklanabilir kaynak işaretleri ([1]).
private struct StreamingAnswer: View {
    let exchange: ArchiveExchange
    let onCitation: @MainActor (Int) -> Void
    @State private var shown: Int = 0
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    private var isWriting: Bool {
        exchange.phase == .writing
    }

    var body: some View {
        let full: String = exchange.answer.text
        let visible: String = String(full.prefix(shown))
        Text(isWriting || shown < full.count
            ? answerAttributedText(text: visible, accent: appearance.accent.color) + streamingCaret(accent: appearance.accent.color)
            : answerAttributedText(text: visible, accent: appearance.accent.color))
            .font(appearance.readingFont(size: appearance.textSize + 2, weight: .regular))
            .lineSpacing(appearance.lineSpacing + 3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { (url: URL) -> OpenURLAction.Result in
                guard url.scheme == citationScheme, let number = Int(url.host() ?? "") else {
                    return .systemAction
                }
                onCitation(number)
                return .handled
            })
            .task(id: full) {
                // Bitmiş (ya da yeniden çizilen) cevap beklemeden görünür; akan cevap yakalanana dek açılır.
                if !isWriting, shown == 0 {
                    shown = full.count
                    return
                }
                while shown < full.count, !Task.isCancelled {
                    shown = min(full.count, shown + max(1, (full.count - shown) / 10))
                    do {
                        try await Task.sleep(for: .milliseconds(18))
                    } catch {
                        return
                    }
                }
            }
    }
}

/// Kaynak işaretlerinin bağlantı şeması (`ainotepad-source://3`).
private let citationScheme: String = "ainotepad-source"

/// Cevap metnini biçimler: satır başı "- " madde işareti olur, **kalın** yazı kalınlaşır, [n] işaretleri küçük,
/// yükseltilmiş, vurgu renkli bağlantılara dönüşür (tıklayınca kaynak açılır). Akarken yarım kalan "**" düz görünür.
/// Saf fonksiyondur.
private func answerAttributedText(text: String, accent: Color) -> AttributedString {
    let bulleted: String = text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { (line: Substring) -> String in
            let trimmed: Substring = line.drop { $0 == " " }
            return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") ? "•  " + trimmed.dropFirst(2) : String(line)
        }
        .joined(separator: "\n")
    let token: Regex<(Substring, Substring?, Substring?)> = /\*\*(.+?)\*\*|\[(\d+)\]/
    var result: AttributedString = AttributedString()
    var rest: Substring = Substring(bulleted)
    while let match = rest.firstMatch(of: token) {
        result += AttributedString(String(rest[rest.startIndex..<match.range.lowerBound]))
        if let bold = match.output.1 {
            var run: AttributedString = AttributedString(String(bold))
            run.inlinePresentationIntent = .stronglyEmphasized
            result += run
        } else if let number = match.output.2 {
            var run: AttributedString = AttributedString("\u{2009}\(number)\u{2009}")
            run.link = URL(string: "\(citationScheme)://\(number)")
            run.foregroundColor = accent
            run.baselineOffset = 5
            run.font = .system(size: 10, weight: .bold)
            result += run
        }
        rest = rest[match.range.upperBound...]
    }
    result += AttributedString(String(rest))
    return result
}

/// Cevap akarken sondaki imleç. Saf fonksiyondur.
private func streamingCaret(accent: Color) -> AttributedString {
    var cursor: AttributedString = AttributedString(" ▍")
    cursor.foregroundColor = accent.opacity(0.7)
    return cursor
}

/// Kaynak kartları: numara (metindeki [n]), toplantı, tarih ve zaman, parçanın başı; tıklayınca toplantı açılır.
private struct SourceCards: View {
    let sources: [ArchivePassage]
    let onOpen: @MainActor (ArchivePassage) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KAYNAKLAR")
                .appFont(size: 11, weight: .semibold)
                .tracking(DesignTokens.labelTracking)
                .foregroundStyle(Theme.muted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { (item: (offset: Int, element: ArchivePassage)) in
                    Button {
                        onOpen(item.element)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(verbatim: "\(item.offset + 1)")
                                    .appFont(size: 10, weight: .bold)
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(appearance.accent.color, in: Circle())
                                Text(item.element.meetingTitle)
                                    .appFont(size: 13, weight: .medium)
                                    .lineLimit(1)
                            }
                            Label(sourceDetail(source: item.element), systemImage: item.element.kind == .note ? "doc.text" : "text.bubble")
                                .appFont(size: 11, weight: .regular)
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                            Text(sourceSnippet(source: item.element))
                                .appFont(size: 12, weight: .regular)
                                .foregroundStyle(Theme.ink.opacity(0.72))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .cardSurface(cornerRadius: 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverPlain)
                    .hoverHint("Toplantıyı aç", alignment: .leading, edge: .bottom)
                }
            }
        }
        .transition(.opacity)
    }

    /// "26 Eki · not" ya da "26 Eki · 04:12".
    private func sourceDetail(source: ArchivePassage) -> String {
        let date: String = source.meetingDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale()))
        let place: String = source.kind == .note ? String(localized: "not") : timestamp(seconds: source.startSec)
        return "\(date) · \(place)"
    }

    /// Parçanın ilk anlamlı satırı (zaman ve konuşmacı öneki atılır).
    private func sourceSnippet(source: ArchivePassage) -> String {
        let line: String = source.text.split(separator: "\n").first.map(String.init) ?? ""
        let withoutTime: String = line.replacing(/^\[\d+:\d+(:\d+)?\]\s*/, with: "")
        return withoutTime.replacing(/^Özet:\s*/, with: "")
    }
}

/// Bitmiş cevabın altındaki eylemler: kopyala.
private struct AnswerActions: View {
    let exchange: ArchiveExchange
    @State private var copied: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(exchange.answer.text, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Kopyalandı" : "Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.hoverPlain)
        }
        .task(id: copied) {
            guard copied else {
                return
            }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            copied = false
        }
    }
}
