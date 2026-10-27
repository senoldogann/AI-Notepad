import AINotepadCore
import AINotepadUI
import os
import SwiftUI

private let appLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "App")

/// Giriş noktası: `--mcp` ile pencere açmadan yerel MCP sunucusu (stdio; Claude Desktop, ChatGPT gibi istemciler
/// toplantı arşivini sorgular), yoksa uygulama.
@main
enum AppEntry {
    static func main() {
        #if DEBUG
        if CommandLine.arguments.contains("--icloud-yokla") {
            probeICloud()
            return
        }
        #endif
        guard CommandLine.arguments.contains("--mcp") else {
            AINotepadApp.main()
            return
        }
        do {
            let version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            runMCPServer(input: .standardInput, output: .standardOutput, sessionsDirectories: try AppPaths.meetingDirectories(location: storedStorageLocation()), version: version)
        } catch {
            FileHandle.standardError.write(Data("AI-Notepad MCP: toplantı klasörü açılamadı: \(error)\n".utf8))
            exit(1)
        }
    }
}

#if DEBUG
/// `--icloud-yokla` (yalnız Debug): iCloud kapsayıcısını çözer, içine deneme dosyası yazıp okur ve siler; sonucu
/// standart çıktıya yazar. Ayarlara ve toplantılara dokunmaz.
private func probeICloud() {
    do {
        let cloud: URL = try AppPaths.cloudSessionsDirectory()
        // Sahte toplantı geçici yerel klasörde; kullanıcının toplantılarına dokunulmaz.
        let local: URL = FileManager.default.temporaryDirectory.appending(path: "ainotepad-icloud-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        let id: String = "probe-\(UUID().uuidString)"
        let folder: URL = local.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: MeetingRecord = MeetingRecord(
            id: id, title: "Yoklama", startedAt: Date(), endedAt: Date(), language: .finnish, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: true,
            engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        try saveMeeting(record: record, directory: folder)
        let inCloud: URL = try moveMeetingToCloud(directory: folder, cloudSessions: cloud)
        let seenInCloud: Bool = loadMeetings(sessionsDirectory: cloud).meetings.contains { $0.id == id }
        let back: URL = try moveMeetingToLocal(directory: inCloud, localSessions: local)
        let seenLocally: Bool = loadMeetings(sessionsDirectory: local).meetings.contains { $0.id == id }
        let goneFromCloud: Bool = !FileManager.default.fileExists(atPath: inCloud.path)
        try FileManager.default.removeItem(at: local)
        print("iCloud tamam: \(cloud.path) | iCloud'da görüldü: \(seenInCloud) | geri geldi: \(seenLocally) (\(back.lastPathComponent)) | iCloud'dan kalktı: \(goneFromCloud)")
        // Anahtar Zinciri eşitlemesi: ayrı servis adıyla deneme değeri (gerçek anahtarlara dokunulmaz).
        let service: String = "AINotepad-yoklama"
        try saveSyncedSecret(service: service, account: .webhook, value: "deneme")
        let synced: Bool = try syncedSecretExists(service: service, account: .webhook)
        try deleteSyncedSecret(service: service, account: .webhook)
        print("Anahtar Zinciri eşitlemesi: yazıldı \(synced), silindi \(try !syncedSecretExists(service: service, account: .webhook))")
    } catch {
        print("iCloud hata: \(error)")
    }
}
#endif

/// Uygulama: ana pencere (Dock), menü çubuğu, kayıt sırasında yüzen panel ve ada.
struct AINotepadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate: AppDelegate
    @State private var model: AppModel
    @State private var panel: LivePanelController
    @State private var island: IslandController
    @State private var shortcuts: ShortcutController
    @State private var router: MainWindowRouter
    @State private var player: MeetingAudioPlayer

    init() {
        registerDefaultSettings()
        if migrateSmartEffort(defaults: .standard) {
            appLogger.info("Not effort'u high'a taşındı (xhigh/max notu kesiyordu)")
        }
        let engine: LiveEngine = LiveEngine(rawValue: UserDefaults.standard.string(forKey: SettingsKey.liveEngine) ?? "") ?? .deepgram
        let displayMode: DisplayMode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.displayMode) ?? "") ?? .bilingual
        // Tek çalar: panel ve ana pencere aynı toplantıyı ya da birini çalar, ikisi üst üste değil.
        let player: MeetingAudioPlayer = MeetingAudioPlayer()
        _player = State(initialValue: player)
        let model: AppModel = AppModel(liveEngine: engine, displayMode: displayMode, player: player)
        _model = State(initialValue: model)
        let hideFromCapture: Bool = UserDefaults.standard.bool(forKey: SettingsKey.hideFromScreenCapture)
        let router: MainWindowRouter = MainWindowRouter()
        _router = State(initialValue: router)
        let panel: LivePanelController = LivePanelController(model: model, hideFromCapture: hideFromCapture, mainRouter: router, player: player)
        _panel = State(initialValue: panel)
        let island: IslandController = IslandController(model: model, onTap: { panel.toggle() })
        _island = State(initialValue: island)
        let shortcuts: ShortcutController = ShortcutController(hotKeys: HotKeyCenter(), model: model, actions: [
            .record: { Task { await toggleRecordingFlow(model: model, panel: panel, island: island) } },
            .toggleWindows: { toggleWindows(panel: panel, island: island) },
        ])
        _shortcuts = State(initialValue: shortcuts)
        // Kayıt ya da işleme sürerken çıkış (⌘Q, Dock, menü) sorulur; toplantı yarıda kalmasın.
        QuitGuard.shared.isBusy = { model.isBusy }
        AppDelegate.onStartFromNotification = {
            guard !model.isRecording else {
                return
            }
            Task { await toggleRecordingFlow(model: model, panel: panel, island: island) }
        }
        model.onAutoRecord = {
            guard !model.isRecording else {
                return
            }
            await toggleRecordingFlow(model: model, panel: panel, island: island)
        }
        QuitGuard.shared.onBlocked = {
            router.quitWarning = true
            openMainWindow(router: router, section: .home)
        }
        panel.attach {
            Task { await toggleRecordingFlow(model: model, panel: panel, island: island) }
        }
        // Pencereler ve kısayollar uygulama açıldıktan sonra kurulur.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // Tema açılışta bir kez uygulanır (hiç pencere açılmasa da ada ve menüler doğru temada olsun).
                applyTheme(theme: AppTheme(rawValue: UserDefaults.standard.string(forKey: SettingsKey.theme) ?? "") ?? .light)
                island.install()
                model.performStartupMaintenance()
                shortcuts.registerAll()
                // Kurulum yalnızca ilk açılışta bir kez (tam pencere); sonra ayarlar Ayarlar'dan değişir.
                if !UserDefaults.standard.bool(forKey: SettingsKey.onboardingCompleted) {
                    UserDefaults.standard.set(true, forKey: SettingsKey.onboardingCompleted)
                    router.section = .setup
                }
                // "--riza": kayıt başlatmadan rıza hatırlatmasını gösterir (görsel kontrol için).
                if CommandLine.arguments.contains("--riza") {
                    model.consentReminderVisible = true
                }
                // "--soru <metin>": Sor bölümünde soruyu sorar (görsel kontrol için).
                if let index = CommandLine.arguments.firstIndex(of: "--soru"), CommandLine.arguments.indices.contains(index + 1) {
                    model.askArchive(question: CommandLine.arguments[index + 1])
                }
                let section: MainSection? = launchSection(arguments: CommandLine.arguments)
                let page: PanelPage? = launchPage(arguments: CommandLine.arguments)
                if let section {
                    router.section = section
                }
                // "--bolum toplantilar --toplanti <id>": toplantı ana pencerede açılır; yalnızca "--toplanti" panelde.
                if section == .meetings, case .meeting(let id) = page {
                    router.selectedMeetingID = id
                } else if let page {
                    panel.show(page: page)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { (_: Notification) -> Void in
            MainActor.assumeIsolated {
                shortcuts.unregisterAll()
            }
        }
        // WhisperKit modeli yalnızca o motor seçiliyse yüklenir.
        if engine == .whisperKit {
            Task { await model.loadModel() }
        }
    }

    var body: some Scene {
        // Açılışta ana pencere; kapatılınca uygulama menü çubuğunda sürer, Dock simgesi ya da menü yeniden açar.
        Window("AI-Notepad", id: mainWindowID) {
            MainWindowView(
                model: model, router: router, shortcuts: shortcuts, player: player,
                onStartRecording: { Task { await toggleRecordingFlow(model: model, panel: panel, island: island) } },
                onShowPanel: {
                    panel.show(page: .live)
                    island.show()
                }
            )
        }
        .defaultSize(width: 1180, height: 780)
        // Başlık çubuğu gizli: ElevenLabs gibi kendi kenar çubuğu ve üst çubuğu pencerenin tepesine kadar.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Ayarlar…") { openMainWindow(router: router, section: .settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {}
        }
        MenuBarExtra {
            MenuContent(model: model, panel: panel, island: island, shortcuts: shortcuts, router: router)
        } label: {
            MenuBarLabel(symbol: menuSymbol)
        }
    }

    private var menuSymbol: String {
        switch model.phase {
        case .recording: "record.circle"
        case .finishing: "hourglass"
        case .idle: "waveform"
        }
    }
}

/// Kaydı başlatır (paneli ve gizlenmiş adayı da gösterir) ya da durdurur. Menü ve kısayol aynı yolu kullanır.
@MainActor
func toggleRecordingFlow(model: AppModel, panel: LivePanelController, island: IslandController) async {
    if model.isRecording {
        model.stopRecording()
        return
    }
    await model.startRecording()
    // Başlatma başarısız olsa da panel canlı sayfada açılır: metin ya da hata orada görünür
    // (önceki toplantının sayfası açık kalmış olabilir).
    panel.show(page: .live)
    island.show()
}

/// Ada + paneli birlikte gösterir/gizler. Ada penceresi kayıt yokken saydam olarak hep açık olduğundan
/// karar panelin durumuna göre verilir.
@MainActor
func toggleWindows(panel: LivePanelController, island: IslandController) {
    if panel.isVisible {
        panel.hide()
        island.hide()
    } else {
        panel.show()
        island.show()
    }
}

/// Menü çubuğu menüsü.
private struct MenuContent: View {
    @Bindable var model: AppModel
    let panel: LivePanelController
    let island: IslandController
    let shortcuts: ShortcutController
    let router: MainWindowRouter
    @AppStorage(SettingsKey.hideFromScreenCapture) private var hideFromCapture: Bool = true

    var body: some View {
        switch model.phase {
        case .recording:
            Button("Kaydı bitir", systemImage: "stop.circle") {
                model.stopRecording()
            }
            .menuShortcut(binding: shortcuts.currentBinding(action: .record))
            Button(model.isPaused ? "Devam ettir" : "Duraklat", systemImage: model.isPaused ? "play.circle" : "pause.circle") {
                model.togglePause()
            }
        case .finishing:
            Button("Bitiriliyor…", systemImage: "hourglass") {}
                .disabled(true)
        case .idle:
            Button("Kaydı başlat", systemImage: "record.circle") {
                Task { await toggleRecordingFlow(model: model, panel: panel, island: island) }
            }
            .disabled(!model.isReadyToRecord || model.isStarting)
            .menuShortcut(binding: shortcuts.currentBinding(action: .record))
        }

        Button("Ada ve paneli göster / gizle", systemImage: "rectangle.on.rectangle") {
            toggleWindows(panel: panel, island: island)
        }
        .menuShortcut(binding: shortcuts.currentBinding(action: .toggleWindows))

        // Kayıt başlamadan görünmesi gereken sorunlar (kırmızı): eksik anahtar/ayar ve kısayol hataları.
        ForEach(Array((model.setupProblems + [model.shortcutError, model.localDiarizationWarning].compactMap { $0 }).enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
            Text(item.element).foregroundStyle(.red)
        }

        Divider()

        if model.isRecording {
            // Kayıt sırasında: otomatik algılama yanılırsa dil buradan değişir (o andan itibaren uygulanır).
            Menu("Dili değiştir", systemImage: "globe") {
                LanguageMenuItems { (language: MeetingLanguage) -> Void in model.setLanguage(language: language) }
            }
            .disabled(model.isFinishing)
        } else {
            Menu {
                Button("Otomatik") { model.languageMode = .automatic }
                LanguageMenuItems { (language: MeetingLanguage) -> Void in model.languageMode = .fixed(language) }
            } label: {
                switch model.languageMode {
                case .automatic: Label("Dil: Otomatik", systemImage: "globe")
                case .fixed(let language): Label(String(localized: "Dil: \(meetingLanguageName(language: language))"), systemImage: "globe")
                }
            }
        }

        Toggle("Ekran görüntülerinde gizle", systemImage: "eye.slash", isOn: $hideFromCapture)
            .onChange(of: hideFromCapture) { (_: Bool, newValue: Bool) in
                panel.setHideFromCapture(hidden: newValue)
                island.setHideFromCapture(hidden: newValue)
            }

        Button("Ana pencere", systemImage: "macwindow") {
            // Açık bölüm korunur (okunan toplantı kaybolmasın); Dock simgesiyle aynı.
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
        Button("Toplantılar", systemImage: "list.bullet.rectangle") {
            openMainWindow(router: router, section: .meetings)
        }
        if !model.processingMeetingIDs.isEmpty {
            Text("Toplantı işleniyor…")
        }

        Button("Ayarlar", systemImage: "gearshape") {
            openMainWindow(router: router, section: .settings)
        }

        if model.liveEngine == .whisperKit {
            switch model.modelStatus {
            case .loading:
                Divider()
                Text("Model hazırlanıyor… İlk açılışta birkaç dakika sürebilir.")
            case .ready:
                if model.localDiarizationWarning != nil {
                    Button("Modeli yeniden yükle", systemImage: "arrow.clockwise") {
                        Task { await model.loadModel() }
                    }
                }
            case .failed(let message):
                Divider()
                Text(message).foregroundStyle(.red)
                Button("Modeli yeniden yükle", systemImage: "arrow.clockwise") {
                    Task { await model.loadModel() }
                }
            }
        }

        Divider()
        Button("Çık", systemImage: "power") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

private extension View {
    /// Global kısayolu menüde ipucu olarak gösterir; harf/rakam olmayan tuşlarda ipucu yok.
    @ViewBuilder
    func menuShortcut(binding: KeyBinding) -> some View {
        if let character = keyEquivalentCharacter(binding: binding) {
            keyboardShortcut(KeyEquivalent(character), modifiers: eventModifiers(binding: binding))
        } else {
            self
        }
    }
}

/// Carbon maskesinden SwiftUI değiştiricileri. Saf fonksiyondur.
private func eventModifiers(binding: KeyBinding) -> EventModifiers {
    var modifiers: EventModifiers = []
    if binding.modifiers & CarbonModifier.control != 0 { modifiers.insert(.control) }
    if binding.modifiers & CarbonModifier.option != 0 { modifiers.insert(.option) }
    if binding.modifiers & CarbonModifier.shift != 0 { modifiers.insert(.shift) }
    if binding.modifiers & CarbonModifier.command != 0 { modifiers.insert(.command) }
    return modifiers
}
