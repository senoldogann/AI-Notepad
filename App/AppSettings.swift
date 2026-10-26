import AINotepadCore
import AINotepadUI
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
    static let recordShortcut: String = "shortcut.record"
    static let windowsShortcut: String = "shortcut.windows"
    static let onboardingCompleted: String = "onboardingCompleted"
    /// "Sen" (mikrofon) kapalı mı.
    static let micMuted: String = "micMuted"
}

/// Ayar aralıkları.
enum SettingsRange {
    static let missedWindowMinutes: ClosedRange<Int> = 1...10
    static let audioRetentionDays: ClosedRange<Int> = 7...365
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
        SettingsKey.onboardingCompleted: false,
        SettingsKey.micMuted: false,
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
        return .anthropic(apiKey: try await readSecretInBackground(service: keychainService, account: .anthropic))
    case .openAICompatible:
        let defaults: UserDefaults = UserDefaults.standard
        return .openAICompatible(try openAICompatibleConfig(
            baseURLText: defaults.string(forKey: SettingsKey.llmBaseURL) ?? "",
            apiKey: try await optionalSecretInBackground(service: keychainService, account: .openai),
            fastModel: defaults.string(forKey: SettingsKey.llmFastModel) ?? "",
            smartModel: defaults.string(forKey: SettingsKey.llmSmartModel) ?? ""
        ))
    }
}
