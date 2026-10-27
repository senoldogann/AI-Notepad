import AINotepadCore
import AINotepadUI
import AppIntents
import SwiftUI

/// iPhone uygulaması: sekmeler (Kayıt, Toplantılar, Sor, Görevler, Ayarlar). Mac'le aynı çekirdeği ve görünümü
/// kullanır; toplantılar aynı klasör yapısındadır (eşitleme aşamasında iCloud kapsayıcısına taşınır).
@main
struct AINotepadiOSApp: App {
    @State private var store: PhoneStore
    @State private var recorder: PhoneRecorder
    @State private var ask: PhoneAsk
    @State private var router: PhoneRouter
    @State private var player: MeetingAudioPlayer = MeetingAudioPlayer()

    init() {
        registerPhoneDefaults()
        // Tema ilk kareden önce uygulanır.
        let theme: AppTheme = AppTheme(rawValue: UserDefaults.standard.string(forKey: PhoneSettingsKey.theme) ?? "") ?? .system
        ThemeStore.shared.set(light: theme.colorSets.light, dark: theme.colorSets.dark)
        #if DEBUG
        // `--karsilama` (yalnız Debug, görsel kontrol): ilk açılış karşılaması yeniden gösterilir.
        if CommandLine.arguments.contains("--karsilama") {
            UserDefaults.standard.removeObject(forKey: PhoneSettingsKey.onboardingCompleted)
        }
        #endif
        let store: PhoneStore = PhoneStore()
        let recorder: PhoneRecorder = PhoneRecorder(store: store)
        let router: PhoneRouter = PhoneRouter(
            tab: launchTab(arguments: CommandLine.arguments), meetingsPath: launchMeetingPath(arguments: CommandLine.arguments)
        )
        _store = State(initialValue: store)
        _recorder = State(initialValue: recorder)
        _router = State(initialValue: router)
        _ask = State(initialValue: PhoneAsk(store: store))
        // Kısayollar, Denetim Merkezi ve canlı etkinlikteki niyetler kaydediciye ve gezinmeye buradan ulaşır.
        AppDependencyManager.shared.add(dependency: recorder)
        AppDependencyManager.shared.add(dependency: router)
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, recorder: recorder, ask: ask, router: router, player: player)
                .environment(\.panelAppearance, .standard)
                .font(PanelAppearance.standard.font(size: 15, weight: .regular))
                .tint(PanelAppearance.standard.accent.color)
                .task {
                    store.reload()
                    ask.loadRecipes()
                    await store.cloud.start(excluding: recorder.busyMeetingIDs.union([player.meetingID].compactMap { $0 })) { store.reload() }
                    store.applyRetention(now: Date())
                    #if DEBUG
                    if CommandLine.arguments.contains("--ornek-kayit") {
                        recorder.showSampleRecording()
                        return
                    }
                    if let index = CommandLine.arguments.firstIndex(of: "--soru"), CommandLine.arguments.indices.contains(index + 1) {
                        ask.ask(question: CommandLine.arguments[index + 1], meetingIDs: [], recipeTitle: nil)
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
    /// İlk açılış karşılaması bitti (`--karsilama` ile Debug'da yeniden gösterilir).
    @AppStorage(PhoneSettingsKey.onboardingCompleted) private var onboardingCompleted: Bool = false
    @AppStorage(PhoneSettingsKey.theme) private var theme: String = AppTheme.system.rawValue

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("Kayıt", systemImage: "record.circle", value: PhoneTab.record) {
                RecordTab(recorder: recorder, store: store, router: router)
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
                PhoneSettingsTab(store: store, excludedFromMoves: recorder.busyMeetingIDs.union([player.meetingID].compactMap { $0 }))
            }
        }
        .tabViewBottomAccessory(isEnabled: player.meetingID != nil) {
            MiniPlayer(player: player, store: store, router: router)
        }
        .fullScreenCover(isPresented: Binding<Bool>(get: { !onboardingCompleted }, set: { (_: Bool) -> Void in })) {
            PhoneOnboarding {
                onboardingCompleted = true
                router.tab = .settings
            } onFinish: {
                onboardingCompleted = true
            }
        }
        .preferredColorScheme((AppTheme(rawValue: theme) ?? .system).isDark.map { $0 ? ColorScheme.dark : ColorScheme.light })
        .onChange(of: theme) { (_: String, value: String) in
            let selected: AppTheme = AppTheme(rawValue: value) ?? .system
            ThemeStore.shared.set(light: selected.colorSets.light, dark: selected.colorSets.dark)
        }
        .onChange(of: player.meetingID, initial: true) { (_: String?, id: String?) in
            store.playingMeetingID = id
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
    /// iCloud'dan henüz inmemiş toplantı sayısı.
    private(set) var downloadingCount: Int = 0
    /// iCloud eşitlemesi (Ayarlar › Eşitleme).
    let cloud: CloudSyncController = CloudSyncController()
    /// Çalan toplantı: iCloud'a taşınmaz, sesi saklama süresiyle silinmez (dosyaları kullanımda).
    var playingMeetingID: String?

    /// Toplantıları diskten yeniden okur (en yeni önce): bu iPhone'daki ve iCloud açıksa iCloud'daki.
    func reload() {
        do {
            let result: MeetingLoadResult = loadMeetings(directories: try AppPaths.meetingDirectories(location: cloud.activeLocation))
            meetings = result.meetings
            problems = result.failures.map { "\($0.folder): \($0.reason)" }
            downloadingCount = result.downloading.count
        } catch {
            problems = [userFacingMessage(error: error)]
        }
    }

    /// Kaydedilen toplantıyı listeye yazar (her kayıtta klasör yeniden okunmaz).
    func upsert(record: MeetingRecord) {
        meetings = upsertMeeting(records: meetings, record: record)
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

    /// Toplantıyı kalıcı olarak siler (onay arayüzde sorulur). Kayıttaki ya da işlenen toplantı silinmez.
    func deleteMeeting(id: String) throws {
        guard let record = meetings.first(where: { $0.id == id }), record.status != .recording, record.status != .processing else {
            throw StorageError.deleteFailed(path: id, reason: "kayıtta ya da işleniyor")
        }
        try deleteMeetingDirectory(directory: try sessionDirectory(id: id))
        meetings.removeAll { $0.id == id }
    }

    /// Saklama süresi (Ayarlar) dolan toplantıların sesini ve ses izlerini siler; metin ve not kalır. Silinemeyenin
    /// nedeni sorunlarda görünür, bir sonraki açılışta yeniden denenir.
    func applyRetention(now: Date) {
        let days: Int = min(365, max(7, UserDefaults.standard.integer(forKey: PhoneSettingsKey.audioRetentionDays)))
        // iCloud'daki toplantılar da (eşitleme açıkken biten her toplantı iCloud'a taşınır); çalan toplantının sesi kalır.
        for id in audioToDelete(records: meetings.filter { $0.id != playingMeetingID }, now: now, retentionDays: days) {
            guard let record = meetings.first(where: { $0.id == id }) else {
                continue
            }
            do {
                let directory: URL = try sessionDirectory(id: id)
                try deleteAudioFiles(directory: directory)
                let updated: MeetingRecord = record.withAudioDeleted().with(voiceprints: nil)
                try saveMeeting(record: updated, directory: directory)
                upsert(record: updated)
            } catch {
                problems = appendUnique(messages: problems, message: userFacingMessage(error: error))
            }
        }
    }

    /// Notu yeniden yazılan toplantılar (menüde "Not yazılıyor…").
    private(set) var regeneratingIDs: Set<String> = []

    /// Notu yeniden yazar (Mac'teki "Notu yenile"): başarısız ya da yarım kalan toplantı da iPhone'dan düzelir.
    func regenerateNote(meetingID: String) async {
        guard let record = meetings.first(where: { $0.id == meetingID }), record.status != .recording, record.status != .processing,
              !regeneratingIDs.contains(meetingID) else {
            return
        }
        regeneratingIDs.insert(meetingID)
        defer { regeneratingIDs.remove(meetingID) }
        do {
            let llm: LLMProvider = try await phoneLLMProvider()
            let directory: URL = try sessionDirectory(id: meetingID)
            let userName: String = UserDefaults.standard.string(forKey: PhoneSettingsKey.userName) ?? ""
            let result: MeetingRecord = await AINotepadCore.regenerateNote(record: record, directory: directory, llm: llm, userName: userName)
            try saveMeeting(record: result, directory: directory)
            upsert(record: result)
        } catch {
            problems = appendUnique(messages: problems, message: String(localized: "Not yenilenemedi: \(userFacingMessage(error: error))"))
        }
    }

    /// Toplantının klasörü (klasör adı toplantı kimliğidir).
    func sessionDirectory(id: String) throws -> URL {
        try AppPaths.meetingDirectory(id: id, location: cloud.activeLocation)
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
