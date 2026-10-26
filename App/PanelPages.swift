import AINotepadCore
import AINotepadUI
import AppKit
import Observation
import SwiftUI

/// Kayıt sırasındaki cam panelin sayfaları: canlı metin ve biten toplantının sonucu. Toplantılar, Ayarlar ve Kurulum
/// ana pencerededir (tek kopya: iki ayrı ekran birbirinden habersiz kalmasın).
enum PanelPage: Equatable {
    case live
    case meeting(id: String)
}

/// Panelde hangi sayfanın açık olduğu.
@MainActor
@Observable
final class PanelRouter {
    var page: PanelPage = .live
}

/// Modeli gözleyip sayfayı seçen kabuk; tüm sayfalara aynı cam yüzeyi verir.
struct PanelHost: View {
    let model: AppModel
    /// "Arka planda devam et" ile kapatılan ilerleme kartları.
    @State private var dismissedProgress: Set<String> = []
    @State private var dismissedFinishing: Bool = false
    let router: PanelRouter
    let player: MeetingAudioPlayer
    let onStart: @MainActor () -> Void
    let onHide: @MainActor () -> Void
    /// Ana pencereyi bir bölümde açar (Toplantılar, Ayarlar).
    let onOpenMainWindow: @MainActor (MainSection) -> Void

    var body: some View {
        let progress: ProcessingProgress? = processingProgress
        content
            // Toplantı hazırlanırken arka plan bulanıklaşır; ortadaki kart tamamlanana kadar kalır.
            .blur(radius: progress == nil ? 0 : 8)
            .allowsHitTesting(progress == nil)
            .overlay {
                if let progress {
                    ProcessingOverlay(progress: progress) {
                        if let id = progress.meetingID {
                            dismissedProgress.insert(id)
                        } else {
                            dismissedFinishing = true
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: progress)
            .onChange(of: model.phase) { (_: RecordingPhase, phase: RecordingPhase) in
                // Yeni bir bitirme için kart yeniden gösterilir.
                if phase == .recording {
                    dismissedFinishing = false
                }
            }
            // Canlı metin ile toplantı sayfası arasında yumuşak geçiş.
            .animation(.smooth(duration: 0.25), value: router.page)
            .frame(minWidth: 300, minHeight: 240)
            .panelSurface()
            .modifier(AppearanceEnvironment())
    }

    /// Gösterilecek ilerleme: kayıt bitiriliyorsa ya da son biten toplantı işleniyorsa (kullanıcı kapatmadıysa).
    private var processingProgress: ProcessingProgress? {
        if model.phase == .finishing {
            return dismissedFinishing ? nil : ProcessingProgress(meetingID: nil, stepIndex: 0, isLocal: model.liveEngine == .whisperKit)
        }
        // Bitirilirken kapatıldıysa aynı kaydın işlemesi için de yeniden açılmaz.
        guard !dismissedFinishing, let id = model.lastFinishedMeetingID, let step = model.processingSteps[id], !dismissedProgress.contains(id) else {
            return nil
        }
        let isLocal: Bool = model.meetings.first { $0.id == id }?.engine == .local
        return ProcessingProgress(meetingID: id, stepIndex: step.rawValue + 1, isLocal: isLocal)
    }

    @ViewBuilder
    private var content: some View {
        switch router.page {
        case .live:
            TranscriptPanel(
                state: model.viewState,
                actions: PanelActions(
                    onHide: onHide,
                    onStart: onStart,
                    onTogglePause: { model.togglePause() },
                    onToggleMic: { model.toggleMicrophone() },
                    onStop: { model.stopRecording() },
                    onOpenMeetings: { onOpenMainWindow(.meetings) },
                    onOpenSettings: { onOpenMainWindow(.settings) },
                    onMissed: { model.askWhatIMissed() },
                    onAsk: { (question: String) -> Void in model.ask(question: question) },
                    onCloseCard: { model.closeAssistantCard() },
                    onRetryTranslations: { (ids: [SegmentID]) -> Void in model.retryTranslations(ids: ids) },
                    onSetLanguage: { (language: MeetingLanguage) -> Void in model.setLanguage(language: language) },
                    onReassignBlock: { (segments: [SegmentID], person: Int) -> Void in model.reassignBlock(segments: segments, person: person) },
                    onMergePerson: { (from: Int, into: Int) -> Void in model.mergeLivePersons(from: from, into: into) }
                )
            )
        case .meeting(let id):
            PanelPageView(model: model, router: router, title: "Toplantı", back: .live, onHide: onHide) {
                if let record = model.meetings.first(where: { $0.id == id }) {
                    MeetingDetailPage(model: model, player: player, record: record) { router.page = .live }
                        // Toplantı değişince ad alanları gibi durumlar sıfırlansın.
                        .id(record.id)
                } else {
                    ContentUnavailableView("Toplantı bulunamadı", systemImage: "doc.questionmark")
                }
            }
        }
    }
}

/// Alt sayfanın çerçevesi: geri, başlık, kayıttaysa canlı sayfaya dönüş, gizle.
private struct PanelPageView<Content: View>: View {
    let model: AppModel
    let router: PanelRouter
    let title: LocalizedStringKey
    let back: PanelPage
    let onHide: @MainActor () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.s) {
                Button {
                    router.page = back
                } label: {
                    ViewThatFits(in: .horizontal) {
                        Label("Canlı", systemImage: "chevron.left")
                        Image(systemName: "chevron.left")
                    }
                    .font(DesignTokens.statusFont)
                }
                .buttonStyle(.hoverPlain)
                .foregroundStyle(.secondary)
                .hoverHint("Geri", alignment: .leading, edge: .bottom)
                Spacer(minLength: DesignTokens.Spacing.s)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: DesignTokens.Spacing.s)
                if model.phase != .idle {
                    // Kayıt sürerken her sayfadan canlı metne tek dokunuşla dönülür.
                    Button {
                        router.page = .live
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            Label(model.isFinishing ? "Bitiriliyor" : "Kayıtta", systemImage: "record.circle")
                            Image(systemName: "record.circle")
                        }
                        .font(DesignTokens.statusFont)
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.hoverPlain)
                    .hoverHint("Canlı metne dön", alignment: .trailing, edge: .bottom)
                }
                Button(action: onHide) {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .foregroundStyle(.secondary)
                .hoverHint("Paneli gizle", alignment: .trailing, edge: .bottom)
                .accessibilityLabel("Paneli gizle")
            }
            .padding(.horizontal, DesignTokens.Spacing.l)
            .padding(.vertical, DesignTokens.Spacing.m)
            // İpuçları başlığın altına taşar: içeriğin üstünde çizilsin.
            .zIndex(1)
            Divider().opacity(0.35)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// `--sayfa canli` ya da `--toplanti <kimlik>` başlatma argümanının panel sayfası (geliştirme ve görsel kontrol için;
/// ana pencere bölümleri `--bolum` ile); argüman yoksa ya da tanınmıyorsa nil. Saf fonksiyondur.
func launchPage(arguments: [String]) -> PanelPage? {
    if let index = arguments.firstIndex(of: "--toplanti"), arguments.indices.contains(index + 1) {
        return .meeting(id: arguments[index + 1])
    }
    guard let index = arguments.firstIndex(of: "--sayfa"), arguments.indices.contains(index + 1), arguments[index + 1] == "canli" else {
        return nil
    }
    return .live
}

/// Ayarlar › Görünüm değerlerini (AppStorage) okuyup görünüme uygular: panel görünümü ortamı, vurgu rengi (sistem
/// denetimleri de kullanır), yazı tipi tasarımı (yazı tipini ayrıca belirtmeyen metinler de) ve pencere teması. Panel ve
/// ana pencere aynı ayarları kullanır; değişince ikisi de hemen güncellenir.
struct AppearanceEnvironment: ViewModifier {
    @AppStorage(SettingsKey.theme) private var theme: String = AppTheme.system.rawValue
    @AppStorage(SettingsKey.accent) private var accent: String = PanelAppearance.standard.accent.rawValue
    @AppStorage(SettingsKey.panelBackground) private var background: String = PanelAppearance.standard.background.rawValue
    @AppStorage(SettingsKey.fontDesign) private var fontDesign: String = PanelAppearance.standard.fontDesign.rawValue
    @AppStorage(SettingsKey.textSize) private var textSize: Double = PanelAppearance.standard.textSize
    @AppStorage(SettingsKey.lineSpacing) private var lineSpacing: Double = PanelAppearance.standard.lineSpacing
    @AppStorage(SettingsKey.bottomSpacing) private var bottomSpacing: Double = PanelAppearance.standard.bottomSpacing

    func body(content: Content) -> some View {
        let standard: PanelAppearance = .standard
        let appearance: PanelAppearance = PanelAppearance(
            fontDesign: PanelFontDesign(rawValue: fontDesign) ?? standard.fontDesign,
            textSize: textSize, lineSpacing: lineSpacing, bottomSpacing: bottomSpacing,
            accent: PanelAccent(rawValue: accent) ?? standard.accent,
            background: PanelBackground(rawValue: background) ?? standard.background
        )
        content
            .environment(\.panelAppearance, appearance)
            .tint(appearance.accent.color)
            .fontDesign(appearance.fontDesign.design)
            // Stil belirtilmemiş tüm düğmeler etkileşimli Liquid Glass (el imleci ve hover dahil).
            .buttonStyle(.glassAction)
            .background(WindowAppearance(theme: AppTheme(rawValue: theme) ?? .system))
    }
}

/// Panel penceresinin açık/koyu görünümünü ayarlar (cam malzemesi pencere görünümüne göre çizilir).
private struct WindowAppearance: NSViewRepresentable {
    let theme: AppTheme

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Pencere görünüm ağacına eklendikten sonra atanır.
        DispatchQueue.main.async {
            view.window?.appearance = switch theme {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }
}

/// İlerleme kartının durumu: hangi toplantı (bitirilirken henüz yok), kaçıncı adım, yerel motor mu.
struct ProcessingProgress: Equatable {
    let meetingID: String?
    /// 0: kayıt bitiriliyor, 1: ses, 2: son geçiş, 3: not.
    let stepIndex: Int
    let isLocal: Bool
}

/// Toplantı hazırlanırken panelin ortasındaki kart: animasyonlu simge, adımlar (biten ✓, süren gösterge, bekleyen
/// soluk), ilerleme çubuğu ve "Arka planda devam et".
private struct ProcessingOverlay: View {
    let progress: ProcessingProgress
    let onDismiss: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    private var steps: [LocalizedStringKey] {
        [
            "Kayıt bitiriliyor",
            "Ses kaydı hazırlanıyor",
            progress.isLocal ? "Konuşmacılar Mac'te ayrılıyor" : "Kaydın tamamı işleniyor",
            "Not hazırlanıyor",
        ]
    }

    var body: some View {
        // Kısa panelde önce simge ve açıklama düşer.
        ViewThatFits(in: .vertical) {
            card(isCompact: false)
            card(isCompact: true)
        }
        .padding(DesignTokens.Spacing.m)
    }

    private func card(isCompact: Bool) -> some View {
        VStack(spacing: isCompact ? DesignTokens.Spacing.m : DesignTokens.Spacing.l) {
            if !isCompact {
                waveIcon
            }
            Text("Toplantı hazırlanıyor")
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { (item: (offset: Int, element: LocalizedStringKey)) in
                    HStack(spacing: DesignTokens.Spacing.s) {
                        Group {
                            if item.offset < progress.stepIndex {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if item.offset == progress.stepIndex {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "circle").foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 18, height: 18)
                        Text(item.element)
                            .font(.system(size: 13, weight: item.offset == progress.stepIndex ? .semibold : .regular))
                            .foregroundStyle(item.offset > progress.stepIndex ? .secondary : .primary)
                    }
                }
            }
            ProgressView(value: Double(progress.stepIndex) + 0.5, total: Double(steps.count))
                .tint(appearance.accent.color)
            // Seçilen yazı tipi tasarımı yazı tipini ayrıca belirtmeyen tüm metinlere de uygulanır.
            .fontDesign(appearance.fontDesign.design)
            if !isCompact {
                Text("Bitince toplantının sayfası açılır; görevlerin en üstte.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Arka planda devam et", action: onDismiss)
                .buttonStyle(.hoverPlain)
                .font(.callout)
                .foregroundStyle(appearance.accent.color)
        }
        .padding(isCompact ? DesignTokens.Spacing.l : DesignTokens.Spacing.xl)
        .frame(maxWidth: 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .accessibilityElement(children: .combine)
    }

    private var waveIcon: some View {
        Image(systemName: "waveform")
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(appearance.accent.color)
            .symbolEffect(.variableColor.iterative.reversing, options: .repeat(.continuous))
    }
}
