import AINotepadCore
import AINotepadUI
import SwiftUI

/// iPhone uygulaması: sekmeler (Kayıt, Toplantılar, Sor, Görevler, Ayarlar). Mac'le aynı çekirdeği ve görünümü
/// kullanır; toplantılar aynı klasör yapısındadır (eşitleme aşamasında iCloud kapsayıcısına taşınır).
@main
struct AINotepadiOSApp: App {
    @State private var store: PhoneStore = PhoneStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .environment(\.panelAppearance, .standard)
                .font(PanelAppearance.standard.font(size: 15, weight: .regular))
                .tint(PanelAppearance.standard.accent.color)
                .task { store.reload() }
        }
    }
}

/// Sekmeler.
enum PhoneTab: String, Hashable {
    case record = "kayit"
    case meetings = "toplantilar"
    case ask = "sor"
    case tasks = "gorevler"
    case settings = "ayarlar"
}

/// `--sekme kayit|toplantilar|sor|gorevler|ayarlar` başlatma argümanı (görsel kontrol için); yoksa Kayıt. Saf fonksiyondur.
func launchTab(arguments: [String]) -> PhoneTab {
    guard let index = arguments.firstIndex(of: "--sekme"), arguments.indices.contains(index + 1),
          let tab = PhoneTab(rawValue: arguments[index + 1]) else {
        return .record
    }
    return tab
}

/// Sekme çubuğu.
struct RootView: View {
    let store: PhoneStore
    @State private var tab: PhoneTab = launchTab(arguments: CommandLine.arguments)

    var body: some View {
        TabView(selection: $tab) {
            Tab("Kayıt", systemImage: "record.circle", value: PhoneTab.record) {
                RecordTab()
            }
            Tab("Toplantılar", systemImage: "list.bullet.rectangle", value: PhoneTab.meetings) {
                MeetingsTab(store: store)
            }
            Tab("Sor", systemImage: "sparkle.magnifyingglass", value: PhoneTab.ask) {
                ComingSoonTab(title: "Toplantılarına sor", symbol: "sparkle.magnifyingglass")
            }
            Tab("Görevler", systemImage: "checkmark.circle", value: PhoneTab.tasks) {
                ComingSoonTab(title: "Görevlerim", symbol: "checkmark.circle")
            }
            Tab("Ayarlar", systemImage: "gearshape", value: PhoneTab.settings) {
                PhoneSettingsTab(store: store)
            }
        }
    }
}

/// Yerel toplantı arşivi (cihazdaki `Sessions` klasörü); eşitleme aşamasında iCloud kapsayıcısı olur.
@MainActor
@Observable
final class PhoneStore {
    private(set) var meetings: [MeetingRecord] = []
    /// Okunamayan klasörler ya da klasöre erişim hatası (kullanıcıya gösterilir).
    private(set) var problems: [String] = []

    /// Toplantıları diskten yeniden okur (en yeni önce).
    func reload() {
        do {
            let result: MeetingLoadResult = loadMeetings(sessionsDirectory: try AppPaths.sessionsDirectory())
            meetings = result.meetings.sorted { $0.startedAt > $1.startedAt }
            problems = result.failures.map { "\($0.folder): \($0.reason)" }
        } catch {
            problems = [userFacingMessage(error: error)]
        }
    }
}
