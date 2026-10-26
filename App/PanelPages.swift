import AINotepadCore
import AINotepadUI
import AppKit
import Observation
import SwiftUI

/// Panelin sayfaları: tüm uygulama tek cam panelin içinde (ayrı pencere ya da açılır pencere yok).
enum PanelPage: Equatable {
    case live
    case meetings
    case meeting(id: String)
    case settings
    case setup
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
    // Görünüm ayarları: değişince panel hemen güncellenir.
    @AppStorage(SettingsKey.theme) private var theme: String = AppTheme.system.rawValue
    @AppStorage(SettingsKey.accent) private var accent: String = PanelAppearance.standard.accent.rawValue
    @AppStorage(SettingsKey.panelBackground) private var background: String = PanelAppearance.standard.background.rawValue
    @AppStorage(SettingsKey.fontDesign) private var fontDesign: String = PanelAppearance.standard.fontDesign.rawValue
    @AppStorage(SettingsKey.textSize) private var textSize: Double = PanelAppearance.standard.textSize
    @AppStorage(SettingsKey.lineSpacing) private var lineSpacing: Double = PanelAppearance.standard.lineSpacing
    @AppStorage(SettingsKey.bottomSpacing) private var bottomSpacing: Double = PanelAppearance.standard.bottomSpacing
    let router: PanelRouter
    let shortcuts: ShortcutController
    let player: MeetingAudioPlayer
    let onStart: @MainActor () -> Void
    let onHide: @MainActor () -> Void

    var body: some View {
        content
            .frame(minWidth: 300, minHeight: 240)
            .panelSurface()
            // Ayar değerleri (AppStorage) okunarak görünüm kurulur; değişince yeniden çizilir.
            .environment(\.panelAppearance, appearance)
            .background(WindowAppearance(theme: AppTheme(rawValue: theme) ?? .system))
    }

    private var appearance: PanelAppearance {
        let standard: PanelAppearance = .standard
        return PanelAppearance(
            fontDesign: PanelFontDesign(rawValue: fontDesign) ?? standard.fontDesign,
            textSize: textSize, lineSpacing: lineSpacing, bottomSpacing: bottomSpacing,
            accent: PanelAccent(rawValue: accent) ?? standard.accent,
            background: PanelBackground(rawValue: background) ?? standard.background
        )
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
                    onOpenMeetings: { router.page = .meetings },
                    onOpenSettings: { router.page = .settings },
                    onMissed: { model.askWhatIMissed() },
                    onAsk: { (question: String) -> Void in model.ask(question: question) },
                    onCloseCard: { model.closeAssistantCard() },
                    onRetryTranslations: { (ids: [SegmentID]) -> Void in model.retryTranslations(ids: ids) },
                    onSetLanguage: { (language: MeetingLanguage) -> Void in model.setLanguage(language: language) },
                    onReassignBlock: { (segments: [SegmentID], person: Int) -> Void in model.reassignBlock(segments: segments, person: person) },
                    onMergePerson: { (from: Int, into: Int) -> Void in model.mergeLivePersons(from: from, into: into) }
                )
            )
        case .meetings:
            PanelPageView(model: model, router: router, title: "Toplantılar", back: .live, onHide: onHide) {
                MeetingsListPage(model: model) { (id: String) -> Void in router.page = .meeting(id: id) }
            }
        case .meeting(let id):
            PanelPageView(model: model, router: router, title: "Toplantı", back: .meetings, onHide: onHide) {
                if let record = model.meetings.first(where: { $0.id == id }) {
                    MeetingDetailPage(model: model, player: player, record: record)
                        // Toplantı değişince ad alanları gibi durumlar sıfırlansın.
                        .id(record.id)
                } else {
                    ContentUnavailableView("Toplantı bulunamadı", systemImage: "doc.questionmark")
                }
            }
        case .settings:
            PanelPageView(model: model, router: router, title: "Ayarlar", back: .live, onHide: onHide) {
                SettingsPage(model: model, shortcuts: shortcuts)
            }
        case .setup:
            PanelPageView(model: model, router: router, title: "Kurulum", back: .live, onHide: onHide) {
                SetupPage(model: model, shortcuts: shortcuts) { router.page = .live }
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
                    Label(back == .live ? "Canlı" : "Toplantılar", systemImage: "chevron.left")
                        .font(DesignTokens.statusFont)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .hoverHint("Geri", alignment: .leading, edge: .bottom)
                Spacer(minLength: DesignTokens.Spacing.s)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: DesignTokens.Spacing.s)
                if model.phase != .idle {
                    // Kayıt sürerken her sayfadan canlı metne tek dokunuşla dönülür.
                    Button {
                        router.page = .live
                    } label: {
                        Label(model.isFinishing ? "Bitiriliyor" : "Kayıtta", systemImage: "record.circle")
                            .font(DesignTokens.statusFont)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .hoverHint("Canlı metne dön", alignment: .trailing, edge: .bottom)
                }
                Button(action: onHide) {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

/// `--sayfa canli|toplantilar|ayarlar|kurulum` ya da `--toplanti <kimlik>` başlatma argümanının sayfası (geliştirme ve
/// görsel kontrol için); argüman yoksa ya da tanınmıyorsa nil.
func launchPage(arguments: [String]) -> PanelPage? {
    if let index = arguments.firstIndex(of: "--toplanti"), arguments.indices.contains(index + 1) {
        return .meeting(id: arguments[index + 1])
    }
    guard let index = arguments.firstIndex(of: "--sayfa"), arguments.indices.contains(index + 1) else {
        return nil
    }
    switch arguments[index + 1] {
    case "canli": return .live
    case "toplantilar": return .meetings
    case "ayarlar": return .settings
    case "kurulum": return .setup
    default: return nil
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
