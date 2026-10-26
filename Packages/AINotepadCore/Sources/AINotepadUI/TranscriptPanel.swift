import AINotepadCore
import AppKit
import SwiftUI

/// Panelin kullanıcı eylemleri.
public struct PanelActions {
    public let onHide: @MainActor () -> Void
    public let onStop: @MainActor () -> Void
    public let onMissed: @MainActor () -> Void
    public let onAsk: @MainActor (String) -> Void
    public let onCloseCard: @MainActor () -> Void

    public init(
        onHide: @escaping @MainActor () -> Void,
        onStop: @escaping @MainActor () -> Void,
        onMissed: @escaping @MainActor () -> Void,
        onAsk: @escaping @MainActor (String) -> Void,
        onCloseCard: @escaping @MainActor () -> Void
    ) {
        self.onHide = onHide
        self.onStop = onStop
        self.onMissed = onMissed
        self.onAsk = onAsk
        self.onCloseCard = onCloseCard
    }
}

/// Canlı transkriptin Liquid Glass paneli: üst satırda durum ve eylemler, gövdede konuşmacı blokları (Türkçesiyle),
/// altta asistan kartı, "Ne kaçırdım?" ve soru alanı, son hatalar. Yalnızca `LiveViewState` ile beslenir.
public struct TranscriptPanel: View {
    let state: LiveViewState
    let actions: PanelActions
    @State private var question: String = ""

    public init(state: LiveViewState, actions: PanelActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DesignTokens.Spacing.l)
                .padding(.vertical, DesignTokens.Spacing.m)
            Divider().opacity(0.35)
            transcript
            if let card = state.assistantCard {
                AssistantCardView(card: card, onClose: actions.onCloseCard)
                    .padding(.horizontal, DesignTokens.Spacing.m)
                    .padding(.bottom, DesignTokens.Spacing.s)
            }
            footer
                .padding(.horizontal, DesignTokens.Spacing.m)
                .padding(.bottom, DesignTokens.Spacing.m)
            if !state.errors.isEmpty {
                errorBand
            }
        }
        .frame(minWidth: 300, minHeight: 240)
        // Hata bandı gibi dolgular yuvarlak köşelerin dışına taşmasın.
        .clipShape(.rect(cornerRadius: DesignTokens.panelRadius))
        .glassEffect(.regular, in: .rect(cornerRadius: DesignTokens.panelRadius))
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            StatusLabel(state: state)
            Spacer(minLength: DesignTokens.Spacing.s)
            Text(state.languageText)
                .font(DesignTokens.statusFont)
                .padding(.horizontal, DesignTokens.Spacing.s)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.chipRadius))
            if state.isRecording {
                IconButton(symbol: "stop.circle", help: "Kaydı durdur", action: actions.onStop)
            }
            IconButton(symbol: "doc.on.doc", help: "Tümünü kopyala") {
                copyToPasteboard(text: plainText(blocks: state.blocks))
            }
            .disabled(state.blocks.isEmpty)
            IconButton(symbol: "minus", help: "Paneli gizle", action: actions.onHide)
        }
    }

    private var transcript: some View {
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                    ForEach(state.blocks) { (block: SpeakerBlock) in
                        BlockView(
                            block: block,
                            turkish: blockTurkishText(block: block, translations: state.translations),
                            translations: state.translations,
                            displayMode: state.displayMode
                        )
                        .id(block.id)
                    }
                }
                .padding(DesignTokens.Spacing.l)
            }
            // Blok içinde metin büyüdüğünde ya da çeviri geldiğinde en alta kaydır.
            .onChange(of: state.blocks) { (_: [SpeakerBlock], blocks: [SpeakerBlock]) in
                if let last = blocks.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: state.translations.count) { (_: Int, _: Int) in
                if let last = state.blocks.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// "Ne kaçırdım?" düğmesi ve Türkçe soru alanı.
    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            Button(action: actions.onMissed) {
                Label("Ne kaçırdım?", systemImage: "sparkles")
                    .font(DesignTokens.statusFont)
                    .padding(.horizontal, DesignTokens.Spacing.m)
                    .padding(.vertical, 6)
                    .background(DesignTokens.meColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(state.blocks.isEmpty)
            TextField("Toplantı hakkında sor…", text: $question)
                .textFieldStyle(.plain)
                .font(DesignTokens.statusFont)
                .padding(.horizontal, DesignTokens.Spacing.m)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
                .onSubmit {
                    let trimmed: String = question.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        return
                    }
                    actions.onAsk(trimmed)
                    question = ""
                }
        }
    }

    private var errorBand: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ForEach(state.errors, id: \.self) { (message: String) in
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.Spacing.l)
        .padding(.vertical, DesignTokens.Spacing.s)
        .background(Color.red.opacity(0.12))
    }
}

/// Kayıt sırasında kırmızı nokta + süre, değilse durum metni.
struct StatusLabel: View {
    let state: LiveViewState

    var body: some View {
        if state.isRecording, let startedAt = state.startedAt {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 7, height: 7)
                TimelineView(.periodic(from: startedAt, by: 1)) { (context: TimelineViewDefaultContext) in
                    Text(timestamp(seconds: context.date.timeIntervalSince(startedAt)))
                        .font(DesignTokens.statusFont)
                        .monospacedDigit()
                }
            }
        } else {
            Text(state.statusText)
                .font(DesignTokens.statusFont)
                .foregroundStyle(.secondary)
        }
    }
}

/// Konuşmacı bloğu: renk noktası, etiket, akan metin (kesinleşmemiş kısım soluk) ve Türkçesi.
/// İki dilde orijinal küçük ve soluk, Türkçe asıl metin; "Sadece Türkçe"de çevirisi olmayan metin orijinal kalır.
struct BlockView: View {
    let block: SpeakerBlock
    let turkish: String?
    let translations: [SegmentID: String]
    let displayMode: DisplayMode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.s) {
            Circle()
                .fill(blockColor(block: block))
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { (dimensions: ViewDimensions) -> CGFloat in dimensions[.bottom] }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                // Renk yalnızca noktada: renkli küçük etiket camda yeterince okunmuyor.
                Text(speakerLabel(speaker: block.speaker, person: block.person).uppercased())
                    .font(DesignTokens.labelFont)
                    .tracking(DesignTokens.labelTracking)
                    .foregroundStyle(.secondary)
                if displayMode == .turkishOnly && turkish != nil {
                    turkishOnlyText
                        .font(DesignTokens.bodyFont)
                        .lineSpacing(DesignTokens.bodyLineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    flowingText
                        .font(turkish == nil ? DesignTokens.bodyFont : .system(size: 13))
                        .opacity(turkish == nil ? 1 : 0.6)
                        .lineSpacing(DesignTokens.bodyLineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if displayMode == .bilingual, let turkish {
                    Text(turkish)
                        .font(DesignTokens.bodyFont)
                        .lineSpacing(DesignTokens.bodyLineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(block.segments.filter { (segment: LiveSegment) -> Bool in segment.failureMessage != nil }) { (segment: LiveSegment) in
                    Text("Yazıya dökülemedi: \(segment.failureMessage ?? "")")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
        }
        .contextMenu {
            Button("Kopyala") {
                copyToPasteboard(text: plainText(blocks: [block]))
            }
        }
    }

    /// "Sadece Türkçe": çevrilen bölümler Türkçe, henüz çevrilmeyenler orijinal ve soluk.
    private var turkishOnlyText: Text {
        turkishOnlyParts(block: block, translations: translations)
            .enumerated()
            .reduce(Text("")) { (combined: Text, item: (offset: Int, element: DisplayPart)) -> Text in
                let piece: Text = Text((item.offset == 0 ? "" : " ") + item.element.text)
                let styled: Text = item.element.isTranslated ? piece : piece.foregroundColor(Color.primary.opacity(DesignTokens.partialOpacity))
                return Text("\(combined)\(styled)")
            }
    }

    /// Bölümleri tek paragrafta birleştirir; kesinleşmemiş metin soluk.
    private var flowingText: Text {
        block.segments
            .filter { (segment: LiveSegment) -> Bool in segment.failureMessage == nil && !segment.text.isEmpty }
            .enumerated()
            .reduce(Text("")) { (combined: Text, item: (offset: Int, element: LiveSegment)) -> Text in
                let piece: Text = Text((item.offset == 0 ? "" : " ") + item.element.text)
                let styled: Text = item.element.isFinal ? piece : piece.foregroundColor(Color.primary.opacity(DesignTokens.partialOpacity))
                return Text("\(combined)\(styled)")
            }
    }
}

/// Asistan kartı: yükleniyor, "Ne kaçırdım?" özeti, soru cevabı ya da hata; kapatılabilir.
struct AssistantCardView: View {
    let card: AssistantCard
    let onClose: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            HStack {
                Text(title)
                    .font(DesignTokens.labelFont)
                    .tracking(DesignTokens.labelTracking)
                    .foregroundStyle(.secondary)
                Spacer()
                IconButton(symbol: "xmark", help: "Kapat", action: onClose)
            }
            content
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignTokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private var title: String {
        switch card {
        case .loading(let title): title.uppercased()
        case .summary: "NE KAÇIRDIM?"
        case .answer: "CEVAP"
        case .failed: "HATA"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch card {
        case .loading:
            ProgressView().controlSize(.small)
        case .summary(let summary):
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.topic)
                if !summary.decisions.isEmpty {
                    Text("Kararlar").font(DesignTokens.labelFont).foregroundStyle(.secondary)
                    ForEach(summary.decisions, id: \.self) { (item: String) in Text("• " + item) }
                }
                if !summary.askedOfYou.isEmpty {
                    Text("Senden istenenler").font(DesignTokens.labelFont).foregroundStyle(DesignTokens.meColor)
                    ForEach(summary.askedOfYou, id: \.self) { (item: String) in Text("• " + item) }
                }
            }
        case .answer(let question, let text):
            VStack(alignment: .leading, spacing: 4) {
                Text(question).foregroundStyle(.secondary)
                Text(text)
            }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }
}

/// Sade ikon düğmesi.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// "Sen" vurgu rengi, atanmış kişi kendi rengi, atanmamış "Diğerleri" ikincil renk.
func blockColor(block: SpeakerBlock) -> Color {
    switch (block.speaker, block.person) {
    case (_, .some(let person)): personColor(person: person)
    case (.me, nil): DesignTokens.meColor
    case (.others, nil): .secondary
    }
}

/// Metni genel panoya yazar.
@MainActor
func copyToPasteboard(text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
