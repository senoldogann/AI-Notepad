import AINotepadCore
import AppKit
import SwiftUI

/// Canlı transkript: üstte durum satırı, ortada konuşmacı blokları, altta hatalar.
struct LiveTranscriptView: View {
    let model: AppModel

    var body: some View {
        // Hoparlörden mikrofona giren ses ("Diğerleri"nin "Sen" altında tekrarı) gösterilmez.
        let blocks: [SpeakerBlock] = groupBySpeaker(transcript: suppressEchoes(transcript: model.transcript))
        VStack(alignment: .leading, spacing: 0) {
            StatusBar(model: model, blocks: blocks)
                .padding(10)
            Divider()
            ScrollViewReader { (proxy: ScrollViewProxy) in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(blocks) { (block: SpeakerBlock) in
                            BlockRow(block: block)
                                .id(block.id)
                        }
                    }
                    .padding(10)
                }
                // Blok içinde metin büyüdüğünde de en alta kaydır.
                .onChange(of: model.transcript) { (_: [LiveSegment], _: [LiveSegment]) in
                    if let last = blocks.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            if !model.errorMessages.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.errorMessages, id: \.self) { (message: String) in
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
            }
        }
        .frame(minWidth: 280, minHeight: 240)
    }
}

/// Model durumu, kayıt süresi, dil ve "Tümünü kopyala".
private struct StatusBar: View {
    let model: AppModel
    let blocks: [SpeakerBlock]

    var body: some View {
        HStack(spacing: 8) {
            if model.isRecording, let startedAt = model.recordingStartedAt {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                TimelineView(.periodic(from: startedAt, by: 1)) { (context: TimelineViewDefaultContext) in
                    Text(timestamp(seconds: context.date.timeIntervalSince(startedAt))).monospacedDigit()
                }
            } else {
                Text(model.liveEngine == .deepgram ? "Hazır · Deepgram" : modelStatusText(status: model.modelStatus))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(languageText(locked: model.lockedLanguage, mode: model.languageMode, isRecording: model.isRecording))
                .foregroundStyle(.secondary)
            Button {
                copyToPasteboard(text: plainText(blocks: blocks))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Tümünü kopyala")
            .disabled(blocks.isEmpty)
        }
        .font(.callout)
    }
}

/// Bir konuşmacı bloğu: etiket, akan metin (geçici kısım soluk), varsa hatalar.
private struct BlockRow: View {
    let block: SpeakerBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(speakerLabel(speaker: block.speaker, person: block.person))
                .font(.caption.weight(.semibold))
                .foregroundStyle(block.speaker == .me ? Color.accentColor : Color.secondary)
            blockText
                .textSelection(.enabled)
            ForEach(block.segments.filter { (segment: LiveSegment) -> Bool in segment.failureMessage != nil }) { (segment: LiveSegment) in
                Text("Yazıya dökülemedi: \(segment.failureMessage ?? "")")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .contextMenu {
            Button("Kopyala") {
                copyToPasteboard(text: plainText(blocks: [block]))
            }
        }
    }

    /// Bölümleri tek paragrafta birleştirir; geçici metin soluk gösterilir.
    private var blockText: Text {
        block.segments
            .filter { (segment: LiveSegment) -> Bool in segment.failureMessage == nil && !segment.text.isEmpty }
            .enumerated()
            .reduce(Text("")) { (combined: Text, item: (offset: Int, element: LiveSegment)) -> Text in
                let piece: Text = Text((item.offset == 0 ? "" : " ") + item.element.text)
                let styled: Text = item.element.isFinal ? piece : piece.foregroundStyle(.secondary)
                return Text("\(combined)\(styled)")
            }
    }
}

/// Metni genel panoya yazar.
@MainActor
private func copyToPasteboard(text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private func modelStatusText(status: ModelStatus) -> String {
    switch status {
    case .loading: "Model hazırlanıyor…"
    case .ready: "Hazır"
    case .failed(let message): message
    }
}

private func languageText(locked: MeetingLanguage?, mode: LanguageMode, isRecording: Bool) -> String {
    if let locked {
        return languageName(language: locked)
    }
    switch mode {
    case .fixed(let language):
        return languageName(language: language)
    case .automatic:
        return isRecording ? "Dil algılanıyor…" : "Dil: Otomatik"
    }
}

func languageName(language: MeetingLanguage) -> String {
    switch language {
    case .finnish: "🇫🇮 Fince"
    case .english: "🇬🇧 İngilizce"
    }
}
