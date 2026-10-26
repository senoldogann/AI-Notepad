import AINotepadCore
import SwiftUI

/// Menü çubuğunda çalışan uygulamanın giriş noktası.
@main
struct AINotepadApp: App {
    @State private var model: AppModel
    @State private var panel: LivePanelController
    @State private var island: IslandController
    @State private var hotKeys: HotKeyCenter

    init() {
        UserDefaults.standard.register(defaults: [liveEngineKey: LiveEngine.deepgram.rawValue])
        let engine: LiveEngine = LiveEngine(rawValue: UserDefaults.standard.string(forKey: liveEngineKey) ?? "") ?? .deepgram
        let model: AppModel = AppModel(liveEngine: engine)
        _model = State(initialValue: model)
        // Varsayılan: gizli. Kullanıcı menüden değiştirince UserDefaults'a yazılır.
        UserDefaults.standard.register(defaults: [hideFromScreenCaptureKey: true])
        let hideFromCapture: Bool = UserDefaults.standard.bool(forKey: hideFromScreenCaptureKey)
        let panel: LivePanelController = LivePanelController(model: model, hideFromCapture: hideFromCapture)
        _panel = State(initialValue: panel)
        let island: IslandController = IslandController(model: model, onTap: { panel.toggle() })
        _island = State(initialValue: island)
        let hotKeys: HotKeyCenter = HotKeyCenter()
        _hotKeys = State(initialValue: hotKeys)
        // Pencereler ve kısayollar uygulama açıldıktan sonra kurulur.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                island.install(hideFromCapture: hideFromCapture)
                registerShortcuts(hotKeys: hotKeys, model: model, panel: panel, island: island)
            }
        }
        // WhisperKit modeli yalnızca o motor seçiliyse yüklenir.
        if engine == .whisperKit {
            Task { await model.loadModel() }
        }
    }

    var body: some Scene {
        MenuBarExtra("AI-Notepad", systemImage: model.isRecording ? "record.circle" : "waveform") {
            MenuContent(model: model, panel: panel, island: island)
        }
        Settings {
            SettingsView(model: model)
        }
    }
}

/// ⌃⌥R kayıt başlat/durdur, ⌃⌥Space ada + paneli göster/gizle. Hata menüde gösterilir.
@MainActor
private func registerShortcuts(hotKeys: HotKeyCenter, model: AppModel, panel: LivePanelController, island: IslandController) {
    do {
        try hotKeys.register(keyCode: Shortcut.record, modifiers: Shortcut.modifiers) {
            Task {
                await model.toggleRecording()
                if model.isRecording {
                    panel.show()
                }
            }
        }
        try hotKeys.register(keyCode: Shortcut.toggleWindows, modifiers: Shortcut.modifiers) {
            // Ada penceresi kayıt yokken saydam olarak hep açıktır; karar panelin durumuna göre verilir.
            if panel.isVisible {
                panel.hide()
                island.hide()
            } else {
                panel.show()
                island.show()
            }
        }
    } catch {
        model.shortcutError = "Kısayol kaydedilemedi (\(error)). Başka bir uygulama ⌃⌥R ya da ⌃⌥Space kullanıyor olabilir."
    }
}

/// Menü çubuğu menüsü.
private struct MenuContent: View {
    @Bindable var model: AppModel
    let panel: LivePanelController
    let island: IslandController
    @AppStorage(hideFromScreenCaptureKey) private var hideFromCapture: Bool = true
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.isRecording {
            Button("Kaydı durdur", systemImage: "stop.circle") {
                model.stopRecording()
            }
            .keyboardShortcut("r", modifiers: [.control, .option])
        } else {
            Button("Kaydı başlat", systemImage: "record.circle") {
                Task {
                    await model.startRecording()
                    panel.show()
                }
            }
            .disabled(!model.isReadyToRecord || model.isStarting)
            .keyboardShortcut("r", modifiers: [.control, .option])
        }

        Button("Paneli göster / gizle", systemImage: "rectangle.on.rectangle") {
            panel.toggle()
        }
        .keyboardShortcut(.space, modifiers: [.control, .option])

        if let shortcutError = model.shortcutError {
            Text(shortcutError)
        }

        Divider()

        Picker("Dil", systemImage: "globe", selection: $model.languageMode) {
            Text("Otomatik").tag(LanguageMode.automatic)
            Text("Fince").tag(LanguageMode.fixed(.finnish))
            Text("İngilizce").tag(LanguageMode.fixed(.english))
        }
        .disabled(model.isRecording)

        Toggle("Ekran görüntülerinde gizle", systemImage: "eye.slash", isOn: $hideFromCapture)
            .onChange(of: hideFromCapture) { (_: Bool, newValue: Bool) in
                panel.setHideFromCapture(hidden: newValue)
                island.setHideFromCapture(hidden: newValue)
            }

        Button("Ayarlar…", systemImage: "gearshape") {
            // Menü çubuğu uygulaması: pencere öne gelsin diye önce uygulama etkinleştirilir.
            NSApplication.shared.activate()
            openSettings()
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
                Text(message)
                Button("Modeli yeniden yükle", systemImage: "arrow.clockwise") {
                    Task { await model.loadModel() }
                }
            }
        }

        Divider()
        Button("Çık", systemImage: "power") {
            NSApplication.shared.terminate(nil)
        }
    }
}
