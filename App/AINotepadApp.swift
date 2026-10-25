import AINotepadCore
import SwiftUI

/// Menü çubuğunda çalışan uygulamanın giriş noktası.
@main
struct AINotepadApp: App {
    @State private var model: AppModel
    @State private var panel: LivePanelController

    init() {
        let model: AppModel = AppModel()
        _model = State(initialValue: model)
        // Varsayılan: gizli. Kullanıcı menüden değiştirince UserDefaults'a yazılır.
        UserDefaults.standard.register(defaults: [hideFromScreenCaptureKey: true])
        _panel = State(initialValue: LivePanelController(
            model: model,
            hideFromCapture: UserDefaults.standard.bool(forKey: hideFromScreenCaptureKey)
        ))
        Task { await model.loadModel() }
    }

    var body: some Scene {
        MenuBarExtra("AI-Notepad", systemImage: model.isRecording ? "record.circle" : "waveform") {
            MenuContent(model: model, panel: panel)
        }
    }
}

/// Menü çubuğu menüsü.
private struct MenuContent: View {
    @Bindable var model: AppModel
    let panel: LivePanelController
    @AppStorage(hideFromScreenCaptureKey) private var hideFromCapture: Bool = true

    var body: some View {
        if model.isRecording {
            Button("Kaydı durdur") {
                model.stopRecording()
            }
        } else {
            Button("Kaydı başlat") {
                Task {
                    await model.startRecording()
                    panel.show()
                }
            }
            .disabled(model.modelStatus != .ready || model.isStarting)
        }

        Picker("Dil", selection: $model.languageMode) {
            Text("Otomatik").tag(LanguageMode.automatic)
            Text("Fince").tag(LanguageMode.fixed(.finnish))
            Text("İngilizce").tag(LanguageMode.fixed(.english))
        }
        .disabled(model.isRecording)

        Button("Paneli göster") {
            panel.show()
        }

        Toggle("Ekran görüntülerinde ve kayıtlarda gizle", isOn: $hideFromCapture)
            .onChange(of: hideFromCapture) { (_: Bool, newValue: Bool) in
                panel.setHideFromCapture(hidden: newValue)
            }

        Divider()
        switch model.modelStatus {
        case .loading:
            Text("Model hazırlanıyor… İlk açılışta indirme ve derleme birkaç dakika sürebilir.")
        case .ready:
            EmptyView()
        case .failed(let message):
            Text(message)
            Button("Modeli yeniden yükle") {
                Task { await model.loadModel() }
            }
        }
        Button("Çık") {
            NSApplication.shared.terminate(nil)
        }
    }
}
