import Foundation
import os

/// İsteğin model sınıfı: sağlayıcı bunu kendi modeline çevirir.
public enum LLMTier: String, Sendable {
    /// Canlı cümle çevirisi: hızlı ve ucuz (Claude Haiku).
    case fast
    /// "Ne kaçırdım?", soru-cevap ve toplantı notu (Claude Opus).
    case smart
}

/// Tek turlu LLM isteği; sağlayıcıdan bağımsız.
public struct LLMRequest: Sendable, Equatable {
    public let tier: LLMTier
    public let system: String
    public let userText: String
    public let maxTokens: Int
    /// Claude `output_config.effort`: "low" | "medium" | "high" | "xhigh" | "max". OpenAI uyumlu sağlayıcıya gönderilmez.
    public let effort: String
    /// Yapılandırılmış çıktı için JSON şeması (metin); yoksa serbest metin.
    public let jsonSchema: String?
    /// Deneme başına zaman aşımı; canlı çeviride kısa tutulur ki kuyruk tıkanmasın.
    public let timeoutSec: Double

    public init(tier: LLMTier, system: String, userText: String, maxTokens: Int, effort: String, jsonSchema: String?, timeoutSec: Double) {
        self.tier = tier
        self.system = system
        self.userText = userText
        self.maxTokens = maxTokens
        self.effort = effort
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
    /// Güvenlik sınıflandırıcısı isteği reddetti.
    case refusal(category: String?)
    case malformed(body: String)
    /// Yanıtta metin yok.
    case empty
    case invalidSchema(schema: String)
    /// Sağlayıcı ayarı eksik ya da geçersiz (ör. adres yok).
    case notConfigured(detail: String)
}

/// OpenAI uyumlu sağlayıcı (OpenAI, Ollama, OpenCode Go…) ayarı.
public struct OpenAICompatibleConfig: Sendable, Equatable {
    /// `/chat/completions`'ın bulunduğu temel adres, ör. `https://api.openai.com/v1`, `http://localhost:11434/v1`.
    public let baseURL: URL
    /// Yerel sağlayıcılarda (Ollama) anahtar gerekmez.
    public let apiKey: String?
    public let fastModel: String
    public let smartModel: String

    public init(baseURL: URL, apiKey: String?, fastModel: String, smartModel: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.fastModel = fastModel
        self.smartModel = smartModel
    }
}

/// İsteğin gideceği sağlayıcı ve kimlik bilgisi.
public enum LLMProvider: Sendable, Equatable {
    case anthropic(apiKey: String)
    case openAICompatible(OpenAICompatibleConfig)
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
    status == 408 || status == 429 || status >= 500
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
/// diğer her sonuç kesindir.
public func sendLLM(provider: LLMProvider, request: LLMRequest) async throws -> String {
    let call: PreparedLLMCall = switch provider {
    case .anthropic(let apiKey): try prepareClaudeCall(apiKey: apiKey, request: request)
    case .openAICompatible(let config): try prepareOpenAICall(config: config, request: request)
    }
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
