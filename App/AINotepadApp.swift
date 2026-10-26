import AINotepadCore
import AINotepadUI
import os
import SwiftUI

/// Menü çubuğunda çalışan uygulamanın giriş noktası.
@main
struct AINotepadApp: App {
    @State private var model: AppModel
    @State private var panel: LivePanelController
    @State private var island: IslandController
    @State private var shortcuts: ShortcutController
    @State private var onboarding: OnboardingController

    init() {
        registerDefaultSettings()
        let engine: LiveEngine = LiveEngine(rawValue: UserDefaults.standard.string(forKey: SettingsKey.liveEngine) ?? "") ?? .deepgram
        let displayMode: DisplayMode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.displayMode) ?? "") ?? .bilingual
        let model: AppModel = AppModel(liveEngine: engine, displayMode: displayMode)
        _model = State(initialValue: model)
        let hideFromCapture: Bool = UserDefaults.standard.bool(forKey: SettingsKey.hideFromScreenCapture)
        let panel: LivePanelController = LivePanelController(model: model, hideFromCapture: hideFromCapture)
        _panel = State(initialValue: panel)
        let island: IslandController = IslandController(model: model, onTap: { panel.toggle() })
        _island = State(initialValue: island)
        let shortcuts: ShortcutController = ShortcutController(hotKeys: HotKeyCenter(), model: model, actions: [
            .record: { Task { await toggleRecordingFlow(model: model, panel: panel, island: island) } },
            .toggleWindows: { toggleWindows(panel: panel, island: island) },
        ])
        _shortcuts = State(initialValue: shortcuts)
        let onboarding: OnboardingController = OnboardingController(model: model, shortcuts: shortcuts)
        _onboarding = State(initialValue: onboarding)
        // Pencereler ve kısayollar uygulama açıldıktan sonra kurulur.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                island.install()
                model.performStartupMaintenance()
                shortcuts.registerAll()
                onboarding.showIfNeeded()
            }
        }
        // WhisperKit modeli yalnızca o motor seçiliyse yüklenir.
        if engine == .whisperKit {
            Task { await model.loadModel() }
        }
    }

    var body: some Scene {
        MenuBarExtra("AI-Notepad", systemImage: menuSymbol) {
            MenuContent(model: model, panel: panel, island: island, shortcuts: shortcuts, onboarding: onboarding)
        }
        Settings {
            SettingsView(model: model, shortcuts: shortcuts)
        }
        Window("Toplantılar", id: "meetings") {
            MeetingsWindow(model: model)
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
    // Başlatma başarısız olsa da panel açılır: hata orada görünür.
    panel.show()
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
    let onboarding: OnboardingController
    @AppStorage(SettingsKey.hideFromScreenCapture) private var hideFromCapture: Bool = true
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.phase {
        case .recording:
            Button("Kaydı durdur", systemImage: "stop.circle") {
                model.stopRecording()
            }
            .menuShortcut(binding: shortcuts.currentBinding(action: .record))
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
        ForEach(Array((model.setupProblems + [model.shortcutError].compactMap { $0 }).enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
            Text(item.element).foregroundStyle(.red)
        }

        Divider()

        if model.isRecording {
            // Kayıt sırasında: otomatik algılama yanılırsa dil buradan değişir (o andan itibaren uygulanır).
            Menu("Dili değiştir", systemImage: "globe") {
                Button("🇫🇮 Fince") { model.setLanguage(language: .finnish) }
                Button("🇬🇧 İngilizce") { model.setLanguage(language: .english) }
            }
            .disabled(model.isFinishing)
        } else {
            Picker("Dil", systemImage: "globe", selection: $model.languageMode) {
                Text("Otomatik").tag(LanguageMode.automatic)
                Text("Fince").tag(LanguageMode.fixed(.finnish))
                Text("İngilizce").tag(LanguageMode.fixed(.english))
            }
        }

        Toggle("Ekran görüntülerinde gizle", systemImage: "eye.slash", isOn: $hideFromCapture)
            .onChange(of: hideFromCapture) { (_: Bool, newValue: Bool) in
                panel.setHideFromCapture(hidden: newValue)
                island.setHideFromCapture(hidden: newValue)
            }

        Button("Toplantılar…", systemImage: "list.bullet.rectangle") {
            NSApplication.shared.activate()
            openWindow(id: "meetings")
        }
        if !model.processingMeetingIDs.isEmpty {
            Text("Toplantı işleniyor…")
        }

        Button("Ayarlar…", systemImage: "gearshape") {
            // Menü çubuğu uygulaması: pencere öne gelsin diye önce uygulama etkinleştirilir.
            NSApplication.shared.activate()
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("Kurulum…", systemImage: "wand.and.stars") {
            onboarding.show()
        }

        if model.liveEngine == .whisperKit {
            switch model.modelStatus {
            case .loading:
                Divider()
                Text("Model hazırlanıyor… İlk açılışta birkaç dakika sürebilir.")
            case .ready:
                EmptyView()
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
