import AINotepadCore
import AINotepadUI
import SwiftUI

/// iPhone uygulaması: sekmeler (Kayıt, Toplantılar, Sor, Görevler, Ayarlar). Mac'le aynı çekirdeği ve görünümü
/// kullanır; toplantılar aynı klasör yapısındadır (eşitleme aşamasında iCloud kapsayıcısına taşınır).
@main
struct AINotepadiOSApp: App {
    @State private var store: PhoneStore
    @State private var recorder: PhoneRecorder
    @State private var ask: PhoneAsk
    @State private var router: PhoneRouter = PhoneRouter(
        tab: launchTab(arguments: CommandLine.arguments), meetingsPath: launchMeetingPath(arguments: CommandLine.arguments)
    )
    @State private var player: MeetingAudioPlayer = MeetingAudioPlayer()

    init() {
        let store: PhoneStore = PhoneStore()
        _store = State(initialValue: store)
        _recorder = State(initialValue: PhoneRecorder(store: store))
        _ask = State(initialValue: PhoneAsk(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, recorder: recorder, ask: ask, router: router, player: player)
                .environment(\.panelAppearance, .standard)
                .font(PanelAppearance.standard.font(size: 15, weight: .regular))
                .tint(PanelAppearance.standard.accent.color)
                .task {
                    store.reload()
                    #if DEBUG
                    if CommandLine.arguments.contains("--ornek-kayit") {
                        recorder.showSampleRecording()
                        return
                    }
                    if let index = CommandLine.arguments.firstIndex(of: "--soru"), CommandLine.arguments.indices.contains(index + 1) {
                        ask.ask(question: CommandLine.arguments[index + 1])
                    }
                    #endif
                    await recorder.resumeUnfinished()
                }
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

/// Gezinme durumu: seçili sekme ve Toplantılar'da açık toplantı (Sor'daki kaynak, görev ya da mini çalar oraya götürür).
@MainActor
@Observable
final class PhoneRouter {
    var tab: PhoneTab
    var meetingsPath: [String]

    init(tab: PhoneTab, meetingsPath: [String]) {
        self.tab = tab
        self.meetingsPath = meetingsPath
    }

    /// Toplantıyı Toplantılar sekmesinde açar.
    func open(meetingID: String) {
        tab = .meetings
        meetingsPath = [meetingID]
    }
}

/// `--sekme kayit|toplantilar|sor|gorevler|ayarlar` başlatma argümanı (görsel kontrol için); yoksa Kayıt. Saf fonksiyondur.
func launchTab(arguments: [String]) -> PhoneTab {
    guard let index = arguments.firstIndex(of: "--sekme"), arguments.indices.contains(index + 1),
          let tab = PhoneTab(rawValue: arguments[index + 1]) else {
        return .record
    }
    return tab
}

/// `--toplanti <kimlik>` başlatma argümanı toplantıyı doğrudan açar (görsel kontrol için). Saf fonksiyondur.
func launchMeetingPath(arguments: [String]) -> [String] {
    guard let index = arguments.firstIndex(of: "--toplanti"), arguments.indices.contains(index + 1) else {
        return []
    }
    return [arguments[index + 1]]
}

/// Sekme çubuğu; bir toplantı çalarken sekme çubuğunun üstünde mini çalar.
struct RootView: View {
    let store: PhoneStore
    let recorder: PhoneRecorder
    let ask: PhoneAsk
    @Bindable var router: PhoneRouter
    let player: MeetingAudioPlayer

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("Kayıt", systemImage: "record.circle", value: PhoneTab.record) {
                RecordTab(recorder: recorder)
            }
            Tab("Toplantılar", systemImage: "list.bullet.rectangle", value: PhoneTab.meetings) {
                MeetingsTab(store: store, router: router, player: player, isRecording: recorder.phase != .idle)
            }
            Tab("Sor", systemImage: "sparkle.magnifyingglass", value: PhoneTab.ask) {
                AskTab(ask: ask, store: store, router: router)
            }
            Tab("Görevler", systemImage: "checkmark.circle", value: PhoneTab.tasks) {
                TasksTab(store: store, router: router)
            }
            Tab("Ayarlar", systemImage: "gearshape", value: PhoneTab.settings) {
                PhoneSettingsTab(store: store)
            }
        }
        .tabViewBottomAccessory(isEnabled: player.meetingID != nil) {
            MiniPlayer(player: player, store: store, router: router)
        }
        .onChange(of: recorder.phase) { (_: RecorderPhase, phase: RecorderPhase) in
            // Kayıt başlarken çalma durur (mikrofon ve hoparlör aynı oturumu paylaşamaz).
            if phase == .starting {
                player.stop()
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

    /// Kaydedilen toplantıyı listeye yazar (her kayıtta klasör yeniden okunmaz).
    func upsert(record: MeetingRecord) {
        meetings = upsertMeeting(records: meetings, record: record).sorted { $0.startedAt > $1.startedAt }
    }

    /// Görevin tamamlandı işaretini değiştirir ve toplantıyı saklar.
    func toggleTask(meetingID: String, task: NoteTask) {
        guard let record = meetings.first(where: { $0.id == meetingID }), record.status != .recording, record.status != .processing else {
            return
        }
        let updated: MeetingRecord = togglingTask(record: record, task: task)
        do {
            try saveMeeting(record: updated, directory: try sessionDirectory(id: meetingID))
            upsert(record: updated)
        } catch {
            problems = appendUnique(messages: problems, message: String(localized: "Toplantı kaydedilemedi: \(userFacingMessage(error: error))"))
        }
    }

    /// Toplantının klasörü (klasör adı toplantı kimliğidir).
    func sessionDirectory(id: String) throws -> URL {
        try AppPaths.sessionsDirectory().appending(path: id, directoryHint: .isDirectory)
    }

    /// Toplantının ses kayıtları ("Diğerleri" önce); ses silindiyse ya da hiç yoksa boş.
    func audioURLs(record: MeetingRecord) throws -> [URL] {
        guard !record.audioDeleted else {
            return []
        }
        let directory: URL = try sessionDirectory(id: record.id)
        return [Speaker.others, Speaker.me].compactMap { meetingAudioURL(directory: directory, speaker: $0) }
    }
}
