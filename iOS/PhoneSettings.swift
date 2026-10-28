import AINotepadCore
import Foundation
import os

/// iPhone ayar anahtarları; adlar Mac'tekilerle aynıdır. Ayarlar cihazda kalır (iCloud yalnızca toplantıları ve
/// paylaşılan anahtarları eşitler).
enum PhoneSettingsKey {
    static let primaryMeetingLanguage: String = "language.primary"
    /// Not ve çeviri dili (`ShareLanguage`): not, canlı çeviri ve Sor cevapları bu dilde yazılır.
    static let noteLanguage: String = "language.note"
    static let userName: String = "userName"
    /// Kayıt başında "katılımcılara haber ver" kartı.
    static let consentReminder: String = "consentReminder"
    /// Ses dosyalarının saklama süresi (gün).
    static let audioRetentionDays: String = "audioRetentionDays"
    /// İlk açılış karşılaması bitti ya da atlandı.
    static let onboardingCompleted: String = "onboardingCompleted"
    /// Tema takımı (Mac'teki ayarla aynı ad; bkz. `AppTheme`).
    static let theme: String = "appearance.theme"
    /// Takvim (sıradaki toplantılar, kaydı süren etkinliğe bağlama); varsayılan kapalı, açılınca izin istenir.
    static let calendarEnabled: String = "calendar.enabled"
    /// Yazıya dökme ve notun yapıldığı yer (bkz. `PhoneEngine`).
    static let engine: String = "phone.engine"
}

/// iPhone'da yazıya dökme ve not: bulut (kendi anahtarlarınla) ya da cihaz içi (Apple, anahtarsız).
enum PhoneEngine: String, CaseIterable {
    /// Deepgram + ElevenLabs + Claude: konuşmacılar ayrılır, not daha ayrıntılı.
    case cloud
    /// Apple konuşma tanıma + Apple Intelligence: ücretsiz, anahtarsız, internetsiz; konuşmacılar ayrılmaz.
    case onDevice
}

/// iPhone ayarlarının varsayılanları (Mac'tekilerle aynı).
func registerPhoneDefaults() {
    UserDefaults.standard.register(defaults: [
        PhoneSettingsKey.consentReminder: true,
        PhoneSettingsKey.audioRetentionDays: 30,
        PhoneSettingsKey.primaryMeetingLanguage: MeetingLanguage.finnish.rawValue,
        // Mevcut kullanıcılar bulutta kalır; ilk açılışta anahtar yoksa cihaz içi seçilir (`choosePhoneOnDeviceOnFirstRun`).
        PhoneSettingsKey.engine: PhoneEngine.cloud.rawValue,
        // Arayüz dili: Türkçe arayüzde mevcut kullanıcıların notu eskisi gibi Türkçe sürer.
        PhoneSettingsKey.noteLanguage: defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue,
    ])
}

/// Seçili motor; tanınmayan değer bulut sayılır ve hata loglanır.
func phoneEngine() -> PhoneEngine {
    let stored: String = UserDefaults.standard.string(forKey: PhoneSettingsKey.engine) ?? PhoneEngine.cloud.rawValue
    guard let engine = PhoneEngine(rawValue: stored) else {
        phoneSettingsLogger.error("Motor ayarı tanınmadı, değer: \(stored, privacy: .public)")
        return .cloud
    }
    return engine
}

/// İlk açılışta (karşılama bitmemiş, motor hiç seçilmemiş) hiçbir anahtar yoksa ve Apple Intelligence
/// kullanılabiliyorsa cihaz içi mod seçilir: uygulama kurulur kurulmaz anahtarsız çalışır. Anahtarı olan kullanıcıya
/// dokunulmaz. Seçim yapıldıysa true.
func choosePhoneOnDeviceOnFirstRun(defaults: UserDefaults) async -> Bool {
    // Kayıtlı (varsayılan olmayan) değerler yalnız uygulamanın kendi alanında görünür.
    guard let bundleID = Bundle.main.bundleIdentifier else {
        phoneSettingsLogger.error("İlk açılışta paket kimliği yok, cihaz içi mod seçilmedi")
        return false
    }
    guard !defaults.bool(forKey: PhoneSettingsKey.onboardingCompleted), defaults.persistentDomain(forName: bundleID)?[PhoneSettingsKey.engine] == nil else {
        return false
    }
    for account in [SecretAccount.deepgram, .elevenlabs, .anthropic] {
        do {
            if try await Task.detached(operation: { try secretExists(service: keychainService, account: account) }).value {
                return false
            }
        } catch {
            // Anahtar Zinciri okunamadıysa anahtar var sayılır: mevcut kullanıcının ayarı değişmesin.
            phoneSettingsLogger.error("İlk açılışta anahtar denetlenemedi, cihaz içi mod seçilmedi, hesap: \(account.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            return false
        }
    }
    do {
        _ = try onDeviceConfig(outputLanguage: noteOutputLanguage)
    } catch {
        phoneSettingsLogger.info("İlk açılışta cihaz içi model kullanılamıyor, hata: \(String(describing: error), privacy: .public)")
        return false
    }
    defaults.set(PhoneEngine.onDevice.rawValue, forKey: PhoneSettingsKey.engine)
    return true
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

/// Not ve çeviri dili (Ayarlar); kayıtlı değer tanınmıyorsa (loglanır) arayüz dilinin varsayılanı.
func phoneNoteLanguage() -> ShareLanguage {
    phoneStoredNoteLanguage(value: UserDefaults.standard.string(forKey: PhoneSettingsKey.noteLanguage) ?? "")
}

/// Ayarın ham değerinden not dili (görünümlerdeki `@AppStorage(PhoneSettingsKey.noteLanguage)` için: dil değişince
/// etiketler de güncellenir); tanınmıyorsa (loglanır) arayüz dilinin varsayılanı.
func phoneStoredNoteLanguage(value stored: String) -> ShareLanguage {
    guard let language = ShareLanguage(rawValue: stored) else {
        phoneSettingsLogger.error("Not dili tanınmadı, varsayılan kullanılıyor, değer: \(stored, privacy: .public)")
        return defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations)
    }
    return language
}

/// Kullanıcının adı (notta "senin görevlerin" ayrımı için); yoksa boş.
func phoneUserName() -> String {
    UserDefaults.standard.string(forKey: PhoneSettingsKey.userName) ?? ""
}

/// Telefonda not ve çeviri: cihaz içi modda Apple Intelligence; bulutta Claude, modeller Mac'in varsayılanlarıdır
/// (Haiku: çeviri düşük, not yüksek effort).
func phoneLLMProvider() async throws -> LLMProvider {
    switch phoneEngine() {
    case .onDevice:
        return .onDevice(try onDeviceConfig(outputLanguage: noteOutputLanguage))
    case .cloud:
        return .anthropic(AnthropicConfig(
            apiKey: try await readSecretInBackground(service: keychainService, account: .anthropic),
            fastModel: .haiku, smartModel: .haiku, fastEffort: .low, smartEffort: .high
        ))
    }
}
