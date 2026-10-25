import AINotepadCore
import SwiftUI

/// Canlı transkript: üstte durum satırı, ortada bölümler, altta hatalar.
struct LiveTranscriptView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusBar(model: model)
                .padding(10)
            Divider()
            ScrollViewReader { (proxy: ScrollViewProxy) in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.transcript) { (segment: LiveSegment) in
                            SegmentRow(segment: segment)
                                .id(segment.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: model.transcript.last?.id) { (_: SegmentID?, newValue: SegmentID?) in
                    if let newValue {
                        withAnimation { proxy.scrollTo(newValue, anchor: .bottom) }
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

/// Model durumu, kayıt süresi ve dil.
private struct StatusBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isRecording, let startedAt = model.recordingStartedAt {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                TimelineView(.periodic(from: startedAt, by: 1)) { (context: TimelineViewDefaultContext) in
                    Text(elapsedText(from: startedAt, to: context.date)).monospacedDigit()
                }
            } else {
                Text(modelStatusText(status: model.modelStatus))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(languageText(locked: model.lockedLanguage, mode: model.languageMode, isRecording: model.isRecording))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

/// Tek bölüm: konuşmacı etiketi ve metin. Geçici metin soluk, hata kırmızı.
private struct SegmentRow: View {
    let segment: LiveSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(speakerLabel(speaker: segment.id.speaker))
                .font(.caption.weight(.semibold))
                .foregroundStyle(segment.id.speaker == .me ? Color.accentColor : Color.secondary)
            if let failure = segment.failureMessage {
                Text("Yazıya dökülemedi: \(failure)")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(segment.text)
                    .opacity(segment.isFinal ? 1 : 0.5)
                    .textSelection(.enabled)
            }
        }
    }
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

private func elapsedText(from start: Date, to now: Date) -> String {
    let total: Int = max(0, Int(now.timeIntervalSince(start)))
    return String(format: "%02d:%02d", total / 60, total % 60)
}
