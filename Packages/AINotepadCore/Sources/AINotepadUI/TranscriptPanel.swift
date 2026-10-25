import AINotepadCore
import AppKit
import SwiftUI

/// Canlı transkriptin Liquid Glass paneli: üst satırda durum ve eylemler, gövdede konuşmacı blokları,
/// altta son hatalar. Yalnızca `LiveViewState` ile beslenir.
public struct TranscriptPanel: View {
    let state: LiveViewState
    let onHide: @MainActor () -> Void

    public init(state: LiveViewState, onHide: @escaping @MainActor () -> Void) {
        self.state = state
        self.onHide = onHide
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DesignTokens.Spacing.l)
                .padding(.vertical, DesignTokens.Spacing.m)
            Divider().opacity(0.35)
            transcript
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
            IconButton(symbol: "doc.on.doc", help: "Tümünü kopyala") {
                copyToPasteboard(text: plainText(blocks: state.blocks))
            }
            .disabled(state.blocks.isEmpty)
            IconButton(symbol: "minus", help: "Paneli gizle", action: onHide)
        }
    }

    private var transcript: some View {
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                    ForEach(state.blocks) { (block: SpeakerBlock) in
                        BlockView(block: block)
                            .id(block.id)
                    }
                }
                .padding(DesignTokens.Spacing.l)
            }
            // Blok içinde metin büyüdüğünde de en alta kaydır.
            .onChange(of: state.blocks) { (_: [SpeakerBlock], blocks: [SpeakerBlock]) in
                if let last = blocks.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
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

/// Konuşmacı bloğu: renk noktası, etiket ve akan metin (kesinleşmemiş kısım soluk).
struct BlockView: View {
    let block: SpeakerBlock

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.s) {
            Circle()
                .fill(blockColor(block: block))
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { (dimensions: ViewDimensions) -> CGFloat in dimensions[.bottom] }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(speakerLabel(speaker: block.speaker, person: block.person).uppercased())
                    .font(DesignTokens.labelFont)
                    .tracking(DesignTokens.labelTracking)
                    .foregroundStyle(blockColor(block: block))
                flowingText
                    .font(DesignTokens.bodyFont)
                    .lineSpacing(DesignTokens.bodyLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
