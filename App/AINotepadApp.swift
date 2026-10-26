import AINotepadCore
import os
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

private let shortcutLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Shortcuts")

/// Kaydı başlatır (paneli ve gizlenmiş adayı da gösterir) ya da durdurur. Menü ve ⌃⌥R aynı yolu kullanır.
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

/// ⌃⌥R kayıt başlat/durdur, ⌃⌥P ada + paneli göster/gizle. Her kısayolun hatası ayrı ve adıyla menüde gösterilir.
@MainActor
private func registerShortcuts(hotKeys: HotKeyCenter, model: AppModel, panel: LivePanelController, island: IslandController) {
    let shortcuts: [(name: String, keyCode: UInt32, action: @MainActor () -> Void)] = [
        ("⌃⌥R", Shortcut.record, { Task { await toggleRecordingFlow(model: model, panel: panel, island: island) } }),
        ("⌃⌥P", Shortcut.toggleWindows, { toggleWindows(panel: panel, island: island) }),
    ]
    var failures: [String] = []
    for shortcut in shortcuts {
        do {
            try hotKeys.register(keyCode: shortcut.keyCode, modifiers: Shortcut.modifiers, action: shortcut.action)
        } catch HotKeyError.conflictsWithSystemShortcut {
            shortcutLogger.error("Kısayol sistem kısayoluyla çakışıyor: \(shortcut.name, privacy: .public)")
            failures.append("\(shortcut.name) bir macOS sistem kısayolu")
        } catch {
            shortcutLogger.error("Kısayol kaydedilemedi: \(shortcut.name, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            failures.append("\(shortcut.name) başka bir uygulamada kullanılıyor")
        }
    }
    model.shortcutError = failures.isEmpty ? nil : "Kısayol çalışmıyor: " + failures.joined(separator: ", ")
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
                Task { await toggleRecordingFlow(model: model, panel: panel, island: island) }
            }
            .disabled(!model.isReadyToRecord || model.isStarting)
            .keyboardShortcut("r", modifiers: [.control, .option])
        }

        Button("Ada ve paneli göster / gizle", systemImage: "rectangle.on.rectangle") {
            toggleWindows(panel: panel, island: island)
        }
        .keyboardShortcut("p", modifiers: [.control, .option])

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
