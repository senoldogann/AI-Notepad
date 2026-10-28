import AINotepadCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif
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
    /// Bir bloğun bölümlerini verilen konuşmacıya ata (otomatik ayırma yanıldıysa).
    public let onReassignBlock: @MainActor ([SegmentID], Int) -> Void
    /// Bir konuşmacının tümünü (geçmiş ve gelecek) diğeriyle birleştir.
    public let onMergePerson: @MainActor (Int, Int) -> Void
    /// Şu anı önemli olarak işaretle.
    public let onBookmark: @MainActor () -> Void

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
        onSetLanguage: @escaping @MainActor (MeetingLanguage) -> Void,
        onReassignBlock: @escaping @MainActor ([SegmentID], Int) -> Void,
        onMergePerson: @escaping @MainActor (Int, Int) -> Void,
        onBookmark: @escaping @MainActor () -> Void
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
        self.onReassignBlock = onReassignBlock
        self.onMergePerson = onMergePerson
        self.onBookmark = onBookmark
    }
}

/// Panelin canlı sayfası: üst satırda durum, kayıt denetimleri (başlat, duraklat/devam, mikrofon, bitir) ve
/// gezinme; gövdede konuşmacı blokları (Türkçesiyle), altta asistan kartı, "Ne kaçırdım?" ve soru alanı, son hatalar.
/// Yalnızca `LiveViewState` ile beslenir; cam yüzey `panelSurface()` ile dışarıdan verilir.
public struct TranscriptPanel: View {
    let state: LiveViewState
    let actions: PanelActions
    /// Kayıt sırasında canlı ses çubukları.
    let levels: AudioLevels
    /// Kullanıcının kayıt sırasında kendi yazdığı notlar (not bunları öncelik sayar).
    @Binding var myNotes: String
    /// "Notlarım" alanı açık.
    @State private var isNotesOpen: Bool = false
    @State private var question: String = ""
    /// Kullanıcı transkriptin en altında mı (canlı metni izliyor mu).
    @State private var isFollowing: Bool = true
    /// Kullanıcı şu an kaydırıyor (sürükleme, tekerlek, savrulma): izlemeyi yalnızca o bırakır.
    @State private var isUserScrolling: Bool = false
    /// Kullanıcı yukarıdayken yeni metin geldi.
    @State private var hasUnseenText: Bool = false
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(state: LiveViewState, actions: PanelActions, levels: AudioLevels, myNotes: Binding<String>) {
        self.state = state
        self.actions = actions
        self.levels = levels
        self._myNotes = myNotes
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
                .overlay {
                    if state.blocks.isEmpty {
                        emptyState
                    }
                }
            if isNotesOpen, state.phase != .idle {
                MyNotesEditor(text: $myNotes) { withAnimation(.smooth(duration: 0.25)) { isNotesOpen = false } }
                    .padding(.horizontal, DesignTokens.Spacing.m)
                    .padding(.bottom, DesignTokens.Spacing.s)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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
            // Dar panelde durum metni tek satırda kısalır; düğmeler ve dil çipi her zaman tam görünür.
            StatusLabel(state: state)
                .lineLimit(1)
                .truncationMode(.tail)
                // Durum hiç görünmez olmasın: önce düğmeler menüye toplanır, durum en son kısalır.
                // Kayıtta yalnızca nokta + süre (kısa); boşta "Hazır · Deepgram" gibi daha uzun.
                .frame(minWidth: state.isRecording ? 60 : 96, alignment: .leading)
                .layoutPriority(-1)
            if state.isRecording && !state.isPaused {
                LevelMeter(levels: levels)
                    .transition(.opacity)
            }
            Spacer(minLength: DesignTokens.Spacing.s)
            // Genişlik daraldıkça önce gezinme düğmeleri, sonra dil çipi "⋯" menüsüne toplanır; kayıt denetimleri
            // ve gizle her zaman görünür.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignTokens.Spacing.s) {
                    languageChip
                    recordingControls
                    IconButton(symbol: "doc.on.doc", help: "Tümünü kopyala", action: copyAll)
                        .disabled(state.blocks.isEmpty)
                    IconButton(symbol: "list.bullet.rectangle", help: "Toplantılar", action: actions.onOpenMeetings)
                    IconButton(symbol: "gearshape", help: "Ayarlar", action: actions.onOpenSettings)
                }
                HStack(spacing: DesignTokens.Spacing.s) {
                    languageChip
                    recordingControls
                    overflowMenu { overflowItems }
                }
                HStack(spacing: DesignTokens.Spacing.s) {
                    recordingControls
                    overflowMenu {
                        if state.isRecording {
                            Menu("Dili değiştir") {
                                LanguageMenuItems(onSetLanguage: actions.onSetLanguage)
                            }
                        }
                        overflowItems
                    }
                }
            }
            IconButton(symbol: "minus", help: "Paneli gizle", action: actions.onHide)
        }
    }

    private func copyAll() {
        copyToPasteboard(text: plainText(blocks: state.blocks))
    }

    /// Dar panelde sığmayan gezinme eylemleri.
    @ViewBuilder
    private var overflowItems: some View {
        Button("Tümünü kopyala", systemImage: "doc.on.doc", action: copyAll)
            .disabled(state.blocks.isEmpty)
        Button("Toplantılar", systemImage: "list.bullet.rectangle", action: actions.onOpenMeetings)
        Button("Ayarlar", systemImage: "gearshape", action: actions.onOpenSettings)
    }

    /// "⋯" menüsü; içeriği genişliğe göre değişir (çok darda dil de içinde).
    private func overflowMenu(@ViewBuilder items: () -> some View) -> some View {
        Menu {
            items()
        } label: {
            Image(systemName: "ellipsis.circle")
                .appFont(size: 12, weight: .medium)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.hoverPlain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .hoverHint("Diğer", alignment: .trailing, edge: .bottom)
        .accessibilityLabel("Diğer")
    }

    /// Kayıt yokken mikrofon seçimi ve "Başlat"; kayıtta duraklat/devam, mikrofon ve "Bitir"; bitirilirken hiçbiri.
    @ViewBuilder
    private var recordingControls: some View {
        switch state.phase {
        case .idle:
            IconButton(
                symbol: state.isMicMuted ? "mic.slash" : "mic",
                help: state.isMicMuted ? "Yalnızca karşı taraf kaydedilecek (tıkla: kendi sesin de)" : "Kendi sesin de kaydedilecek (tıkla: yalnızca karşı taraf)",
                action: actions.onToggleMic
            )
            Button(action: actions.onStart) {
                Label("Başlat", systemImage: "record.circle")
                    .appFont(size: 12, weight: .medium)
                    .padding(.horizontal, DesignTokens.Spacing.s)
                    .padding(.vertical, 3)
                    .background(Theme.primary, in: Capsule())
                    .foregroundStyle(Theme.onPrimary)
            }
            .buttonStyle(.hoverCapsule)
            .disabled(!state.canStart)
            .hoverHint("Kaydı başlat", alignment: .center, edge: .bottom)
        case .recording:
            IconButton(symbol: state.isPaused ? "play.fill" : "pause.fill", help: state.isPaused ? "Devam ettir" : "Duraklat", action: actions.onTogglePause)
            if state.isInPerson {
                // Yüz yüze: mikrofon tek kaynak ve odadaki herkesi kaydediyor.
                IconButton(symbol: "person.3", help: "Yüz yüze: mikrofon odadaki herkesi kaydediyor", action: actions.onToggleMic)
                    .disabled(true)
            } else if state.canToggleMic {
                IconButton(symbol: state.isMicMuted ? "mic.slash" : "mic", help: state.isMicMuted ? "Mikrofonu aç (Sen)" : "Mikrofonu kapat (yalnızca dinliyorum)", action: actions.onToggleMic)
            } else {
                // Kayıt mikrofonsuz başladı: mikrofon hiç açılmadı, bu kayıtta açılamaz.
                IconButton(symbol: "mic.slash", help: "Bu kayıt yalnızca bilgisayardan gelen sesi alıyor", action: actions.onToggleMic)
                    .disabled(true)
            }
            IconButton(symbol: "bookmark", help: "Bu anı işaretle (notta öne çıkar)", action: actions.onBookmark)
            IconButton(
                symbol: isNotesOpen ? "square.and.pencil.circle.fill" : "square.and.pencil",
                help: "Notlarım: kendi notunu yaz, not onu öncelik sayar",
                action: { withAnimation(.smooth(duration: 0.25)) { isNotesOpen.toggle() } }
            )
            IconButton(symbol: "stop.fill", help: "Bitir", action: actions.onStop)
        case .finishing:
            EmptyView()
        }
    }

    /// Dil etiketi; kayıt sırasında dokununca dil değiştirilebilir (otomatik algılama yanılırsa).
    @ViewBuilder
    private var languageChip: some View {
        let chip: some View = Text(state.languageText)
            .appFont(size: 12, weight: .medium)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, DesignTokens.Spacing.s)
            .padding(.vertical, 3)
            .background(Theme.soft, in: RoundedRectangle(cornerRadius: DesignTokens.chipRadius))
        if state.isRecording {
            Menu {
                LanguageMenuItems(onSetLanguage: actions.onSetLanguage)
            } label: {
                chip
            }
            .menuStyle(.button)
            .buttonStyle(.hoverCapsule)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverHint("Toplantı dilini değiştir", alignment: .center, edge: .bottom)
            .accessibilityLabel("Toplantı dili: \(state.languageText). Değiştir")
        } else {
            chip
        }
    }

    /// Henüz metin yokken ortada ne olacağını söyler (boş siyah alan kalmasın).
    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            Image(systemName: state.isRecording ? "waveform" : "waveform.badge.mic")
                .appFont(size: 30, weight: .light)
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, isActive: state.isRecording)
            Text(state.isRecording ? "Dinleniyor…" : "Kayıt yok")
                .appFont(size: 15, weight: .semibold)
            Text(state.isRecording
                ? "Konuşma başlayınca metin burada akar."
                : "\"Başlat\"a bas; konuşmalar burada canlı yazıya dökülür, bitince toplantının notu hazırlanır.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .padding(DesignTokens.Spacing.l)
        .allowsHitTesting(false)
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
                            persons: state.persons,
                            newPersonNumber: state.newPersonNumber,
                            onRetryTranslations: actions.onRetryTranslations,
                            onReassign: actions.onReassignBlock,
                            onMerge: actions.onMergePerson
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
            .onScrollPhaseChange { (_: ScrollPhase, phase: ScrollPhase) in
                isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: Bool.self) { (geometry: ScrollGeometry) -> Bool in
                // Alta 60 pt'den yakınsa kullanıcı canlı metni izliyor sayılır.
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
            } action: { (_: Bool, atBottom: Bool) in
                if atBottom {
                    isFollowing = true
                    hasUnseenText = false
                } else if isUserScrolling {
                    // Yalnızca kullanıcı yukarı kaydırınca izleme durur. Yeni metin içeriği büyütüp alttan bir anlığına
                    // uzaklaştırdığında durmaz (önceden uzun toplantıda bir süre sonra otomatik kaydırma kalıyordu).
                    isFollowing = false
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
                            .appFont(size: 12, weight: .medium)
                            .padding(.horizontal, DesignTokens.Spacing.m)
                            .padding(.vertical, 5)
                            .background(Theme.primary, in: Capsule())
                            .foregroundStyle(Theme.onPrimary)
                    }
                    .buttonStyle(.hoverCapsule)
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
        // Dar panelde "Ne kaçırdım?" yalnızca simge olur; soru alanı kalan genişliği alır.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.s) {
                missedButton(horizontalPadding: DesignTokens.Spacing.m) { Label("Ne kaçırdım?", systemImage: "sparkles") }
                questionField.frame(minWidth: 150)
            }
            HStack(spacing: DesignTokens.Spacing.s) {
                missedButton(horizontalPadding: DesignTokens.Spacing.s) { Image(systemName: "sparkles") }
                questionField
            }
        }
    }

    /// "Ne kaçırdım?" düğmesi; etiketi (yazılı ya da yalnızca simge) genişliğe göre verilir.
    private func missedButton(horizontalPadding: CGFloat, @ViewBuilder label: () -> some View) -> some View {
        // Metin yokken soluk gri hap (yarı saydam siyah leke gibi durmasın).
        let isEnabled: Bool = !state.blocks.isEmpty
        return Button(action: actions.onMissed) {
            label()
            .appFont(size: 12, weight: .medium)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 6)
            .background(isEnabled ? Theme.primary : Theme.soft, in: Capsule())
            .foregroundStyle(isEnabled ? Theme.onPrimary : Theme.muted)
        }
        .buttonStyle(.hoverCapsule)
        .disabled(!isEnabled)
        .hoverHint("Son dakikaların özeti", alignment: .leading, edge: .top)
        .accessibilityLabel("Ne kaçırdım?")
        .accessibilityHint("Son dakikaların özetini gösterir")
    }

    private var questionField: some View {
        TextField("Toplantı hakkında sor…", text: $question)
            .textFieldStyle(.plain)
            .appFont(size: 12, weight: .medium)
            .padding(.horizontal, DesignTokens.Spacing.m)
            .padding(.vertical, 6)
            .background(Theme.soft, in: Capsule())
            .onSubmit {
                let trimmed: String = question.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return
                }
                actions.onAsk(trimmed)
                question = ""
            }
    }

    private var errorBand: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ForEach(Array(state.errors.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                let message: String = item.element
                Text(message)
                    .appFont(size: 11, weight: .regular)
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

/// Seçicilerde öne çıkan toplantı dilleri; diğerleri "Diğer diller" alt menüsünde.
public let featuredMeetingLanguages: [MeetingLanguage] = [.finnish, .english, .swedish, .turkish]

/// Toplantı dili seçenekleri (panel, ada, menü çubuğu ve ana sayfa): öne çıkanlar, sonra alt menüde diğer diller.
public struct LanguageMenuItems: View {
    let onSetLanguage: @MainActor (MeetingLanguage) -> Void

    public init(onSetLanguage: @escaping @MainActor (MeetingLanguage) -> Void) {
        self.onSetLanguage = onSetLanguage
    }

    public var body: some View {
        ForEach(featuredMeetingLanguages, id: \.self) { (language: MeetingLanguage) in
            Button(languageName(language: language)) { onSetLanguage(language) }
        }
        Menu("Diğer diller") {
            ForEach(MeetingLanguage.allCases.filter { !featuredMeetingLanguages.contains($0) }, id: \.self) { (language: MeetingLanguage) in
                Button(languageName(language: language)) { onSetLanguage(language) }
            }
        }
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
                    .appFont(size: 12, weight: .medium)
            }
            .accessibilityElement(children: .combine)
        } else if state.isRecording, state.isPaused {
            Label("Duraklatıldı", systemImage: "pause.circle.fill")
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(.orange)
        } else if state.isRecording, let startedAt = state.startedAt {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 7, height: 7)
                TimelineView(.periodic(from: startedAt, by: 1)) { (context: TimelineViewDefaultContext) in
                    Text(timestamp(seconds: context.date.timeIntervalSince(startedAt)))
                        .appFont(size: 12, weight: .medium)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Kayıtta")
        } else {
            Text(state.statusText)
                .appFont(size: 12, weight: .medium)
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
    /// Transkriptteki kişiler (düzeltme menüsü).
    let persons: [Int]
    let newPersonNumber: Int
    let onRetryTranslations: @MainActor ([SegmentID]) -> Void
    let onReassign: @MainActor ([SegmentID], Int) -> Void
    let onMerge: @MainActor (Int, Int) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.s) {
            Circle()
                .fill(blockColor(block: block))
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { (dimensions: ViewDimensions) -> CGFloat in dimensions[.bottom] }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                // Renk yalnızca noktada: renkli küçük etiket camda yeterince okunmuyor.
                if block.speaker == .others {
                    // Otomatik ayırma yanıldıysa etikete tıklayıp düzeltilir.
                    Menu {
                        SpeakerCorrectionMenu(block: block, persons: persons, newPersonNumber: newPersonNumber, onReassign: onReassign, onMerge: onMerge)
                    } label: {
                        HStack(spacing: 3) {
                            speakerLabelText
                            Image(systemName: "chevron.down")
                                .appFont(size: 7, weight: .bold)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.hoverPlain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .hoverHint("Konuşmacıyı düzelt", alignment: .leading, edge: .bottom)
                } else {
                    speakerLabelText
                }
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
                        .appFont(size: 11, weight: .regular)
                        .foregroundStyle(.red)
                }
                if !failedTranslations.isEmpty, displayMode.needsLiveTranslation {
                    Button {
                        onRetryTranslations(failedTranslations)
                    } label: {
                        Label("Çeviri alınamadı · Tekrar dene", systemImage: "arrow.clockwise")
                            .appFont(size: 11, weight: .medium)
                    }
                    .buttonStyle(.hoverPlain)
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

    private var speakerLabelText: some View {
        Text(interfaceUppercased(text: speakerLabel(speaker: block.speaker, person: block.person)))
            .appFont(size: 11, weight: .semibold)
            .tracking(DesignTokens.labelTracking)
            .foregroundStyle(.secondary)
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

/// "Diğerleri" bloğunun konuşmacı düzeltme menüsü: bloğu başka kişiye ata ya da kişinin tümünü birleştir.
struct SpeakerCorrectionMenu: View {
    let block: SpeakerBlock
    let persons: [Int]
    let newPersonNumber: Int
    let onReassign: @MainActor ([SegmentID], Int) -> Void
    let onMerge: @MainActor (Int, Int) -> Void

    var body: some View {
        let ids: [SegmentID] = block.segments.map(\.id)
        let others: [Int] = persons.filter { $0 != block.person }
        Section("Bu bölümü ata") {
            ForEach(others, id: \.self) { (person: Int) in
                Button(speakerLabel(speaker: .others, person: person)) { onReassign(ids, person) }
            }
            Button("Yeni konuşmacı") { onReassign(ids, newPersonNumber) }
        }
        if let current = block.person, !others.isEmpty {
            // Ayırma aynı kişiyi iki numaraya böldüyse: geçmiş ve gelecek tüm bölümler birleşir.
            Section("Tümünü birleştir: \(speakerLabel(speaker: .others, person: current)) →") {
                ForEach(others, id: \.self) { (person: Int) in
                    Button(speakerLabel(speaker: .others, person: person)) { onMerge(current, person) }
                }
            }
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
                    .appFont(size: 11, weight: .semibold)
                    .tracking(DesignTokens.labelTracking)
                    .foregroundStyle(.secondary)
                Spacer()
                IconButton(symbol: "xmark", help: "Kapat", action: onClose)
            }
            // Uzun cevap kısa panelde transkripti kapatmasın: sığmazsa kartın içinde kaydırılır.
            ViewThatFits(in: .vertical) {
                styledContent
                ScrollView {
                    styledContent
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(DesignTokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
    }

    private var title: String {
        switch card {
        case .loading(let title): interfaceUppercased(text: title)
        case .summary: String(localized: "NE KAÇIRDIM?")
        case .answer: String(localized: "CEVAP")
        case .failed: String(localized: "HATA")
        }
    }

    private var styledContent: some View {
        content
            .font(appearance.secondaryFont)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    Text("Kararlar").appFont(size: 11, weight: .semibold).foregroundStyle(.secondary)
                    ForEach(Array(summary.decisions.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in Text("• " + item.element) }
                }
                if !summary.askedOfYou.isEmpty {
                    Text("Senden istenenler").appFont(size: 11, weight: .semibold).foregroundStyle(appearance.accent.color)
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
    let help: LocalizedStringKey
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .appFont(size: 12, weight: .medium)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .foregroundStyle(.secondary)
        .hoverHint(help, alignment: .trailing, edge: .bottom)
        .accessibilityLabel(help)
    }
}

/// "Sen" vurgu rengi, atanmış kişi kendi rengi, atanmamış "Diğerleri" ikincil renk.
func blockColor(block: SpeakerBlock) -> Color {
    switch (block.speaker, block.person) {
    case (_, .some(let person)): personColor(person: person)
    case (.me, nil): DesignTokens.meSpeakerColor
    case (.others, nil): .secondary
    }
}

/// Metni genel panoya yazar.
@MainActor
func copyToPasteboard(text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}


/// Kayıt sırasında "Notlarım": kullanıcının kendi notları (madde, başlık, kısaltma). Toplantı bitince not bunları
/// öncelik sayar, transkriptten tamamlar. Yazılanlar kayıtla birlikte saklanır.
public struct MyNotesEditor: View {
    @Binding var text: String
    let onClose: @MainActor () -> Void
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, onClose: @escaping @MainActor () -> Void) {
        self._text = text
        self.onClose = onClose
    }

    public var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil").appFont(size: 11, weight: .semibold)
                Text("NOTLARIM").appFont(size: 11, weight: .semibold).tracking(DesignTokens.labelTracking)
                Spacer()
                Text("Not bunları öncelik sayar")
                    .appFont(size: 11, weight: .regular)
                Button(action: onClose) {
                    Image(systemName: "chevron.down").appFont(size: 10, weight: .bold)
                }
                .buttonStyle(.hoverPlain)
                .accessibilityLabel("Notlarımı gizle")
            }
            .foregroundStyle(Theme.muted)
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Önemli gördüğünü yaz: \"- bütçe cuma\", \"## Riskler\"… Kısa yeter, gerisini not tamamlar.")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted.opacity(0.8))
                        // TextEditor'ın iç boşluğuyla hizalı.
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .appFont(size: 13, weight: .regular)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .frame(minHeight: 70, maxHeight: 140)
            }
        }
        .padding(12)
        .background(Theme.card, in: shape)
        .overlay(shape.strokeBorder(isFocused ? Theme.ink.opacity(0.25) : Theme.line))
        .onAppear { isFocused = true }
    }
}
