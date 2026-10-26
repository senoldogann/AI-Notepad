import AINotepadCore
import AINotepadUI
import AppKit
import Foundation
import os

private let settingsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Settings")

/// Canlı metin motoru. Seçim UserDefaults'ta `SettingsKey.liveEngine` ile saklanır.
enum LiveEngine: String, CaseIterable {
    case deepgram
    case whisperKit

    /// Bu motorla kaydedilen toplantının son geçiş türü.
    var recordingEngine: RecordingEngine {
        switch self {
        case .deepgram: .cloud
        case .whisperKit: .local
        }
    }
}

/// UserDefaults anahtarları.
enum SettingsKey {
    static let liveEngine: String = "liveEngine"
    static let displayMode: String = "displayMode"
    /// Kullanıcı adı (not görevlerinde "benim" tespiti için).
    static let userName: String = "userName"
    static let hideFromScreenCapture: String = "hideFromScreenCapture"
    /// "Ne kaçırdım?" penceresi (dakika).
    static let missedWindowMinutes: String = "missedWindowMinutes"
    /// Ses dosyalarının saklama süresi (gün).
    static let audioRetentionDays: String = "audioRetentionDays"
    static let llmProvider: String = "llmProvider"
    static let llmBaseURL: String = "llmBaseURL"
    static let llmFastModel: String = "llmFastModel"
    static let llmSmartModel: String = "llmSmartModel"
    /// OpenAI uyumlu `reasoning_effort` (boş: gönderilmez).
    static let llmFastEffort: String = "llmFastEffort"
    static let llmSmartEffort: String = "llmSmartEffort"
    /// Claude: model sınıfı başına model ve effort.
    static let claudeFastModel: String = "claudeFastModel"
    static let claudeSmartModel: String = "claudeSmartModel"
    static let claudeFastEffort: String = "claudeFastEffort"
    static let claudeSmartEffort: String = "claudeSmartEffort"
    static let recordShortcut: String = "shortcut.record"
    static let windowsShortcut: String = "shortcut.windows"
    static let onboardingCompleted: String = "onboardingCompleted"
    /// "Sen" (mikrofon) kapalı mı.
    static let micMuted: String = "micMuted"
    /// Görünüm.
    static let theme: String = "appearance.theme"
    static let accent: String = "appearance.accent"
    static let panelBackground: String = "appearance.background"
    static let fontDesign: String = "appearance.fontDesign"
    static let textSize: String = "appearance.textSize"
    static let lineSpacing: String = "appearance.lineSpacing"
    static let bottomSpacing: String = "appearance.bottomSpacing"
    static let islandEnabled: String = "appearance.islandEnabled"
}

/// Arayüz dili; macOS'ta uygulama dili yeniden başlatınca uygulanır.
enum InterfaceLanguage: String, CaseIterable {
    case system
    case turkish = "tr"
    case english = "en"
}

/// Uygulamanın kendi tercihinde (`AppleLanguages`) kayıtlı arayüz dili; yoksa sistem.
func storedInterfaceLanguage() -> InterfaceLanguage {
    guard let identifier = Bundle.main.bundleIdentifier,
          let languages = UserDefaults.standard.persistentDomain(forName: identifier)?["AppleLanguages"] as? [String],
          let first = languages.first
    else {
        return .system
    }
    return InterfaceLanguage(rawValue: String(first.prefix(2))) ?? .system
}

/// Arayüz dilini kaydeder: yalnızca bu uygulamanın `AppleLanguages` tercihi değişir.
func storeInterfaceLanguage(language: InterfaceLanguage) {
    switch language {
    case .system:
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    case .turkish, .english:
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }
}

/// Uygulamayı yeniden başlatır (arayüz dili değişince).
@MainActor
func relaunchApplication() {
    let configuration: NSWorkspace.OpenConfiguration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { (_: NSRunningApplication?, error: (any Error)?) -> Void in
        if let error {
            settingsLogger.error("Uygulama yeniden başlatılamadı, hata: \(String(describing: error), privacy: .public)")
            return
        }
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }
}

/// Panelin açık/koyu görünümü.
enum AppTheme: String, CaseIterable {
    case system
    case light
    case dark
}

/// Ayar aralıkları.
enum SettingsRange {
    static let missedWindowMinutes: ClosedRange<Int> = 1...10
    static let audioRetentionDays: ClosedRange<Int> = 7...365
    static let textSize: ClosedRange<Double> = 11...24
    static let lineSpacing: ClosedRange<Double> = 0...12
    static let bottomSpacing: ClosedRange<Double> = 0...160
}

/// Görünüm ayarlarını varsayılana döndürür.
func resetAppearanceSettings(defaults: UserDefaults) {
    for key in [SettingsKey.theme, SettingsKey.accent, SettingsKey.panelBackground, SettingsKey.fontDesign, SettingsKey.textSize,
                SettingsKey.lineSpacing, SettingsKey.bottomSpacing, SettingsKey.islandEnabled] {
        defaults.removeObject(forKey: key)
    }
}

/// Varsayılanları bir kez kaydeder (uygulama açılışında).
func registerDefaultSettings() {
    UserDefaults.standard.register(defaults: [
        SettingsKey.liveEngine: LiveEngine.deepgram.rawValue,
        SettingsKey.displayMode: DisplayMode.bilingual.rawValue,
        SettingsKey.hideFromScreenCapture: true,
        SettingsKey.missedWindowMinutes: 3,
        SettingsKey.audioRetentionDays: 30,
        SettingsKey.llmProvider: LLMProviderKind.anthropic.rawValue,
        SettingsKey.llmBaseURL: "http://localhost:11434/v1",
        SettingsKey.llmFastModel: "",
        SettingsKey.llmSmartModel: "",
        SettingsKey.llmFastEffort: "",
        SettingsKey.llmSmartEffort: "",
        SettingsKey.claudeFastModel: ClaudeModel.haiku.rawValue,
        SettingsKey.claudeSmartModel: ClaudeModel.opus.rawValue,
        SettingsKey.claudeFastEffort: LLMEffort.low.rawValue,
        SettingsKey.claudeSmartEffort: LLMEffort.medium.rawValue,
        SettingsKey.onboardingCompleted: false,
        SettingsKey.micMuted: false,
        SettingsKey.theme: AppTheme.system.rawValue,
        SettingsKey.accent: PanelAppearance.standard.accent.rawValue,
        SettingsKey.panelBackground: PanelAppearance.standard.background.rawValue,
        SettingsKey.fontDesign: PanelAppearance.standard.fontDesign.rawValue,
        SettingsKey.textSize: PanelAppearance.standard.textSize,
        SettingsKey.lineSpacing: PanelAppearance.standard.lineSpacing,
        SettingsKey.bottomSpacing: PanelAppearance.standard.bottomSpacing,
        SettingsKey.islandEnabled: true,
    ])
}

/// Kayıtlı ayarın değeri, aralığa sıkıştırılmış.
func clampedSetting(key: String, range: ClosedRange<Int>) -> Int {
    min(max(UserDefaults.standard.integer(forKey: key), range.lowerBound), range.upperBound)
}

/// Seçili LLM sağlayıcı türü.
func selectedLLMProviderKind() -> LLMProviderKind {
    LLMProviderKind(rawValue: UserDefaults.standard.string(forKey: SettingsKey.llmProvider) ?? "") ?? .anthropic
}

/// Kayıtlı kısayol; yoksa varsayılan.
func storedKeyBinding(key: String, fallback: KeyBinding) -> KeyBinding {
    guard let data = UserDefaults.standard.data(forKey: key) else {
        return fallback
    }
    do {
        return try JSONDecoder().decode(KeyBinding.self, from: data)
    } catch {
        // Bozuk kayıt: varsayılan kullanılır, yeni seçim üzerine yazar.
        settingsLogger.error("Kısayol ayarı okunamadı, anahtar: \(key, privacy: .public), hata: \(String(describing: error), privacy: .public)")
        return fallback
    }
}

/// Kısayolu kaydeder.
func storeKeyBinding(key: String, binding: KeyBinding) throws {
    UserDefaults.standard.set(try JSONEncoder().encode(binding), forKey: key)
}

/// Seçili sağlayıcının yapılandırması: anahtar Keychain'den arka planda okunur. Anthropic anahtarı yoksa
/// `KeychainError.notFound`; OpenAI uyumlu ayar eksikse `LLMError.notConfigured`.
func resolveLLMProvider() async throws -> LLMProvider {
    switch selectedLLMProviderKind() {
    case .anthropic:
        return .anthropic(AnthropicConfig(
            apiKey: try await readSecretInBackground(service: keychainService, account: .anthropic),
            fastModel: storedClaudeModel(key: SettingsKey.claudeFastModel, fallback: .haiku),
            smartModel: storedClaudeModel(key: SettingsKey.claudeSmartModel, fallback: .opus),
            fastEffort: storedEffort(key: SettingsKey.claudeFastEffort) ?? .low,
            smartEffort: storedEffort(key: SettingsKey.claudeSmartEffort) ?? .medium
        ))
    case .openAICompatible:
        return .openAICompatible(try storedOpenAIConfig(apiKey: try await optionalSecretInBackground(service: keychainService, account: .openai)))
    }
}

/// Kayıtlı OpenAI uyumlu ayar; adres ya da model eksikse `LLMError.notConfigured`.
func storedOpenAIConfig(apiKey: String?) throws -> OpenAICompatibleConfig {
    let defaults: UserDefaults = UserDefaults.standard
    return try openAICompatibleConfig(
        baseURLText: defaults.string(forKey: SettingsKey.llmBaseURL) ?? "",
        apiKey: apiKey,
        fastModel: defaults.string(forKey: SettingsKey.llmFastModel) ?? "",
        smartModel: defaults.string(forKey: SettingsKey.llmSmartModel) ?? "",
        fastEffort: storedEffort(key: SettingsKey.llmFastEffort),
        smartEffort: storedEffort(key: SettingsKey.llmSmartEffort)
    )
}

/// Kayıtlı Claude modeli; tanınmayan değerde (eski sürüm) varsayılan.
func storedClaudeModel(key: String, fallback: ClaudeModel) -> ClaudeModel {
    ClaudeModel(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? fallback
}

/// Kayıtlı effort; boş değer "gönderme" demektir (nil).
func storedEffort(key: String) -> LLMEffort? {
    LLMEffort(rawValue: UserDefaults.standard.string(forKey: key) ?? "")
}
