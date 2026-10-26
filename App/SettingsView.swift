import AINotepadCore
import AINotepadUI
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Ayarlar: genel, LLM sağlayıcısı, bulut anahtarları ve kısayollar.
struct SettingsView: View {
    let model: AppModel
    let shortcuts: ShortcutController

    var body: some View {
        TabView {
            Tab("Genel", systemImage: "gearshape") {
                GeneralSettings(model: model)
            }
            Tab("LLM", systemImage: "sparkles") {
                LLMSettings(model: model)
            }
            Tab("Anahtarlar", systemImage: "key") {
                KeySettings(model: model)
            }
            Tab("Kısayollar", systemImage: "command") {
                ShortcutSettings(shortcuts: shortcuts)
            }
        }
        .frame(width: 520)
    }
}

/// Motor, ad, görünüm, "Ne kaçırdım?" süresi ve ses saklama süresi.
private struct GeneralSettings: View {
    let model: AppModel
    @AppStorage(SettingsKey.userName) private var userName: String = ""
    @AppStorage(SettingsKey.missedWindowMinutes) private var missedMinutes: Int = 3
    @AppStorage(SettingsKey.audioRetentionDays) private var retentionDays: Int = 30

    var body: some View {
        Form {
            Section("Canlı metin") {
                Picker("Motor", selection: Binding<LiveEngine>(
                    get: { model.liveEngine },
                    set: { (engine: LiveEngine) -> Void in
                        Task { await model.selectEngine(engine: engine) }
                    }
                )) {
                    Text("Deepgram (bulut, ~1 sn)").tag(LiveEngine.deepgram)
                    Text("Mac'te (WhisperKit, internetsiz)").tag(LiveEngine.whisperKit)
                }
                .disabled(model.isRecording)
                Text(model.liveEngine == .deepgram
                    ? "Konuşmacılar ElevenLabs ile dakikada bir ayrılır; kayıt bitince ElevenLabs son geçişi yapılır."
                    : "Ses Mac'ten çıkmaz; kayıt bitince konuşmacılar Mac'te (SpeakerKit) ayrılır. Not için LLM gerekir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Sen") {
                TextField("Adın", text: $userName)
                Text("Toplantı notunda sana düşen görevleri ayırmak için kullanılır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Türkçe çeviri") {
                Picker("Görünüm", selection: Binding<DisplayMode>(
                    get: { model.displayMode },
                    set: { (mode: DisplayMode) -> Void in model.selectDisplayMode(mode: mode) }
                )) {
                    Text("İki dil (orijinal + Türkçe)").tag(DisplayMode.bilingual)
                    Text("Sadece Türkçe").tag(DisplayMode.turkishOnly)
                }
            }
            Section("Asistan") {
                Stepper(value: $missedMinutes, in: SettingsRange.missedWindowMinutes) {
                    Text("\"Ne kaçırdım?\" son \(missedMinutes) dakikayı özetler")
                }
            }
            Section("Ses kayıtları") {
                Picker("Sesleri sakla", selection: $retentionDays) {
                    ForEach([7, 14, 30, 60, 90, 180, 365], id: \.self) { (days: Int) in
                        Text("\(days) gün").tag(days)
                    }
                }
                .onChange(of: retentionDays) { (_: Int, _: Int) in
                    model.applyRetention()
                }
                Text("Süre dolunca ses dosyaları silinir; metin ve not kalır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// LLM sağlayıcısı: Anthropic ya da OpenAI uyumlu (OpenAI, Ollama, OpenCode Go…).
private struct LLMSettings: View {
    let model: AppModel
    @AppStorage(SettingsKey.llmProvider) private var provider: String = LLMProviderKind.anthropic.rawValue
    @AppStorage(SettingsKey.llmBaseURL) private var baseURL: String = ""
    @AppStorage(SettingsKey.llmFastModel) private var fastModel: String = ""
    @AppStorage(SettingsKey.llmSmartModel) private var smartModel: String = ""
    @State private var testResult: ConnectionTest = .idle

    var body: some View {
        Form {
            Section("Sağlayıcı") {
                Picker("LLM", selection: $provider) {
                    Text("Anthropic (Claude)").tag(LLMProviderKind.anthropic.rawValue)
                    Text("OpenAI uyumlu (OpenAI, Ollama, OpenCode Go…)").tag(LLMProviderKind.openAICompatible.rawValue)
                }
                if provider == LLMProviderKind.anthropic.rawValue {
                    Text("Çeviri: Claude Haiku 5.5 · Özet, soru ve not: Claude Opus 5.5")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecretField(title: "Anthropic anahtarı", account: .anthropic, onChange: model.settingsChanged)
                } else {
                    TextField("Temel adres", text: $baseURL, prompt: Text("http://localhost:11434/v1"))
                    TextField("Çeviri modeli (hızlı)", text: $fastModel, prompt: Text("ör. gpt-5-mini, qwen3:8b"))
                    TextField("Özet ve not modeli", text: $smartModel, prompt: Text("ör. gpt-5, gpt-oss:120b"))
                    SecretField(title: "Anahtar (Ollama'da gerekmez)", account: .openai, onChange: model.settingsChanged)
                }
            }
            Section {
                HStack {
                    Button("Bağlantıyı dene") {
                        testResult = .running
                        Task { testResult = await testConnection() }
                    }
                    .disabled(testResult == .running)
                    switch testResult {
                    case .idle:
                        EmptyView()
                    case .running:
                        ProgressView().controlSize(.small)
                    case .succeeded(let reply):
                        Label("Çalışıyor: \(reply)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
                    case .failed(let message):
                        Text(message).foregroundStyle(.red).font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: provider) { (_: String, _: String) in settingsEdited() }
        .onChange(of: baseURL) { (_: String, _: String) in settingsEdited() }
        .onChange(of: fastModel) { (_: String, _: String) in settingsEdited() }
        .onChange(of: smartModel) { (_: String, _: String) in settingsEdited() }
    }

    private func settingsEdited() {
        testResult = .idle
        model.settingsChanged()
    }
}

private enum ConnectionTest: Equatable {
    case idle
    case running
    case succeeded(String)
    case failed(String)
}

/// Seçili sağlayıcıya kısa bir çeviri isteği gönderir.
@MainActor
private func testConnection() async -> ConnectionTest {
    do {
        let reply: String = try await sendLLM(
            provider: try await resolveLLMProvider(),
            request: translationRequest(sentence: "Hyvää huomenta.", context: [])
        )
        return .succeeded(reply)
    } catch {
        return .failed(userFacingMessage(error: error))
    }
}

/// Bulut konuşma tanıma anahtarları.
private struct KeySettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Bulut konuşma tanıma") {
                SecretField(title: "Deepgram", account: .deepgram, onChange: model.settingsChanged)
                SecretField(title: "ElevenLabs", account: .elevenlabs, onChange: model.settingsChanged)
            }
            Section {
                Text("Anahtarlar macOS Anahtar Zinciri'nde saklanır ve hiçbir zaman gösterilmez. Terminal'den eklediysen ilk kullanımda çıkan izin penceresinde \"Her Zaman İzin Ver\"i seç.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Kısayolları değiştirme.
private struct ShortcutSettings: View {
    let shortcuts: ShortcutController

    var body: some View {
        Form {
            Section("Global kısayollar") {
                ForEach(ShortcutAction.allCases, id: \.self) { (action: ShortcutAction) in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(action.title) {
                            ShortcutRecorder(binding: shortcuts.currentBinding(action: action)) { (binding: KeyBinding) -> Void in
                                shortcuts.change(action: action, binding: binding)
                            }
                        }
                        if let error = shortcuts.errors[action] {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            Section {
                Text("Kısayola tıklayıp yeni tuşlara bas; vazgeçmek için Esc. ⌃, ⌥ ya da ⌘ ile birlikte bir harf ya da rakam seç.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Tıklanınca bir sonraki tuş bileşimini kaydeden düğme.
private struct ShortcutRecorder: View {
    let binding: KeyBinding
    let onRecord: @MainActor (KeyBinding) -> Void
    @State private var isRecording: Bool = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? "Tuşlara bas…" : keyBindingDisplay(binding: binding))
                .monospaced()
                .frame(minWidth: 110)
        }
        .accessibilityLabel(isRecording ? "Kısayol kaydediliyor" : "Kısayol: \(keyBindingDisplay(binding: binding)). Değiştir")
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { (event: NSEvent) -> NSEvent? in
            MainActor.assumeIsolated {
                if event.keyCode == UInt16(kVK_Escape) {
                    stop()
                } else {
                    onRecord(KeyBinding(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers(flags: event.modifierFlags)))
                    stop()
                }
            }
            // Tuş başka bir yere yazılmasın.
            return nil
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }
}

/// AppKit değiştiricilerini Carbon maskesine çevirir. Saf fonksiyondur.
func carbonModifiers(flags: NSEvent.ModifierFlags) -> UInt32 {
    var modifiers: UInt32 = 0
    if flags.contains(.control) { modifiers |= CarbonModifier.control }
    if flags.contains(.option) { modifiers |= CarbonModifier.option }
    if flags.contains(.shift) { modifiers |= CarbonModifier.shift }
    if flags.contains(.command) { modifiers |= CarbonModifier.command }
    return modifiers
}
