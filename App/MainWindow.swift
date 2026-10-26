import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI
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
    /// Üst çubuktaki arama (Toplantılar listesini süzer).
    var searchQuery: String = ""
    /// Kayıt ya da işleme sürerken çıkış istendi: Ana sayfada satır içi soru gösterilir.
    var quitWarning: Bool = false
    /// Açılış ekranı bu açılışta gösterildi.
    var hasShownSplash: Bool = false
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
    let onStartRecording: @MainActor () -> Void
    let onShowPanel: @MainActor () -> Void

    var body: some View {
        ZStack {
            // İlk açılışta bir kez: tam pencere, kenar çubuğu yok, içerik ortada.
            if router.section == .setup {
                SetupScreen(model: model, router: router, shortcuts: shortcuts)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                HStack(spacing: 0) {
                    Sidebar(model: model, router: router)
                    VStack(spacing: 0) {
                        TopBar(router: router, onShowPanel: onShowPanel)
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
        // Açılış ekranı: uygulama her açıldığında bir kez (pencere kapatılıp açılınca tekrarlanmaz).
        .overlay {
            if !router.hasShownSplash {
                LaunchSplash {
                    withAnimation(.smooth(duration: 0.45)) { router.hasShownSplash = true }
                }
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .foregroundStyle(Theme.ink)
        // Toplantı hazırlanırken ana pencerede de aynı ilerleme kartı (panelle eş zamanlı).
        .modifier(ProcessingOverlayHost(model: model))
        .frame(minWidth: 860, minHeight: 580)
        .background(Theme.background)
        .containerBackground(Theme.background, for: .window)
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
        case .tasks:
            TasksPage(model: model, router: router)
        case .settings:
            // Geniş pencerede form satırları ekran boyu uzamasın.
            SettingsPage(model: model, shortcuts: shortcuts)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
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
        let myTaskCount: Int = myTasks(meetings: Array(model.meetings.prefix(10))).filter { !isTaskDone(record: $0.record, task: $0.task) }.count
        VStack(alignment: .leading, spacing: 2) {
            // Trafik ışıklarına yer.
            Color.clear.frame(height: 40)
            item(title: "Ana sayfa", symbol: "house", section: .home, badge: nil)
            item(title: "Toplantılar", symbol: "list.bullet.rectangle", section: .meetings, badge: nil)
            item(title: "Görevlerim", symbol: "checkmark.circle", section: .tasks, badge: myTaskCount > 0 ? myTaskCount : nil)
            item(title: "Ayarlar", symbol: "gearshape", section: .settings, badge: nil)
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
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: 228)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func item(title: LocalizedStringKey, symbol: String, section: MainSection, badge: Int?) -> some View {
        let isSelected: Bool = router.section == section
        return Button {
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

/// Üst çubuk: sayfa adı, toplantılarda arama (⌘K; yazınca Toplantılar açılır), "Canlı panel".
private struct TopBar: View {
    let router: MainWindowRouter
    let onShowPanel: @MainActor () -> Void
    @FocusState private var isSearching: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            Text(title).appFont(size: 14, weight: .medium)
            Spacer(minLength: DesignTokens.Spacing.m)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Toplantılarda ara…", text: Binding<String>(
                    get: { router.searchQuery },
                    set: { (value: String) -> Void in
                        router.searchQuery = value
                        if !value.isEmpty {
                            router.section = .meetings
                        }
                    }
                ))
                .textFieldStyle(.plain)
                .focused($isSearching)
                // Pencere açılınca arama kutusu kendiliğinden odak almaz (imleç yanıp sönmesin).
                .defaultFocus($isSearching, false)
                Text("⌘K")
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 5)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
            }
            .appFont(size: 13, weight: .regular)
            .padding(.horizontal, 10)
            .frame(width: 320, height: 32)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSearching ? Theme.ink.opacity(0.35) : Theme.line))
            .background {
                // ⌘K aramaya odaklanır.
                Button("") { isSearching = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
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

    private var title: LocalizedStringKey {
        switch router.section {
        case .home: "Ana sayfa"
        case .meetings: "Toplantılar"
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
        GeometryReader { (geometry: GeometryProxy) in
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.l) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable()
                        .frame(width: 88, height: 88)
                        .floating3D()
                        .tilt3D(maxAngle: 14)
                    SetupPage(model: model, shortcuts: shortcuts) { router.section = .home }
                        .frame(width: min(660, max(geometry.size.width - 64, 360)), height: 540)
                }
                .padding(.vertical, DesignTokens.Spacing.xl)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }
}
private struct QuitWarning: View {
    let model: AppModel
    let router: MainWindowRouter

    var body: some View {
        let isBusy: Bool = model.phase != .idle || !model.processingMeetingIDs.isEmpty
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
                VStack(spacing: 20) {
                    heading
                    RecordBar(model: model, onStartRecording: onStartRecording, onShowPanel: onShowPanel)
                }
                .padding(.top, 36)
                ToolTiles(model: model, router: router, onStartRecording: onStartRecording, onShowPanel: onShowPanel)
                if !model.setupProblems.isEmpty {
                    problems
                }
                UpcomingMeetings(model: model, onStartRecording: onStartRecording)
                BannerCarousel(model: model, router: router)
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
                    .symbolEffect(.pulse, isActive: !model.isPaused)
                if let startedAt = model.recordingStartedAt {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
                Text(model.isPaused ? "· duraklatıldı" : "· dinleniyor")
                    .foregroundStyle(Theme.muted)
            }
            .appFont(size: 34, weight: .regular)
        case .finishing:
            Text("Bitiriliyor…")
                .appFont(size: 34, weight: .regular)
        case .idle:
            Text("Bugün hangi toplantıyı dinleyelim?")
                .appFont(size: 34, weight: .regular)
                .tracking(-0.6)
                .multilineTextAlignment(.center)
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
        HStack(spacing: 10) {
            Circle()
                .fill(RadialGradient(
                    colors: [appearance.accent.color.mix(with: .white, by: 0.45), appearance.accent.color, appearance.accent.color.mix(with: .black, by: 0.55)],
                    center: UnitPoint(x: 0.35, y: 0.35), startRadius: 1, endRadius: 22
                ))
                .frame(width: 34, height: 34)
                .tilt3D(maxAngle: 18)
            switch model.phase {
            case .idle:
                Text("Toplantını dinlemeye başla")
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 6)
                languageChip
                chip(title: model.isMicMuted ? "Yalnız karşı taraf" : "Benim sesim de", isOn: !model.isMicMuted) {
                    model.toggleMicrophone()
                }
                chip(title: "Canlı çeviri", isOn: model.displayMode.needsLiveTranslation) {
                    model.selectDisplayMode(mode: model.displayMode.needsLiveTranslation ? .originalOnly : .bilingual)
                }
                Button("Başlat", systemImage: "record.circle", action: onStartRecording)
                    .buttonStyle(.pillPrimary)
                    .disabled(!model.isReadyToRecord || model.isStarting)
            case .recording:
                Text(model.isPaused ? "Kayıt duraklatıldı" : "Kayıt sürüyor — konuşmalar canlı panelde")
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 6)
                Button("Paneli göster", systemImage: "rectangle.on.rectangle") { onShowPanel() }
                    .buttonStyle(.pill)
                Button("Bitir", systemImage: "stop.fill") { model.stopRecording() }
                    .buttonStyle(.pillPrimary)
            case .finishing:
                Text("Kalan metin ve konuşmacılar tamamlanıyor.")
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 6)
                ProgressView().controlSize(.small)
            }
        }
        .appFont(size: 14, weight: .regular)
        .controlSize(.small)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 720)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
    }

    private var languageChip: some View {
        Menu {
            Button("Otomatik") { model.languageMode = .automatic }
            Button("Fince") { model.languageMode = .fixed(.finnish) }
            Button("İngilizce") { model.languageMode = .fixed(.english) }
        } label: {
            Text(languageTitle)
                .appFont(size: 12, weight: .medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.soft, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.hoverCapsule)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var languageTitle: LocalizedStringKey {
        switch model.languageMode {
        case .automatic: "Otomatik dil"
        case .fixed(.finnish): "Fince"
        case .fixed(.english): "İngilizce"
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
            .foregroundStyle(isOn ? Theme.ink : Theme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.soft, in: Capsule())
        }
        .buttonStyle(.hoverCapsule)
        .fixedSize()
    }
}

/// Araç kutucukları: beyaz, çerçeveli kare simgeler ve altında adı (ElevenLabs araç satırı).
private struct ToolTiles: View {
    let model: AppModel
    let router: MainWindowRouter
    let onStartRecording: @MainActor () -> Void
    let onShowPanel: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            tile(title: "Kaydı başlat", symbol: "waveform", isEnabled: model.phase == .idle && model.isReadyToRecord) { onStartRecording() }
            tile(title: "Canlı panel", symbol: "rectangle.on.rectangle", isEnabled: true) { onShowPanel() }
            tile(title: "Toplantılar", symbol: "list.bullet.rectangle", isEnabled: true) { router.section = .meetings }
            tile(title: "Görevlerim", symbol: "checkmark.circle", isEnabled: true) { router.section = .tasks }
            tile(title: "Ayarlar", symbol: "gearshape", isEnabled: true) { router.section = .settings }
        }
    }

    private func tile(title: LocalizedStringKey, symbol: String, isEnabled: Bool, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .appFont(size: 18, weight: .regular)
                    .frame(width: 48, height: 48)
                    .cardSurface(cornerRadius: 12)
                    .tilt3D(maxAngle: 10)
                Text(title).appFont(size: 13, weight: .regular)
            }
            .foregroundStyle(Theme.ink)
            .frame(width: 92)
        }
        .buttonStyle(.hoverPlain)
        .disabled(!isEnabled)
    }
}

/// Banner karuseli: üç slayt (yenilikler ve ipuçları), kendiliğinden ilerler, fare üstündeyken durur; noktalar.
private struct BannerCarousel: View {
    let model: AppModel
    let router: MainWindowRouter
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @State private var index: Int = 0
    @State private var isHovering: Bool = false

    private struct Slide {
        let title: LocalizedStringKey
        let primary: LocalizedStringKey
        let secondary: LocalizedStringKey
        let color: Color
    }

    private var slides: [Slide] {
        [
            Slide(title: "Uzun toplantılar artık parça parça not — hiçbir görev kaybolmaz", primary: "Son toplantıyı aç", secondary: "Toplantılar", color: appearance.accent.color),
            Slide(title: "Yalnızca karşı tarafı kaydet — mikrofon hiç açılmaz, yankı olmaz", primary: "Ayarlar", secondary: "Ana sayfa", color: Color(red: 0.18, green: 0.36, blue: 0.88)),
            Slide(title: "Konuşmacılara ad ver — \"Gözden geçir\" adları ve birleştirmeleri önerir", primary: "Toplantılar", secondary: "Görevlerim", color: Color(red: 0.16, green: 0.55, blue: 0.45)),
        ]
    }

    var body: some View {
        let slide: Slide = slides[index]
        VStack(spacing: 10) {
            GradientBanner(accent: slide.color) {
                VStack(spacing: 14) {
                    Text(slide.title)
                        .appFont(size: 24, weight: .regular)
                        .tracking(-0.3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                    HStack(spacing: 18) {
                        Button(slide.primary) { act(primary: true) }
                            .buttonStyle(.bannerPrimary)
                        Button(slide.secondary) { act(primary: false) }
                            .buttonStyle(.hoverPlain)
                            .foregroundStyle(.white)
                    }
                }
                .id(index)
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
            .onHover { (hovering: Bool) -> Void in isHovering = hovering }
            HStack(spacing: 6) {
                ForEach(slides.indices, id: \.self) { (position: Int) in
                    Button {
                        index = position
                    } label: {
                        Circle()
                            .fill(position == index ? Theme.ink : Theme.line)
                            .frame(width: 6, height: 6)
                            .padding(3)
                    }
                    .buttonStyle(.hoverCapsule)
                }
            }
        }
        .animation(.smooth(duration: 0.5), value: index)
        .task {
            // Kendiliğinden ilerler; fare üstündeyken ya da "Hareketi azalt" açıkken durur.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(7))
                } catch {
                    return
                }
                if !isHovering && !reduceMotion {
                    index = (index + 1) % slides.count
                }
            }
        }
    }

    private func act(primary: Bool) {
        switch (index, primary) {
        case (0, true):
            router.selectedMeetingID = model.meetings.first?.id
            router.section = .meetings
        case (0, false), (2, true):
            router.section = .meetings
        case (1, true):
            router.section = .settings
        case (2, false):
            router.section = .tasks
        default:
            router.section = .home
        }
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

    var body: some View {
        let now: Date = Date()
        let items: [CalendarMeeting] = model.upcomingMeetings.filter { $0.end > now && $0.start.timeIntervalSince(now) < 12 * 3600 }
        if let error = model.calendarError {
            EmptyStateCard(symbol: "calendar.badge.exclamationmark", title: "Takvim okunamadı", message: LocalizedStringKey(error))
        } else if !items.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                Text("Yaklaşan toplantılar").appFont(size: 15, weight: .medium)
                VStack(spacing: 0) {
                    ForEach(Array(items.prefix(4).enumerated()), id: \.element.id) { (item: (offset: Int, element: CalendarMeeting)) in
                        if item.offset > 0 {
                            Rectangle().fill(Theme.line).frame(height: 1)
                        }
                        row(meeting: item.element, now: now)
                    }
                }
                .padding(.horizontal, 14)
                .cardSurface(cornerRadius: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            if let url = meeting.joinURL {
                Button("Katıl", systemImage: "video") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
                    .hoverHint("Görüşme bağlantısını aç", alignment: .trailing, edge: .bottom)
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

/// Toplantılardan kullanıcıya düşen görevler (verilen sırada). Saf fonksiyondur.
func myTasks(meetings: [MeetingRecord]) -> [(record: MeetingRecord, task: NoteTask)] {
    meetings.flatMap { (record: MeetingRecord) -> [(record: MeetingRecord, task: NoteTask)] in
        (record.note?.tasks ?? []).filter(\.isMine).map { (record: record, task: $0) }
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
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

/// Toplantı kartı: toplantıya göre sabit renkli gradyan kapak, altta başlık, tarih ve görev sayısı.
private struct MeetingCover: View {
    let record: MeetingRecord
    let isProcessing: Bool

    var body: some View {
        let mine: Int = record.note?.tasks.filter(\.isMine).count ?? 0
        ZStack(alignment: .bottomLeading) {
            CoverBackground(seed: record.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.note?.title ?? record.title)
                    .appFont(size: 14, weight: .medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(coverSubtitle(mine: mine))
                    .appFont(size: 12, weight: .regular)
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .frame(height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .tilt3D(maxAngle: 4)
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
                        EmptyStateCard(symbol: "checkmark.circle", title: "Tamamlanan görev yok", message: "Bir görevin dairesine tıklayınca buraya taşınır.")
                    } else if doneCount > 0 {
                        EmptyStateCard(symbol: "party.popper", title: "Açık görevin kalmadı", message: "Hepsi tamamlandı.")
                    } else {
                        EmptyStateCard(symbol: "checklist", title: "Henüz sana düşen görev yok", message: "Toplantı notlarında senin adına yazılan işler burada toplanır.")
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
                        ForEach(Array(group.tasks.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteTask)) in
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

    var body: some View {
        HStack(spacing: 0) {
            MeetingsListPage(
                model: model, selectedID: router.selectedMeetingID, query: router.searchQuery,
                onOpen: { (id: String) -> Void in router.selectedMeetingID = id },
                onDeleted: { (ids: Set<String>) -> Void in
                    if let open = router.selectedMeetingID, ids.contains(open) {
                        router.selectedMeetingID = nil
                    }
                }
            )
            .frame(width: 300)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
            ZStack {
                if let id = router.selectedMeetingID, let record = model.meetings.first(where: { $0.id == id }) {
                    MeetingDetailPage(model: model, player: player, record: record) { router.selectedMeetingID = nil }
                        // Toplantı değişince ad alanları gibi durumlar sıfırlansın.
                        .id(record.id)
                        .transition(.opacity)
                } else {
                    ContentUnavailableView("Bir toplantı seç", systemImage: "doc.text", description: Text("Notu, görevleri ve transkripti burada görürsün."))
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.25), value: router.selectedMeetingID)
        }
    }
}
