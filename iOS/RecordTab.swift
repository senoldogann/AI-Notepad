import AINotepadCore
import AINotepadUI
import SwiftUI

/// Kayıt sekmesi: boştayken dil seçimi ve büyük kayıt düğmesi; kayıtta süre, ses çubukları, konuşmacılı canlı metin ve
/// Türkçe çevirisi; bitince toplantının hazırlanma adımları.
struct RecordTab: View {
    let recorder: PhoneRecorder

    var body: some View {
        NavigationStack {
            Group {
                switch recorder.phase {
                case .idle, .starting:
                    RecordHome(recorder: recorder)
                case .recording, .finishing:
                    LiveRecordingView(recorder: recorder)
                }
            }
            .background(Theme.background)
        }
    }
}

/// Kayıt öncesi: dil, kayıt düğmesi, kısa açıklama, hatalar ve son toplantının hazırlanma kartı.
private struct RecordHome: View {
    let recorder: PhoneRecorder
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                Spacer(minLength: 36)
                Menu {
                    Button("Otomatik") { recorder.languageMode = .automatic }
                    LanguageMenuItems { (language: MeetingLanguage) -> Void in recorder.setLanguage(language: language) }
                } label: {
                    HStack(spacing: 6) {
                        Text(languageText(locked: nil, mode: recorder.languageMode, isRecording: false))
                        Image(systemName: "chevron.down").appFont(size: 11, weight: .semibold)
                    }
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.soft, in: Capsule())
                }
                Button {
                    Task { await recorder.start() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(appearance.accent.color)
                            .frame(width: 116, height: 116)
                            .shadow(color: appearance.accent.color.opacity(0.35), radius: 18, y: 8)
                        if recorder.phase == .starting {
                            ProgressView().tint(.white).controlSize(.large)
                        } else {
                            Image(systemName: "mic.fill")
                                .appFont(size: 40, weight: .regular)
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(recorder.phase == .starting)
                .accessibilityLabel("Kaydı başlat")
                VStack(spacing: 8) {
                    Text("Yüz yüze toplantını kaydet")
                        .appFont(size: 22, weight: .regular)
                        .tracking(-0.3)
                    Text("Odadaki konuşmayı telefon mikrofonuyla yazıya döker, konuşmacıları ayırır ve Türkçeye çevirir; bitince notu yazar. Telefondaki Teams/Zoom görüşmeleri kaydedilemez (iOS izin vermez); onlar için Mac'i kullan.")
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 12)
                ErrorList(messages: recorder.errorMessages)
                if let id = recorder.lastMeetingID, let step = recorder.processingSteps[id] {
                    PreparingCard(step: step)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .navigationTitle("Kayıt")
    }
}

/// Kayıt sırasında: süre, dil, ses çubukları, canlı metin (en alta kayar) ve "Bitir".
private struct LiveRecordingView: View {
    let recorder: PhoneRecorder
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    private var blocks: [SpeakerBlock] {
        groupBySpeaker(transcript: recorder.transcript.filter { !$0.text.isEmpty })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ErrorList(messages: recorder.errorMessages)
                .padding(.horizontal, 16)
            ScrollViewReader { (proxy: ScrollViewProxy) in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if blocks.isEmpty {
                            Text("Dinliyor… Konuşma başlayınca metin burada akar.")
                                .appFont(size: 15, weight: .regular)
                                .foregroundStyle(Theme.muted)
                                .padding(.top, 40)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(blocks) { (block: SpeakerBlock) in
                            LiveBlockView(block: block, translations: recorder.translations)
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(16)
                }
                .onChange(of: recorder.transcript) {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }
            footer
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private let bottomID: String = "son"

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 9, height: 9)
                if let startedAt = recorder.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { (context: TimelineViewDefaultContext) in
                        Text(timestamp(seconds: context.date.timeIntervalSince(startedAt)))
                            .appFont(size: 17, weight: .semibold)
                            .monospacedDigit()
                    }
                }
                Spacer()
                Menu {
                    LanguageMenuItems { (language: MeetingLanguage) -> Void in recorder.setLanguage(language: language) }
                } label: {
                    Text(languageText(locked: recorder.lockedLanguage, mode: recorder.languageMode, isRecording: true))
                        .appFont(size: 13, weight: .medium)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.soft, in: Capsule())
                }
                .disabled(recorder.phase != .recording)
            }
            LevelMeter(levels: recorder.levels)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        Group {
            if recorder.phase == .finishing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Bitiriliyor…").appFont(size: 16, weight: .medium)
                }
                .frame(maxWidth: .infinity, minHeight: 54)
            } else {
                Button {
                    recorder.stop()
                } label: {
                    Label("Bitir", systemImage: "stop.fill")
                        .appFont(size: 17, weight: .semibold)
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Theme.primary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Bir konuşmacının ardışık cümleleri: ad, özgün metin (geçici kısım soluk) ve Türkçesi.
private struct LiveBlockView: View {
    let block: SpeakerBlock
    let translations: [SegmentID: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(speakerLabel(speaker: block.speaker, person: block.person))
                .appFont(size: 12, weight: .semibold)
                .foregroundStyle(block.person.map { personColor(person: $0) } ?? Theme.muted)
            Text("\(Text(finalText))\(Text(partialText).foregroundStyle(Theme.muted))")
                .appFont(size: 17, weight: .regular)
                .lineSpacing(3)
            if !turkish.isEmpty {
                Text(turkish)
                    .appFont(size: 15, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var finalText: String {
        block.segments.filter(\.isFinal).map(\.text).joined(separator: " ")
    }

    private var partialText: String {
        let partial: String = block.segments.filter { !$0.isFinal }.map(\.text).joined(separator: " ")
        return finalText.isEmpty || partial.isEmpty ? partial : " " + partial
    }

    private var turkish: String {
        block.segments.compactMap { translations[$0.id] }.joined(separator: " ")
    }
}

/// Toplantı hazırlanıyor: adımlar (biten ✓, süren gösterge, bekleyen soluk).
private struct PreparingCard: View {
    let step: ProcessingStep

    private let titles: [LocalizedStringKey] = ["Ses kaydı hazırlanıyor", "Kaydın tamamı işleniyor", "Not hazırlanıyor"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Toplantı hazırlanıyor")
                .appFont(size: 16, weight: .semibold)
            ForEach(Array(titles.enumerated()), id: \.offset) { (item: (offset: Int, element: LocalizedStringKey)) in
                HStack(spacing: 10) {
                    Group {
                        if item.offset < step.rawValue {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if item.offset == step.rawValue {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(item.element)
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(item.offset > step.rawValue ? Theme.muted : Theme.ink)
                }
            }
            Text("Not hazır olunca Toplantılar'da görünür. Uygulamayı kapatırsan hazırlık sonraki açılışta sürer.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Hata satırları (turuncu, okunur boyutta).
private struct ErrorList: View {
    let messages: [String]

    var body: some View {
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(messages, id: \.self) { (message: String) in
                    Label(message, systemImage: "exclamationmark.triangle")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
