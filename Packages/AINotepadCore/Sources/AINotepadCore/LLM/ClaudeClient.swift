import Foundation

/// Seçilebilen Claude modelleri; ham değer API kimliğidir.
public enum ClaudeModel: String, Sendable, CaseIterable, Codable {
    /// Hızlı ve çok ucuz: canlı çeviri için varsayılan.
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
    /// "Ne kaçırdım?", soru-cevap ve not için varsayılan.
    case opus = "claude-opus-5-5"
    /// En yetenekli (ve en pahalı).
    case fable = "claude-fable-5-1"
}

/// Model sınıfının seçili Claude modeli. Saf fonksiyondur.
public func claudeModel(config: AnthropicConfig, tier: LLMTier) -> ClaudeModel {
    switch tier {
    case .fast: config.fastModel
    case .smart: config.smartModel
    }
}

/// Model sınıfının seçili effort seviyesi. Saf fonksiyondur.
public func claudeEffort(config: AnthropicConfig, tier: LLMTier) -> LLMEffort {
    switch tier {
    case .fast: config.fastEffort
    case .smart: config.smartEffort
    }
}

/// Hızlı sınıfta (canlı çeviri) düşünmeyi kapatan alan; model kapatmayı desteklemiyorsa ya da effort `xhigh`/`max`
/// ise (kapatma 400 döndürür) nil — düşünme açık kalır. Akıllı sınıfta düşünme her zaman uyarlamalıdır. Saf fonksiyondur.
/// Haiku 5.5: `disabled`; Sonnet 5.5: `between_tools` (`disabled` 400); Opus 5.5 ve Fable 5.1: kapatılamaz.
public func claudeThinking(model: ClaudeModel, tier: LLMTier, effort: LLMEffort) -> [String: String]? {
    guard tier == .fast, [LLMEffort.low, .medium, .high].contains(effort) else {
        return nil
    }
    switch model {
    case .haiku: return ["type": "disabled"]
    case .sonnet: return ["type": "between_tools"]
    case .opus, .fable: return nil
    }
}

/// Reddetmede sunucu tarafı yedek model (`fallbacks: "default"`) kullanılabilir mi; Haiku 5.5'te liste 400 döndürür.
/// Saf fonksiyondur.
public func claudeSupportsServerFallback(model: ClaudeModel) -> Bool {
    model != .haiku
}

/// İstek gövdesi: seçili model ve effort, hızlı sınıfta mümkünse düşünme kapalı, destekleyen modelde sunucu tarafı
/// yedek model. Örnekleme parametreleri gönderilmez. Saf fonksiyondur.
public func claudeRequestBody(request: LLMRequest, model: ClaudeModel, effort: LLMEffort) throws -> Data {
    var outputConfig: [String: Any] = ["effort": effort.rawValue]
    if let schemaText = request.jsonSchema {
        outputConfig["format"] = ["type": "json_schema", "schema": try parsedSchema(text: schemaText)]
    }
    var body: [String: Any] = [
        "model": model.rawValue,
        "max_tokens": request.maxTokens,
        "system": request.system,
        "messages": [["role": "user", "content": request.userText]],
        "output_config": outputConfig,
    ]
    if let thinking = claudeThinking(model: model, tier: request.tier, effort: effort) {
        body["thinking"] = thinking
    }
    if claudeSupportsServerFallback(model: model) {
        body["fallbacks"] = "default"
    }
    return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
}

/// JSON şema metnini nesneye çevirir; geçersizse `invalidSchema`.
func parsedSchema(text: String) throws -> [String: Any] {
    guard let schema = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
        throw LLMError.invalidSchema(schema: text)
    }
    return schema
}

/// İstek başlıkları. Saf fonksiyondur.
public func claudeHeaders(apiKey: String, model: ClaudeModel) -> [String: String] {
    var headers: [String: String] = [
        "x-api-key": apiKey,
        "anthropic-version": "2026-10-21",
        "content-type": "application/json",
    ]
    if claudeSupportsServerFallback(model: model) {
        headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
    }
    return headers
}

/// Yanıttaki metin bloklarını birleştirir; düşünme ve diğer bloklar atlanır. Önce reddetme, sonra
/// `max_tokens` kesilmesi denetlenir (yarım JSON ayrıştırılmaya çalışılmasın).
public func parseClaudeResponse(data: Data, model: String) throws -> String {
    let body: String = String(decoding: data, as: UTF8.self)
    guard let raw = try? JSONDecoder().decode(RawClaudeResponse.self, from: data) else {
        throw LLMError.malformed(body: body)
    }
    if raw.stop_reason == "refusal" {
        throw LLMError.refusal(category: raw.stop_details?.category)
    }
    if raw.stop_reason == "max_tokens" {
        throw LLMError.truncated(model: model)
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

/// Durum koduna ve gövdeye göre sonucu belirler. 200 içindeki reddetme/kesilme/bozuk/boş yanıt kesin hatadır
/// (yeniden denemek aynı sonucu verir, maliyeti katlar ve canlı çeviriyi tıkar). Saf fonksiyondur.
public func classifyClaudeResponse(status: Int, data: Data, model: String, requestID: String?) -> LLMOutcome {
    let body: String = String(decoding: data, as: UTF8.self)
    switch status {
    case 200..<300:
        do {
            return .success(try parseClaudeResponse(data: data, model: model))
        } catch let error as LLMError {
            return .final(error)
        } catch {
            return .final(.malformed(body: body))
        }
    case let status where isRetryableLLMStatus(status: status):
        return .retryable(.http(status: status, body: body, model: model, requestID: requestID))
    default:
        return .final(.http(status: status, body: body, model: model, requestID: requestID))
    }
}

/// Anthropic Messages API çağrısını hazırlar.
func prepareClaudeCall(config: AnthropicConfig, request: LLMRequest) throws -> PreparedLLMCall {
    let model: ClaudeModel = claudeModel(config: config, tier: request.tier)
    // Sabit, geçerli adres.
    var urlRequest: URLRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = request.timeoutSec
    urlRequest.httpBody = try claudeRequestBody(request: request, model: model, effort: claudeEffort(config: config, tier: request.tier))
    for (field, value) in claudeHeaders(apiKey: config.apiKey, model: model) {
        urlRequest.setValue(value, forHTTPHeaderField: field)
    }
    return PreparedLLMCall(urlRequest: urlRequest, model: model.rawValue, requestIDHeader: "request-id") { (status: Int, data: Data, requestID: String?) -> LLMOutcome in
        classifyClaudeResponse(status: status, data: data, model: model.rawValue, requestID: requestID)
    }
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
