import Foundation
import os

/// İsteğin model sınıfı: sağlayıcı bunu kendi modeline çevirir.
public enum LLMTier: String, Sendable {
    /// Canlı cümle çevirisi: hızlı ve ucuz (Claude Haiku).
    case fast
    /// Toplantı notu, not düzenleme ve arşiv soruları (Claude Opus).
    case smart
    /// Kayıt sırasında kullanıcının beklediği akıllı istekler: "Ne kaçırdım?" ve toplantı sorusu. Kendi anahtarlı
    /// sağlayıcılar bunu `smart` gibi işler; abonelik sürümü daha düşük effort'la (hızlı yanıt) gönderir.
    case live
}

/// Tek turlu LLM isteği; sağlayıcıdan bağımsız.
public struct LLMRequest: Sendable, Equatable {
    public let tier: LLMTier
    public let system: String
    public let userText: String
    public let maxTokens: Int
    /// Yapılandırılmış çıktı için JSON şeması (metin); yoksa serbest metin.
    public let jsonSchema: String?
    /// Deneme başına zaman aşımı; canlı çeviride kısa tutulur ki kuyruk tıkanmasın.
    public let timeoutSec: Double

    public init(tier: LLMTier, system: String, userText: String, maxTokens: Int, jsonSchema: String?, timeoutSec: Double) {
        self.tier = tier
        self.system = system
        self.userText = userText
        self.maxTokens = maxTokens
        self.jsonSchema = jsonSchema
        self.timeoutSec = timeoutSec
    }
}

/// LLM çağrısı hataları. Anahtar değeri hiçbir zaman hataya girmez.
public enum LLMError: Error, Equatable {
    /// Başarısız HTTP yanıtı; `requestID` sağlayıcının destek için verdiği kimliktir.
    case http(status: Int, body: String, model: String, requestID: String?)
    /// Yanıt `max_tokens` sınırında kesildi.
    case truncated(model: String)
    /// Akış (SSE) başarılı başladıktan sonra hata olayıyla bitti (ör. `overloaded_error`).
    case streamFailed(errorType: String, message: String, model: String)
    /// Güvenlik sınıflandırıcısı isteği reddetti.
    case refusal(category: String?)
    case malformed(body: String)
    /// Yanıtta metin yok.
    case empty
    case invalidSchema(schema: String)
    /// Sağlayıcı ayarı eksik ya da geçersiz (ör. adres yok).
    case notConfigured(detail: String)
    /// Abonelik sunucusu isteği reddetti (deneme bitti, aylık sınır, toplantı kapalı…).
    case hosted(HostedAPIError)
}

/// Model düşünürken / akıl yürütürken çıktı sınırı en az bu kadar: düşünme de bu sınırdan harcar; `max` effort'ta kısa
/// bir toplantının notu bile 16.000'i doldurup kesiliyordu. 64.000, `xhigh`/`max` için yayımlanan başlangıç değeridir;
/// sınır yalnızca güvenlik payıdır (kullanılan kadar ödenir).
let reasoningTokenFloor: Int = 64000

/// Yapılandırılmış yanıtın JSON gövdesi: şemayı yalnızca istemden alan sunucular (ör. Ollama'daki modeller) JSON'u
/// ```` ```json ```` çitine sarabilir; çit varsa içi döner, yoksa metin aynen. Saf fonksiyondur.
public func jsonBody(text: String) -> String {
    let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), let firstNewline = trimmed.firstIndex(of: "\n") else {
        return trimmed
    }
    return String(trimmed[trimmed.index(after: firstNewline)..<trimmed.index(trimmed.endIndex, offsetBy: -3)])
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Modelin ne kadar düşüneceği / çaba seviyesi (Claude `output_config.effort`, OpenAI `reasoning_effort`).
public enum LLMEffort: String, Sendable, CaseIterable, Codable {
    case low
    case medium
    case high
    case xhigh
    case max
}

/// Anthropic ayarı: model sınıfı başına model ve effort (Ayarlar'dan seçilir).
public struct AnthropicConfig: Sendable, Equatable {
    public let apiKey: String
    public let fastModel: ClaudeModel
    public let smartModel: ClaudeModel
    public let fastEffort: LLMEffort
    public let smartEffort: LLMEffort

    public init(apiKey: String, fastModel: ClaudeModel, smartModel: ClaudeModel, fastEffort: LLMEffort, smartEffort: LLMEffort) {
        self.apiKey = apiKey
        self.fastModel = fastModel
        self.smartModel = smartModel
        self.fastEffort = fastEffort
        self.smartEffort = smartEffort
    }
}

/// OpenAI uyumlu sağlayıcı (OpenAI, Ollama, OpenCode Go…) ayarı.
public struct OpenAICompatibleConfig: Sendable, Equatable {
    /// `/chat/completions`'ın bulunduğu temel adres, ör. `https://api.openai.com/v1`, `http://localhost:11434/v1`.
    public let baseURL: URL
    /// Yerel sağlayıcılarda (Ollama) anahtar gerekmez.
    public let apiKey: String?
    public let fastModel: String
    public let smartModel: String
    /// `reasoning_effort`; nil ise gönderilmez (her sunucu desteklemez).
    public let fastEffort: LLMEffort?
    public let smartEffort: LLMEffort?

    public init(baseURL: URL, apiKey: String?, fastModel: String, smartModel: String, fastEffort: LLMEffort?, smartEffort: LLMEffort?) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.fastModel = fastModel
        self.smartModel = smartModel
        self.fastEffort = fastEffort
        self.smartEffort = smartEffort
    }
}

/// İsteğin gideceği sağlayıcı ve kimlik bilgisi.
public enum LLMProvider: Sendable, Equatable {
    case anthropic(AnthropicConfig)
    case openAICompatible(OpenAICompatibleConfig)
    /// Apple Intelligence (cihaz içi): anahtarsız, ücretsiz, internetsiz; küçük bağlam penceresi.
    case onDevice(OnDeviceConfig)
    /// Abonelik sürümünün sunucusu (Claude Haiku 5.5 vekili). Yalnızca abonelik hedefi seçer; ayarlarda görünmez.
    case hosted(HostedLLMConfig)
}

/// HTTP yanıtının sonucu: başarı, yeniden denenebilir hata (408/429/5xx) ya da kesin hata.
public enum LLMOutcome: Sendable, Equatable {
    case success(String)
    case retryable(LLMError)
    case final(LLMError)
}

/// En uzun bekleme: `retry-after` bundan uzunsa beklemek yerine bu kadar beklenir.
private let maxRetryDelaySec: Double = 30

/// Yeniden deneme beklemesi: `retry-after` (saniye) varsa ona uyulur (en fazla 30 sn), yoksa 1, 2, 4… sn.
/// Saf fonksiyondur.
public func retryDelay(retryAfterHeader: String?, attempt: Int) -> Double {
    if let header = retryAfterHeader, let seconds = Double(header.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
        return min(seconds, maxRetryDelaySec)
    }
    return pow(2, Double(attempt - 1))
}

/// Durum koduna göre yeniden denenebilir mi: zaman aşımı, hız sınırı ve sunucu hataları.
func isRetryableLLMStatus(status: Int) -> Bool {
    status >= 500 || ((400..<500).contains(status) && !isPermanentHTTPRejection(status: status))
}

private let llmLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "LLM")
private let llmAttempts: Int = 3

/// Hazırlanmış, sağlayıcıya özgü çağrı.
struct PreparedLLMCall: Sendable {
    let urlRequest: URLRequest
    let model: String
    /// Yanıttaki istek kimliği başlığı.
    let requestIDHeader: String
    let classify: @Sendable (_ status: Int, _ data: Data, _ requestID: String?) -> LLMOutcome
}

/// İsteği seçili sağlayıcıya gönderir: 408/429/5xx/ağ hatası 3 deneme (`retry-after`'a uyarak, uyarı logu);
/// diğer her sonuç kesindir. Cihaz içi model kendi kurallarıyla çalışır (bkz. `sendOnDevice`).
public func sendLLM(provider: LLMProvider, request: LLMRequest) async throws -> String {
    switch provider {
    case .anthropic(let config):
        return try await sendPreparedLLM(call: try prepareClaudeCall(config: config, request: request))
    case .openAICompatible(let config):
        return try await sendPreparedLLM(call: try prepareOpenAICall(config: config, request: request))
    case .onDevice(let config):
        return try await sendOnDevice(config: config, request: request)
    case .hosted(let config):
        do {
            return try await sendPreparedLLM(call: try await prepareHostedCall(config: config, request: request))
        } catch LLMError.hosted(let error) where error.status == 401 {
            // Erişim jetonu süresinden önce reddedildi (ör. sunucu anahtarı döndü): bir kez yenilenip yeniden denenir.
            llmLogger.warning("Abonelik sunucusu jetonu reddetti, yenilenip yeniden deneniyor, kod: \(error.rawCode, privacy: .public)")
            try await config.credentials.refreshAccessToken()
            return try await sendPreparedLLM(call: try await prepareHostedCall(config: config, request: request))
        } catch LLMError.hosted(let error) {
            // Abonelik gerektiren ret (deneme bitti vb.): uygulama teklifi gösterir.
            announceIfSubscriptionRequired(error: error)
            throw LLMError.hosted(error)
        }
    }
}

/// Hazırlanmış çağrıyı gönderir: 408/429/5xx/ağ hatası 3 deneme (`retry-after`'a uyarak, uyarı logu); diğer her
/// sonuç kesindir.
private func sendPreparedLLM(call: PreparedLLMCall) async throws -> String {
    var lastError: any Error = LLMError.empty
    for attempt in 1...llmAttempts {
        var retryAfter: String?
        do {
            let (data, response): (Data, URLResponse) = try await URLSession.shared.data(for: call.urlRequest)
            let http: HTTPURLResponse? = response as? HTTPURLResponse
            let requestID: String? = http?.value(forHTTPHeaderField: call.requestIDHeader)
            switch call.classify(http?.statusCode ?? 0, data, requestID) {
            case .success(let text):
                return text
            case .final(let error):
                throw error
            case .retryable(let error):
                lastError = error
                retryAfter = http?.value(forHTTPHeaderField: "retry-after")
            }
        } catch let error as URLError where error.code != .cancelled {
            lastError = error
        }
        try Task.checkCancellation()
        // Hata gövdesi toplantı metni içerebilir: yalnızca özel (private) loglanır.
        llmLogger.warning("LLM isteği başarısız, deneme: \(attempt, privacy: .public), model: \(call.model, privacy: .public), hata: \(String(describing: lastError), privacy: .private)")
        if attempt < llmAttempts {
            try await Task.sleep(for: .seconds(retryDelay(retryAfterHeader: retryAfter, attempt: attempt)))
        }
    }
    throw lastError
}

/// Sağlayıcı abonelik sunucusu mu. Saf fonksiyondur.
private func isHostedProvider(provider: LLMProvider) -> Bool {
    if case .hosted = provider {
        return true
    }
    return false
}

/// Yapılandırılmış yanıt ister ve ayrıştırır. Model şemaya uyan ama boş ya da bozuk içerik döndürebilir (ör. Haiku
/// `max` effort'ta uzun toplantıda arada bir yalnızca başlıklı not) ya da arada bir döngüye girip çıktı sınırına
/// dayanabilir (ör. Haiku `low` effort'ta ~2 bin token'lık konuşmacı incelemesi seyrek olarak 64 bin sınırında
/// kesilir). Bunlar aralıklıdır: aynı istek yeniden sorulur (uyarı logu) ve son denemenin hatası fırlatılır. Diğer hatalar `sendLLM`'in kendi kurallarıyla biter.
public func requestStructured<Value: Sendable>(
    provider: LLMProvider, request: LLMRequest, parse: @Sendable (String) throws -> Value
) async throws -> Value {
    var lastError: LLMError = .empty
    for attempt in 1...llmAttempts {
        do {
            return try parse(try await sendLLM(provider: provider, request: request))
        } catch let error as LLMError {
            switch error {
            case .truncated where isHostedProvider(provider: provider):
                // Abonelik sunucusu çıktıyı kendi sınırında keser: aynı isteği yinelemek aynı sonucu verir ve kotadan
                // düşer.
                throw error
            case .malformed, .empty, .truncated:
                lastError = error
                llmLogger.warning("Yapılandırılmış yanıt kullanılamadı, deneme: \(attempt, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            default:
                throw error
            }
        }
        try Task.checkCancellation()
    }
    throw lastError
}
