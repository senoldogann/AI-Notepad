import AINotepadCore
import AINotepadUI
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Ayarlar bölümleri.
private enum SettingsSection: CaseIterable {
    case general
    case appearance
    case llm
    case keys
    case shortcuts

    var title: LocalizedStringKey {
        switch self {
        case .general: "Genel"
        case .appearance: "Görünüm"
        case .llm: "LLM"
        case .keys: "Anahtarlar"
        case .shortcuts: "Kısayollar"
        }
    }
}

/// Panelin Ayarlar sayfası (ayrı pencere değil): genel, LLM sağlayıcısı, bulut anahtarları ve kısayollar.
struct SettingsPage: View {
    let model: AppModel
    let shortcuts: ShortcutController
    @State private var section: SettingsSection = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("Bölüm", selection: $section) {
                ForEach(SettingsSection.allCases, id: \.self) { (item: SettingsSection) in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DesignTokens.Spacing.l)
            .padding(.top, DesignTokens.Spacing.m)
            Group {
                switch section {
                case .general: GeneralSettings(model: model)
                case .appearance: AppearanceSettings()
                case .llm: LLMSettings(model: model)
                case .keys: KeySettings(model: model)
                case .shortcuts: ShortcutSettings(shortcuts: shortcuts)
                }
            }
            // Cam yüzey görünsün.
            .scrollContentBackground(.hidden)
        }
    }
}

/// Motor, ad, görünüm, "Ne kaçırdım?" süresi ve ses saklama süresi.
private struct GeneralSettings: View {
    let model: AppModel
    @AppStorage(SettingsKey.userName) private var userName: String = ""
    @AppStorage(SettingsKey.missedWindowMinutes) private var missedMinutes: Int = 3
    @AppStorage(SettingsKey.audioRetentionDays) private var retentionDays: Int = 30
    @State private var interfaceLanguage: InterfaceLanguage = storedInterfaceLanguage()
    /// Açılışta geçerli olan dil; farklı seçilince yeniden başlatma önerilir.
    @State private var launchedLanguage: InterfaceLanguage = storedInterfaceLanguage()

    var body: some View {
        Form {
            Section("Arayüz dili") {
                Picker("Dil", selection: $interfaceLanguage) {
                    Text("Sistem").tag(InterfaceLanguage.system)
                    Text(verbatim: "Türkçe").tag(InterfaceLanguage.turkish)
                    Text(verbatim: "English").tag(InterfaceLanguage.english)
                }
                .onChange(of: interfaceLanguage) { (_: InterfaceLanguage, language: InterfaceLanguage) in
                    storeInterfaceLanguage(language: language)
                }
                if interfaceLanguage != launchedLanguage {
                    HStack {
                        Text("Yeniden başlatınca uygulanır.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Şimdi yeniden başlat") {
                            relaunchApplication()
                        }
                        .disabled(model.phase != .idle)
                        .hoverHint(model.phase != .idle ? "Kayıt bitince yeniden başlatılabilir" : "Uygulamayı yeni dille yeniden açar", alignment: .trailing, edge: .bottom)
                    }
                }
                Text("Toplantı notları ve canlı çeviri her zaman Türkçedir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                Picker("Gösterim", selection: Binding<DisplayMode>(
                    get: { model.displayMode },
                    set: { (mode: DisplayMode) -> Void in model.selectDisplayMode(mode: mode) }
                )) {
                    Text("İki dil (orijinal + Türkçe)").tag(DisplayMode.bilingual)
                    Text("Sadece Türkçe").tag(DisplayMode.turkishOnly)
                    Text("Sadece orijinal (Fince/İngilizce)").tag(DisplayMode.originalOnly)
                }
                Text(model.displayMode == .originalOnly
                    ? "Canlı çeviri yapılmaz; toplantı bitince Türkçe not (görevler, kararlar, özet) yine hazırlanır."
                    : "Toplantı bitince Türkçe not (görevler, kararlar, özet) hazırlanır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Mikrofon") {
                Toggle("Mikrofonu kaydet (Sen)", isOn: Binding<Bool>(
                    get: { !model.isMicMuted },
                    set: { (enabled: Bool) -> Void in
                        if enabled == model.isMicMuted {
                            model.toggleMicrophone()
                        }
                    }
                ))
                Text("Konuşmayıp yalnızca dinlediğin toplantılarda kapat: hoparlörden gelen ses \"Sen\" olarak yazılmaz. Panelden kayıt sırasında da değiştirilebilir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

/// Görünüm: tema, vurgu rengi, panel arka planı, yazı tipi, metin boyutu, satır aralığı, alt boşluk, ada.
/// Değişiklikler panelde anında görünür.
private struct AppearanceSettings: View {
    @AppStorage(SettingsKey.theme) private var theme: String = AppTheme.system.rawValue
    @AppStorage(SettingsKey.accent) private var accent: String = PanelAppearance.standard.accent.rawValue
    @AppStorage(SettingsKey.panelBackground) private var background: String = PanelAppearance.standard.background.rawValue
    @AppStorage(SettingsKey.fontDesign) private var fontDesign: String = PanelAppearance.standard.fontDesign.rawValue
    @AppStorage(SettingsKey.textSize) private var textSize: Double = PanelAppearance.standard.textSize
    @AppStorage(SettingsKey.lineSpacing) private var lineSpacing: Double = PanelAppearance.standard.lineSpacing
    @AppStorage(SettingsKey.bottomSpacing) private var bottomSpacing: Double = PanelAppearance.standard.bottomSpacing
    @AppStorage(SettingsKey.islandEnabled) private var islandEnabled: Bool = true
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        Form {
            Section("Renkler") {
                Picker("Tema", selection: $theme) {
                    Text("Sistem").tag(AppTheme.system.rawValue)
                    Text("Açık").tag(AppTheme.light.rawValue)
                    Text("Koyu").tag(AppTheme.dark.rawValue)
                }
                .pickerStyle(.segmented)
                Picker("Vurgu rengi", selection: $accent) {
                    ForEach(PanelAccent.allCases, id: \.self) { (item: PanelAccent) in
                        Label(accentName(accent: item), systemImage: "circle.fill")
                            .foregroundStyle(item.color)
                            .tag(item.rawValue)
                    }
                }
                Picker("Panel arka planı", selection: $background) {
                    Text("Cam").tag(PanelBackground.glass.rawValue)
                    Text("Koyu cam (hareketli arka planda okunaklı)").tag(PanelBackground.tintedGlass.rawValue)
                    Text("Opak").tag(PanelBackground.solid.rawValue)
                }
            }
            Section("Metin") {
                Picker("Yazı tipi", selection: $fontDesign) {
                    Text("Sistem (SF Pro)").tag(PanelFontDesign.system.rawValue)
                    Text("Yuvarlak (SF Rounded)").tag(PanelFontDesign.rounded.rawValue)
                    Text("Tırnaklı (New York)").tag(PanelFontDesign.serif.rawValue)
                    Text("Eş aralıklı (SF Mono)").tag(PanelFontDesign.monospaced.rawValue)
                }
                LabeledContent("Metin boyutu: \(Int(textSize)) pt") {
                    Slider(value: $textSize, in: SettingsRange.textSize, step: 1)
                }
                LabeledContent("Satır aralığı: \(Int(lineSpacing))") {
                    Slider(value: $lineSpacing, in: SettingsRange.lineSpacing, step: 1)
                }
                LabeledContent("Alt boşluk: \(Int(bottomSpacing)) pt") {
                    Slider(value: $bottomSpacing, in: SettingsRange.bottomSpacing, step: 4)
                }
                // Önizleme seçilen yazı tipi ve boyutla.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hyvää huomenta kaikille, aloitetaan palaveri.")
                        .font(appearance.secondaryFont)
                        .opacity(0.6)
                    Text("Herkese günaydın, toplantıya başlayalım.")
                        .font(appearance.bodyFont)
                }
                .lineSpacing(appearance.lineSpacing)
            }
            Section("Ada") {
                Toggle("Kayıt sırasında çentikte adayı göster", isOn: $islandEnabled)
            }
            Section {
                Button("Görünümü varsayılana döndür") {
                    resetAppearanceSettings(defaults: UserDefaults.standard)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Vurgu renginin adı.
private func accentName(accent: PanelAccent) -> String {
    switch accent {
    case .blue: String(localized: "Mavi")
    case .green: String(localized: "Yeşil")
    case .purple: String(localized: "Mor")
    case .orange: String(localized: "Turuncu")
    case .pink: String(localized: "Pembe")
    }
}

/// LLM sağlayıcısı: Anthropic ya da OpenAI uyumlu (OpenAI, Ollama, OpenCode Go…).
private struct LLMSettings: View {
    let model: AppModel
    @AppStorage(SettingsKey.llmProvider) private var provider: String = LLMProviderKind.anthropic.rawValue
    @AppStorage(SettingsKey.llmBaseURL) private var baseURL: String = ""
    @AppStorage(SettingsKey.llmFastModel) private var fastModel: String = ""
    @AppStorage(SettingsKey.llmSmartModel) private var smartModel: String = ""
    @AppStorage(SettingsKey.llmFastEffort) private var openAIFastEffort: String = ""
    @AppStorage(SettingsKey.llmSmartEffort) private var openAISmartEffort: String = ""
    @AppStorage(SettingsKey.claudeFastModel) private var claudeFastModel: String = ClaudeModel.haiku.rawValue
    @AppStorage(SettingsKey.claudeSmartModel) private var claudeSmartModel: String = ClaudeModel.opus.rawValue
    @AppStorage(SettingsKey.claudeFastEffort) private var claudeFastEffort: String = LLMEffort.low.rawValue
    @AppStorage(SettingsKey.claudeSmartEffort) private var claudeSmartEffort: String = LLMEffort.medium.rawValue
    @State private var testResult: ConnectionTest = .idle

    var body: some View {
        Form {
            Section("Sağlayıcı") {
                Picker("LLM", selection: $provider) {
                    Text("Anthropic (Claude)").tag(LLMProviderKind.anthropic.rawValue)
                    Text("OpenAI uyumlu (OpenAI, Ollama, OpenCode Go…)").tag(LLMProviderKind.openAICompatible.rawValue)
                }
                if provider == LLMProviderKind.anthropic.rawValue {
                    SecretField(title: "Anthropic anahtarı", account: .anthropic, onChange: model.settingsChanged)
                } else {
                    TextField("Temel adres", text: $baseURL, prompt: Text("http://localhost:11434/v1"))
                    SecretField(title: "Anahtar (Ollama'da gerekmez)", account: .openai, onChange: model.settingsChanged)
                }
            }
            if provider == LLMProviderKind.anthropic.rawValue {
                Section {
                    ClaudeModelPicker(selection: $claudeFastModel)
                    EffortPicker(selection: $claudeFastEffort, allowsNone: false)
                } header: {
                    Text("Canlı çeviri")
                } footer: {
                    Text("Hızlı model ve düşük effort önerilir: çeviri 1–2 sn'de gelir. Haiku ve Sonnet'te düşünme bu görevde kapatılır.")
                }
                Section {
                    ClaudeModelPicker(selection: $claudeSmartModel)
                    EffortPicker(selection: $claudeSmartEffort, allowsNone: false)
                } header: {
                    Text("\"Ne kaçırdım?\", soru ve toplantı notu")
                } footer: {
                    Text("Daha yüksek effort daha dikkatli ama daha yavaş ve pahalı sonuç verir.")
                }
            } else {
                Section {
                    TextField("Model", text: $fastModel, prompt: Text("ör. gpt-5-mini, qwen3:8b"))
                    EffortPicker(selection: $openAIFastEffort, allowsNone: true)
                } header: {
                    Text("Canlı çeviri")
                }
                Section {
                    TextField("Model", text: $smartModel, prompt: Text("ör. gpt-5, gpt-oss:120b"))
                    EffortPicker(selection: $openAISmartEffort, allowsNone: true)
                } header: {
                    Text("\"Ne kaçırdım?\", soru ve toplantı notu")
                } footer: {
                    Text("Effort `reasoning_effort` olarak gönderilir; desteklemeyen sunucularda \"Gönderme\"yi seç.")
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
        // Yazarken her tuşta Keychain denetlenmesin: son değişiklikten 0,6 sn sonra bir kez.
        .task(id: [provider, baseURL, fastModel, smartModel, openAIFastEffort, openAISmartEffort, claudeFastModel, claudeSmartModel, claudeFastEffort, claudeSmartEffort]) {
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                // Yeni bir değişiklik geldi; bu bekleme iptal edildi.
                return
            }
            testResult = .idle
            model.settingsChanged()
        }
    }
}

/// Claude modeli seçimi (ad, kısa nitelik).
private struct ClaudeModelPicker: View {
    @Binding var selection: String

    var body: some View {
        Picker("Model", selection: $selection) {
            Text("Claude Haiku 5.5 — en hızlı, en ucuz").tag(ClaudeModel.haiku.rawValue)
            Text("Claude Sonnet 5.5 — dengeli").tag(ClaudeModel.sonnet.rawValue)
            Text("Claude Opus 5.5 — güçlü").tag(ClaudeModel.opus.rawValue)
            Text("Claude Fable 5.1 — en yetenekli, en pahalı").tag(ClaudeModel.fable.rawValue)
        }
    }
}

/// Effort seçimi; OpenAI uyumlu sağlayıcıda "Gönderme" (boş) ve yalnızca low/medium/high.
private struct EffortPicker: View {
    @Binding var selection: String
    let allowsNone: Bool

    var body: some View {
        Picker("Effort", selection: $selection) {
            if allowsNone {
                Text("Gönderme").tag("")
            }
            Text("Düşük").tag(LLMEffort.low.rawValue)
            Text("Orta").tag(LLMEffort.medium.rawValue)
            Text("Yüksek").tag(LLMEffort.high.rawValue)
            if !allowsNone {
                Text("Çok yüksek").tag(LLMEffort.xhigh.rawValue)
                Text("En yüksek").tag(LLMEffort.max.rawValue)
            }
        }
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
            Text(isRecording ? String(localized: "Tuşlara bas…") : keyBindingDisplay(binding: binding))
                .monospaced()
                .frame(minWidth: 110)
        }
        .accessibilityLabel(isRecording ? String(localized: "Kısayol kaydediliyor") : String(localized: "Kısayol: \(keyBindingDisplay(binding: binding)). Değiştir"))
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
