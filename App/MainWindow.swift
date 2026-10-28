import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Ana pencerenin sahne kimliği.
let mainWindowID: String = "main"

extension Notification.Name {
    /// Ana pencereyi açma isteği (menü, Dock simgesi, kısayol). Menü çubuğu simgesi her zaman çizildiği için onu dinler
    /// ve SwiftUI'nin `openWindow` eylemiyle pencereyi açar.
    static let openMainWindow: Notification.Name = Notification.Name("com.senoldogan.AINotepad.openMainWindow")
}

/// Ana pencerenin bölümleri (kenar çubuğu).
enum MainSection: Hashable {
    case home
    case meetings
    case ask
    case people
    case tasks
    case settings
    case setup
}

/// Ana pencerede açık bölüm ve seçili toplantı; menü ve Dock da buradan bölüm seçer.
@MainActor
@Observable
final class MainWindowRouter {
    var section: MainSection = .home
    var selectedMeetingID: String?
    /// Toplantılar listesini süzen arama (arama penceresinde ↩ ile uygulanır; üst çubukta görünür, × ile temizlenir).
    var searchQuery: String = ""
    /// Orta ekrandaki arama penceresi açık.
    var isSearchPresented: Bool = false
    /// Kayıt ekranı bu kayıt için kapatıldı ("Uygulamaya dön"); üst çubuktaki "Kayıtta" hapı yeniden açar. Her yeni
    /// kayıtta sıfırlanır.
    var isRecordingFocusDismissed: Bool = false
    /// Kayıt ya da işleme sürerken çıkış istendi: Ana sayfada satır içi soru gösterilir.
    var quitWarning: Bool = false
    /// Açılış ekranı bu açılışta gösterildi.
    var hasShownSplash: Bool = false
    /// Toplantılar listesini süzen klasör; nil hepsi.
    var folderFilter: String?
}

/// Çıkış koruması: kayıt ya da işleme sürerken uygulama hemen kapanmaz (toplantı "yarıda kaldı" olurdu); ana pencere
/// sorar. Uygulama açılışında bağlanır.
@MainActor
final class QuitGuard {
    static let shared: QuitGuard = QuitGuard()
    var isBusy: (@MainActor () -> Bool)?
    var onBlocked: (@MainActor () -> Void)?
    /// "Yine de çık" seçildi: bir sonraki çıkış sorulmaz.
    var allowQuit: Bool = false
}

/// `--bolum ana|toplantilar|ayarlar|kurulum` başlatma argümanından ana pencere bölümü (görsel kontrol ve geliştirme
/// için); yoksa nil. Saf fonksiyondur.
func launchSection(arguments: [String]) -> MainSection? {
    guard let index = arguments.firstIndex(of: "--bolum"), arguments.indices.contains(index + 1) else {
        return nil
    }
    switch arguments[index + 1] {
    case "ana": return .home
    case "toplantilar": return .meetings
    case "gorevler": return .tasks
    case "sor": return .ask
    case "kisiler": return .people
    case "ayarlar": return .settings
    case "kurulum": return .setup
    default: return nil
    }
}

/// Ana pencereyi verilen bölümde açar ve uygulamayı öne getirir.
@MainActor
func openMainWindow(router: MainWindowRouter, section: MainSection) {
    router.section = section
    NotificationCenter.default.post(name: .openMainWindow, object: nil)
}

/// Dock simgesine tıklanınca ana pencere açılır: ada penceresi hep açık olduğu için sistem "görünür pencere var" sayıp
/// kendiliğinden açmazdı.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Bildirimdeki "Dinlemeye başla" (ya da bildirime tıklama) kaydı başlatır; uygulama açılışında bağlanır.
    @MainActor static var onStartFromNotification: (@MainActor () -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.categoryIdentifier == MeetingNotificationID.category,
              response.actionIdentifier != UNNotificationDismissActionIdentifier else {
            return
        }
        await MainActor.run { AppDelegate.onStartFromNotification?() }
    }

    // Uygulama öndeyken de toplantı bildirimi görünsün.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let quitGuard: QuitGuard = .shared
        guard !quitGuard.allowQuit, let isBusy = quitGuard.isBusy, isBusy() else {
            return .terminateNow
        }
        quitGuard.onBlocked?()
        return .terminateCancel
    }
}

/// Menü çubuğu simgesi; ana pencereyi açma isteklerini dinler (simge uygulama boyunca çizili kalır).
struct MenuBarLabel: View {
    let symbol: String
    @Environment(\.openWindow) private var openWindow: OpenWindowAction

    var body: some View {
        Image(systemName: symbol)
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { (_: Notification) in
                openWindow(id: mainWindowID)
                NSApplication.shared.activate()
            }
    }
}

/// Uygulamanın ana penceresi (ElevenLabs düzeni): solda kendi kenar çubuğu (Ana sayfa, Toplantılar, Görevlerim,
/// Ayarlar, son toplantılar, durum), üstte sayfa adı + arama + "Canlı panel", altında bölüm içeriği. Kurulum yalnızca
/// ilk açılışta tam pencere. Kayıt sırasındaki panel ve ada ayrıca çalışır; pencere kapatılınca uygulama menü
/// çubuğunda sürer.
struct MainWindowView: View {
    let model: AppModel
    let router: MainWindowRouter
    let shortcuts: ShortcutController
    let player: MeetingAudioPlayer
    let updater: AppUpdater
    let crashReports: CrashReportCenter
    let onStartRecording: @MainActor () -> Void
    let onShowPanel: @MainActor () -> Void

    var body: some View {
        let isRecordingFocusVisible: Bool = model.phase == .recording && !router.isRecordingFocusDismissed && router.section != .setup
        // Arama penceresi ya da kayıt ekranı açıkken içerik bulanıklaşır (koyu perde yok, açık buzlu cam; toplantı
        // hazırlanırken çıkan kart gibi) ve tıklamaları almaz.
        let isContentCovered: Bool = router.isSearchPresented || isRecordingFocusVisible
        ZStack {
            // İlk açılışta bir kez: tam pencere, kenar çubuğu yok, içerik ortada.
            if router.section == .setup {
                SetupScreen(model: model, router: router, shortcuts: shortcuts)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                HStack(spacing: 0) {
                    Sidebar(model: model, router: router)
                    VStack(spacing: 0) {
                        TopBar(model: model, router: router, onShowPanel: onShowPanel)
                        // Ana penceredeki eylemlerin hataları (not düzenleme, tarif, ses silme…) burada görünür; önceden
                        // yalnızca canlı panelde çıkıyordu.
                        if !model.errorMessages.isEmpty {
                            ErrorBanner(messages: model.errorMessages) { model.dismissErrors() }
                        }
                        // Önceki açılışta çöktüyse bir kez sorulur (rapor yalnızca bu Mac'te; gönderen kullanıcı).
                        if let report = crashReports.reportToAnnounce {
                            CrashReportBanner(center: crashReports, report: report)
                        }
                        detail
                            .id(router.section)
                            .transition(.opacity)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // Çalan toplantı her bölümde altta görünür; sayfa değişince ses durmaz.
                    .safeAreaInset(edge: .bottom) {
                        PlayerDock(model: model, player: player) { (id: String) -> Void in
                            router.selectedMeetingID = id
                            router.section = .meetings
                        }
                        .frame(maxWidth: 720)
                    }
                    .animation(.smooth(duration: 0.25), value: router.section)
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: router.section == .setup)
        .blur(radius: isContentCovered ? 10 : 0)
        .allowsHitTesting(!isContentCovered)
        .animation(.easeInOut(duration: 0.25), value: isContentCovered)
        // Açılış ekranı: uygulama her açıldığında bir kez (pencere kapatılıp açılınca tekrarlanmaz).
        .overlay {
            // Animasyonsuz kaldırılır: sönmeyi açılış ekranı kendisi yapar (bkz. `LaunchSplash.play`).
            if !router.hasShownSplash {
                LaunchSplash {
                    var transaction: Transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { router.hasShownSplash = true }
                }
            }
        }
        .overlay {
            if isRecordingFocusVisible {
                RecordingFocus(model: model, router: router, onShowPanel: onShowPanel)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isRecordingFocusVisible)
        .onChange(of: model.phase) { (old: RecordingPhase, new: RecordingPhase) -> Void in
            if old == .idle, new == .recording {
                router.isRecordingFocusDismissed = false
            }
        }
        .overlay {
            if router.isSearchPresented {
                SearchComposer(model: model, router: router)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: router.isSearchPresented)
        .foregroundStyle(Theme.ink)
        // Toplantı hazırlanırken ana pencerede de aynı ilerleme kartı (panelle eş zamanlı).
        .modifier(ProcessingOverlayHost(model: model))
        .frame(minWidth: 860, minHeight: 580)
        // Cam tek katman: pencere zemini (ikinci bir arka plan opaklığı iki kat gösteriyordu).
        .containerBackground(for: .window) { WindowBackdrop() }
        // Başlık çubuğu gizli: içerik pencerenin tepesine kadar sürer (trafik ışıkları kenar çubuğunun üstünde).
        .ignoresSafeArea(.container, edges: .top)
        .modifier(AppearanceEnvironment())
    }

    @ViewBuilder
    private var detail: some View {
        switch router.section {
        case .home:
            HomePage(model: model, router: router, shortcuts: shortcuts, onStartRecording: onStartRecording, onShowPanel: onShowPanel)
        case .meetings:
            MeetingsSplit(model: model, router: router, player: player)
        case .ask:
            AskPage(model: model, router: router)
        case .people:
            PeoplePage(model: model, router: router)
        case .tasks:
            TasksPage(model: model, router: router)
        case .settings:
            // Geniş pencerede form satırları ekran boyu uzamasın.
            // Genişlik sınırı sayfanın içinde: kaydırma çubuğu pencerenin sağ kenarında kalır.
            SettingsPage(model: model, shortcuts: shortcuts, updater: updater, crashReports: crashReports) { router.section = .setup }
                .scrollContentBackground(.hidden)
        case .setup:
            // Kurulum kenar çubuğu olmadan gösterilir (bkz. `body`); buraya gelinmez.
            EmptyView()
        }
    }
}

/// Kenar çubuğu (ElevenLabs): sade simgeli satırlar, seçili satır gri hap, "Son toplantılar" grubu.
private struct Sidebar: View {
    let model: AppModel
    let router: MainWindowRouter

    var body: some View {
        // Yalnızca açık (tamamlanmamış) görevler sayılır.
        let myTaskCount: Int = myTasks(meetings: model.meetings).filter { !isTaskDone(record: $0.record, task: $0.task) }.count
        VStack(alignment: .leading, spacing: 2) {
            // Trafik ışıklarına yer.
            Color.clear.frame(height: 40)
            item(title: "Ana sayfa", symbol: "house", section: .home, badge: nil)
            item(title: "Toplantılar", symbol: "list.bullet.rectangle", section: .meetings, badge: nil)
            item(title: "Sor", symbol: "sparkle.magnifyingglass", section: .ask, badge: nil)
            item(title: "Görevlerim", symbol: "checkmark.circle", section: .tasks, badge: myTaskCount > 0 ? myTaskCount : nil)
            item(title: "Kişiler", symbol: "person.2", section: .people, badge: nil)
            // Klasörler ve son toplantılar kayar: alçak pencerede ya da büyük arayüz ölçeğinde Ayarlar alttan taşmasın.
            ScrollView {
            VStack(alignment: .leading, spacing: 2) {
            SidebarFolders(model: model, router: router)
            if !model.meetings.isEmpty {
                Text("Son toplantılar")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 10)
                    .padding(.top, 18)
                    .padding(.bottom, 4)
                ForEach(model.meetings.prefix(4)) { (record: MeetingRecord) in
                    Button {
                        router.selectedMeetingID = record.id
                        router.section = .meetings
                    } label: {
                        Text(record.note?.title ?? record.title)
                            .appFont(size: 13, weight: .regular)
                            .lineLimit(1)
                            .foregroundStyle(Theme.ink.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.hoverPlain)
                }
            }
            }
            }
            .scrollIndicators(.never)
            // Ayarlar en altta, sol köşede (uygulamaların alışılmış yeri).
            Spacer(minLength: 12)
            item(title: "Ayarlar", symbol: "gearshape", section: .settings, badge: nil)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .pageBackground()
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func item(title: LocalizedStringKey, symbol: String, section: MainSection, badge: Int?) -> some View {
        // Klasör süzgeci açıkken "Toplantılar" değil klasör seçili görünür.
        let isSelected: Bool = router.section == section && !(section == .meetings && router.folderFilter != nil)
        return Button {
            if section == .meetings {
                router.folderFilter = nil
            }
            router.section = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .appFont(size: 14, weight: .regular)
                    .frame(width: 18)
                    .symbolEffect(.bounce, value: isSelected)
                Text(title).appFont(size: 14, weight: isSelected ? .medium : .regular)
                Spacer(minLength: 0)
                if let badge {
                    Text("\(badge)")
                        .appFont(size: 11, weight: .medium)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.soft, in: Capsule())
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.hoverPlain)
    }
}

/// Üst çubuk: sayfa adı, arama hapı (tıklayınca ya da ⌘K / ⌘F ile orta ekranda arama penceresi açılır; yazı alanı
/// değildir, imleç yanıp sönmez), "Canlı panel". Listeye uygulanmış arama hapta görünür, × ile temizlenir.
/// Ana penceredeki kenar çubuğunun genişliği (arama penceresi içerik alanına göre ortalanır).
private let sidebarWidth: CGFloat = 228

private struct TopBar: View {
    let model: AppModel
    let router: MainWindowRouter
    let onShowPanel: @MainActor () -> Void

    @AppStorage(SettingsKey.meetingsListVisible) private var meetingsListVisible: Bool = true
    @AppStorage(SettingsKey.peopleListVisible) private var peopleListVisible: Bool = false
    @AppStorage(SettingsKey.askHistoryVisible) private var askHistoryVisible: Bool = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            // Sayfanın sol listesini gizle/göster: her bölümde aynı yerde, başlığın solunda.
            switch router.section {
            case .meetings where router.selectedMeetingID != nil:
                // Toplantı seçili değilken liste hep görünür (seçecek bir şey kalmasın).
                listToggle(isVisible: $meetingsListVisible, show: "Toplantı listesini göster", hide: "Toplantı listesini gizle")
            case .people:
                listToggle(isVisible: $peopleListVisible, show: "Kişi listesini göster", hide: "Kişi listesini gizle")
            case .ask where !model.askConversations.isEmpty:
                listToggle(isVisible: $askHistoryVisible, show: "Sohbet geçmişini göster", hide: "Sohbet geçmişini gizle")
            default:
                EmptyView()
            }
            // En dar pencerede başlık tek satırda kalır, arama hapı daralır; çubuk taşmaz.
            Text(title)
                .appFont(size: 14, weight: .medium)
                .lineLimit(1)
                .layoutPriority(1)
            // Kayıt ekranı kapatıldıysa "Kayıtta" hapı onu yeniden açar.
            if model.phase == .recording, router.isRecordingFocusDismissed {
                Button {
                    router.isRecordingFocusDismissed = false
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text("Kayıtta").appFont(size: 12, weight: .medium)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.hoverCapsule)
                .hoverHint("Kayıt ekranını aç", alignment: .leading, edge: .bottom)
            }
            Spacer(minLength: DesignTokens.Spacing.m)
            HStack(spacing: 8) {
                Button {
                    router.isSearchPresented = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                        if router.searchQuery.isEmpty {
                            Text("Toplantılarda ara…").foregroundStyle(Theme.muted)
                        } else {
                            Text(verbatim: router.searchQuery).foregroundStyle(Theme.ink).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if router.searchQuery.isEmpty {
                    Text("⌘K")
                        .appFont(size: 11, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 5)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                } else {
                    Button {
                        router.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Aramayı temizle")
                }
            }
            .appFont(size: 13, weight: .regular)
            .padding(.horizontal, 10)
            .frame(minWidth: 180, idealWidth: 320, maxWidth: 320)
            .frame(height: 32)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            .linkPointer(isEnabled: true)
            .background {
                // ⌘K ve ⌘F arama penceresini açar.
                Button { router.isSearchPresented = true } label: { Text(verbatim: "") }
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
                Button { router.isSearchPresented = true } label: { Text(verbatim: "") }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: DesignTokens.Spacing.m)
            Button("Canlı panel", systemImage: "rectangle.on.rectangle") { onShowPanel() }
                .buttonStyle(.pill)
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// Sol listeyi gizleyen/gösteren düğme (Toplantılar, Kişiler, Sor'da aynı).
    private func listToggle(isVisible: Binding<Bool>, show: LocalizedStringKey, hide: LocalizedStringKey) -> some View {
        Button {
            isVisible.wrappedValue.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .appFont(size: 14, weight: .medium)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.hoverPlain)
        .accessibilityLabel(isVisible.wrappedValue ? hide : show)
        .hoverHint(isVisible.wrappedValue ? hide : show, alignment: .leading, edge: .bottom)
    }

    private var title: LocalizedStringKey {
        switch router.section {
        case .home: "Ana sayfa"
        case .meetings: "Toplantılar"
        case .ask: "Toplantılarıma sor"
        case .people: "Kişiler"
        case .tasks: "Görevlerim"
        case .settings: "Ayarlar"
        case .setup: "Kurulum"
        }
    }
}

private struct SetupScreen: View {
    let model: AppModel
    let router: MainWindowRouter
    let shortcuts: ShortcutController

    var body: some View {
        // Tüm pencere: solda adımın film gradyanlı paneli, sağda içeriği (bkz. `SetupPage`).
        SetupPage(model: model, shortcuts: shortcuts) {
            // Kurulum ancak bitince tamamlanmış sayılır: yarıda kapatılırsa bir sonraki açılışta yeniden gelir.
            UserDefaults.standard.set(true, forKey: SettingsKey.onboardingCompleted)
            router.section = .home
        }
            .padding(.top, 28)
            .background { FlowingLines(seed: "kurulum", lineCount: 14, isAnimated: false).ignoresSafeArea() }
    }
}

private struct QuitWarning: View {
    let model: AppModel
    let router: MainWindowRouter

    var body: some View {
        let isBusy: Bool = model.isBusy
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            Label(
                model.phase == .idle
                    ? "Toplantı işleniyor. Şimdi çıkarsan not hazırlanmaz; açılınca \"Tekrar işle\" gerekir."
                    : "Kayıt sürüyor. Şimdi çıkarsan toplantı yarıda kalır.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .appFont(size: 13, weight: .semibold)
            .foregroundStyle(.orange)
            HStack(spacing: DesignTokens.Spacing.s) {
                if model.phase == .recording {
                    Button("Kaydı bitir", systemImage: "stop.fill") {
                        model.stopRecording()
                        router.quitWarning = false
                    }
                    .buttonStyle(.pillPrimary)
                }
                Button("Yine de çık", role: .destructive) {
                    QuitGuard.shared.allowQuit = true
                    NSApplication.shared.terminate(nil)
                }
                Button("Vazgeç") { router.quitWarning = false }
            }
        }
        .padding(DesignTokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.orange.opacity(0.30)))
        .onChange(of: isBusy) { (_: Bool, busy: Bool) in
            if !busy {
                router.quitWarning = false
            }
        }
    }
}


/// Ana sayfa (ElevenLabs düzeni): ortada büyük ince başlık ve kayıt çubuğu, araç kutucukları, banner karuseli,
/// sana düşen görevler ve gradyan kapaklı son toplantılar.
private struct HomePage: View {
    let model: AppModel
    let router: MainWindowRouter
    let shortcuts: ShortcutController
    let onStartRecording: @MainActor () -> Void
    let onShowPanel: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                if router.quitWarning {
                    QuitWarning(model: model, router: router)
                }
                VStack(alignment: .leading, spacing: 18) {
                    heading
                    RecordBar(model: model, onStartRecording: onStartRecording, onShowPanel: onShowPanel)
                }
                .padding(.top, 24)
                Shortcuts(model: model, router: router, onShowPanel: onShowPanel)
                if !model.setupProblems.isEmpty {
                    problems
                }
                UpcomingMeetings(model: model, onStartRecording: onStartRecording) { (meeting: CalendarMeeting) -> Void in
                    // Brifing yeni bir konu: önceki sohbet bağlam olmasın.
                    model.clearArchiveConversation()
                    model.askArchive(question: briefingQuestion(meeting: meeting), meetingIDs: [], recipeTitle: nil)
                    router.section = .ask
                } onOpenMeeting: { (id: String) -> Void in
                    router.selectedMeetingID = id
                    router.section = .meetings
                }
                HomeTasks(model: model, router: router)
                RecentMeetingCards(model: model, router: router)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
            .animation(.smooth(duration: 0.3), value: router.quitWarning)
            .animation(.smooth(duration: 0.3), value: model.phase)
            .animation(.smooth(duration: 0.3), value: model.setupProblems)
        }
    }

    @ViewBuilder
    private var heading: some View {
        switch model.phase {
        case .recording:
            HStack(spacing: 12) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    // Kayıt ekranı açıkken bulanıklığın altında boşuna titreşmesin.
                    .symbolEffect(.pulse, isActive: !model.isPaused && router.isRecordingFocusDismissed)
                if let startedAt = model.recordingStartedAt {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
                Text(model.isPaused ? "· duraklatıldı" : "· dinleniyor")
                    .foregroundStyle(Theme.muted)
            }
            .appFont(size: 34, weight: .regular)
            // Kayıt sürerken sayfanın odağı bu satır: ortada durur.
            .frame(maxWidth: .infinity, alignment: .center)
        case .finishing:
            Text("Bitiriliyor…")
                .appFont(size: 34, weight: .regular)
        case .idle:
            VStack(alignment: .leading, spacing: 4) {
                Text(Date.now.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(interfaceLocale())))
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                Text(verbatim: homeGreeting(name: UserDefaults.standard.string(forKey: SettingsKey.userName) ?? "", hour: Calendar.current.component(.hour, from: .now)))
                    .appFont(size: 30, weight: .semibold)
                    .tracking(-0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var problems: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Kayıttan önce tamamlanmalı", systemImage: "exclamationmark.triangle.fill")
                .appFont(size: 13, weight: .semibold)
                .foregroundStyle(.orange)
            ForEach(model.setupProblems, id: \.self) { (problem: String) in
                Text(problem).foregroundStyle(Theme.muted)
            }
            Button("Ayarları aç") { router.section = .settings }
                .buttonStyle(.pill)
                .controlSize(.small)
        }
        .padding(DesignTokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.orange.opacity(0.28)))
    }
}

/// Kayıt çubuğu (ElevenLabs'in "oluştur" çubuğu gibi): küre, açıklama, seçenek çipleri ve siyah "Başlat"; kayıtta
/// "Paneli göster" ve "Bitir".
private struct RecordBar: View {
    @Bindable var model: AppModel
    let onStartRecording: @MainActor () -> Void
    let onShowPanel: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        if model.phase == .idle {
            hero
        } else {
            bar.frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
    }

    /// Boşta: gradyan kayıt kartı (ElevenLabs'in büyük oluştur kartı gibi): ortada küre ve "Dinlemeye başla", altında
    /// seçenekler. Gradyan açık tonlu olduğundan kart her temada açık görünümle çizilir.
    private var hero: some View {
        VStack(spacing: 16) {
            orb(size: 64)
                .padding(5)
                .background(Color.white.opacity(0.4), in: Circle())
                .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
            Button(action: onStartRecording) {
                Label("Dinlemeye başla", systemImage: "record.circle")
            }
            .buttonStyle(.bannerPrimary)
            .disabled(!model.isReadyToRecord || model.isStarting)
            options
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 240)
        .background {
            FilmGradient(seed: "kayit-karti", palette: .sunset)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .environment(\.colorScheme, .light)
    }

    private func orb(size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [appearance.accent.color.mix(with: .white, by: 0.45), appearance.accent.color, appearance.accent.color.mix(with: .black, by: 0.55)],
                center: UnitPoint(x: 0.35, y: 0.35), startRadius: 1, endRadius: size * 0.65
            ))
            .frame(width: size, height: size)
            .tilt3D(maxAngle: 8)
    }

    /// Seçenekler ortalı ve gerekirse alt satıra geçer: dar pencerede, İngilizcede ya da büyük arayüz boyutunda kartın
    /// dışına taşıp kesilmez.
    private var options: some View {
        VStack {
            if model.phase == .idle {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    languageChip
                    chip(title: "Yüz yüze", isOn: model.isInPerson) { model.toggleInPerson() }
                        .hoverHint("Aynı odadaki toplantı: mikrofondaki herkes konuşmacılara ayrılır", alignment: .center, edge: .bottom)
                    if !model.isInPerson {
                        chip(title: model.isMicMuted ? "Yalnız karşı taraf" : "Benim sesim de", isOn: !model.isMicMuted) {
                            model.toggleMicrophone()
                        }
                    }
                    chip(title: "Canlı çeviri", isOn: model.displayMode.needsLiveTranslation) {
                        model.selectDisplayMode(mode: model.displayMode.needsLiveTranslation ? .originalOnly : .bilingual)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 620)
    }

    private var bar: some View {
        HStack(spacing: 10) {
            orb(size: 34)
            switch model.phase {
            case .idle:
                Text("Toplantını dinlemeye başla")
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button("Başlat", systemImage: "record.circle", action: onStartRecording)
                    .buttonStyle(.pillPrimary)
                    .disabled(!model.isReadyToRecord || model.isStarting)
                    .fixedSize()
            case .recording:
                Text(model.isPaused ? "Kayıt duraklatıldı" : "Kayıt sürüyor — konuşmalar canlı panelde")
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button("Paneli göster", systemImage: "rectangle.on.rectangle") { onShowPanel() }
                    .buttonStyle(.pill)
                    .fixedSize()
                Button("Bitir", systemImage: "stop.fill") { model.stopRecording() }
                    .buttonStyle(.pillPrimary)
                    .fixedSize()
            case .finishing:
                Text("Kalan metin ve konuşmacılar tamamlanıyor.")
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 6)
                ProgressView().controlSize(.small)
            }
        }
        .appFont(size: 14, weight: .regular)
        .controlSize(.small)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
    }

    private var languageChip: some View {
        Menu {
            Button("Otomatik") { model.languageMode = .automatic }
            LanguageMenuItems { (language: MeetingLanguage) -> Void in model.languageMode = .fixed(language) }
        } label: {
            // Kart her temada açık pastel: yazı temanın mürekkebini değil siyahı alır (koyu temada beyaz kalıp kayboluyordu).
            languageTitle
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(Color.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .menuStyle(.button)
        .buttonStyle(HeroChipButtonStyle(fillOpacity: 0.9))
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var languageTitle: Text {
        switch model.languageMode {
        case .automatic: Text("Otomatik dil")
        case .fixed(let language): Text(verbatim: meetingLanguageName(language: language))
        }
    }

    private func chip(title: LocalizedStringKey, isOn: Bool, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark" : "minus")
                    .appFont(size: 10, weight: .semibold)
                    .contentTransition(.symbolEffect(.replace))
                Text(title).appFont(size: 12, weight: .medium)
            }
            .foregroundStyle(isOn ? Color.black : Color.black.opacity(0.62))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(HeroChipButtonStyle(fillOpacity: isOn ? 0.9 : 0.45))
        .fixedSize()
    }
}

/// Kayıt kartındaki seçenek hapı: pastel zeminde beyaz kapsül. Fare üstündeyken beyaz dolgu parlar (temanın koyu
/// hover tonu pastel kartta kirli bir hale çiziyordu), basılınca hafifçe küçülür; el imleci gösterir.
private struct HeroChipButtonStyle: ButtonStyle {
    let fillOpacity: Double

    func makeBody(configuration: Configuration) -> some View {
        HeroChipBody(configuration: configuration, fillOpacity: fillOpacity)
    }
}

private struct HeroChipBody: View {
    let configuration: ButtonStyleConfiguration
    let fillOpacity: Double
    @Environment(\.isEnabled) private var isEnabled: Bool
    @State private var isHovering: Bool = false

    var body: some View {
        configuration.label
            .background(Color.white.opacity(isEnabled && isHovering ? min(fillOpacity + 0.25, 1) : fillOpacity), in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { (hovering: Bool) -> Void in isHovering = hovering }
            .linkPointer(isEnabled: isEnabled)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Kısayollar: dört sade, yatay kart: solda küçük gradyan kutuda simge, yanında ad ve kısa bilgi. Kayıt büyük kartta,
/// Ayarlar kenar çubuğunda olduğu için burada yok.
private struct Shortcuts: View {
    let model: AppModel
    let router: MainWindowRouter
    let onShowPanel: @MainActor () -> Void

    var body: some View {
        let openTasks: Int = myTasks(meetings: model.meetings).filter { !isTaskDone(record: $0.record, task: $0.task) }.count
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            Text("Kısayollar").appFont(size: 15, weight: .medium)
            // Dört kart satırı doldurur; dar pencerede ikişerli iki satıra iner.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { cards(openTasks: openTasks) }
                    .frame(minWidth: 720)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)], spacing: 12) {
                    cards(openTasks: openTasks)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cards(openTasks: Int) -> some View {
        Group {
            card(title: "Canlı panel", detail: String(localized: "Kayıt sırasında yazı"), symbol: "rectangle.on.rectangle", palette: .ocean) { onShowPanel() }
            card(title: "İçe aktar", detail: String(localized: "Ses ya da video"), symbol: "square.and.arrow.down", palette: .mint) {
                router.section = .meetings
                chooseMediaToImport(model: model)
            }
            card(title: "Toplantılarına sor", detail: String(localized: "\(model.meetings.count) toplantı"), symbol: "sparkle.magnifyingglass", palette: .violet) {
                router.section = .ask
            }
            card(title: "Görevlerim", detail: String(localized: "\(openTasks) açık"), symbol: "checkmark.circle", palette: .coral) {
                router.section = .tasks
            }
        }
    }

    private func card(title: LocalizedStringKey, detail: String, symbol: String, palette: FilmPalette, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Color.black.opacity(0.78))
                    .frame(width: 34, height: 34)
                    .background { FilmGradient(seed: "kisayol-\(symbol)", palette: palette) }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .appFont(size: 13, weight: .medium)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(verbatim: detail)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { ShortcutCardBackground() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
    }
}

/// Son toplantılarda sana düşen görevler (en yeni toplantıdan başlayarak).
private struct HomeTasks: View {
    let model: AppModel
    let router: MainWindowRouter
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let items: [(record: MeetingRecord, task: NoteTask)] = myTasks(meetings: Array(model.meetings.prefix(10)))
            .filter { !isTaskDone(record: $0.record, task: $0.task) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                HStack {
                    Text("Sana düşen görevler").appFont(size: 15, weight: .medium)
                    Spacer(minLength: 0)
                    Button("Tümü ›") { router.section = .tasks }
                        .buttonStyle(.hoverPlain)
                        .foregroundStyle(Theme.muted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.prefix(5).enumerated()), id: \.offset) { (item: (offset: Int, element: (record: MeetingRecord, task: NoteTask))) in
                        TaskLine(model: model, record: item.element.record, task: item.element.task) {
                            router.selectedMeetingID = item.element.record.id
                            router.section = .meetings
                        }
                    }
                }
                .padding(8)
                .cardSurface(cornerRadius: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Yaklaşan toplantılar (takvim açıksa, önümüzdeki 12 saat): saat, başlık, katılımcılar; bağlantısı varsa "Katıl",
/// başlamak üzereyse (10 dk) ya da sürüyorsa "Dinle".
private struct UpcomingMeetings: View {
    let model: AppModel
    let onStartRecording: @MainActor () -> Void
    /// Toplantı öncesi brifing (arşive sorulur, Sor sayfasında açılır).
    let onBriefing: @MainActor (CalendarMeeting) -> Void
    /// Bugün biten etkinliğin kaydını açar.
    let onOpenMeeting: @MainActor (String) -> Void

    var body: some View {
        let now: Date = Date()
        let items: [CalendarMeeting] = model.upcomingMeetings.filter { $0.end > now && $0.start.timeIntervalSince(now) < 12 * 3600 }
        // Bugün biten etkinlikler: kaydı olanın notu takvimden açılır (en yeni önce).
        let earlier: [CalendarMeeting] = model.upcomingMeetings
            .filter { $0.end <= now && Calendar.current.isDate($0.start, inSameDayAs: now) }
            .sorted { $0.start > $1.start }
        if let error = model.calendarError {
            EmptyStateCard(symbol: "calendar.badge.exclamationmark", title: "Takvim okunamadı", message: "\(error)")
        } else if !items.isEmpty || !earlier.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                if !items.isEmpty {
                    group(title: "Yaklaşan toplantılar", meetings: Array(items.prefix(4))) { (meeting: CalendarMeeting) in
                        row(meeting: meeting, now: now)
                    }
                }
                if !earlier.isEmpty {
                    group(title: "Bugün biten toplantılar", meetings: Array(earlier.prefix(4))) { (meeting: CalendarMeeting) in
                        pastRow(meeting: meeting)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func group(title: LocalizedStringKey, meetings: [CalendarMeeting], @ViewBuilder row: @escaping (CalendarMeeting) -> some View) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text(title).appFont(size: 15, weight: .medium)
            VStack(spacing: 0) {
                ForEach(Array(meetings.enumerated()), id: \.element.id) { (item: (offset: Int, element: CalendarMeeting)) in
                    if item.offset > 0 {
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                    row(item.element)
                }
            }
            .padding(.horizontal, 14)
            .cardSurface(cornerRadius: 16)
        }
    }

    /// Biten etkinlik: kaydı varsa notun durumu ve "Notu aç", yoksa "Kaydedilmedi".
    private func pastRow(meeting: CalendarMeeting) -> some View {
        let time: String = meeting.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale()))
            + "–" + meeting.end.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale()))
        let record: MeetingRecord? = recordedMeeting(meeting: meeting, records: model.meetings)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(time).appFont(size: 12, weight: .medium).monospacedDigit().foregroundStyle(Theme.muted)
                Text(meeting.title).appFont(size: 14, weight: .medium).lineLimit(1)
                if let summary = record?.note?.summary {
                    Text(summary)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let record {
                Button(record.note == nil ? LocalizedStringKey("Kaydı aç") : LocalizedStringKey("Notu aç"), systemImage: "doc.text") { onOpenMeeting(record.id) }
                    .controlSize(.small)
            } else {
                Text("Kaydedilmedi").appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 10)
    }

    private func row(meeting: CalendarMeeting, now: Date) -> some View {
        let isSoon: Bool = meeting.start.timeIntervalSince(now) <= 600
        let time: String = meeting.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale()))
            + "–" + meeting.end.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale()))
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(time).appFont(size: 12, weight: .medium).monospacedDigit().foregroundStyle(isSoon ? Color.orange : Theme.muted)
                Text(meeting.title).appFont(size: 14, weight: .medium).lineLimit(1)
                if !meeting.attendees.isEmpty {
                    Text(meeting.attendees.prefix(4).joined(separator: ", ") + (meeting.attendees.count > 4 ? " +\(meeting.attendees.count - 4)" : ""))
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !model.meetings.isEmpty {
                Button("Brifing", systemImage: "text.magnifyingglass") { onBriefing(meeting) }
                    .controlSize(.small)
                    .hoverHint("Bu kişilerle ve konuda önceki toplantılar, kararlar, açık görevler", alignment: .trailing, edge: .bottom)
            }
            if let url = meeting.joinURL {
                Button("Katıl", systemImage: "video") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
                    .hoverHint("Görüşme bağlantısını aç: \(url.host() ?? "")", alignment: .trailing, edge: .bottom)
            }
            if isSoon, !model.isRecording {
                Button("Dinle", systemImage: "record.circle") { onStartRecording() }
                    .buttonStyle(.pillPrimary)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 10)
    }
}

/// Görev satırı: tamamlandı kutusu, iş, tarih ve toplantı adı (tıklayınca toplantı açılır), Anımsatıcılar'a ekleme.
private struct TaskLine: View {
    let model: AppModel
    let record: MeetingRecord
    let task: NoteTask
    let onOpen: @MainActor () -> Void

    var body: some View {
        let isDone: Bool = isTaskDone(record: record, task: task)
        HStack(alignment: .center, spacing: 8) {
            TaskCheckbox(isDone: isDone) { model.toggleTask(meetingID: record.id, task: task) }
                .disabled(model.isLocked(meetingID: record.id))
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.description)
                            .appFont(size: 14, weight: .regular)
                            .strikethrough(isDone, color: Theme.muted)
                            .foregroundStyle(isDone ? Theme.muted : Theme.ink)
                        Text(([task.dueDate].compactMap { $0 } + [record.note?.title ?? record.title]).joined(separator: " · "))
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            ReminderButton(model: model, record: record, task: task)
        }
        .padding(.horizontal, 8)
        .animation(.smooth(duration: 0.2), value: isDone)
    }
}

/// Son toplantılar: gradyan kapaklı kartlar (renk toplantıya göre sabit), başlık ve bilgi kapağın üstünde.
private struct RecentMeetingCards: View {
    let model: AppModel
    let router: MainWindowRouter

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            HStack {
                Text("Son toplantılar").appFont(size: 15, weight: .medium)
                Spacer(minLength: 0)
                if !model.meetings.isEmpty {
                    Button("Tümünü gör ›") { router.section = .meetings }
                        .buttonStyle(.hoverPlain)
                        .foregroundStyle(Theme.muted)
                }
            }
            if model.meetings.isEmpty {
                EmptyStateCard(symbol: "waveform", title: "Henüz toplantı yok", message: "Kaydı başlatınca toplantıların ve notların burada görünür.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(model.meetings.prefix(6)) { (record: MeetingRecord) in
                        Button {
                            router.selectedMeetingID = record.id
                            router.section = .meetings
                        } label: {
                            MeetingCover(record: record, isProcessing: model.processingMeetingIDs.contains(record.id))
                        }
                        .buttonStyle(.hoverPlain)
                    }
                }
            }
        }
    }
}

/// Toplantı kartı: toplantıya göre sabit renkli gradyan kapak; başlık, tarih ve görev sayısı kapağın altında.
private struct MeetingCover: View {
    let record: MeetingRecord
    let isProcessing: Bool

    var body: some View {
        let mine: Int = record.note?.tasks.filter(\.isMine).count ?? 0
        VStack(alignment: .leading, spacing: 0) {
            CoverImage(seed: record.id)
                // Ortada toplantıya özgü ses dalgası, kapağın kendi renginin koyu tonunda.
                .overlay { CoverWaveform(seed: record.id) }
                .frame(height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .tilt3D(maxAngle: 4)
            Text(record.note?.title ?? record.title)
                .appFont(size: 14, weight: .medium)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.top, 10)
            Text(coverSubtitle(mine: mine))
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(record.status == .failed ? Color.red : Theme.muted)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func coverSubtitle(mine: Int) -> String {
        let date: String = record.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))
        if isProcessing || record.status == .processing {
            return date + " · " + String(localized: "İşleniyor")
        }
        if record.status == .failed {
            return date + " · " + String(localized: "Hata")
        }
        return mine > 0 ? date + " · " + String(localized: "\(mine) görev") : date
    }
}

/// Görevlerim: tüm toplantılardan sana düşen işler, toplantıya göre gruplu; başlığa tıklayınca toplantı açılır.
private struct TasksPage: View {
    let model: AppModel
    let router: MainWindowRouter
    @State private var showsDone: Bool = false
    /// Not ve çeviri dili (Ayarlar › Genel): boş durumda notun dili adıyla geçer.
    @AppStorage(SettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue

    var body: some View {
        let all: [(record: MeetingRecord, task: NoteTask)] = myTasks(meetings: model.meetings)
        let doneCount: Int = all.filter { isTaskDone(record: $0.record, task: $0.task) }.count
        let groups: [(record: MeetingRecord, tasks: [NoteTask])] = model.meetings.compactMap { (record: MeetingRecord) -> (record: MeetingRecord, tasks: [NoteTask])? in
            let mine: [NoteTask] = (record.note?.tasks ?? []).filter { $0.isMine && isTaskDone(record: record, task: $0) == showsDone }
            return mine.isEmpty ? nil : (record: record, tasks: mine)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sana düşen görevler")
                        .appFont(size: 28, weight: .regular)
                        .tracking(-0.4)
                    Spacer(minLength: 0)
                    PillPicker(selection: $showsDone, options: [
                        (false, "Açık · \(all.count - doneCount)"), (true, "Tamamlanan · \(doneCount)"),
                    ])
                    .fixedSize()
                }
                if groups.isEmpty {
                    if showsDone {
                        EmptyStateHero(
                            symbol: "checkmark.circle", title: "Tamamlanan görev yok",
                            message: "Bir görevin dairesine tıklayınca buraya taşınır; bitirdiklerin burada birikir.", palette: .sunset, steps: []
                        ) {
                            EmptyView()
                        }
                    } else if doneCount > 0 {
                        EmptyStateHero(
                            symbol: "party.popper.fill", title: "Açık görevin kalmadı",
                            message: "Hepsi tamamlandı. Yeni toplantılarda sana düşen işler buraya gelir.", palette: .sunset, steps: []
                        ) {
                            EmptyView()
                        }
                        .overlay { ConfettiBurst(palette: .sunset) }
                    } else {
                        EmptyStateHero(
                            symbol: "checklist", title: "Henüz sana düşen görev yok",
                            message: "Toplantı bitince not yazılır; içinde senin adına yazılan işler burada toplanır, tamamlayınca işaretlersin.",
                            palette: .sunset,
                            steps: [
                                EmptyStateStep(symbol: "record.circle", title: "Toplantıyı kaydet"),
                                EmptyStateStep(symbol: "sparkles", title: "\(storedNoteLanguage(value: noteLanguage).interfaceName) not yazılır"),
                                EmptyStateStep(symbol: "checkmark.circle", title: "Görevlerin burada"),
                            ]
                        ) {
                            if (UserDefaults.standard.string(forKey: SettingsKey.userName) ?? "").isEmpty {
                                Button("Adını yaz (görevlerin tanınsın)", systemImage: "person.text.rectangle") { router.section = .settings }
                                    .buttonStyle(.pillPrimary)
                            }
                        }
                    }
                }
                ForEach(groups, id: \.record.id) { (group: (record: MeetingRecord, tasks: [NoteTask])) in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            router.selectedMeetingID = group.record.id
                            router.section = .meetings
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.record.note?.title ?? group.record.title).appFont(size: 15, weight: .medium)
                                    Text(meetingMetaLine(record: group.record)).appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverPlain)
                        ForEach(Array(group.tasks.enumerated()), id: \.element.trackingKey) { (item: (offset: Int, element: NoteTask)) in
                            TaskLine(model: model, record: group.record, task: item.element) {
                                router.selectedMeetingID = group.record.id
                                router.section = .meetings
                            }
                        }
                    }
                    .padding(8)
                    .cardSurface(cornerRadius: 16)
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: showsDone)
            .animation(.smooth(duration: 0.25), value: doneCount)
            .padding(36)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Toplantılar bölümü: solda liste (üst çubuktaki aramayla süzülür), sağda seçili toplantının sayfası.
private struct MeetingsSplit: View {
    let model: AppModel
    let router: MainWindowRouter
    let player: MeetingAudioPlayer
    @AppStorage(SettingsKey.meetingsListVisible) private var listVisible: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            // Liste üst çubuktaki düğmeyle gizlenir; toplantı seçili değilken seçecek bir şey kalmasın diye hep görünür.
            if listVisible || router.selectedMeetingID == nil {
                MeetingsListPage(
                    model: model, selectedID: router.selectedMeetingID, query: router.searchQuery, folder: router.folderFilter,
                    onClearFolder: { router.folderFilter = nil },
                    onOpen: { (id: String) -> Void in router.selectedMeetingID = id },
                    onDeleted: { (ids: Set<String>) -> Void in
                        if let open = router.selectedMeetingID, ids.contains(open) {
                            router.selectedMeetingID = nil
                        }
                    }
                )
                .frame(width: 300)
                // Ses/video dosyası listeye bırakılınca toplantı olarak içe aktarılır.
                .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
                    let media: [URL] = urls.filter { (url: URL) -> Bool in
                        guard let type = UTType(filenameExtension: url.pathExtension) else {
                            return false
                        }
                        return type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)
                    }
                    guard !media.isEmpty else {
                        return false
                    }
                    model.importMedia(urls: media)
                    return true
                }
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ZStack {
                if let id = router.selectedMeetingID, let record = model.meetings.first(where: { $0.id == id }) {
                    MeetingDetailPage(model: model, player: player, record: record) {
                        router.selectedMeetingID = nil
                    } onRunRecipe: { (recipe: Recipe) -> Void in
                        model.askArchive(question: recipe.prompt, meetingIDs: [record.id], recipeTitle: recipe.title)
                        router.section = .ask
                    }
                        // Toplantı değişince ad alanları gibi durumlar sıfırlansın.
                        .id(record.id)
                        .transition(.opacity)
                } else {
                    ScrollView {
                        if model.meetings.isEmpty {
                            EmptyStateHero(
                                symbol: "waveform", title: "Henüz toplantı yok",
                                message: "Kaydı başlat ya da bir ses/video dosyasını soldaki listeye sürükle; bitince notu, görevleri ve konuşmacılı transkripti burada görürsün.",
                                palette: .sunset,
                                steps: [
                                    EmptyStateStep(symbol: "record.circle", title: "Kaydı başlat"),
                                    EmptyStateStep(symbol: "square.and.arrow.down", title: "ya da dosya sürükle"),
                                    EmptyStateStep(symbol: "doc.text", title: "Not burada"),
                                ]
                            ) {
                                EmptyView()
                            }
                        } else {
                            EmptyStateHero(
                                symbol: "doc.text.magnifyingglass", title: "Bir toplantı seç",
                                message: "Notu, görevleri, konu akışını ve konuşmacılı transkripti burada görürsün.", palette: .sunset, steps: []
                            ) {
                                EmptyView()
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .padding(.top, 40)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.25), value: router.selectedMeetingID)
        }
        .animation(.smooth(duration: 0.25), value: listVisible)
    }
}

/// Kenar çubuğunda klasörler (Otter'daki kanallar gibi): proje, ekip ya da ders başına; tıklayınca Toplantılar o
/// klasörle süzülür. "+" ile satır içinde yeni klasör; sağ tıkla silinir (toplantılar silinmez).
private struct SidebarFolders: View {
    let model: AppModel
    let router: MainWindowRouter
    @State private var isAdding: Bool = false
    @State private var newName: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Klasörler").appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Button {
                    isAdding = true
                    isFocused = true
                } label: {
                    Image(systemName: "plus").appFont(size: 11, weight: .semibold).foregroundStyle(Theme.muted).frame(width: 20, height: 20)
                }
                .buttonStyle(.hoverPlain)
                .hoverHint("Yeni klasör", alignment: .trailing, edge: .bottom)
            }
            .padding(.horizontal, 10)
            .padding(.top, 18)
            .padding(.bottom, 4)
            ForEach(model.folders) { (folder: FolderSummary) in
                let isSelected: Bool = router.section == .meetings && router.folderFilter?.caseInsensitiveCompare(folder.name) == .orderedSame
                Button {
                    router.folderFilter = folder.name
                    router.selectedMeetingID = nil
                    router.section = .meetings
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "folder.fill" : "folder").appFont(size: 13, weight: .regular).frame(width: 18)
                        Text(folder.name).appFont(size: 13, weight: isSelected ? .medium : .regular).lineLimit(1)
                        Spacer(minLength: 0)
                        if folder.count > 0 {
                            Text("\(folder.count)").appFont(size: 11, weight: .medium).foregroundStyle(Theme.muted)
                        }
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isSelected ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.hoverPlain)
                .contextMenu {
                    Button("Klasörü sil", systemImage: "trash", role: .destructive) {
                        if router.folderFilter == folder.name {
                            router.folderFilter = nil
                        }
                        model.deleteFolder(name: folder.name)
                    }
                    // İşlenen toplantı klasörden çıkarılamaz; silinse klasör yeniden belirirdi.
                    .disabled(!model.canDeleteFolder(name: folder.name))
                }
            }
            if isAdding {
                TextField("Klasör adı", text: $newName)
                    .textFieldStyle(.plain)
                    .appFont(size: 13, weight: .regular)
                    .focused($isFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
                    .onSubmit {
                        model.createFolder(name: newName)
                        newName = ""
                        isAdding = false
                    }
                    .onExitCommand {
                        newName = ""
                        isAdding = false
                    }
            }
        }
    }
}

/// Ana penceredeki hata şeridi: son hatalar, kapatma düğmesi. Metin seçilebilir (destek için kopyalanabilsin).
private struct ErrorBanner: View {
    let messages: [String]
    let onDismiss: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(messages.suffix(3).enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                    Text(item.element)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .appFont(size: 11, weight: .semibold)
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.hoverPlain)
            .accessibilityLabel(Text("Hataları kapat"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Saate göre selam; ad varsa ilk adıyla. Saf fonksiyondur.
func homeGreeting(name: String, hour: Int) -> String {
    let base: String = switch hour {
    case 5..<12: String(localized: "Günaydın")
    case 12..<18: String(localized: "İyi günler")
    case 18..<23: String(localized: "İyi akşamlar")
    default: String(localized: "İyi geceler")
    }
    let first: String = name.split(separator: " ").first.map(String.init) ?? ""
    return first.isEmpty ? base : "\(base), \(first)"
}

/// Orta ekrandaki arama penceresi (Spotlight gibi): arka plan bulanıklaşır ve kararır; büyük arama alanı yazıldıkça
/// toplantıları anında süzer (başlık, not, görevler, adlar, transkript). ↑↓ seçer, ↩ seçileni açar (seçim yoksa aramayı
/// Toplantılar listesine uygular), Esc ya da dışarı tıklama kapatır.
private struct SearchComposer: View {
    let model: AppModel
    let router: MainWindowRouter
    @State private var query: String = ""
    @State private var highlighted: Int = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        let trimmed: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let results: [MeetingRecord] = Array((trimmed.isEmpty ? model.meetings : filterMeetings(records: model.meetings, query: trimmed)).prefix(8))
        ZStack(alignment: .top) {
            // Arkadaki içerik pencerede bulanıklaşır; burada yalnızca dışarı tıklayınca kapatan saydam katman.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .appFont(size: 18, weight: .medium)
                        .foregroundStyle(Theme.muted)
                    TextField("Toplantılarda ara…", text: $query)
                        .textFieldStyle(.plain)
                        .appFont(size: 20, weight: .regular)
                        .focused($isFocused)
                        .onSubmit { open(results: results) }
                    Text("esc")
                        .appFont(size: 11, weight: .medium)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                }
                .padding(.horizontal, 18)
                .frame(height: 60)
                Rectangle().fill(Theme.line).frame(height: 1)
                if results.isEmpty {
                    Text("Eşleşen toplantı yok")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trimmed.isEmpty ? "Son toplantılar" : "Toplantılar")
                            .appFont(size: 11, weight: .semibold)
                            .tracking(DesignTokens.labelTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        ForEach(Array(results.enumerated()), id: \.element.id) { (item: (offset: Int, element: MeetingRecord)) in
                            row(record: item.element, isHighlighted: item.offset == min(highlighted, results.count - 1))
                                .onHover { (hovering: Bool) -> Void in
                                    if hovering {
                                        highlighted = item.offset
                                    }
                                }
                        }
                    }
                    .padding(8)
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack(spacing: 14) {
                    Text("↑↓ seç")
                    Text("↩ aç")
                    Spacer(minLength: 0)
                    if !trimmed.isEmpty {
                        Button("Tüm sonuçları listede göster") { applyToList() }
                            .buttonStyle(.hoverPlain)
                    }
                }
                .appFont(size: 11, weight: .regular)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 16)
                .frame(height: 34)
            }
            .frame(width: 600)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 18)
            .padding(.top, 96)
            // Kenar çubuğundan sonraki içerik alanının ortasında (pencerenin ortasında kenar çubuğu yüzünden sola kaymış
            // görünüyordu).
            .padding(.leading, sidebarWidth)
        }
        .onAppear {
            query = router.searchQuery
            isFocused = true
        }
        .onChange(of: query) { (_: String, _: String) -> Void in highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(0, results.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onExitCommand { close() }
    }

    private func row(record: MeetingRecord, isHighlighted: Bool) -> some View {
        Button {
            openMeeting(id: record.id)
        } label: {
            HStack(spacing: 12) {
                CoverImage(seed: record.id)
                    .frame(width: 40, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.note?.title ?? record.title)
                        .appFont(size: 14, weight: .medium)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(record.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                if isHighlighted {
                    Image(systemName: "return")
                        .appFont(size: 11, weight: .medium)
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isHighlighted ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// ↩: vurgulanan toplantıyı açar; sonuç yoksa aramayı listeye uygular.
    private func open(results: [MeetingRecord]) {
        guard !results.isEmpty else {
            applyToList()
            return
        }
        openMeeting(id: results[min(highlighted, results.count - 1)].id)
    }

    private func openMeeting(id: String) {
        router.searchQuery = ""
        router.folderFilter = nil
        router.selectedMeetingID = id
        router.section = .meetings
        close()
    }

    /// Aramayı Toplantılar listesine uygular (üst çubukta görünür, × ile temizlenir).
    private func applyToList() {
        router.searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        router.folderFilter = nil
        router.section = .meetings
        close()
    }

    private func close() {
        router.isSearchPresented = false
    }
}

/// Kısayol kartının zemini: Sor'daki örnek kartlar gibi kart yüzeyi, sağa doğru beliren ince çapraz çizgiler ve çerçeve.
private struct ShortcutCardBackground: View {
    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            shape.fill(Theme.card)
            DiagonalLines(spacing: 9)
                .stroke(Theme.line, lineWidth: 1)
                .mask(LinearGradient(colors: [.clear, .clear, .black], startPoint: .leading, endPoint: .trailing))
                .clipShape(shape)
            shape.strokeBorder(Theme.line)
        }
    }
}

/// Kayıt ekranı: kayıt sürerken ana pencerenin arkası bulanıklaşır, ortada paneldeki ses ölçerin büyük eşi, süre ve
/// durum; altında duraklat/devam, paneli göster ve kırmızı "Bitir". "Uygulamaya dön" (ya da Esc) ekranı bu kayıt için
/// kapatır; üst çubuktaki "Kayıtta" hapı geri açar.
private struct RecordingFocus: View {
    let model: AppModel
    let router: MainWindowRouter
    let onShowPanel: @MainActor () -> Void
    // Ekran açılınca odak buraya alınır: tuşlar ve Return arkadaki gizli alanlara (ör. Sor kutusu) gitmesin.
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // Arkadaki içerik pencerede bulanıklaşır; koyu perde yok. Temanın zemin rengiyle hafif bir örtü yazıyı
            // açık ve koyu temada okunur tutar, tıklamaları da arkaya geçirmez.
            Theme.background
                .opacity(0.35)
                .contentShape(Rectangle())
                .ignoresSafeArea()
            VStack(spacing: 22) {
                LargeLevelMeter(levels: model.audioLevels)
                    .opacity(model.isPaused ? 0.35 : 1)
                VStack(spacing: 6) {
                    if let startedAt = model.recordingStartedAt {
                        TimelineView(.periodic(from: startedAt, by: 1)) { (context: TimelineViewDefaultContext) in
                            Text(timestamp(seconds: context.date.timeIntervalSince(startedAt)))
                                .appFont(size: 40, weight: .semibold)
                                .monospacedDigit()
                                .tracking(-1)
                        }
                    }
                    Text(model.isPaused ? "Duraklatıldı" : "Dinleniyor — konuşmalar canlı panelde yazıya dökülüyor")
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                HStack(spacing: 10) {
                    Button(model.isPaused ? "Devam ettir" : "Duraklat", systemImage: model.isPaused ? "play.fill" : "pause.fill") { model.togglePause() }
                        .buttonStyle(.pill)
                    Button("Paneli göster", systemImage: "rectangle.on.rectangle") { onShowPanel() }
                        .buttonStyle(.pill)
                    Button {
                        model.stopRecording()
                    } label: {
                        Label("Bitir", systemImage: "stop.fill")
                            .appFont(size: 13, weight: .semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.red, in: Capsule())
                    }
                    .buttonStyle(.hoverCapsule)
                }
                // Bulanık zeminde soluk renk okunmuyordu: koyu yazı.
                Button("Uygulamaya dön") { router.isRecordingFocusDismissed = true }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(Theme.ink.opacity(0.8))
                    .appFont(size: 12, weight: .medium)
                    .padding(.top, 4)
            }
            .padding(36)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onExitCommand { router.isRecordingFocusDismissed = true }
    }
}
