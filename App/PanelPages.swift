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
    let router: PanelRouter
    let player: MeetingAudioPlayer
    let onStart: @MainActor () -> Void
    let onHide: @MainActor () -> Void
    /// Ana pencereyi bir bölümde açar (Toplantılar, Ayarlar).
    let onOpenMainWindow: @MainActor (MainSection) -> Void

    var body: some View {
        content
            // Çalan toplantı canlı sayfada da altta görünür (geri dönünce ses durmaz).
            .safeAreaInset(edge: .bottom) {
                PlayerDock(model: model, player: player) { (id: String) -> Void in router.page = .meeting(id: id) }
            }
            .modifier(ProcessingOverlayHost(model: model))
            // Canlı metin ile toplantı sayfası arasında yumuşak geçiş.
            .animation(.smooth(duration: 0.25), value: router.page)
            .frame(minWidth: 300, minHeight: 240)
            .panelSurface()
            .modifier(AppearanceEnvironment())
    }

    @ViewBuilder
    private var content: some View {
        switch router.page {
        case .live:
            VStack(spacing: 0) {
                if model.consentReminderVisible {
                    ConsentBanner { withAnimation(.smooth(duration: 0.25)) { model.consentReminderVisible = false } }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
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
                    onMergePerson: { (from: Int, into: Int) -> Void in model.mergeLivePersons(from: from, into: into) },
                    onBookmark: { model.bookmarkNow() }
                ),
                levels: model.audioLevels,
                myNotes: Binding<String>(get: { model.liveMyNotes }, set: { (text: String) -> Void in model.liveMyNotes = text })
            )
            }
            .animation(.smooth(duration: 0.25), value: model.consentReminderVisible)
        case .meeting(let id):
            PanelPageView(model: model, router: router, title: "Toplantı", back: .live, onHide: onHide) {
                if let record = model.meetings.first(where: { $0.id == id }) {
                    MeetingDetailPage(model: model, player: player, record: record) {
                        router.page = .live
                    } onRunRecipe: { (recipe: Recipe) -> Void in
                        model.askArchive(question: recipe.prompt, meetingIDs: [record.id], recipeTitle: recipe.title)
                        onOpenMainWindow(.ask)
                    }
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
                    .appFont(size: 12, weight: .medium)
                }
                .buttonStyle(.hoverPlain)
                .foregroundStyle(.secondary)
                .hoverHint("Geri", alignment: .leading, edge: .bottom)
                Spacer(minLength: DesignTokens.Spacing.s)
                Text(title)
                    .appFont(size: 13, weight: .semibold)
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
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.hoverPlain)
                    .hoverHint("Canlı metne dön", alignment: .trailing, edge: .bottom)
                }
                Button(action: onHide) {
                    Image(systemName: "minus")
                        .appFont(size: 12, weight: .medium)
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
    @AppStorage(SettingsKey.theme) private var theme: String = AppTheme.light.rawValue
    @AppStorage(SettingsKey.accent) private var accent: String = PanelAppearance.standard.accent.rawValue
    @AppStorage(SettingsKey.fontDesign) private var fontDesign: String = PanelAppearance.standard.fontChoice.storageValue
    @AppStorage(SettingsKey.uiScale) private var uiScale: Double = PanelAppearance.standard.uiScale
    @AppStorage(SettingsKey.textSize) private var textSize: Double = PanelAppearance.standard.textSize
    @AppStorage(SettingsKey.lineSpacing) private var lineSpacing: Double = PanelAppearance.standard.lineSpacing
    @AppStorage(SettingsKey.bottomSpacing) private var bottomSpacing: Double = PanelAppearance.standard.bottomSpacing

    func body(content: Content) -> some View {
        let standard: PanelAppearance = .standard
        let appearance: PanelAppearance = PanelAppearance(
            fontChoice: AppFontChoice.parse(storage: fontDesign) ?? standard.fontChoice,
            uiScale: min(max(uiScale, SettingsRange.uiScale.lowerBound), SettingsRange.uiScale.upperBound),
            textSize: textSize, lineSpacing: lineSpacing, bottomSpacing: bottomSpacing,
            accent: PanelAccent(rawValue: accent) ?? standard.accent
        )
        content
            .environment(\.panelAppearance, appearance)
            .tint(appearance.accent.color)
            .fontDesign(appearance.fontDesign.design)
            // Yazı tipi belirtilmemiş metinler ve sistem denetimleri de seçili aile ve ölçekte.
            .font(appearance.font(size: 13, weight: .regular))
            // İpuçları pencerenin en üst katmanında (metnin altında kalmasın, kesilmesin).
            .hoverHintLayer()
            // Stil belirtilmemiş tüm düğmeler etkileşimli Liquid Glass (el imleci ve hover dahil).
            .buttonStyle(.pill)
            // Tema uygulamanın tamamına uygulanır: ana pencere, cam zemin, panel, ada ve menüler aynı anda değişir.
            .onChange(of: theme, initial: true) { (_: String, value: String) in
                applyTheme(theme: AppTheme(rawValue: value) ?? .system)
            }
    }
}


/// İlerleme kartının durumu: hangi toplantı (bitirilirken henüz yok), kaçıncı adım, yerel motor mu.
/// Toplantı hazırlanırken içeriği bulanıklaştırıp ortada ilerleme kartını gösterir; panel ve ana pencere aynı kartı
/// gösterir, "Arka planda devam et" ikisinde birden kapatır (durum modelde).
struct ProcessingOverlayHost: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        let progress: ProcessingProgress? = processingProgress
        content
            .blur(radius: progress == nil ? 0 : 8)
            .allowsHitTesting(progress == nil)
            .overlay {
                if let progress {
                    ProcessingOverlay(progress: progress) {
                        if let id = progress.meetingID {
                            model.dismissedProgressIDs.insert(id)
                        } else {
                            model.finishingCardDismissed = true
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: progress)
    }

    /// Gösterilecek ilerleme: kayıt bitiriliyorsa ya da son biten toplantı işleniyorsa (kullanıcı kapatmadıysa).
    private var processingProgress: ProcessingProgress? {
        if model.phase == .finishing {
            return model.finishingCardDismissed ? nil : ProcessingProgress(meetingID: nil, stepIndex: 0, isLocal: model.liveEngine == .whisperKit)
        }
        // Bitirilirken kapatıldıysa aynı kaydın işlemesi için de yeniden açılmaz.
        guard !model.finishingCardDismissed, let id = model.lastFinishedMeetingID, let step = model.processingSteps[id],
              !model.dismissedProgressIDs.contains(id) else {
            return nil
        }
        let isLocal: Bool = model.meetings.first { $0.id == id }?.engine == .local
        return ProcessingProgress(meetingID: id, stepIndex: step.rawValue + 1, isLocal: isLocal)
    }
}

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
                .appFont(size: 16, weight: .semibold)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { (item: (offset: Int, element: LocalizedStringKey)) in
                    HStack(spacing: DesignTokens.Spacing.s) {
                        Group {
                            if item.offset < progress.stepIndex {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            } else if item.offset == progress.stepIndex {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "circle").foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 18, height: 18)
                        Text(item.element)
                            .appFont(size: 13, weight: item.offset == progress.stepIndex ? .semibold : .regular)
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
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Arka planda devam et", action: onDismiss)
                .buttonStyle(.hoverPlain)
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(appearance.accent.color)
        }
        .padding(isCompact ? DesignTokens.Spacing.l : DesignTokens.Spacing.xl)
        .frame(maxWidth: 300)
        .cardSurface(cornerRadius: 20)
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .accessibilityElement(children: .combine)
    }

    private var waveIcon: some View {
        Image(systemName: "waveform")
            .appFont(size: 34, weight: .medium)
            .foregroundStyle(appearance.accent.color)
            .symbolEffect(.variableColor.iterative.reversing, options: .repeat(.continuous))
    }
}

/// Katılımcılara kayıttan haber verme metni (Fince ve İngilizce; toplantı sohbetine yapıştırılır).
let consentNoticeText: String = "Hei! Tallennan tämän palaverin, jotta voin tehdä siitä muistiinpanot.\nHi! I'm recording this meeting so I can take notes."

/// Kayıt başında panelin üstünde: katılımcılara haber verme hatırlatması ve kopyalanabilir bildirim. Kapatılınca o
/// kayıt boyunca görünmez; Ayarlar'dan tamamen kapatılabilir.
private struct ConsentBanner: View {
    let onDismiss: @MainActor () -> Void
    @State private var copied: Bool = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            Image(systemName: "person.wave.2")
                .foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
            Text("Kayıt yapıyorsun: katılımcılara haber ver.")
                .appFont(size: 12, weight: .medium)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DesignTokens.Spacing.s)
            Button(copied ? "Kopyalandı" : "Bildirimi kopyala", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(consentNoticeText, forType: .string)
                copied = true
            }
            .controlSize(.small)
            .hoverHint("Fince ve İngilizce kısa bildirim; toplantı sohbetine yapıştır", alignment: .trailing, edge: .bottom)
            Button("Kapat", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.hoverPlain)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, DesignTokens.Spacing.m)
        .padding(.vertical, 8)
        .background(Theme.soft)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
