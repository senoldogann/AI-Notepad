import AINotepadCore
import Foundation
import os

/// iPhone ayar anahtarları; adlar Mac'tekilerle aynıdır (eşitleme aşamasında ortaklaşır).
enum PhoneSettingsKey {
    static let primaryMeetingLanguage: String = "language.primary"
    static let userName: String = "userName"
    /// Kayıt başında "katılımcılara haber ver" kartı.
    static let consentReminder: String = "consentReminder"
    /// Ses dosyalarının saklama süresi (gün).
    static let audioRetentionDays: String = "audioRetentionDays"
}

/// iPhone ayarlarının varsayılanları (Mac'tekilerle aynı).
func registerPhoneDefaults() {
    UserDefaults.standard.register(defaults: [
        PhoneSettingsKey.consentReminder: true,
        PhoneSettingsKey.audioRetentionDays: 30,
        PhoneSettingsKey.primaryMeetingLanguage: MeetingLanguage.finnish.rawValue,
    ])
}

private let phoneSettingsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneSettings")

/// Ana toplantı dili (otomatik modda Deepgram bununla başlar); kayıtlı değer yoksa Fince, tanınmıyorsa Fince ve hata loglanır.
func phonePrimaryMeetingLanguage() -> MeetingLanguage {
    let stored: String = UserDefaults.standard.string(forKey: PhoneSettingsKey.primaryMeetingLanguage) ?? MeetingLanguage.finnish.rawValue
    guard let language = MeetingLanguage(rawValue: stored) else {
        phoneSettingsLogger.error("Ana toplantı dili tanınmadı, değer: \(stored, privacy: .public)")
        return .finnish
    }
    return language
}

/// Kullanıcının adı (notta "senin görevlerin" ayrımı için); yoksa boş.
func phoneUserName() -> String {
    UserDefaults.standard.string(forKey: PhoneSettingsKey.userName) ?? ""
}

/// Telefonda not ve çeviri Claude ile yazılır; modeller Mac'in varsayılanlarıdır (Haiku: çeviri düşük, not yüksek effort).
func phoneLLMProvider() async throws -> LLMProvider {
    .anthropic(AnthropicConfig(
        apiKey: try await readSecretInBackground(service: keychainService, account: .anthropic),
        fastModel: .haiku, smartModel: .haiku, fastEffort: .low, smartEffort: .high
    ))
}
