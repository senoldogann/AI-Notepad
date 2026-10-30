import Foundation
import FoundationModels
import os

/// Cihaz içi model (Apple Intelligence, `SystemLanguageModel`) ayarı: anahtar ve internet gerekmez, ücretsizdir.
public struct OnDeviceConfig: Sendable, Equatable {
    /// Modelin bağlam penceresi (token): istem, şema ve yanıt birlikte buna sığmalıdır (macOS/iOS 26'da 4096).
    public let contextTokens: Int
    /// Modelin anladığı ve yazdığı diller (ISO 639 kodları, ör. "tr", "en", "nb"); Fince yoktur.
    public let languageCodes: Set<String>

    public init(contextTokens: Int, languageCodes: Set<String>) {
        self.contextTokens = contextTokens
        self.languageCodes = languageCodes
    }
}

/// Cihaz içi modelin kullanılamama nedeni.
public enum OnDeviceUnavailableReason: Sendable, Equatable {
    /// Cihaz Apple Intelligence'ı desteklemiyor.
    case deviceNotEligible
    /// Apple Intelligence sistem ayarlarında kapalı.
    case appleIntelligenceNotEnabled
    /// Model henüz indirilmedi ya da hazırlanıyor.
    case modelNotReady
    /// Sistem `FoundationModels`'ı içermiyor (macOS 26'dan eski).
    case requiresNewerSystem
    /// Sistemin bu sürümde tanımadığımız bir neden bildirdi.
    case unknown(detail: String)
}

/// Cihaz içi model hataları.
public enum OnDeviceLLMError: Error, Equatable {
    case unavailable(reason: OnDeviceUnavailableReason)
    /// Model istemin dilini desteklemiyor (ör. Fince transkript); sistem üretim sırasında fark etti.
    case unsupportedLanguage(detail: String)
    /// Toplantının dili modelde yok (ör. Fince): iş başlamadan reddedilir, not yazılmaz.
    case meetingLanguageUnsupported(languageName: String)
    /// Çıktı dili (not, çeviri, paylaşım) modelde yok: iş başlamadan reddedilir.
    case outputLanguageUnsupported(languageName: String)
    /// İstem modelin bağlam penceresine sığmıyor (`promptTokens` + en az yanıt > `contextTokens`).
    case contextTooLong(promptTokens: Int, contextTokens: Int)
    /// Sistemin güvenlik denetimi istemi ya da yanıtı engelledi.
    case guardrailViolation(detail: String)
    /// Model dosyaları kullanılamıyor (ör. indirme sürüyor, disk dolu).
    case assetsUnavailable(detail: String)
    /// Sistem isteği kısıtladı (ör. uygulama arka planda, aynı anda çok istek).
    case rateLimited(detail: String)
    /// Diğer üretim hataları (ör. desteklenmeyen şema).
    case generationFailed(detail: String)
}

/// Cihaz içi model (`FoundationModels`) bu sistemde var mı: macOS 26 ve sonrası, iPhone'da (iOS 26+) her zaman. Arayüz
/// seçeneği bununla kapatır; `onDeviceConfig` ve istekler aynı koşulda `unavailable(reason: .requiresNewerSystem)` atar.
public func onDeviceLLMSupportedBySystem() -> Bool {
    if #available(macOS 26.0, *) {
        return true
    }
    return false
}

/// Sistemin bildirdiği kullanılabilirliği nedene çevirir; kullanılabiliyorsa nil. Saf fonksiyondur.
@available(macOS 26.0, *)
public func onDeviceUnavailableReason(availability: SystemLanguageModel.Availability) -> OnDeviceUnavailableReason? {
    switch availability {
    case .available:
        return nil
    case .unavailable(.deviceNotEligible):
        return .deviceNotEligible
    case .unavailable(.appleIntelligenceNotEnabled):
        return .appleIntelligenceNotEnabled
    case .unavailable(.modelNotReady):
        return .modelNotReady
    case .unavailable(let reason):
        return .unknown(detail: String(describing: reason))
    }
}

/// Kullanılamama nedeninin kullanıcıya gösterilen açıklaması ve ne yapması gerektiği. Saf fonksiyondur.
public func onDeviceUnavailableMessage(reason: OnDeviceUnavailableReason) -> String {
    switch reason {
    case .deviceNotEligible:
        String(localized: "Bu cihaz Apple Intelligence'ı desteklemiyor; cihaz içi not yazılamaz. Ayarlar'da kendi anahtarınla bir sağlayıcı seç (ör. Anthropic).")
    case .appleIntelligenceNotEnabled:
        String(localized: "Apple Intelligence kapalı. Mac'te Sistem Ayarları, iPhone'da Ayarlar › Apple Intelligence ve Siri'den aç; model indirilince cihaz içi not hazır olur.")
    case .modelNotReady:
        String(localized: "Apple Intelligence modeli henüz hazır değil (indiriliyor). Cihazı Wi‑Fi'ye ve güce bağlı bırakıp birkaç dakika sonra yeniden dene.")
    case .requiresNewerSystem:
        String(localized: "Cihaz içi model macOS 26 gerektirir. Ayarlar'da kendi anahtarınla bir sağlayıcı seç (ör. Anthropic).")
    case .unknown(let detail):
        String(localized: "Apple Intelligence şu an kullanılamıyor (\(detail)). Cihazı yeniden başlatıp tekrar dene.")
    }
}

/// Bu cihazda cihaz içi model kullanılabiliyorsa ayarı (bağlam ve diller); değilse nedeniyle
/// `OnDeviceLLMError.unavailable`. Sağlayıcı dilden bağımsızdır: istemler dili kendileri taşır, iş başlatan yer dili
/// `requireOnDeviceLanguages` ile denetler. Sistem eskiyse `unavailable(reason: .requiresNewerSystem)`.
public func onDeviceConfig() throws -> OnDeviceConfig {
    guard #available(macOS 26.0, *) else {
        throw OnDeviceLLMError.unavailable(reason: .requiresNewerSystem)
    }
    let model: SystemLanguageModel = onDeviceModel()
    if let reason = onDeviceUnavailableReason(availability: model.availability) {
        throw OnDeviceLLMError.unavailable(reason: reason)
    }
    return OnDeviceConfig(
        contextTokens: model.contextSize,
        languageCodes: Set(model.supportedLanguages.compactMap { $0.languageCode?.identifier })
    )
}

/// BCP 47 dil kodu ("fi", "no", "zh-Hans") cihaz içi modelin dilleri arasında mı. Norveççe modelde Bokmål ("nb")
/// olarak geçer. Saf fonksiyondur.
public func onDeviceSupports(languageCode: String, languageCodes: Set<String>) -> Bool {
    let base: String = localeLanguagePart(identifier: languageCode)
    return languageCodes.contains(base == "no" ? "nb" : base)
}

/// Toplantı dili cihaz içi modelin desteklediği diller arasında mı. Saf fonksiyondur.
public func onDeviceSupports(language: MeetingLanguage, languageCodes: Set<String>) -> Bool {
    onDeviceSupports(languageCode: language.rawValue, languageCodes: languageCodes)
}

/// İşin dilleri cihaz içi modelde yoksa hata: önce okunan metnin dilleri (ör. Fince transkript), sonra yazılacak dil
/// (not ve çeviri dili). Hepsi destekleniyorsa nil. Saf fonksiyondur.
public func onDeviceLanguageError(config: OnDeviceConfig, meetingLanguages: [MeetingLanguage], outputLanguage: ShareLanguage) -> OnDeviceLLMError? {
    if let unsupported = meetingLanguages.first(where: { !onDeviceSupports(language: $0, languageCodes: config.languageCodes) }) {
        return .meetingLanguageUnsupported(languageName: meetingLanguageName(language: unsupported))
    }
    guard onDeviceSupports(languageCode: outputLanguage.rawValue, languageCodes: config.languageCodes) else {
        return .outputLanguageUnsupported(languageName: outputLanguage.interfaceName)
    }
    return nil
}

/// İş başlamadan dil denetimi: sağlayıcı cihaz içiyse okunan metnin dilleri ve yazılacak dil (not dili ya da paylaşım
/// dili) modelde olmalı, yoksa `meetingLanguageUnsupported`/`outputLanguageUnsupported` (kötü bir not sessizce
/// yazılmasın). Diğer sağlayıcılar her dili yazar; denetim yoktur. Saf fonksiyondur.
public func requireOnDeviceLanguages(provider: LLMProvider, meetingLanguages: [MeetingLanguage], outputLanguage: ShareLanguage) throws {
    guard case .onDevice(let config) = provider else {
        return
    }
    if let error = onDeviceLanguageError(config: config, meetingLanguages: meetingLanguages, outputLanguage: outputLanguage) {
        throw error
    }
}

/// Cihaz içi modelle "Sor"un okuyabileceği toplantılar ve okuyamadığı diller.
public struct OnDeviceReadableRecords: Sendable, Equatable {
    /// Dili desteklenen (ya da dili bilinmeyen) toplantılar.
    public let records: [MeetingRecord]
    /// Atlanan toplantıların dilleri (tekil, ilk görülme sırasıyla).
    public let skippedLanguages: [MeetingLanguage]

    public init(records: [MeetingRecord], skippedLanguages: [MeetingLanguage]) {
        self.records = records
        self.skippedLanguages = skippedLanguages
    }
}

/// Arşiv sorusunda cihaz içi modelin okuyabileceği toplantılar: dili modelde olmayanlar (ör. Fince) çıkarılır ki cevap
/// anlamadığı metinden uydurulmasın. Diğer sağlayıcılarda hepsi okunur. Saf fonksiyondur.
public func onDeviceReadableRecords(records: [MeetingRecord], provider: LLMProvider) -> OnDeviceReadableRecords {
    guard case .onDevice(let config) = provider else {
        return OnDeviceReadableRecords(records: records, skippedLanguages: [])
    }
    let isReadable: (MeetingRecord) -> Bool = { (record: MeetingRecord) -> Bool in
        record.language.map { onDeviceSupports(language: $0, languageCodes: config.languageCodes) } ?? true
    }
    let skipped: [MeetingLanguage] = records.filter { !isReadable($0) }.compactMap(\.language)
        .reduce(into: [MeetingLanguage]()) { (result: inout [MeetingLanguage], language: MeetingLanguage) -> Void in
            if !result.contains(language) {
                result.append(language)
            }
        }
    return OnDeviceReadableRecords(records: records.filter(isReadable), skippedLanguages: skipped)
}

/// Arşiv sorusunun okuyacağı toplantılar: cevap dili cihaz içi modelde yoksa `outputLanguageUnsupported`; dili
/// desteklenmeyen toplantılar çıkarılır, geriye toplantı kalmıyorsa ilk atlanan dille `meetingLanguageUnsupported`
/// (cevap boş arşivden uydurulmasın). Saf fonksiyondur.
public func onDeviceAskableArchive(records: [MeetingRecord], provider: LLMProvider, outputLanguage: ShareLanguage) throws -> OnDeviceReadableRecords {
    try requireOnDeviceLanguages(provider: provider, meetingLanguages: [], outputLanguage: outputLanguage)
    let readable: OnDeviceReadableRecords = onDeviceReadableRecords(records: records, provider: provider)
    if readable.records.isEmpty, let language = readable.skippedLanguages.first {
        throw OnDeviceLLMError.meetingLanguageUnsupported(languageName: meetingLanguageName(language: language))
    }
    return readable
}

/// "Nasıl cevaplandı"daki model satırı: model adı ve atlanan toplantı dilleri (cevap onları okumadı). Saf fonksiyondur.
public func askModelName(provider: LLMProvider, readable: OnDeviceReadableRecords) -> String {
    let name: String = llmModelDisplayName(provider: provider, tier: .smart)
    guard !readable.skippedLanguages.isEmpty else {
        return name
    }
    let languages: String = readable.skippedLanguages.map { meetingLanguageName(language: $0) }.joined(separator: ", ")
    return String(localized: "\(name) · okunmadı: \(languages) toplantılar (cihaz içi model bu dilleri desteklemiyor)")
}

/// Cihaz içi mod seçilirken gösterilen uyarı: ana toplantı dili ya da not dili modelde yoksa ne olacağı ve ne
/// yapılacağı; sorun yoksa nil. Saf fonksiyondur.
public func onDeviceModeWarning(config: OnDeviceConfig, primaryLanguage: MeetingLanguage, outputLanguage: ShareLanguage) -> String? {
    switch onDeviceLanguageError(config: config, meetingLanguages: [primaryLanguage], outputLanguage: outputLanguage) {
    case .meetingLanguageUnsupported(let name):
        String(localized: "Cihaz içi model \(name) desteklemiyor: \(name) toplantılar yazıya dökülür ama not ve çeviri yazılmaz. Bu toplantılar için Ayarlar'da kendi anahtarınla bir model seç (Mac'te anahtarsız Ollama da olur); toplantıların başka dildeyse ana toplantı dilini değiştir.")
    case .some(let error):
        onDeviceMessage(error: error)
    case nil:
        nil
    }
}

/// Cihazın tercih ettiği dil (`Locale.preferredLanguages`'ın ilki, ör. "tr-TR") uygulamanın toplantı dillerinden biriyse
/// o; değilse İngilizce. Norveççe ("nb", "nn") toplantıda "no"dur. Abonelik sürümünde ilk açılışta ana toplantı dili
/// budur. Saf fonksiyondur.
public func deviceDefaultMeetingLanguage(preferredLanguages: [String]) -> MeetingLanguage {
    guard let first = preferredLanguages.first else {
        return .english
    }
    let base: String = localeLanguagePart(identifier: first)
    return MeetingLanguage(rawValue: ["nb", "nn"].contains(base) ? "no" : base) ?? .english
}

/// Anahtarsız ilk kurulumda (cihaz içi mod) ana toplantı dili: cihazın dili (`deviceDefaultMeetingLanguage`) cihaz içi
/// model destekliyorsa o; değilse İngilizce. Saf fonksiyondur.
public func onDeviceDefaultMeetingLanguage(preferredLanguages: [String], languageCodes: Set<String>) -> MeetingLanguage {
    let language: MeetingLanguage = deviceDefaultMeetingLanguage(preferredLanguages: preferredLanguages)
    return onDeviceSupports(language: language, languageCodes: languageCodes) ? language : .english
}

/// Cihaz içi modelin yazabildiği toplantı dillerinin adları (Ayarlar'da). Saf fonksiyondur.
public func onDeviceLanguageNames(config: OnDeviceConfig) -> [String] {
    MeetingLanguage.allCases
        .filter { onDeviceSupports(language: $0, languageCodes: config.languageCodes) }
        .map { meetingLanguageName(language: $0) }
}

// MARK: Bağlam bütçesi

/// Token tahmininde karakter/token oranı: ölçümde (Apple tokenizer) Fince 2,7, Türkçe 3,0, İngilizce 4,0; en kötüsüne
/// yakın tutulur ki tahmin bağlamı aşmasın.
let onDeviceCharsPerToken: Double = 2.5
/// Yanıta en az bu kadar token kalmalı; kalmıyorsa istem gönderilmez (model yarım JSON üretirdi).
let onDeviceMinResponseTokens: Int = 400

/// Metnin cihaz içi modeldeki token sayısının (yukarı yuvarlanmış) tahmini. Saf fonksiyondur.
public func estimatedOnDeviceTokens(text: String) -> Int {
    Int((Double(text.count) / onDeviceCharsPerToken).rounded(.up))
}

/// Yanıtın token sınırı: istenen sınır, bağlamda istemden sonra kalan yerle sınırlanır. Yer `onDeviceMinResponseTokens`'tan
/// azsa `contextTooLong`. Saf fonksiyondur.
public func onDeviceResponseTokens(requested: Int, promptTokens: Int, contextTokens: Int) throws -> Int {
    let remaining: Int = contextTokens - promptTokens
    guard remaining >= onDeviceMinResponseTokens else {
        throw OnDeviceLLMError.contextTooLong(promptTokens: promptTokens, contextTokens: contextTokens)
    }
    return min(requested, remaining)
}

/// Sistem istemini küçük bağlam için sıkıştırır: girinti ve boş satırlar atılır, satır sonunda bölünmüş cümleler
/// birleşir; madde ("- ") ve ":" ile biten satırdan sonraki satır yeni satırda kalır. Anlam değişmez, birkaç yüzde
/// token kazanılır (ölçüm: not yönergesi 589 → 567). Saf fonksiyondur.
public func compactedInstructions(system: String) -> String {
    system
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .reduce(into: [String]()) { (lines: inout [String], line: String) -> Void in
            guard let last = lines.last, !line.hasPrefix("- "), !line.hasPrefix("<"), !last.hasSuffix(":"), !last.hasSuffix(">") else {
                lines.append(line)
                return
            }
            lines[lines.count - 1] = last + " " + line
        }
        .joined(separator: "\n")
}

// MARK: Şema

/// JSON şemasının cihaz içi yönlendirmeli üretime (guided generation) çevrilebilen alt kümesi.
public indirect enum JSONSchemaNode: Sendable, Equatable {
    /// `choices` varsa yalnızca bu değerlerden biri (`enum`).
    case string(choices: [String]?)
    case integer
    case number
    case boolean
    case array(item: JSONSchemaNode)
    case object(properties: [JSONSchemaProperty])
}

/// Nesne alanı; sıra üretim sırasıdır (model alanları bu sırayla yazar).
public struct JSONSchemaProperty: Sendable, Equatable {
    public let name: String
    public let node: JSONSchemaNode
    public let isRequired: Bool

    public init(name: String, node: JSONSchemaNode, isRequired: Bool) {
        self.name = name
        self.node = node
        self.isRequired = isRequired
    }
}

/// Şema metnini ayrıştırır. JSON nesnesinde anahtar sırası korunmadığı için alanlar `required` sırasıyla, kalanlar
/// alfabetik sırayla dizilir (uygulamadaki şemalarda `required` tüm alanları istem sırasıyla listeler). Desteklenmeyen
/// tür ya da bozuk şema `LLMError.invalidSchema`. Saf fonksiyondur.
public func parseJSONSchema(text: String) throws -> JSONSchemaNode {
    let raw: RawJSONSchema
    do {
        raw = try JSONDecoder().decode(RawJSONSchema.self, from: Data(text.utf8))
    } catch {
        throw LLMError.invalidSchema(schema: text)
    }
    return try schemaNode(raw: raw, schemaText: text)
}

private func schemaNode(raw: RawJSONSchema, schemaText: String) throws -> JSONSchemaNode {
    switch raw.type {
    case "string":
        return .string(choices: raw.enumValues)
    case "integer":
        return .integer
    case "number":
        return .number
    case "boolean":
        return .boolean
    case "array":
        guard let items = raw.items else {
            throw LLMError.invalidSchema(schema: schemaText)
        }
        return .array(item: try schemaNode(raw: items, schemaText: schemaText))
    case "object":
        let properties: [String: RawJSONSchema] = raw.properties ?? [:]
        let required: [String] = (raw.required ?? []).filter { properties[$0] != nil }
        let rest: [String] = properties.keys.filter { !required.contains($0) }.sorted()
        return .object(properties: try (required + rest).map { (name: String) -> JSONSchemaProperty in
            guard let property = properties[name] else {
                throw LLMError.invalidSchema(schema: schemaText)
            }
            return JSONSchemaProperty(name: name, node: try schemaNode(raw: property, schemaText: schemaText), isRequired: required.contains(name))
        })
    default:
        throw LLMError.invalidSchema(schema: schemaText)
    }
}

/// Şemanın JSON hali; özyinelemeli olduğu için sınıf (yapı kendini içeremez).
private final class RawJSONSchema: Decodable {
    let type: String
    let properties: [String: RawJSONSchema]?
    let required: [String]?
    let items: RawJSONSchema?
    let enumValues: [String]?

    private enum CodingKeys: String, CodingKey {
        case type
        case properties
        case required
        case items
        case enumValues = "enum"
    }
}

/// Şema düğümünü sistemin dinamik şemasına çevirir; iç içe nesneler yol adlarıyla tekil adlandırılır.
@available(macOS 26.0, *)
private func dynamicSchema(node: JSONSchemaNode, name: String) -> DynamicGenerationSchema {
    switch node {
    case .string(let choices):
        guard let choices else {
            return DynamicGenerationSchema(type: String.self)
        }
        return DynamicGenerationSchema(name: name, anyOf: choices)
    case .integer:
        return DynamicGenerationSchema(type: Int.self)
    case .number:
        return DynamicGenerationSchema(type: Double.self)
    case .boolean:
        return DynamicGenerationSchema(type: Bool.self)
    case .array(let item):
        return DynamicGenerationSchema(arrayOf: dynamicSchema(node: item, name: "\(name)Item"))
    case .object(let properties):
        return DynamicGenerationSchema(name: name, properties: properties.map { (property: JSONSchemaProperty) -> DynamicGenerationSchema.Property in
            DynamicGenerationSchema.Property(
                name: property.name, schema: dynamicSchema(node: property.node, name: "\(name)_\(property.name)"), isOptional: !property.isRequired
            )
        })
    }
}

/// Şema metninden yönlendirmeli üretim şeması; çevrilemezse `LLMError.invalidSchema`.
@available(macOS 26.0, *)
private func generationSchema(schemaText: String) throws -> GenerationSchema {
    do {
        return try GenerationSchema(root: dynamicSchema(node: try parseJSONSchema(text: schemaText), name: "Yanit"), dependencies: [])
    } catch let error as LLMError {
        throw error
    } catch {
        throw LLMError.invalidSchema(schema: "\(error): \(schemaText)")
    }
}

// MARK: İstek

private let onDeviceLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "OnDeviceLLM")
private let onDeviceAttempts: Int = 3

/// Toplantı metnini özetleyip çeviren istekler için model: güvenlik denetimi kullanıcının verdiği metni dönüştürmeye
/// izin veren ayarda (toplantıda geçen sıradan sözler yanlışlıkla engellenmesin).
@available(macOS 26.0, *)
private func onDeviceModel() -> SystemLanguageModel {
    SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
}

/// İstemin token sayısı: sistem sayabiliyorsa (macOS/iOS 26.4+) gerçek sayı, değilse tahmin.
@available(macOS 26.0, *)
private func promptTokens(model: SystemLanguageModel, instructions: String, prompt: String, schema: GenerationSchema?) async throws -> Int {
    if #available(macOS 26.4, iOS 26.4, *) {
        var schemaTokens: Int = 0
        if let schema {
            schemaTokens = try await model.tokenCount(for: schema)
        }
        return try await model.tokenCount(for: Instructions(instructions)) + model.tokenCount(for: Prompt(prompt)) + schemaTokens
    }
    return estimatedOnDeviceTokens(text: instructions + prompt) + (schema == nil ? 0 : estimatedOnDeviceTokens(text: String(describing: schema)))
}

/// Sistemin üretim hatasını uygulamanın hatasına çevirir: bozuk/boş yanıt ve reddetme `LLMError` olarak kalır ki
/// `requestStructured` yeniden sorsun ve mesajlar ortak olsun.
@available(macOS 26.0, *)
private func mappedGenerationError(error: LanguageModelSession.GenerationError, promptTokens: Int, contextTokens: Int) -> any Error {
    switch error {
    case .exceededContextWindowSize:
        OnDeviceLLMError.contextTooLong(promptTokens: promptTokens, contextTokens: contextTokens)
    case .assetsUnavailable(let context):
        OnDeviceLLMError.assetsUnavailable(detail: context.debugDescription)
    case .guardrailViolation(let context):
        OnDeviceLLMError.guardrailViolation(detail: context.debugDescription)
    case .unsupportedLanguageOrLocale(let context):
        OnDeviceLLMError.unsupportedLanguage(detail: context.debugDescription)
    case .decodingFailure(let context):
        LLMError.malformed(body: context.debugDescription)
    case .rateLimited(let context), .concurrentRequests(let context):
        OnDeviceLLMError.rateLimited(detail: context.debugDescription)
    case .refusal:
        LLMError.refusal(category: nil)
    case .unsupportedGuide(let context):
        OnDeviceLLMError.generationFailed(detail: context.debugDescription)
    @unknown default:
        OnDeviceLLMError.generationFailed(detail: String(describing: error))
    }
}

/// Hazırlanmış cihaz içi çağrı: model, sıkıştırılmış istem, şema ve yanıt sınırı.
@available(macOS 26.0, *)
private struct PreparedOnDeviceCall {
    let model: SystemLanguageModel
    let instructions: String
    let prompt: String
    let schema: GenerationSchema?
    let options: GenerationOptions
    let promptTokens: Int
}

/// İsteği cihaz içi model için hazırlar: kullanılabilirlik, şema ve bağlam bütçesi denetlenir.
@available(macOS 26.0, *)
private func prepareOnDeviceCall(config: OnDeviceConfig, request: LLMRequest) async throws -> PreparedOnDeviceCall {
    let model: SystemLanguageModel = onDeviceModel()
    if let reason = onDeviceUnavailableReason(availability: model.availability) {
        throw OnDeviceLLMError.unavailable(reason: reason)
    }
    let instructions: String = compactedInstructions(system: request.system)
    let schema: GenerationSchema? = try request.jsonSchema.map { try generationSchema(schemaText: $0) }
    let tokens: Int = try await promptTokens(model: model, instructions: instructions, prompt: request.userText, schema: schema)
    let maxTokens: Int = try onDeviceResponseTokens(requested: request.maxTokens, promptTokens: tokens, contextTokens: config.contextTokens)
    return PreparedOnDeviceCall(
        model: model, instructions: instructions, prompt: request.userText, schema: schema,
        // Örnekleme ve sıcaklık sistemin varsayılanı: etiket SDK 26'da `sampling:`, 27'de `samplingMode:`; verilmeyince
        // ikisinde de derlenir (CI Xcode 26, yerel Xcode 27).
        options: GenerationOptions(maximumResponseTokens: maxTokens), promptTokens: tokens
    )
}

/// İsteği cihaz içi modelle yanıtlar; şema varsa yönlendirmeli üretimle JSON döner (mevcut ayrıştırıcılar aynen
/// kullanılır). Sistem kısıtlarsa (`rateLimited`) 3 deneme (uyarı logu); diğer hatalar kesindir.
@available(macOS 26.0, *)
func sendOnDevice(config: OnDeviceConfig, request: LLMRequest) async throws -> String {
    let call: PreparedOnDeviceCall = try await prepareOnDeviceCall(config: config, request: request)
    var lastError: any Error = LLMError.empty
    for attempt in 1...onDeviceAttempts {
        let session: LanguageModelSession = LanguageModelSession(model: call.model, tools: [], instructions: call.instructions)
        do {
            guard let schema = call.schema else {
                return try await session.respond(to: call.prompt, options: call.options).content
            }
            return try await session.respond(to: call.prompt, schema: schema, includeSchemaInPrompt: true, options: call.options).content.jsonString
        } catch let error as LanguageModelSession.GenerationError {
            let mapped: any Error = mappedGenerationError(error: error, promptTokens: call.promptTokens, contextTokens: config.contextTokens)
            guard case OnDeviceLLMError.rateLimited = mapped else {
                throw mapped
            }
            lastError = mapped
        }
        try Task.checkCancellation()
        onDeviceLogger.warning("Cihaz içi istek kısıtlandı, deneme: \(attempt, privacy: .public), hata: \(String(describing: lastError), privacy: .public)")
        if attempt < onDeviceAttempts {
            try await Task.sleep(for: .seconds(retryDelay(retryAfterHeader: nil, attempt: attempt)))
        }
    }
    throw lastError
}

/// İsteği cihaz içi modelle akışla yanıtlar: her ara görüntüde o ana kadarki metin `onText`'e verilir, sonunda tam
/// metin döner. Akış yeniden denenmez (kullanıcı yarım cevabı görmüş olabilir).
@available(macOS 26.0, *)
func streamOnDevice(config: OnDeviceConfig, request: LLMRequest, onText: LLMTextHandler) async throws -> String {
    let call: PreparedOnDeviceCall = try await prepareOnDeviceCall(config: config, request: request)
    let session: LanguageModelSession = LanguageModelSession(model: call.model, tools: [], instructions: call.instructions)
    var text: String = ""
    do {
        for try await snapshot in session.streamResponse(to: call.prompt, options: call.options) {
            text = snapshot.content
            await onText(text)
        }
    } catch let error as LanguageModelSession.GenerationError {
        throw mappedGenerationError(error: error, promptTokens: call.promptTokens, contextTokens: config.contextTokens)
    }
    guard !text.isEmpty else {
        throw LLMError.empty
    }
    return text
}

/// Hatanın kullanıcıya gösterilen açıklaması. Saf fonksiyondur.
func onDeviceMessage(error: OnDeviceLLMError) -> String {
    switch error {
    case .unavailable(let reason):
        onDeviceUnavailableMessage(reason: reason)
    case .unsupportedLanguage:
        String(localized: "Cihaz içi model bu toplantının dilini desteklemiyor (ör. Fince). Bu toplantı için Ayarlar'da kendi anahtarınla bir sağlayıcı seçip \"Notu yenile\"ye bas.")
    case .meetingLanguageUnsupported(let name):
        String(localized: "Cihaz içi model \(name) desteklemiyor; bu toplantı için Ayarlar'da kendi anahtarınla bir model seç (Mac'te anahtarsız Ollama da olur), sonra \"Notu yenile\"ye bas.")
    case .outputLanguageUnsupported(let name):
        String(localized: "Cihaz içi model \(name) yazamıyor; not dilini değiştir ya da Ayarlar'da kendi anahtarınla bir model seç.")
    case .contextTooLong:
        String(localized: "Metin cihaz içi model için çok uzun. Daha kısa bir soru dene ya da Ayarlar'da kendi anahtarınla bir sağlayıcı seç.")
    case .guardrailViolation:
        String(localized: "Apple Intelligence güvenlik denetimi bu metni işlemedi. Kendi anahtarınla bir sağlayıcı seçip yeniden dene.")
    case .assetsUnavailable:
        String(localized: "Apple Intelligence modeli şu an kullanılamıyor (indiriliyor ya da disk dolu). Birkaç dakika sonra yeniden dene.")
    case .rateLimited:
        String(localized: "Cihaz içi model şu an meşgul (uygulama arka plandayken sistem kısıtlar). Uygulamayı açık tutup yeniden dene.")
    case .generationFailed:
        String(localized: "Cihaz içi model yanıt üretemedi. Tekrar dene.")
    }
}
