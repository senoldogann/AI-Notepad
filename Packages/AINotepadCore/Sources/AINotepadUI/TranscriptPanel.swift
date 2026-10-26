import AINotepadCore
import AppKit
import SwiftUI

/// Panelin kullanıcı eylemleri.
public struct PanelActions {
    public let onHide: @MainActor () -> Void
    public let onStart: @MainActor () -> Void
    public let onTogglePause: @MainActor () -> Void
    public let onToggleMic: @MainActor () -> Void
    public let onStop: @MainActor () -> Void
    public let onOpenMeetings: @MainActor () -> Void
    public let onOpenSettings: @MainActor () -> Void
    public let onMissed: @MainActor () -> Void
    public let onAsk: @MainActor (String) -> Void
    public let onCloseCard: @MainActor () -> Void
    /// Çevirisi başarısız bölümleri yeniden çevir.
    public let onRetryTranslations: @MainActor ([SegmentID]) -> Void
    /// Kayıt sırasında toplantı dilini değiştir.
    public let onSetLanguage: @MainActor (MeetingLanguage) -> Void

    public init(
        onHide: @escaping @MainActor () -> Void,
        onStart: @escaping @MainActor () -> Void,
        onTogglePause: @escaping @MainActor () -> Void,
        onToggleMic: @escaping @MainActor () -> Void,
        onStop: @escaping @MainActor () -> Void,
        onOpenMeetings: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void,
        onMissed: @escaping @MainActor () -> Void,
        onAsk: @escaping @MainActor (String) -> Void,
        onCloseCard: @escaping @MainActor () -> Void,
        onRetryTranslations: @escaping @MainActor ([SegmentID]) -> Void,
        onSetLanguage: @escaping @MainActor (MeetingLanguage) -> Void
    ) {
        self.onHide = onHide
        self.onStart = onStart
        self.onTogglePause = onTogglePause
        self.onToggleMic = onToggleMic
        self.onStop = onStop
        self.onOpenMeetings = onOpenMeetings
        self.onOpenSettings = onOpenSettings
        self.onMissed = onMissed
        self.onAsk = onAsk
        self.onCloseCard = onCloseCard
        self.onRetryTranslations = onRetryTranslations
        self.onSetLanguage = onSetLanguage
    }
}

/// Panelin canlı sayfası: üst satırda durum, kayıt denetimleri (başlat, duraklat/devam, mikrofon, bitir) ve
/// gezinme; gövdede konuşmacı blokları (Türkçesiyle), altta asistan kartı, "Ne kaçırdım?" ve soru alanı, son hatalar.
/// Yalnızca `LiveViewState` ile beslenir; cam yüzey `panelSurface()` ile dışarıdan verilir.
public struct TranscriptPanel: View {
    let state: LiveViewState
    let actions: PanelActions
    @State private var question: String = ""
    /// Kullanıcı transkriptin en altında mı (canlı metni izliyor mu).
    @State private var isFollowing: Bool = true
    /// Kullanıcı yukarıdayken yeni metin geldi.
    @State private var hasUnseenText: Bool = false
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(state: LiveViewState, actions: PanelActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DesignTokens.Spacing.l)
                .padding(.vertical, DesignTokens.Spacing.m)
                // İpuçları başlığın altına taşar: transkriptin üstünde çizilsin.
                .zIndex(1)
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
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            StatusLabel(state: state)
            Spacer(minLength: DesignTokens.Spacing.s)
            languageChip
            recordingControls
            IconButton(symbol: "doc.on.doc", help: "Tümünü kopyala") {
                copyToPasteboard(text: plainText(blocks: state.blocks))
            }
            .disabled(state.blocks.isEmpty)
            IconButton(symbol: "list.bullet.rectangle", help: "Toplantılar", action: actions.onOpenMeetings)
            IconButton(symbol: "gearshape", help: "Ayarlar", action: actions.onOpenSettings)
            IconButton(symbol: "minus", help: "Paneli gizle", action: actions.onHide)
        }
    }

    /// Kayıt yokken "Başlat"; kayıtta duraklat/devam, mikrofon ve "Bitir"; bitirilirken hiçbiri.
    @ViewBuilder
    private var recordingControls: some View {
        switch state.phase {
        case .idle:
            Button(action: actions.onStart) {
                Label("Başlat", systemImage: "record.circle")
                    .font(DesignTokens.statusFont)
                    .padding(.horizontal, DesignTokens.Spacing.s)
                    .padding(.vertical, 3)
                    .background(appearance.accent.color, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!state.canStart)
            .hoverHint("Kaydı başlat", alignment: .center, edge: .bottom)
        case .recording:
            IconButton(symbol: state.isPaused ? "play.fill" : "pause.fill", help: state.isPaused ? "Devam ettir" : "Duraklat", action: actions.onTogglePause)
            IconButton(symbol: state.isMicMuted ? "mic.slash" : "mic", help: state.isMicMuted ? "Mikrofonu aç (Sen)" : "Mikrofonu kapat (yalnızca dinliyorum)", action: actions.onToggleMic)
            IconButton(symbol: "stop.fill", help: "Bitir", action: actions.onStop)
        case .finishing:
            EmptyView()
        }
    }

    /// Dil etiketi; kayıt sırasında dokununca dil değiştirilebilir (otomatik algılama yanılırsa).
    @ViewBuilder
    private var languageChip: some View {
        let chip: some View = Text(state.languageText)
            .font(DesignTokens.statusFont)
            .padding(.horizontal, DesignTokens.Spacing.s)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.chipRadius))
        if state.isRecording {
            Menu {
                LanguageMenuItems(onSetLanguage: actions.onSetLanguage)
            } label: {
                chip
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverHint("Toplantı dilini değiştir", alignment: .center, edge: .bottom)
            .accessibilityLabel("Toplantı dili: \(state.languageText). Değiştir")
        } else {
            chip
        }
    }

    /// Transkript: konuşma akarken en alttaysa en yeni metni izler; kullanıcı yukarı kaydırdıysa yerinde kalır ve
    /// "Yeni metin" düğmesi çıkar. En altta ayarlanabilir boşluk vardır (son satır kenara yapışmasın).
    private var transcript: some View {
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                    ForEach(state.blocks) { (block: SpeakerBlock) in
                        BlockView(
                            block: block,
                            turkish: blockTurkishText(block: block, translations: state.translations),
                            translations: state.translations,
                            failedTranslations: failedTranslationIDs(block: block, failed: state.failedTranslations),
                            displayMode: state.displayMode,
                            onRetryTranslations: actions.onRetryTranslations
                        )
                        .id(block.id)
                    }
                    Color.clear
                        .frame(height: appearance.bottomSpacing)
                        .id(transcriptBottomID)
                }
                .padding(.horizontal, DesignTokens.Spacing.l)
                .padding(.top, DesignTokens.Spacing.l)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { (geometry: ScrollGeometry) -> Bool in
                // Alta 60 pt'den yakınsa kullanıcı canlı metni izliyor sayılır.
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
            } action: { (_: Bool, atBottom: Bool) in
                isFollowing = atBottom
                if atBottom {
                    hasUnseenText = false
                }
            }
            .onChange(of: transcriptVersion) { (_: TranscriptVersion, _: TranscriptVersion) in
                if isFollowing {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(transcriptBottomID, anchor: .bottom) }
                } else {
                    hasUnseenText = true
                }
            }
            .overlay(alignment: .bottom) {
                if hasUnseenText {
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(transcriptBottomID, anchor: .bottom) }
                        hasUnseenText = false
                    } label: {
                        Label("Yeni metin", systemImage: "arrow.down")
                            .font(DesignTokens.statusFont)
                            .padding(.horizontal, DesignTokens.Spacing.m)
                            .padding(.vertical, 5)
                            .background(appearance.accent.color, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, DesignTokens.Spacing.s)
                    .transition(.opacity)
                }
            }
        }
    }

    /// Kaydırmayı tetikleyen değişiklik: yeni/büyüyen metin ya da gelen çeviri.
    private var transcriptVersion: TranscriptVersion {
        TranscriptVersion(
            blockCount: state.blocks.count,
            lastText: state.blocks.last?.segments.map(\.text).joined() ?? "",
            translationCount: state.translations.count
        )
    }

    /// "Ne kaçırdım?" düğmesi ve Türkçe soru alanı.
    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            Button(action: actions.onMissed) {
                Label("Ne kaçırdım?", systemImage: "sparkles")
                    .font(DesignTokens.statusFont)
                    .padding(.horizontal, DesignTokens.Spacing.m)
                    .padding(.vertical, 6)
                    .background(appearance.accent.color, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(state.blocks.isEmpty)
            .hoverHint("Son dakikaların Türkçe özeti", alignment: .leading, edge: .top)
            .accessibilityHint("Son dakikaların Türkçe özetini gösterir")
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
            ForEach(Array(state.errors.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                let message: String = item.element
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

/// Kaydırmayı tetikleyen transkript özeti.
struct TranscriptVersion: Equatable {
    let blockCount: Int
    let lastText: String
    let translationCount: Int
}

/// Transkriptin en altındaki işaret.
private let transcriptBottomID: String = "transkript-sonu"

/// Toplantı dili seçenekleri (panel ve ada menüsü).
struct LanguageMenuItems: View {
    let onSetLanguage: @MainActor (MeetingLanguage) -> Void

    var body: some View {
        Button("🇫🇮 Fince") { onSetLanguage(.finnish) }
        Button("🇬🇧 İngilizce") { onSetLanguage(.english) }
    }
}

/// Kayıt sırasında kırmızı nokta + süre, bitirilirken "Bitiriliyor…", değilse durum metni.
struct StatusLabel: View {
    let state: LiveViewState

    var body: some View {
        if state.phase == .finishing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Bitiriliyor…")
                    .font(DesignTokens.statusFont)
            }
            .accessibilityElement(children: .combine)
        } else if state.isRecording, state.isPaused {
            Label("Duraklatıldı", systemImage: "pause.circle.fill")
                .font(DesignTokens.statusFont)
                .foregroundStyle(.orange)
        } else if state.isRecording, let startedAt = state.startedAt {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 7, height: 7)
                TimelineView(.periodic(from: startedAt, by: 1)) { (context: TimelineViewDefaultContext) in
                    Text(timestamp(seconds: context.date.timeIntervalSince(startedAt)))
                        .font(DesignTokens.statusFont)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Kayıtta")
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
    /// Bu bloğun çevirisi başarısız bölümleri.
    let failedTranslations: [SegmentID]
    let displayMode: DisplayMode
    let onRetryTranslations: @MainActor ([SegmentID]) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

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
                        .font(appearance.bodyFont)
                        .lineSpacing(appearance.lineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let showsTurkish: Bool = displayMode == .bilingual && turkish != nil
                    flowingText
                        .font(showsTurkish ? appearance.secondaryFont : appearance.bodyFont)
                        .opacity(showsTurkish ? 0.6 : 1)
                        .lineSpacing(appearance.lineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if displayMode == .bilingual, let turkish {
                    Text(turkish)
                        .font(appearance.bodyFont)
                        .lineSpacing(appearance.lineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(block.segments.filter { (segment: LiveSegment) -> Bool in segment.failureMessage != nil }) { (segment: LiveSegment) in
                    Text("Yazıya dökülemedi: \(segment.failureMessage ?? "")")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                if !failedTranslations.isEmpty, displayMode.needsLiveTranslation {
                    Button {
                        onRetryTranslations(failedTranslations)
                    } label: {
                        Label("Çeviri alınamadı · Tekrar dene", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(speakerLabel(speaker: block.speaker, person: block.person))
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
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

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
                .font(appearance.secondaryFont)
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
                // Aynı metin iki kez gelebilir: kimlik sıradan.
                if !summary.decisions.isEmpty {
                    Text("Kararlar").font(DesignTokens.labelFont).foregroundStyle(.secondary)
                    ForEach(Array(summary.decisions.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in Text("• " + item.element) }
                }
                if !summary.askedOfYou.isEmpty {
                    Text("Senden istenenler").font(DesignTokens.labelFont).foregroundStyle(appearance.accent.color)
                    ForEach(Array(summary.askedOfYou.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in Text("• " + item.element) }
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
        .hoverHint(help, alignment: .trailing, edge: .bottom)
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
