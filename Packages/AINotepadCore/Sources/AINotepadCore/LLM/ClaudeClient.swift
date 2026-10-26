import Foundation
import os

/// Kullanılan Claude modelleri; ham değer API kimliğidir.
public enum ClaudeModel: String, Sendable {
    /// Canlı cümle çevirisi: hızlı ve çok ucuz.
    case haiku = "claude-haiku-5-5"
    /// "Ne kaçırdım?" ve soru-cevap.
    case opus = "claude-opus-5-5"
}

/// Tek turlu Claude isteği.
public struct ClaudeRequest: Sendable, Equatable {
    public let model: ClaudeModel
    public let system: String
    public let userText: String
    public let maxTokens: Int
    /// `output_config.effort`: "low" | "medium" | "high" | "xhigh" | "max".
    public let effort: String
    /// Yapılandırılmış çıktı için JSON şeması (metin); yoksa serbest metin.
    public let jsonSchema: String?

    public init(model: ClaudeModel, system: String, userText: String, maxTokens: Int, effort: String, jsonSchema: String?) {
        self.model = model
        self.system = system
        self.userText = userText
        self.maxTokens = maxTokens
        self.effort = effort
        self.jsonSchema = jsonSchema
    }
}

/// Claude çağrısı hataları. Anahtar değeri hiçbir zaman hataya girmez.
public enum LLMError: Error, Equatable {
    case http(status: Int, body: String)
    /// Güvenlik sınıflandırıcısı isteği reddetti.
    case refusal(category: String?)
    case malformed(body: String)
    /// Yanıtta metin yok.
    case empty
    case invalidSchema(schema: String)
}

/// İstek gövdesi. Haiku: düşünme kapalı (hız için). Opus: düşünme gönderilmez (her zaman açık) ve reddetmede
/// sunucu tarafı yedek model (`fallbacks: "default"`). Örnekleme parametreleri gönderilmez. Saf fonksiyondur.
public func claudeRequestBody(request: ClaudeRequest) throws -> Data {
    var outputConfig: [String: Any] = ["effort": request.effort]
    if let schemaText = request.jsonSchema {
        guard let schema = try? JSONSerialization.jsonObject(with: Data(schemaText.utf8)) as? [String: Any] else {
            throw LLMError.invalidSchema(schema: schemaText)
        }
        outputConfig["format"] = ["type": "json_schema", "schema": schema]
    }
    var body: [String: Any] = [
        "model": request.model.rawValue,
        "max_tokens": request.maxTokens,
        "system": request.system,
        "messages": [["role": "user", "content": request.userText]],
        "output_config": outputConfig,
    ]
    switch request.model {
    case .haiku:
        body["thinking"] = ["type": "disabled"]
    case .opus:
        body["fallbacks"] = "default"
    }
    return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
}

/// İstek başlıkları. Saf fonksiyondur.
public func claudeHeaders(apiKey: String, model: ClaudeModel) -> [String: String] {
    var headers: [String: String] = [
        "x-api-key": apiKey,
        "anthropic-version": "2026-10-21",
        "content-type": "application/json",
    ]
    if model == .opus {
        headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
    }
    return headers
}

/// Yanıttaki metin bloklarını birleştirir; düşünme ve diğer bloklar atlanır. Önce reddetme denetlenir.
public func parseClaudeResponse(data: Data) throws -> String {
    let body: String = String(decoding: data, as: UTF8.self)
    guard let raw = try? JSONDecoder().decode(RawClaudeResponse.self, from: data) else {
        throw LLMError.malformed(body: body)
    }
    if raw.stop_reason == "refusal" {
        throw LLMError.refusal(category: raw.stop_details?.category)
    }
    let text: String = raw.content
        .filter { (block: RawContentBlock) -> Bool in block.type == "text" }
        .compactMap(\.text)
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        throw LLMError.empty
    }
    return text
}

private let claudeLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Claude")

/// İsteği gönderir: 429/5xx/ağ hatası 3 deneme (üstel bekleme, uyarı logu), 4xx denenmez.
public func sendClaude(apiKey: String, request: ClaudeRequest) async throws -> String {
    // Sabit, geçerli adres.
    var urlRequest: URLRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = 120
    urlRequest.httpBody = try claudeRequestBody(request: request)
    for (field, value) in claudeHeaders(apiKey: apiKey, model: request.model) {
        urlRequest.setValue(value, forHTTPHeaderField: field)
    }

    var text: String?
    var rejection: LLMError?
    try await retryWithBackoff(
        attempts: 3,
        delaySec: 1,
        isolation: nil,
        operation: {
            let (data, response): (Data, URLResponse) = try await URLSession.shared.data(for: urlRequest)
            let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                text = try parseClaudeResponse(data: data)
            case 429, 500...:
                throw LLMError.http(status: status, body: String(decoding: data, as: UTF8.self))
            default:
                // Yeniden denemenin anlamı yok; denemeyi bitir, aşağıda fırlat.
                rejection = .http(status: status, body: String(decoding: data, as: UTF8.self))
            }
        },
        onFailure: { (attempt: Int, error: any Error) -> Void in
            claudeLogger.warning("Claude isteği başarısız, deneme \(attempt, privacy: .public), model: \(request.model.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    )
    if let rejection {
        throw rejection
    }
    guard let text else {
        throw LLMError.empty
    }
    return text
}

// Claude JSON alan adları snake_case olduğu için ara tipler aynı adları kullanır.
private struct RawClaudeResponse: Decodable {
    let stop_reason: String?
    let stop_details: RawStopDetails?
    let content: [RawContentBlock]
}

private struct RawStopDetails: Decodable {
    let category: String?
}

private struct RawContentBlock: Decodable {
    let type: String
    let text: String?
}
