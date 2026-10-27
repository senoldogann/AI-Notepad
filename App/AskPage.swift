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

/// Ajan çalışırken giriş alanının çerçevesinde dönen ince, tek renk ışık.
private struct ThinkingRing: View {
    let shape: RoundedRectangle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { (context: TimelineViewDefaultContext) in
            let angle: Double = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3 * 360
            shape.strokeBorder(
                AngularGradient(
                    colors: [Theme.line, Theme.ink.opacity(0.55), Theme.line, Theme.line],
                    center: .center, angle: .degrees(angle)
                ),
                lineWidth: 1.2
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer(minLength: 80)
                Text(exchange.question)
                    .appFont(size: 15, weight: .regular)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.soft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
            // Çalışırken tek satır "Düşünüyor…" (parıltılı); cevap akmaya başlayınca kalkar.
            if exchange.answer.text.isEmpty, [.understanding, .searching, .writing].contains(exchange.phase) {
                ThinkingLine(exchange: exchange)
                    .transition(.opacity)
            }
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
            if ![.understanding, .searching, .writing].contains(exchange.phase) {
                // Bitince tek sessiz satır: kopyala, kaynaklar ve nasıl cevaplandığı; ayrıntı altta açılır.
                AnswerFooter(exchange: exchange, onOpen: onOpen)
                    .transition(.opacity)
            }
        }
    }
}

/// Çalışırken tek satır: parıltılı durum ("Düşünüyor…", "Arşiv taranıyor…", "8 toplantı okunuyor…").
private struct ThinkingLine: View {
    let exchange: ArchiveExchange
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .appFont(size: 12, weight: .semibold)
                .foregroundStyle(Theme.muted)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            ShimmerText(text: status)
                .appFont(size: 14, weight: .medium)
        }
        .animation(.easeOut(duration: 0.2), value: exchange.phase)
    }

    private var status: Text {
        switch exchange.phase {
        case .searching:
            Text("Arşiv taranıyor…")
        case .writing:
            Text("\(Set(exchange.passages.map(\.meetingID)).count) toplantı okunuyor…")
        case .understanding, .done, .stopped, .failed:
            Text("Düşünüyor…")
        }
    }
}

/// Metnin üstünden soldan sağa yavaşça geçen ışık (düşünme göstergesi); "Hareketi azalt" açıksa durgun ve soluk.
private struct ShimmerText: View {
    let text: Text
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            text.foregroundStyle(Theme.muted)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { (context: TimelineViewDefaultContext) in
                let phase: Double = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                text
                    .foregroundStyle(Theme.muted.opacity(0.75))
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: max(0, phase * 1.6 - 0.5)),
                                .init(color: Theme.ink, location: max(0, phase * 1.6 - 0.3)),
                                .init(color: .clear, location: max(0, phase * 1.6 - 0.1)),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .mask(text)
                        .allowsHitTesting(false)
                    }
            }
        }
    }
}

/// Cevabın altındaki satırda açılabilen ayrıntı.
private enum AnswerDetail: Equatable {
    case sources
    case reasoning
}

/// Bitmiş cevabın altı: kopyala simgesi, "Kaynaklar" ve "8 toplantıdan 42 parça okundu · 6,0 sn" hapları. Bir hapa
/// tıklanınca ayrıntısı altta ince bir kartta açılır (aynı anda biri).
private struct AnswerFooter: View {
    let exchange: ArchiveExchange
    let onOpen: @MainActor (ArchivePassage) -> Void
    @State private var detail: AnswerDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if exchange.phase == .done {
                    CopyAnswerButton(text: exchange.answer.text)
                }
                if !exchange.answer.sources.isEmpty {
                    FooterPill(symbol: "text.quote", isOpen: detail == .sources) {
                        HStack(spacing: 5) {
                            Text("Kaynaklar")
                            Text(verbatim: "\(exchange.answer.sources.count)").fontWeight(.semibold)
                        }
                    } onToggle: {
                        toggle(detail: .sources)
                    }
                }
                FooterPill(symbol: "magnifyingglass", isOpen: detail == .reasoning) {
                    Text(reasoningSummary(exchange: exchange))
                } onToggle: {
                    toggle(detail: .reasoning)
                }
            }
            switch detail {
            case .sources:
                SourcesList(sources: exchange.answer.sources, onOpen: onOpen)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            case .reasoning:
                ReasoningDetails(exchange: exchange)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            case nil:
                EmptyView()
            }
        }
    }

    private func toggle(detail selected: AnswerDetail) {
        withAnimation(.smooth(duration: 0.22)) {
            detail = detail == selected ? nil : selected
        }
    }
}

/// "8 toplantıdan 42 parça okundu · 6,0 sn".
private func reasoningSummary(exchange: ArchiveExchange) -> String {
    let meetings: Int = Set(exchange.passages.map(\.meetingTitle)).count
    let seconds: Double = (exchange.finishedAt ?? Date()).timeIntervalSince(exchange.startedAt)
    let duration: String = seconds.formatted(.number.precision(.fractionLength(1)).locale(interfaceLocale()))
    return String(localized: "\(meetings) toplantıdan \(exchange.passages.count) parça okundu · \(duration) sn")
}

/// Cevap altındaki küçük, soluk hap: simge, metin ve dönen ok; açıkken hafif dolgulu.
private struct FooterPill<Label: View>: View {
    let symbol: String
    let isOpen: Bool
    @ViewBuilder let label: () -> Label
    let onToggle: @MainActor () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .appFont(size: 10, weight: .semibold)
                label()
                Image(systemName: "chevron.down")
                    .appFont(size: 8, weight: .bold)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(isOpen ? Theme.ink : Theme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOpen ? Theme.selected : Theme.soft, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverPlain)
    }
}

/// Nasıl cevaplandı: arama terimleri, okunan toplantılar ve model, ince kartta küçük yazıyla.
private struct ReasoningDetails: View {
    let exchange: ArchiveExchange

    var body: some View {
        let titles: [String] = exchange.passages.reduce(into: [String]()) { (result: inout [String], passage: ArchivePassage) -> Void in
            if !result.contains(passage.meetingTitle) {
                result.append(passage.meetingTitle)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            if !exchange.terms.isEmpty {
                row(label: "Aranan", value: exchange.terms.joined(separator: ", "))
            }
            if !titles.isEmpty {
                row(label: "Okunan", value: titles.joined(separator: " · "))
            }
            if let model = exchange.modelName {
                row(label: "Model", value: model)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .appFont(size: 11, weight: .medium)
                .foregroundStyle(Theme.muted)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.ink.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
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
/// yükseltilmiş, vurgu renkli bağlantılara dönüşür (tıklayınca kaynak açılır). Akarken yarım kalan "**" düz görünür,
/// yarım kaynak işareti gizlenir.
/// Saf fonksiyondur.
private func answerAttributedText(text: String, accent: Color) -> AttributedString {
    // Harf harf açılırken yarım kalan kaynak işareti ("[1") görünmesin.
    let bulleted: String = text.replacing(/\[\d*$/, with: "")
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

/// Kaynaklar: numaralı ince satırlar (numara metindeki [n]; toplantı, tarih, not ya da zaman), ince kartta. Tıklayınca
/// toplantı açılır.
private struct SourcesList: View {
    let sources: [ArchivePassage]
    let onOpen: @MainActor (ArchivePassage) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { (item: (offset: Int, element: ArchivePassage)) in
                Button {
                    onOpen(item.element)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: "\(item.offset + 1)")
                            .appFont(size: 10, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(appearance.accent.color)
                            .frame(width: 14, alignment: .trailing)
                        Text(item.element.meetingTitle)
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.ink.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(sourceDetail(source: item.element))
                            .appFont(size: 11, weight: .regular)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .fixedSize()
                        Image(systemName: "arrow.up.right")
                            .appFont(size: 9, weight: .semibold)
                            .foregroundStyle(Theme.muted.opacity(0.8))
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .hoverHint("Toplantıyı aç", alignment: .leading, edge: .bottom)
            }
        }
        .padding(6)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Theme.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// "26 Eki · not" ya da "26 Eki · 04:12".
    private func sourceDetail(source: ArchivePassage) -> String {
        let date: String = source.meetingDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale()))
        let place: String = source.kind == .note ? String(localized: "not") : timestamp(seconds: source.startSec)
        return "\(date) · \(place)"
    }
}

/// Cevabı kopyalar; yalnız simge (sohbet uygulamalarındaki gibi), kısa süre onay işareti gösterir.
private struct CopyAnswerButton: View {
    let text: String
    @State private var copied: Bool = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(copied ? Theme.ink : Theme.muted)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.hoverPlain)
        .hoverHint(copied ? "Kopyalandı" : "Kopyala", alignment: .leading, edge: .bottom)
        .accessibilityLabel(copied ? "Kopyalandı" : "Kopyala")
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
