import AINotepadCore
import AINotepadUI
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

/// Modeli gözleyip sayfayı seçen kabuk; tüm sayfalara aynı cam yüzeyi verir. Kayıt bitince panel o toplantının
/// sayfasına geçer: toplantıdan çıkınca ilk bakılacak şey kime ne düştüğüdür.
struct PanelHost: View {
    let model: AppModel
    let router: PanelRouter
    let shortcuts: ShortcutController
    let player: MeetingAudioPlayer
    let onStart: @MainActor () -> Void
    let onHide: @MainActor () -> Void

    var body: some View {
        content
            .frame(minWidth: 300, minHeight: 240)
            .panelSurface()
            .onChange(of: model.lastFinishedMeetingID) { (_: String?, id: String?) in
                if let id {
                    router.page = .meeting(id: id)
                }
            }
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
                    onSetLanguage: { (language: MeetingLanguage) -> Void in model.setLanguage(language: language) }
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
    let title: String
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
                .help("Geri")
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
                    .help("Canlı metne dön")
                }
                Button(action: onHide) {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Paneli gizle")
                .accessibilityLabel("Paneli gizle")
            }
            .padding(.horizontal, DesignTokens.Spacing.l)
            .padding(.vertical, DesignTokens.Spacing.m)
            Divider().opacity(0.35)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// `--sayfa canli|toplantilar|ayarlar|kurulum` başlatma argümanının sayfası (geliştirme ve görsel kontrol için);
/// argüman yoksa ya da tanınmıyorsa nil.
func launchPage(arguments: [String]) -> PanelPage? {
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
