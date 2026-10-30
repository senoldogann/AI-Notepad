import AINotepadCore
import AINotepadUI
import os
import SwiftUI

private let appLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "App")
#if DEBUG
/// Kabul testi argümanlarının logu (yalnız Debug).
private let testLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AcceptanceTest")

/// Kabul testinin sonucunu geçici dosyaya ekler (yalnız Debug; test betiği okur).
@MainActor
private func writeAcceptanceResult(line: String) {
    let url: URL = FileManager.default.temporaryDirectory.appending(path: "ainotepad-kabul.txt")
    let text: String = (FileManager.default.contents(atPath: url.path).flatMap { String(data: $0, encoding: .utf8) } ?? "") + line + "\n"
    do {
        try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
        testLogger.error("Kabul testi sonucu yazılamadı: \(String(describing: error), privacy: .private)")
    }
}
#endif

/// Giriş noktası: `--mcp` ile pencere açmadan yerel MCP sunucusu (stdio; Claude Desktop, ChatGPT gibi istemciler
/// toplantı arşivini sorgular), yoksa uygulama.
@main
enum AppEntry {
    static func main() {
        #if HOSTED_EDITION
        // Gistsmith'in arayüzü varsayılan olarak İngilizce açılır (macOS'un dili Türkçe olsa da); Ayarlar'dan
        // değiştirilebilir. Hiçbir metin okunmadan yazılmalı.
        if let identifier = Bundle.main.bundleIdentifier {
            applyDefaultInterfaceLanguageOnce(bundleIdentifier: identifier, language: .english)
        }
        #endif
        // Görünen ad (bkz. `appName`) metinlerden önce okunur: yoksa uygulama hemen, açık hatayla kapanır.
        _ = appName
        // Veri klasörü adı Info.plist'ten gelir; yoksa uygulama başka bir uygulamanın verisine yazmasın diye açılmaz.
        do {
            _ = try AppPaths.dataFolderName(bundle: .main)
        } catch {
            let message: String = userFacingMessage(error: error)
            appLogger.fault("Veri klasörü tanımlı değil, uygulama açılmıyor, hata: \(String(describing: error), privacy: .private)")
            FileHandle.standardError.write(Data("\(appName): \(message)\n".utf8))
            fatalError(message)
        }
        #if HOSTED_EDITION
        // Anahtar Zinciri servis adı da Info.plist'ten (Debug ve Release ayrı); yoksa oturum yanlış yere yazılmasın diye
        // uygulama açılmaz.
        do {
            _ = try hostedKeychainService(bundle: .main)
        } catch {
            let message: String = userFacingMessage(error: error)
            appLogger.fault("Anahtar Zinciri servisi tanımlı değil, uygulama açılmıyor, hata: \(String(describing: error), privacy: .private)")
            FileHandle.standardError.write(Data("\(appName): \(message)\n".utf8))
            fatalError(message)
        }
        #endif
        #if DEBUG
        if CommandLine.arguments.contains("--icloud-yokla") {
            probeICloud()
            return
        }
        // "--tanitim <sahne>": sahte verilerle ekran görüntüsü modu; veri geçici eve yazılır, değilse açılmaz.
        if isDemoMode {
            do {
                _ = try demoScene(arguments: CommandLine.arguments)
                #if HOSTED_EDITION
                // Abonelikte veri hesap başına: tanıtım verisi sahte bir hesabın klasörüne yazılır.
                try AppPaths.activateAccount(key: accountDataKey(userId: "tanitim"))
                #endif
                try seedDemoData(now: Date())
            } catch {
                FileHandle.standardError.write(Data("\(appName) tanıtım: \(error)\n".utf8))
                fatalError(String(describing: error))
            }
        }
        #endif
        guard CommandLine.arguments.contains("--mcp") else {
            AINotepadApp.main()
            return
        }
        #if HOSTED_EDITION
        // Giriş kapısı: oturum yoksa yerel MCP sunucusu da açılmaz (toplantı arşivi girişten sonra kullanılır). Yalnızca
        // giriş yapmış hesabın arşivi okunur; her araç çağrısında oturum yeniden denetlenir (bkz.
        // `hostedMCPAccessDenial`: çıkış ya da başka hesapla giriş yapılınca arşiv okunmaz).
        let archive: HostedMCPArchive
        do {
            guard let current = try hostedMCPArchive(bundle: .main) else {
                FileHandle.standardError.write(Data("\(appName) MCP: \(String(localized: "Önce uygulamayı açıp giriş yap."))\n".utf8))
                exit(1)
            }
            archive = current
        } catch {
            FileHandle.standardError.write(Data("\(appName) MCP: \(userFacingMessage(error: error))\n".utf8))
            exit(1)
        }
        // Arşiv bugün MCP ile açıldı: yalnızca bu Mac'teki günlük kayda yazılır (paylaşım açıksa); uygulama gönderir.
        registerDefaultSettings()
        MainActor.assumeIsolated {
            recordFeatureUsage(feature: .mcp)
        }
        let version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        runMCPServer(
            input: .standardInput, output: .standardOutput, sessionsDirectories: [archive.sessionsDirectory],
            accessDenial: { hostedMCPAccessDenial(archive: archive, bundle: .main) }, version: version, noteLanguage: selectedNoteLanguage(), appName: appName
        )
        #else
        do {
            let version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            runMCPServer(
                input: .standardInput, output: .standardOutput, sessionsDirectories: try AppPaths.meetingDirectories(location: storedStorageLocation()),
                // Geliştirici sürümünde oturum yoktur, ret de yoktur.
                accessDenial: { nil }, version: version, noteLanguage: selectedNoteLanguage(), appName: appName
            )
        } catch {
            FileHandle.standardError.write(Data("\(appName) MCP: toplantı klasörü açılamadı: \(error)\n".utf8))
            exit(1)
        }
        #endif
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
    @State private var updater: AppUpdater
    @State private var crashReports: CrashReportCenter

    init() {
        registerDefaultSettings()
        keepLegacyNoteLanguage(defaults: .standard)
        // Tema ilk kareden önce: Gece/Grafit kullanıcısı açılışta önce açık renkleri görmesin.
        applyTheme(theme: AppTheme(rawValue: UserDefaults.standard.string(forKey: SettingsKey.theme) ?? "") ?? .light)
        if migrateSmartEffort(defaults: .standard) {
            appLogger.info("Not effort'u high'a taşındı (xhigh/max notu kesiyordu)")
        }
        #if HOSTED_EDITION
        // Abonelik sürümünde motor seçimi yok: yerel motor WhisperKit; kaydın canlı motoru sunucuya göre seçilir.
        let engine: LiveEngine = hostedLocalEngine
        #else
        let engine: LiveEngine = LiveEngine(rawValue: UserDefaults.standard.string(forKey: SettingsKey.liveEngine) ?? "") ?? .deepgram
        #endif
        let displayMode: DisplayMode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.displayMode) ?? "") ?? .bilingual
        // Tek çalar: panel ve ana pencere aynı toplantıyı ya da birini çalar, ikisi üst üste değil.
        let player: MeetingAudioPlayer = MeetingAudioPlayer()
        _player = State(initialValue: player)
        let model: AppModel = AppModel(liveEngine: engine, displayMode: displayMode, player: player)
        _model = State(initialValue: model)
        // Güncelleme ve çökme raporları pencerelerden önce: menü ve ayarlar ilk karede doğru görünsün. Kayıt ya da
        // işleme sürerken güncelleme uygulamayı yeniden başlatmaz (çıkış korumasıyla aynı koşul).
        let updater: AppUpdater = AppUpdater(publicKey: sparklePublicKey(bundle: .main), isBusy: { model.isBusy })
        _updater = State(initialValue: updater)
        let crashReports: CrashReportCenter = CrashReportCenter()
        _crashReports = State(initialValue: crashReports)
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
        model.isStartBlocked = { isSignInRequired() || startBlockNotice(model: model) != nil }
        AppDelegate.onStartFromNotification = {
            guard !model.isRecording else {
                return
            }
            Task { await toggleRecordingFlow(model: model, panel: panel, island: island) }
        }
        AppDelegate.onOpenHomeFromNotification = {
            openMainWindow(router: router, section: .home)
        }
        model.onAutoRecord = {
            guard !model.isRecording else {
                return
            }
            await toggleRecordingFlow(model: model, panel: panel, island: island)
        }
        QuitGuard.shared.onBlocked = {
            router.quitWarning = true
            // Kayıt odağı ekranı uyarıyı örtmesin (⌘Q tepkisiz görünüyordu).
            router.isRecordingFocusDismissed = true
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
                // Abonelikte toplantılar, kişiler ve geçmiş yalnızca giriş yapan hesabın verisi yüklüyse okunur; değilse
                // giriş yapılıp hesap yüklenince (bkz. `HostedAccount.dataActivations`).
                if isAccountDataReady() {
                    model.performStartupMaintenance()
                }
                // Önceki açılışın çökme raporları (MetricKit) okunur ve yenileri dinlenir.
                crashReports.start()
                // Giriş kapısı kapalıyken (abonelik sürümü, oturum yok) genel kısayollar kaydedilmez; giriş yapılınca
                // menü çubuğu etiketi kaydeder.
                if !isSignInRequired() {
                    shortcuts.registerAll()
                }
                // Kurulum yalnızca ilk açılışta bir kez (tam pencere); sonra ayarlar Ayarlar'dan değişir.
                if !UserDefaults.standard.bool(forKey: SettingsKey.onboardingCompleted) {
                    router.section = .setup
                }
                #if DEBUG
                // "--riza": kayıt başlatmadan rıza hatırlatmasını gösterir (görsel kontrol için; yalnız Debug).
                if CommandLine.arguments.contains("--riza") {
                    model.consentReminderVisible = true
                }
                // "--soru <metin>": Sor bölümünde soruyu sorar (görsel kontrol için; yalnız Debug: ücretli yapay zekâ
                // isteğidir).
                if !isSignInRequired(), let index = CommandLine.arguments.firstIndex(of: "--soru"), CommandLine.arguments.indices.contains(index + 1) {
                    model.askArchive(question: CommandLine.arguments[index + 1], meetingIDs: [], recipeTitle: nil)
                }
                // "--ara": arama penceresini açar (görsel kontrol için; yalnız Debug).
                if CommandLine.arguments.contains("--ara") {
                    router.isSearchPresented = true
                }
                // "--test-kaydi <sn>": kaydı başlatır, verilen süre sonra durdurur (uçtan uca kabul testi için; yalnız
                // Debug). Ses dışarıdan (ör. `afplay`) sistem sesine çalınır.
                if let index = CommandLine.arguments.firstIndex(of: "--test-kaydi"), CommandLine.arguments.indices.contains(index + 1),
                   let seconds = Double(CommandLine.arguments[index + 1]) {
                    Task {
                        await toggleRecordingFlow(model: model, panel: panel, island: island)
                        do {
                            try await Task.sleep(for: .seconds(seconds))
                        } catch {
                            return
                        }
                        await toggleRecordingFlow(model: model, panel: panel, island: island)
                    }
                }
                // "--test-gorev": en son toplantının kullanıcı görevlerini ilk görev aracına iki kez gönderir (kabul testi:
                // ikincisi iş açmamalı); sonuçlar loglanır ve toplantı sayfasında görünür.
                if CommandLine.arguments.contains("--test-gorev") {
                    Task {
                        for _ in 0..<60 where model.taskTrackers.isEmpty || model.meetings.isEmpty {
                            do {
                                try await Task.sleep(for: .milliseconds(500))
                            } catch {
                                return
                            }
                        }
                        guard let tracker = model.taskTrackers.first,
                              let meeting = model.meetings.max(by: { $0.startedAt < $1.startedAt }) else {
                            testLogger.error("Kabul testi: görev aracı ya da toplantı yok")
                            writeAcceptanceResult(line: "araç ya da toplantı yok, araç: \(model.taskTrackers.count), toplantı: \(model.meetings.count)")
                            return
                        }
                        // "--test-gorev-hedef <ad>": göndermeden önce aracın hedefini (takım/proje) ayarlar.
                        if let index = CommandLine.arguments.firstIndex(of: "--test-gorev-hedef"), CommandLine.arguments.indices.contains(index + 1) {
                            await model.setTrackerTarget(id: tracker.id, target: CommandLine.arguments[index + 1])
                        }
                        writeAcceptanceResult(line: "başladı, araç: \(tracker.service.rawValue), hedef: \(model.taskTrackers.first?.target ?? "-"), toplantı: \(meeting.id)")
                        router.section = .meetings
                        router.selectedMeetingID = meeting.id
                        for round in 1...2 {
                            await model.sendTasks(meetingID: meeting.id, trackerID: tracker.id, scope: .mine)
                            testLogger.info("Kabul testi: görev gönderimi \(round, privacy: .public), durum: \(String(describing: model.trackerStates[meeting.id]), privacy: .public)")
                            writeAcceptanceResult(line: "tur \(round): \(String(describing: model.trackerStates[meeting.id]))")
                        }
                    }
                }
                #endif
                // "--bolum", "--sayfa", "--toplanti": açılışta bölüm, panel sayfası ya da toplantı açılır (yalnızca gezinme;
                // Release'te de görsel kontrol için).
                let section: MainSection? = launchSection(arguments: CommandLine.arguments)
                let page: PanelPage? = launchPage(arguments: CommandLine.arguments)
                if let section {
                    router.section = section
                }
                // "--bolum toplantilar --toplanti <id>": toplantı ana pencerede açılır; yalnızca "--toplanti" panelde.
                if section == .meetings, case .meeting(let id) = page {
                    router.selectedMeetingID = id
                } else if let page {
                    if !isSignInRequired() {
                        panel.show(page: page)
                    }
                }
                #if DEBUG
                // Tanıtım modunun sahnesi (sahne açılışta doğrulandı; burada hata beklenmez).
                if isDemoMode {
                    do {
                        showDemoScene(scene: try demoScene(arguments: CommandLine.arguments), model: model, router: router, panel: panel, updater: updater, now: Date())
                    } catch {
                        fatalError(String(describing: error))
                    }
                }
                #endif
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { (_: Notification) -> Void in
            MainActor.assumeIsolated {
                shortcuts.unregisterAll()
            }
        }
        // WhisperKit modeli yalnızca o motor seçiliyse yüklenir; ilk açılışta anahtar yoksa cihaz içi mod seçilir.
        Task {
            #if DEBUG
            // Tanıtım modu sunucuya bağlanmaz ve konuşma modelini yüklemez (bkz. App/DemoData.swift).
            if isDemoMode {
                return
            }
            #endif
            #if HOSTED_EDITION
            // Abonelik: hesap ve hak durumu açılışta okunur, kurulum eksikleri (giriş) güncellenir. Mac modeli (~630 MB)
            // yalnızca sunucu bulut canlı metnini önermiyorsa ya da hak durumu okunamadıysa yüklenir; bulut
            // kullanılabiliyorsa ilk Mac'e geçişte iner (bkz. `hostedPreloadsLocalModel`).
            chooseHostedMeetingLanguageOnFirstRun(defaults: .standard)
            await HostedAccount.shared.refresh()
            // Kullanım istatistikleri (paylaşım açıksa): önceki oturumdan bekleyenler hemen, sonra düzenli gönderilir.
            HostedTelemetryCenter.shared.start()
            await model.refreshSetupProblems()
            if hostedPreloadsLocalModel(account: .shared) {
                await model.loadModel()
            }
            #else
            if await chooseOnDeviceOnFirstRun(defaults: .standard) {
                appLogger.info("İlk açılış: anahtar yok, cihaz içi mod seçildi")
                await model.selectEngine(engine: .appleSpeech)
                model.settingsChanged()
                return
            }
            switch engine {
            case .deepgram: break
            case .whisperKit: await model.loadModel()
            case .appleSpeech: await model.prepareSpeechModel()
            }
            #endif
        }
    }

    var body: some Scene {
        // Açılışta ana pencere; kapatılınca uygulama menü çubuğunda sürer, Dock simgesi ya da menü yeniden açar.
        Window(appName, id: mainWindowID) {
            Group {
                #if HOSTED_EDITION
                // Giriş kapısı: oturum yoksa yalnızca giriş ekranı (kenar çubuğu, toplantılar, ayarlar ve kayıt yok).
                if HostedAccount.shared.requiresSignIn {
                    HostedSignInGate(account: .shared)
                } else {
                    mainWindow
                }
                #else
                mainWindow
                #endif
            }
        }
        .defaultSize(width: 1180, height: 780)
        // Açılışta her zaman görünür: son oturumda pencere kapatılmışsa durum geri yükleme onu kapalı açıyordu
        // (uygulama açılıyor ama yalnızca menü çubuğunda görünüyordu).
        .defaultLaunchBehavior(.presented)
        // Başlık çubuğu gizli: ElevenLabs gibi kendi kenar çubuğu ve üst çubuğu pencerenin tepesine kadar.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Uygulama menüsünde "Hakkında"nın altında; güncelleme kapalıysa (imza anahtarı yok) görünmez.
            CommandGroup(after: .appInfo) {
                if updater.isEnabled {
                    Button("Güncellemeleri denetle…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Ayarlar…") { openMainWindow(router: router, section: .settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // Menü çubuğundaki menüyle aynı durumlar: bitirilirken "Bitiriliyor…" ve kapalı. Ana pencerede başlatma engelinin
            // nedeni kayıt kartında yazdığı için engelliyken kapalı kalır.
            CommandGroup(replacing: .newItem) {
                Button(newItemTitle(phase: model.phase)) {
                    Task { await toggleRecordingFlow(model: model, panel: panel, island: island) }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.phase == .finishing
                    || (model.phase == .idle && (!model.isReadyToRecord || model.isStarting || isSignInRequired() || startBlockNotice(model: model) != nil)))
            }
            // Bölümler arası geçiş (⌘1–5), Mac uygulamalarının alışılmış kısayolları.
            CommandMenu("Git") {
                Button("Ana sayfa") { openMainWindow(router: router, section: .home) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Toplantılar") { openMainWindow(router: router, section: .meetings) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Sor") { openMainWindow(router: router, section: .ask) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Görevlerim") { openMainWindow(router: router, section: .tasks) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Kişiler") { openMainWindow(router: router, section: .people) }
                    .keyboardShortcut("5", modifiers: .command)
            }
        }
        MenuBarExtra {
            MenuContent(model: model, panel: panel, island: island, shortcuts: shortcuts, router: router, updater: updater)
        } label: {
            MenuBarLabel(symbol: menuSymbol)
                // Menü çubuğu simgesi hep açık: kayıt ve işleme bitince ertelenen güncelleme (varsa) burada sürdürülür,
                // ana pencere kapalı olsa da.
                .onChange(of: model.isBusy) { (_: Bool, isBusy: Bool) in
                    if !isBusy {
                        updater.resumePostponedRelaunch()
                    }
                }
                // Giriş kapısı açılınca genel kısayollar kaydedilir, kapanınca (çıkış, hesap silme) kaldırılır.
                .onChange(of: isSignInRequired()) { (_: Bool, required: Bool) in
                    if required {
                        shortcuts.unregisterAll()
                        if !model.isRecording {
                            panel.hide()
                            island.hide()
                        }
                    } else {
                        shortcuts.registerAll()
                    }
                }
                #if HOSTED_EDITION
                // Bekleyen (çevrimdışı) kayıtlar: ağ gelince, hak durumu okununca, uygulama öne gelince ve kayıt/işleme
                // bitince işlenir (birer birer).
                .onChange(of: HostedAccount.shared.queueTrigger) { (_: Int, _: Int) in
                    Task { await model.runOfflineQueue() }
                }
                .onChange(of: model.isBusy) { (_: Bool, isBusy: Bool) in
                    if !isBusy {
                        relaunchForAccountSwitchIfIdle(model: model)
                        Task { await model.runOfflineQueue() }
                    }
                }
                // Açılışta oturum yoktu, giriş yapılınca hesabın verisi yüklendi: toplantılar, kişiler ve geçmiş şimdi
                // okunur. Başka bir hesapla giriş yapıldıysa uygulama (kayıt ve işleme yokken) yeniden başlar; o
                // hesabın verisi yeni süreçte yüklenir.
                .onChange(of: HostedAccount.shared.dataActivations) { (_: Int, _: Int) in
                    model.performStartupMaintenance()
                }
                .onChange(of: HostedAccount.shared.dataState) { (_: HostedDataState, _: HostedDataState) in
                    relaunchForAccountSwitchIfIdle(model: model)
                }
                // Kurulum eksikleri hesabın her durum değişiminde (giriş, çıkış, hesap silme, hak durumu yenilemesi)
                // yeniden hesaplanır: açılışta bir kez hesaplanıp eskiyen "giriş yapılmamış" uyarısı kalmaz. Menü
                // çubuğu simgesi hep açık olduğundan ana pencere kapalıyken de çalışır.
                .onChange(of: HostedAccount.shared.state) { (_: HostedAccountState, _: HostedAccountState) in
                    Task { await model.refreshSetupProblems() }
                }
                #endif
                // Uygulama öne gelince kurulum eksikleri yenilenir (Anahtar Zinciri ya da Sistem Ayarları'nda yapılan
                // değişiklikler eskimesin).
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { (_: Notification) in
                    Task { await model.refreshSetupProblems() }
                }
        }
    }

    /// Ana pencerenin içeriği (giriş kapısı açıkken).
    private var mainWindow: some View {
        MainWindowView(
            model: model, router: router, shortcuts: shortcuts, player: player, updater: updater, crashReports: crashReports,
            onStartRecording: { Task { await toggleRecordingFlow(model: model, panel: panel, island: island) } },
            onShowPanel: {
                panel.show(page: .live)
                island.show()
            }
        )
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
    // Giriş kapısı: kayıt başlamaz, ana pencere (giriş ekranı) açılır. Menü, kısayol, bildirim, takvimle otomatik
    // kayıt ve ⌘N hep bu yoldan geçer.
    guard !isSignInRequired() else {
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
        return
    }
    // Kayıt başlatılamıyorsa (deneme bitti, aylık sınır, eksik ayar) hata üretilmez: ana pencere açılır, neden başlat
    // düğmesinin yanında yazar. Çözümü abone olmaksa (deneme bitti, abonelik sona erdi) abone olma teklifi de açılır
    // (panelden basıldıysa ana pencere panelin arkasında kalıp hiçbir şey olmamış gibi görünmesin).
    if let notice = startBlockNotice(model: model) {
        #if HOSTED_EDITION
        if notice.action == .subscribe {
            HostedAccount.shared.requestSubscription()
        }
        #endif
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
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
    // Giriş kapısı kapalıyken panel açılmaz; giriş ekranı gösterilir.
    if !panel.isVisible, isSignInRequired() {
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
        return
    }
    if panel.isVisible {
        panel.hide()
        island.hide()
    } else {
        panel.show()
        island.show()
    }
}

/// Dosya menüsündeki ⌘N öğesinin adı (menü çubuğundaki menüyle aynı): boşta başlat, kayıtta bitir, bitirilirken
/// bekleme. Saf fonksiyondur.
func newItemTitle(phase: RecordingPhase) -> LocalizedStringKey {
    switch phase {
    case .idle: "Kaydı başlat"
    case .recording: "Kaydı bitir"
    case .finishing: "Bitiriliyor…"
    }
}

/// Giriş kapısı kapalı mı: abonelik sürümünde bu Mac'te oturum yoksa ana arayüz, kayıt, panel, kısayollar ve menü
/// eylemleri açılmaz (bkz. `HostedAccount.requiresSignIn`); geliştirici sürümünde kapı yoktur.
@MainActor
func isSignInRequired() -> Bool {
    #if HOSTED_EDITION
    HostedAccount.shared.requiresSignIn
    #else
    false
    #endif
}

/// Kullanıcı verisi okunabilir mi: abonelik sürümünde giriş yapan hesabın verisi bu süreçte yüklüyse (bkz.
/// `HostedAccount.dataState`); geliştirici sürümünde her zaman.
@MainActor
func isAccountDataReady() -> Bool {
    #if HOSTED_EDITION
    HostedAccount.shared.isAccountDataLoaded
    #else
    true
    #endif
}

#if HOSTED_EDITION
/// Başka bir hesapla giriş yapıldıysa ve kayıt ya da işleme yoksa uygulamayı yeniden başlatır: yeni süreç o hesabın
/// verisini yükler, bellekteki eski hesabın toplantıları hiç görünmez. Kayıt ya da işleme sürerken beklenir (giriş kapısı
/// nedenini söyler); bitince yeniden denenir. Başlatıcı çalıştırılamazsa neden kapıda görünür.
@MainActor
private func relaunchForAccountSwitchIfIdle(model: AppModel) {
    guard case .relaunchRequired = HostedAccount.shared.dataState, !model.isBusy else {
        return
    }
    appLogger.info("Başka bir hesapla giriş yapıldı, uygulama yeniden başlatılıyor")
    do {
        try relaunchApplication()
    } catch {
        appLogger.error("Hesap değişiminde uygulama yeniden başlatılamadı, hata: \(String(describing: error), privacy: .private)")
        HostedAccount.shared.reportRelaunchFailure(message: userFacingMessage(error: error))
    }
}
#endif

/// Menü çubuğu menüsü. Giriş kapısı kapalıyken yalnızca "Giriş yap…" ve "Çık" (kayıt sürüyorsa "Kaydı bitir").
private struct MenuContent: View {
    @Bindable var model: AppModel
    let panel: LivePanelController
    let island: IslandController
    let shortcuts: ShortcutController
    let router: MainWindowRouter
    let updater: AppUpdater
    @AppStorage(SettingsKey.hideFromScreenCapture) private var hideFromCapture: Bool = true

    var body: some View {
        if isSignInRequired() && !model.isRecording {
            Button("Giriş yap…", systemImage: "person.crop.circle") {
                NotificationCenter.default.post(name: .openMainWindow, object: nil)
            }
            Divider()
            Button("Çık", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } else {
            fullMenu
        }
    }

    /// Menüdeki kırmızı satırlar: kurulum eksikleri, boştayken başlatma engelinin nedeni (abonelikte deneme bitti, aylık
    /// sınır; kurulum eksiğiyse zaten listede) ve kısayol hataları.
    private var menuProblems: [String] {
        let blockReason: String? = model.phase == .idle ? startBlockNotice(model: model)?.reason : nil
        let block: [String] = blockReason.map { (reason: String) -> [String] in model.setupProblems.contains(reason) ? [] : [reason] } ?? []
        return model.setupProblems + block + [model.shortcutError, model.localDiarizationWarning].compactMap { $0 }
    }

    @ViewBuilder
    private var fullMenu: some View {
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
            // Başlatma engelinde de basılabilir: `toggleRecordingFlow` ana pencereyi (neden orada) ve gerekirse abone olma
            // teklifini açar; nedeni aşağıdaki kırmızı satırlarda da yazar.
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

        // Kayıt başlamadan görünmesi gereken sorunlar (kırmızı): eksik anahtar/ayar, başlatma engeli ve kısayol hataları.
        ForEach(Array(menuProblems.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
            Label(item.element, systemImage: "exclamationmark.circle")
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
        if updater.isEnabled {
            // Bulunan ya da indirilen güncelleme: kayıt ya da işleme sürerken yeniden başlatılmaz.
            if let update = updater.availableUpdate {
                Button(updateMenuTitle(update: update, isBusy: model.isBusy), systemImage: "arrow.down.circle.fill") {
                    updater.installUpdate()
                }
                .disabled(model.isBusy)
            }
            Button("Güncellemeleri denetle…", systemImage: "arrow.down.circle") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }

        if model.liveEngine == .appleSpeech, case .failed(let message) = model.modelStatus {
            Divider()
            Label(message, systemImage: "exclamationmark.triangle")
            Button("Konuşma modelini yeniden hazırla", systemImage: "arrow.clockwise") {
                Task { await model.prepareSpeechModel() }
            }
        }
        if model.liveEngine == .whisperKit {
            switch model.modelStatus {
            case .notLoaded:
                EmptyView()
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
                Label(message, systemImage: "exclamationmark.triangle")
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
