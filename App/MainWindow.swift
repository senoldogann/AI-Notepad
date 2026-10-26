import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

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
    case settings
    case setup
}

/// Ana pencerede açık bölüm ve seçili toplantı; menü ve Dock da buradan bölüm seçer.
@MainActor
@Observable
final class MainWindowRouter {
    var section: MainSection = .home
    var selectedMeetingID: String?
    /// Kayıt ya da işleme sürerken çıkış istendi: Ana sayfada satır içi soru gösterilir.
    var quitWarning: Bool = false
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
final class AppDelegate: NSObject, NSApplicationDelegate {
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

/// Uygulamanın ana penceresi: kenar çubuğunda Ana sayfa, Toplantılar, Ayarlar ve Kurulum. Kayıt sırasındaki yüzen panel
/// ve ada ayrıca çalışır; pencere kapatılınca uygulama menü çubuğunda sürer.
struct MainWindowView: View {
    let model: AppModel
    let router: MainWindowRouter
    let shortcuts: ShortcutController
    let player: MeetingAudioPlayer
    let onStartRecording: @MainActor () -> Void
    let onShowPanel: @MainActor () -> Void

    var body: some View {
        ZStack {
            // Kurulum odaklı, tam pencere: kenar çubuğu yok, kart ortada.
            if router.section == .setup {
                SetupScreen(model: model, router: router, shortcuts: shortcuts)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                split
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: router.section == .setup)
        .frame(minWidth: 820, minHeight: 560)
        // Liquid Glass: pencere zemini yarı saydam malzeme; masaüstü arkadan hafifçe görünür, metin okunaklı kalır.
        .containerBackground(.thinMaterial, for: .window)
        // Başlık şeridi ayrı opak bant olmasın; cam zemin pencerenin tepesine kadar sürsün.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .modifier(AppearanceEnvironment())
    }

    private var split: some View {
        NavigationSplitView {
            List(selection: Binding<MainSection?>(
                get: { router.section },
                set: { (section: MainSection?) -> Void in
                    if let section {
                        router.section = section
                    }
                }
            )) {
                Label("Ana sayfa", systemImage: "house").tag(MainSection.home)
                Label("Toplantılar", systemImage: "list.bullet.rectangle").tag(MainSection.meetings)
                Label("Ayarlar", systemImage: "gearshape").tag(MainSection.settings)
                Label("Kurulum", systemImage: "wand.and.stars").tag(MainSection.setup)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                SidebarStatus(model: model)
            }
        } detail: {
            // Bölüm değişince içerik yumuşakça geçer.
            detail
                .id(router.section)
                .transition(.opacity)
                .animation(.smooth(duration: 0.25), value: router.section)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch router.section {
        case .home:
            HomePage(model: model, router: router, shortcuts: shortcuts, onStartRecording: onStartRecording, onShowPanel: onShowPanel)
        case .meetings:
            MeetingsSplit(model: model, router: router, player: player)
        case .settings:
            // Geniş pencerede form satırları ekran boyu uzamasın.
            SettingsPage(model: model, shortcuts: shortcuts)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
        case .setup:
            // Kurulum kenar çubuğu olmadan gösterilir (bkz. `body`); buraya gelinmez.
            EmptyView()
        }
    }
}

/// Kurulum ekranı: kenar çubuğu yok; simge ve cam kart pencerenin ortasında. Kaydırma alanı, uzun ve satır kaydıran
/// "Hoş geldin" metinlerinin pencereyi ekran boyuna büyütüp içeriği boş bırakmasını önler; kart yüksekliği sabit
/// (adımlar arasında düğmeler yerinde kalır, formlar kendi içinde kayar).
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
                        .frame(width: 72, height: 72)
                    SetupPage(model: model, shortcuts: shortcuts) { router.section = .home }
                        .frame(width: min(660, max(geometry.size.width - 64, 360)), height: 540)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .padding(.vertical, DesignTokens.Spacing.xl)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }
}

/// Kenar çubuğunun altında kayıt durumu.
private struct SidebarStatus: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isRecording ? Color.red : (model.setupProblems.isEmpty ? Color.green : Color.orange))
                .frame(width: 7, height: 7)
            Text(model.isRecording ? String(localized: "Kayıt sürüyor") : model.viewState.statusText)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DesignTokens.Spacing.m)
        .padding(.vertical, DesignTokens.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Ana sayfa: kaydı başlat (seçenekleriyle), eksik ayarlar, sana düşen görevler ve son toplantılar.
private struct HomePage: View {
    let model: AppModel
    let router: MainWindowRouter
    let shortcuts: ShortcutController
    let onStartRecording: @MainActor () -> Void
    let onShowPanel: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                if router.quitWarning {
                    QuitWarning(model: model, router: router)
                }
                hero
                if !model.setupProblems.isEmpty {
                    problems
                }
                HomeTasks(model: model, router: router)
                HomeRecentMeetings(model: model, router: router)
            }
            .padding(32)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(.smooth(duration: 0.3), value: router.quitWarning)
            .animation(.smooth(duration: 0.3), value: model.phase)
            .animation(.smooth(duration: 0.3), value: model.setupProblems)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
            HStack(spacing: DesignTokens.Spacing.l) {
                // Sistemin çizdiği simge (köşe maskesi ve cam kenarıyla); Dock'taki ile aynı.
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI-Notepad")
                        .font(.system(size: 28, weight: .bold))
                    Text("Toplantıyı yazıya döker, Türkçeye çevirir; sonunda sana düşenleri çıkarır.")
                        .foregroundStyle(.secondary)
                }
            }
            recordingCard
        }
    }

    @ViewBuilder
    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            switch model.phase {
            case .recording:
                HStack(spacing: DesignTokens.Spacing.m) {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    if let startedAt = model.recordingStartedAt {
                        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    }
                    Text(model.isPaused ? "Duraklatıldı" : "Kayıt sürüyor")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Paneli göster", systemImage: "rectangle.on.rectangle") { onShowPanel() }
                    Button("Bitir", systemImage: "stop.fill") { model.stopRecording() }
                        .buttonStyle(.glassProminentAction)
                }
            case .finishing:
                HStack(spacing: DesignTokens.Spacing.m) {
                    ProgressView().controlSize(.small)
                    Text("Bitiriliyor… kalan metin ve konuşmacılar tamamlanıyor.")
                        .foregroundStyle(.secondary)
                }
            case .idle:
                HStack(alignment: .center, spacing: DesignTokens.Spacing.l) {
                    Button(action: onStartRecording) {
                        Label("Kaydı başlat", systemImage: "record.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, DesignTokens.Spacing.s)
                    }
                    .buttonStyle(.glassProminentAction)
                    .controlSize(.extraLarge)
                    .disabled(!model.isReadyToRecord || model.isStarting)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.viewState.statusText)
                        Text("Kısayol: \(keyBindingDisplay(binding: shortcuts.currentBinding(action: .record)))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                RecordingOptions(model: model)
            }
        }
        .padding(DesignTokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var problems: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Kayıttan önce tamamlanmalı", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            ForEach(model.setupProblems, id: \.self) { (problem: String) in
                Text(problem).foregroundStyle(.secondary)
            }
            Button("Kurulumu aç") { router.section = .setup }
        }
        .padding(DesignTokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color.orange.opacity(0.18)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Kayıt ya da işleme sürerken çıkış istendiğinde sayfanın içindeki soru (ayrı uyarı penceresi yok). İş biterse
/// kendiliğinden kapanır.
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
            .font(.headline)
            .foregroundStyle(.orange)
            HStack(spacing: DesignTokens.Spacing.s) {
                if model.phase == .recording {
                    Button("Kaydı bitir", systemImage: "stop.fill") {
                        model.stopRecording()
                        router.quitWarning = false
                    }
                    .buttonStyle(.glassProminentAction)
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
        .glassEffect(.regular.tint(Color.orange.opacity(0.18)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onChange(of: isBusy) { (_: Bool, busy: Bool) in
            if !busy {
                router.quitWarning = false
            }
        }
    }
}

/// Kayıttan önce seçilenler: kendi sesi, dil, canlı çeviri.
private struct RecordingOptions: View {
    @Bindable var model: AppModel

    var body: some View {
        FlowLayout(spacing: DesignTokens.Spacing.l, lineSpacing: DesignTokens.Spacing.s) {
            Toggle("Kendi sesimi de kaydet", isOn: Binding<Bool>(
                get: { !model.isMicMuted },
                set: { (enabled: Bool) -> Void in
                    if enabled == model.isMicMuted {
                        model.toggleMicrophone()
                    }
                }
            ))
            Toggle("Canlı çeviri", isOn: Binding<Bool>(
                get: { model.displayMode.needsLiveTranslation },
                set: { (enabled: Bool) -> Void in model.selectDisplayMode(mode: enabled ? .bilingual : .originalOnly) }
            ))
            Picker("Dil", selection: $model.languageMode) {
                Text("Otomatik").tag(LanguageMode.automatic)
                Text("Fince").tag(LanguageMode.fixed(.finnish))
                Text("İngilizce").tag(LanguageMode.fixed(.english))
            }
            .fixedSize()
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

/// Son toplantılarda sana düşen görevler (en yeni toplantıdan başlayarak).
private struct HomeTasks: View {
    let model: AppModel
    let router: MainWindowRouter
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let items: [(record: MeetingRecord, task: NoteTask)] = model.meetings
            .prefix(10)
            .flatMap { (record: MeetingRecord) -> [(record: MeetingRecord, task: NoteTask)] in
                (record.note?.tasks ?? []).filter(\.isMine).map { (record: record, task: $0) }
            }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                Text("SANA DÜŞEN GÖREVLER")
                    .font(DesignTokens.labelFont)
                    .tracking(DesignTokens.labelTracking)
                    .foregroundStyle(.tint)
                ForEach(Array(items.prefix(8).enumerated()), id: \.offset) { (item: (offset: Int, element: (record: MeetingRecord, task: NoteTask))) in
                    Button {
                        router.selectedMeetingID = item.element.record.id
                        router.section = .meetings
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.s) {
                            Image(systemName: "circle").font(.system(size: 9)).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.element.task.description)
                                Text(([item.element.task.dueDate].compactMap { $0 } + [item.element.record.note?.title ?? item.element.record.title]).joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverPlain)
                }
            }
            .padding(DesignTokens.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(appearance.accent.color.opacity(0.16)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

/// En son beş toplantı.
private struct HomeRecentMeetings: View {
    let model: AppModel
    let router: MainWindowRouter

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            HStack {
                Text("SON TOPLANTILAR")
                    .font(DesignTokens.labelFont)
                    .tracking(DesignTokens.labelTracking)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if model.meetings.count > 5 {
                    Button("Tümü") { router.section = .meetings }
                        .buttonStyle(.link)
                        .pointerStyle(.link)
                }
            }
            if model.meetings.isEmpty {
                Text("Henüz toplantı yok. Kaydı başlatınca toplantıların ve notların burada görünür.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.meetings.prefix(5)) { (record: MeetingRecord) in
                    Button {
                        router.selectedMeetingID = record.id
                        router.section = .meetings
                    } label: {
                        MeetingRow(record: record, isProcessing: model.processingMeetingIDs.contains(record.id), isSelected: false)
                    }
                    .buttonStyle(.hoverPlain)
                }
            }
        }
    }
}

/// Toplantılar bölümü: solda arama ve liste, sağda seçili toplantının sayfası.
private struct MeetingsSplit: View {
    let model: AppModel
    let router: MainWindowRouter
    let player: MeetingAudioPlayer

    var body: some View {
        HStack(spacing: 0) {
            MeetingsListPage(
                model: model, selectedID: router.selectedMeetingID,
                onOpen: { (id: String) -> Void in router.selectedMeetingID = id },
                onDeleted: { (ids: Set<String>) -> Void in
                    if let open = router.selectedMeetingID, ids.contains(open) {
                        router.selectedMeetingID = nil
                    }
                }
            )
            .frame(width: 300)
            Divider()
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
