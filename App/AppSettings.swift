import AINotepadCore
import AINotepadUI
import AppKit
import Foundation
import SwiftUI
import os

private let settingsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Settings")

/// Canlı metin motoru. Seçim UserDefaults'ta `SettingsKey.liveEngine` ile saklanır.
enum LiveEngine: String, CaseIterable {
    case deepgram
    case whisperKit
    /// Apple'ın cihaz içi konuşma tanıması (SpeechAnalyzer): anahtarsız, büyük model indirmesi yok.
    case appleSpeech

    /// Bu motorla kaydedilen toplantının son geçiş türü.
    var recordingEngine: RecordingEngine {
        switch self {
        case .deepgram: .cloud
        case .whisperKit, .appleSpeech: .local
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
    /// Kayıt başlarken katılımcılara haber verme hatırlatması.
    static let consentReminder: String = "consentReminder"
    /// Yeni toplantıların not şablonu (`NoteTemplateKind`) ve kendi şablonunun yönergesi.
    static let noteTemplate: String = "noteTemplate"
    static let customTemplate: String = "customTemplate"
    /// Takvim: yaklaşan toplantılar, 1 dk önce hatırlatma, görüşme başlayınca öneri.
    static let calendarEnabled: String = "calendar.enabled"
    static let meetingReminders: String = "calendar.reminders"
    static let micSuggestions: String = "calendar.micSuggestions"
    /// Not hazır olunca webhook'a kendiliğinden gönder.
    static let webhookAutoSend: String = "integrations.webhookAutoSend"
    /// Sonucu belirsiz gönderimler ("toplantı|hedef"): sunucu yanıt vermedi, not gitmiş olabilir; kendiliğinden yeniden
    /// gönderilmez. Bu cihaza özeldir.
    static let uncertainSends: String = "integrations.uncertainSends"
    /// Ana toplantı dili: otomatik algılama bu dille başlar (ve Mac'te bununla İngilizce arasında seçer).
    static let primaryMeetingLanguage: String = "language.primary"
    /// Not ve çeviri dili (`ShareLanguage`): not, canlı çeviri, "Ne kaçırdım?" ve Sor cevapları bu dilde yazılır.
    static let noteLanguage: String = "language.note"
    /// Not dili ayarından önceki sürümlerin kullanıcısına Türkçe bir kez yazıldı (`legacyNoteLanguage`).
    static let noteLanguageMigrated: String = "migration.noteLanguage"
    /// Takvimdeki çevrim içi görüşme sürerken mikrofon başka uygulamada açılınca kayıt kendiliğinden başlar.
    static let autoRecord: String = "calendar.autoRecord"
    /// Yüz yüze toplantı: sistem sesi yerine mikrofon "Diğerleri" olarak konuşmacılara ayrılır.
    static let inPersonMode: String = "inPersonMode"
    /// Her not hazır olunca Apple Notlar'a gönder.
    static let appleNotesAutoSend: String = "destinations.appleNotes"
    /// Notların Markdown olarak yazılacağı klasör (Obsidian, iCloud Drive…); seçilmediyse boş.
    static let markdownFolder: String = "destinations.markdownFolder"
    /// Her not hazır olunca klasöre yaz.
    static let markdownAutoExport: String = "destinations.markdownAuto"
    /// Kullanıcının tanıma sözlüğü (satır başına bir ad ya da terim).
    static let customVocabulary: String = "customVocabulary"
    /// Kullanıcının oluşturduğu klasörler (boş olanlar da listede kalsın).
    static let folders: String = "folders"
    /// Toplantı özetinde sözlük açık mı.
    static let glossaryExpanded: String = "meeting.glossaryExpanded"
    /// Kişiler sayfasındaki liste açık (varsayılan kapalı: sayfa kişinin kendisine yer açar).
    static let peopleListVisible: String = "people.listVisible"
    /// Toplantılar sayfasındaki toplantı listesi açık (üst çubuktaki düğmeyle gizlenir).
    static let meetingsListVisible: String = "meetings.listVisible"
    /// Sor sayfasındaki sohbet geçmişi sütunu açık (üst çubuktaki düğmeyle).
    static let askHistoryVisible: String = "ask.historyVisible"
    /// Konuşmacıları sesinden tanıma (ses izleri yalnızca bu Mac'te).
    static let voiceRecognition: String = "voiceRecognition"
    /// Görünüm.
    static let theme: String = "appearance.theme"
    static let accent: String = "appearance.accent"
    static let fontDesign: String = "appearance.fontDesign"
    static let textSize: String = "appearance.textSize"
    /// Arayüz yazılarının ölçeği (1 = varsayılan).
    static let uiScale: String = "appearance.uiScale"
    static let lineSpacing: String = "appearance.lineSpacing"
    static let bottomSpacing: String = "appearance.bottomSpacing"
    static let islandEnabled: String = "appearance.islandEnabled"
    /// Pencere yüzeyi (dolu, buzlu cam, şeffaf cam), cam opaklığı ve zemin tonu.
    static let surface: String = "appearance.surface"
    static let surfaceOpacity: String = "appearance.surfaceOpacity"
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

/// Açılışta geçerli olan arayüz dili (değiştirilince yeniden başlatma önerilir; Ayarlar yeniden kurulsa da kalır).
let launchInterfaceLanguage: InterfaceLanguage = storedInterfaceLanguage()

/// Uygulamayı yeniden başlatır (arayüz dili değişince). Yeni kopya ancak bu kopya gerçekten kapandıktan sonra açılır:
/// kapanış iptal edilirse (kayıt ya da işleme sürüyor, çıkış koruması) 30 sn bekleyip vazgeçer. İki kopya aynı anda
/// çalışırsa yeni kopya kısayolları kaydedemez ve süren kaydı "yarıda kaldı" diye işaretlerdi. Başlatıcı
/// çalıştırılamazsa hata fırlar (uygulama kapanmaz).
@MainActor
func relaunchApplication() throws {
    let launcher: Process = Process()
    launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
    launcher.arguments = [
        "-c",
        "i=0; while /bin/kill -0 \"$1\" 2>/dev/null; do i=$((i+1)); [ $i -gt 150 ] && exit 0; sleep 0.2; done; /usr/bin/open -n \"$0\"",
        Bundle.main.bundleURL.path, String(ProcessInfo.processInfo.processIdentifier),
    ]
    try launcher.run()
    NSApplication.shared.terminate(nil)
}

/// Panelin açık/koyu görünümü.
/// Temanın macOS görünümü; sistem temasında nil (sistemi izler). Saf fonksiyondur.
func nsAppearance(theme: AppTheme) -> NSAppearance? {
    switch theme.isDark {
    case .none: nil
    case .some(false): NSAppearance(named: .aqua)
    case .some(true): NSAppearance(named: .darkAqua)
    }
}

/// Temayı uygulamanın tüm pencerelerine birden uygular (pencere bazında atama cam zemini ve adayı eski temada
/// bırakıyordu) ve renk takımlarını seçer.
@MainActor
func applyTheme(theme: AppTheme) {
    NSApplication.shared.appearance = nsAppearance(theme: theme)
    ThemeStore.shared.set(light: theme.colorSets.light, dark: theme.colorSets.dark)
}

/// Ayar aralıkları.
enum SettingsRange {
    static let missedWindowMinutes: ClosedRange<Int> = 1...10
    static let audioRetentionDays: ClosedRange<Int> = 7...365
    static let textSize: ClosedRange<Double> = 11...24
    static let uiScale: ClosedRange<Double> = 0.85...1.3
    static let lineSpacing: ClosedRange<Double> = 0...12
    static let bottomSpacing: ClosedRange<Double> = 0...160
    static let surfaceOpacity: ClosedRange<Double> = 0.35...0.95
}

/// Görünüm ayarlarını varsayılana döndürür.
func resetAppearanceSettings(defaults: UserDefaults) {
    for key in [SettingsKey.theme, SettingsKey.accent, SettingsKey.fontDesign, SettingsKey.uiScale, SettingsKey.textSize,
                SettingsKey.lineSpacing, SettingsKey.bottomSpacing, SettingsKey.islandEnabled, SettingsKey.surface,
                SettingsKey.surfaceOpacity] {
        defaults.removeObject(forKey: key)
    }
}

/// Not, özet ve soru için sunulan effort seviyeleri. `xhigh`/`max` sunulmaz: gerçek 37 dakikalık toplantıda Haiku 5.5
/// `max` effort'ta parça başına ~4,5 dk düşünüp 64.000 token sınırında kesildi (not hiç oluşmadı); `high` 27 sn'de
/// eksiksiz not yazdı.
let smartEfforts: [LLMEffort] = [.low, .medium, .high]

/// Eski sürümde seçilmiş `xhigh`/`max` not effort'unu bir kez `high`'a taşır (artık sunulmuyor; notu kesiyordu).
/// Açılışta çağrılır; taşındıysa true.
func migrateSmartEffort(defaults: UserDefaults) -> Bool {
    guard let stored = defaults.string(forKey: SettingsKey.claudeSmartEffort),
          let effort = LLMEffort(rawValue: stored), !smartEfforts.contains(effort) else {
        return false
    }
    defaults.set(LLMEffort.high.rawValue, forKey: SettingsKey.claudeSmartEffort)
    return true
}

/// Varsayılanları bir kez kaydeder (uygulama açılışında).
func registerDefaultSettings() {
    UserDefaults.standard.register(defaults: [
        SettingsKey.liveEngine: LiveEngine.deepgram.rawValue,
        // Canlı çeviri isteğe bağlı: asıl amaç toplantı sonu not; açılınca iki dil gösterilir.
        SettingsKey.displayMode: DisplayMode.originalOnly.rawValue,
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
        // Not ve özet için de Haiku yeterli (1–4 saatlik senaryo testlerinde büyük modellerle aynı eksiksizlik).
        SettingsKey.claudeSmartModel: ClaudeModel.haiku.rawValue,
        SettingsKey.claudeFastEffort: LLMEffort.low.rawValue,
        SettingsKey.claudeSmartEffort: LLMEffort.high.rawValue,
        SettingsKey.onboardingCompleted: false,
        SettingsKey.micMuted: false,
        // Ses izi biyometrik veridir: kullanıcı açıkça açmalı.
        SettingsKey.voiceRecognition: false,
        SettingsKey.consentReminder: true,
        SettingsKey.calendarEnabled: false,
        SettingsKey.peopleListVisible: false,
        SettingsKey.meetingsListVisible: true,
        SettingsKey.askHistoryVisible: false,
        SettingsKey.inPersonMode: false,
        SettingsKey.appleNotesAutoSend: false,
        SettingsKey.markdownFolder: "",
        SettingsKey.markdownAutoExport: false,
        SettingsKey.meetingReminders: true,
        SettingsKey.micSuggestions: true,
        SettingsKey.webhookAutoSend: false,
        SettingsKey.primaryMeetingLanguage: MeetingLanguage.finnish.rawValue,
        // Arayüz dili: Türkçe arayüzde mevcut kullanıcıların notu eskisi gibi Türkçe sürer.
        SettingsKey.noteLanguage: defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue,
        SettingsKey.autoRecord: false,
        SettingsKey.noteTemplate: NoteTemplateKind.general.rawValue,
        SettingsKey.customTemplate: "",
        SettingsKey.theme: AppTheme.light.rawValue,
        SettingsKey.accent: PanelAppearance.standard.accent.rawValue,
        SettingsKey.fontDesign: PanelAppearance.standard.fontChoice.storageValue,
        SettingsKey.uiScale: PanelAppearance.standard.uiScale,
        SettingsKey.textSize: PanelAppearance.standard.textSize,
        SettingsKey.lineSpacing: PanelAppearance.standard.lineSpacing,
        SettingsKey.bottomSpacing: PanelAppearance.standard.bottomSpacing,
        SettingsKey.islandEnabled: true,
        SettingsKey.surface: PanelAppearance.standard.surface.rawValue,
        SettingsKey.surfaceOpacity: PanelAppearance.standard.surfaceOpacity,
    ])
}

/// Not dili ayarından önceki sürümlerden gelen kullanıcının notları Türkçe kalır (bkz. `legacyNoteLanguage`); bu sürümün
/// ilk açılışında bir kez çalışır. Varsayılanlar değil, yalnız kayıtlı değerler okunur.
func keepLegacyNoteLanguage(defaults: UserDefaults) {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        settingsLogger.error("Paket kimliği yok, not dili taşınmadı")
        return
    }
    let stored: [String: Any] = defaults.persistentDomain(forName: bundleID) ?? [:]
    let language: ShareLanguage? = legacyNoteLanguage(
        storedNoteLanguage: stored[SettingsKey.noteLanguage] as? String,
        onboardingCompleted: stored[SettingsKey.onboardingCompleted] as? Bool ?? false,
        alreadyMigrated: stored[SettingsKey.noteLanguageMigrated] as? Bool ?? false
    )
    if let language {
        defaults.set(language.rawValue, forKey: SettingsKey.noteLanguage)
        settingsLogger.info("Önceki sürümün kullanıcısı: not dili korundu, dil: \(language.rawValue, privacy: .public)")
    }
    defaults.set(true, forKey: SettingsKey.noteLanguageMigrated)
}

/// Kayıtlı ayarın değeri, aralığa sıkıştırılmış.
func clampedSetting(key: String, range: ClosedRange<Int>) -> Int {
    min(max(UserDefaults.standard.integer(forKey: key), range.lowerBound), range.upperBound)
}

/// Not ve çeviri dili (Ayarlar › Genel); kayıtlı değer tanınmıyorsa (loglanır) arayüz dilinin varsayılanı.
func selectedNoteLanguage() -> ShareLanguage {
    storedNoteLanguage(value: UserDefaults.standard.string(forKey: SettingsKey.noteLanguage) ?? "")
}

/// Ayarın ham değerinden not dili (görünümlerdeki `@AppStorage(SettingsKey.noteLanguage)` için: dil değişince etiketler
/// de güncellenir); tanınmıyorsa (loglanır) arayüz dilinin varsayılanı.
func storedNoteLanguage(value stored: String) -> ShareLanguage {
    guard let language = ShareLanguage(rawValue: stored) else {
        settingsLogger.error("Not dili tanınmadı, varsayılan kullanılıyor, değer: \(stored, privacy: .public)")
        return defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations)
    }
    return language
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
    #if HOSTED_EDITION
    // Abonelik sürümü: sağlayıcı seçimi yok, her istek bizim sunucumuza gider (toplantıdan bağımsız).
    return try hostedAccountLLMProvider()
    #else
    switch selectedLLMProviderKind() {
    case .anthropic:
        return .anthropic(AnthropicConfig(
            apiKey: try await readSecretInBackground(service: appKeychainService, account: .anthropic),
            fastModel: try storedClaudeModel(key: SettingsKey.claudeFastModel),
            smartModel: try storedClaudeModel(key: SettingsKey.claudeSmartModel),
            fastEffort: try requiredEffort(key: SettingsKey.claudeFastEffort),
            smartEffort: try requiredEffort(key: SettingsKey.claudeSmartEffort)
        ))
    case .openAICompatible:
        return .openAICompatible(try storedOpenAIConfig(apiKey: try await optionalSecretInBackground(service: appKeychainService, account: .openai)))
    case .onDevice:
        return .onDevice(try onDeviceConfig())
    }
    #endif
}

/// Kayıt sırasındaki istekler (canlı çeviri, "Ne kaçırdım?", toplantı sorusu) ve kaydın hemen ardından not için
/// sağlayıcı. Kendi anahtarlı sürümde `resolveLLMProvider` ile aynıdır; abonelik sürümünde son açılan toplantının
/// bütçesinden düşer.
func resolveLiveLLMProvider() async throws -> LLMProvider {
    #if HOSTED_EDITION
    return try hostedMeetingLLMProvider()
    #else
    return try await resolveLLMProvider()
    #endif
}

/// İlk açılışta (kurulum bitmemiş, motor ve LLM hiç seçilmemiş) hiçbir anahtar yoksa ve Apple Intelligence
/// kullanılabiliyorsa cihaz içi mod seçilir: uygulama kurulur kurulmaz anahtarsız çalışır. Ana toplantı dili kayıtlı
/// değilse cihazın dili (modelde varsa) ya da İngilizce olur (bkz. `onDeviceDefaultMeetingLanguage`). Anahtarı olan ya
/// da kurulumu bitirmiş kullanıcıya dokunulmaz. Seçim yapıldıysa true.
func chooseOnDeviceOnFirstRun(defaults: UserDefaults) async -> Bool {
    // Kayıtlı (varsayılan olmayan) değerler yalnız uygulamanın kendi alanında görünür.
    guard let bundleID = Bundle.main.bundleIdentifier else {
        settingsLogger.error("İlk açılışta paket kimliği yok, cihaz içi mod seçilmedi")
        return false
    }
    let stored: [String: Any] = defaults.persistentDomain(forName: bundleID) ?? [:]
    guard !defaults.bool(forKey: SettingsKey.onboardingCompleted), stored[SettingsKey.liveEngine] == nil, stored[SettingsKey.llmProvider] == nil else {
        return false
    }
    for account in [SecretAccount.deepgram, .elevenlabs, .anthropic, .openai] {
        do {
            if try await Task.detached(operation: { try secretExists(service: appKeychainService, account: account) }).value {
                return false
            }
        } catch {
            // Anahtar Zinciri okunamadıysa anahtar var sayılır: mevcut kullanıcının ayarı değişmesin.
            settingsLogger.error("İlk açılışta anahtar denetlenemedi, cihaz içi mod seçilmedi, hesap: \(account.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            return false
        }
    }
    let config: OnDeviceConfig
    do {
        config = try onDeviceConfig()
    } catch {
        settingsLogger.info("İlk açılışta cihaz içi model kullanılamıyor, hata: \(String(describing: error), privacy: .public)")
        return false
    }
    // Kayıtlı ana toplantı dili korunur (kurulumda bu arada seçilmiş olabilir: alan şimdi yeniden okunur); yoksa
    // (varsayılan Fince modelde yok) cihazın dili ya da İngilizce.
    if defaults.persistentDomain(forName: bundleID)?[SettingsKey.primaryMeetingLanguage] == nil {
        let language: MeetingLanguage = onDeviceDefaultMeetingLanguage(preferredLanguages: Locale.preferredLanguages, languageCodes: config.languageCodes)
        defaults.set(language.rawValue, forKey: SettingsKey.primaryMeetingLanguage)
        settingsLogger.info("İlk açılışta ana toplantı dili seçildi, dil: \(language.rawValue, privacy: .public)")
    }
    defaults.set(LiveEngine.appleSpeech.rawValue, forKey: SettingsKey.liveEngine)
    defaults.set(LLMProviderKind.onDevice.rawValue, forKey: SettingsKey.llmProvider)
    return true
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

/// Kayıtlı Claude modeli (varsayılanı kayıtlı); tanınmayan değer `notConfigured` (Ayarlar'dan yeniden seçilir).
func storedClaudeModel(key: String) throws -> ClaudeModel {
    let value: String = UserDefaults.standard.string(forKey: key) ?? ""
    guard let model = ClaudeModel(rawValue: value) else {
        throw LLMError.notConfigured(detail: String(localized: "Claude modeli (\(value))"))
    }
    return model
}

/// Claude effort'u (varsayılanı kayıtlı); tanınmayan değer `notConfigured`.
func requiredEffort(key: String) throws -> LLMEffort {
    let value: String = UserDefaults.standard.string(forKey: key) ?? ""
    guard let effort = LLMEffort(rawValue: value) else {
        throw LLMError.notConfigured(detail: String(localized: "effort (\(value))"))
    }
    return effort
}

/// Kayıtlı effort; boş değer "gönderme" demektir (nil).
func storedEffort(key: String) -> LLMEffort? {
    LLMEffort(rawValue: UserDefaults.standard.string(forKey: key) ?? "")
}

/// Ayarlardaki varsayılan not şablonu (yeni toplantılar bununla yazılır).
func defaultNoteTemplate() -> NoteTemplate {
    NoteTemplate(
        kind: NoteTemplateKind(rawValue: UserDefaults.standard.string(forKey: SettingsKey.noteTemplate) ?? "") ?? .general,
        customInstructions: UserDefaults.standard.string(forKey: SettingsKey.customTemplate) ?? ""
    )
}

/// Şablonun arayüz adı.
func templateTitle(kind: NoteTemplateKind) -> LocalizedStringKey {
    switch kind {
    case .general: "Genel"
    case .oneOnOne: "Birebir görüşme"
    case .client: "Müşteri görüşmesi"
    case .lecture: "Ders / eğitim"
    case .interview: "İş mülakatı"
    case .custom: "Kendi şablonum"
    }
}


/// Ayarlardaki ana toplantı dili; kayıtlı değer tanınmıyorsa Fince (varsayılan) ve hata loglanır.
func primaryMeetingLanguage() -> MeetingLanguage {
    let stored: String = UserDefaults.standard.string(forKey: SettingsKey.primaryMeetingLanguage) ?? MeetingLanguage.finnish.rawValue
    guard let language = MeetingLanguage(rawValue: stored) else {
        settingsLogger.error("Ana toplantı dili tanınmadı, değer: \(stored, privacy: .public)")
        return .finnish
    }
    return language
}

/// Bu uygulamanın Anahtar Zinciri servis adı: geliştirici sürümünde `AINotepad` (iPhone ile paylaşılan), abonelik
/// sürümünde kendi servisi (kanal ve görev aracı bağlantıları geliştirici sürümünün öğelerine yazılmasın).
let appKeychainService: String = {
    #if HOSTED_EDITION
    hostedKeychainService
    #else
    keychainService
    #endif
}()
