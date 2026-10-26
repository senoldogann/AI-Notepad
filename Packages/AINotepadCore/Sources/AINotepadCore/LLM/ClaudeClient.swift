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

/// Gönderilecek `max_tokens`: düşünme kapalıysa (`thinking` alanı var) isteğin sınırı, açıksa en az
/// `reasoningTokenFloor`. Saf fonksiyondur.
public func claudeMaxTokens(requested: Int, thinking: [String: String]?) -> Int {
    thinking == nil ? max(requested, reasoningTokenFloor) : requested
}

/// İstek gövdesi: seçili model ve effort, hızlı sınıfta mümkünse düşünme kapalı, destekleyen modelde sunucu tarafı
/// yedek model, akış (SSE) açık — model uzun düşünürken de bağlantıdan veri gelir, boşta zaman aşımı dolmaz.
/// Örnekleme parametreleri gönderilmez. Saf fonksiyondur.
public func claudeRequestBody(request: LLMRequest, model: ClaudeModel, effort: LLMEffort) throws -> Data {
    var outputConfig: [String: Any] = ["effort": effort.rawValue]
    if let schemaText = request.jsonSchema {
        outputConfig["format"] = ["type": "json_schema", "schema": try parsedSchema(text: schemaText)]
    }
    let thinking: [String: String]? = claudeThinking(model: model, tier: request.tier, effort: effort)
    var body: [String: Any] = [
        "model": model.rawValue,
        "max_tokens": claudeMaxTokens(requested: request.maxTokens, thinking: thinking),
        "stream": true,
        "system": request.system,
        "messages": [["role": "user", "content": request.userText]],
        "output_config": outputConfig,
    ]
    if let thinking {
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

/// Akışın (SSE) sonucu: metin parçaları birleştirilir (sunucu tarafı yedek model akışın ortasında devralırsa metni
/// sürdürür, birleşim tam yanıttır), durma nedeni son `message_delta`'dan gelir. Önce akış içi hata, sonra reddetme,
/// sonra kesilme denetlenir. Saf fonksiyondur.
public func parseClaudeStream(data: Data, model: String) throws -> String {
    let body: String = String(decoding: data, as: UTF8.self)
    let events: [RawStreamEvent] = try body
        .split(whereSeparator: \.isNewline)
        .filter { $0.hasPrefix("data:") }
        .map { (line: Substring) -> RawStreamEvent in
            let payload: Substring = line.dropFirst("data:".count).drop { $0 == " " }
            do {
                return try JSONDecoder().decode(RawStreamEvent.self, from: Data(payload.utf8))
            } catch {
                throw LLMError.malformed(body: "\(error): \(body)")
            }
        }
    if let failure = events.first(where: { $0.type == "error" })?.error {
        throw LLMError.streamFailed(errorType: failure.type, message: failure.message, model: model)
    }
    let stop: RawStreamDelta? = events.last { $0.type == "message_delta" }?.delta
    guard events.contains(where: { $0.type == "message_stop" }), let stopReason = stop?.stop_reason else {
        // Akış bitmeden kapandı: yarım yanıt kullanılmaz.
        throw LLMError.malformed(body: body)
    }
    if stopReason == "refusal" {
        throw LLMError.refusal(category: stop?.stop_details?.category)
    }
    if stopReason == "max_tokens" {
        throw LLMError.truncated(model: model)
    }
    let text: String = events
        .filter { $0.type == "content_block_delta" && $0.delta?.type == "text_delta" }
        .compactMap { $0.delta?.text }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        throw LLMError.empty
    }
    return text
}

/// Akışın (SSE) bir satırındaki yanıt metni parçası; metin parçası değilse nil (bozuk satır da nil: akış bitince
/// tamamı `parseClaudeStream` ile doğrulanır ve bozukluk orada hata olur). Saf fonksiyondur.
func claudeTextDelta(line: Substring) -> String? {
    guard line.hasPrefix("data:") else {
        return nil
    }
    let payload: Substring = line.dropFirst("data:".count).drop { $0 == " " }
    guard let event = try? JSONDecoder().decode(RawStreamEvent.self, from: Data(payload.utf8)),
          event.type == "content_block_delta", event.delta?.type == "text_delta" else {
        return nil
    }
    return event.delta?.text
}

/// Akış içi hatanın türü yeniden denenebilir mi (aşırı yük, sunucu hatası, hız sınırı).
func isRetryableStreamError(errorType: String) -> Bool {
    ["overloaded_error", "api_error", "rate_limit_error"].contains(errorType)
}

/// Durum koduna ve gövdeye göre sonucu belirler. 2xx gövde bir akıştır (SSE); başarısız durumda gövde JSON hatadır.
/// 200 içindeki reddetme/kesilme/bozuk/boş yanıt kesin hatadır (yeniden denemek aynı sonucu verir, maliyeti katlar ve
/// canlı çeviriyi tıkar); akış ortasındaki aşırı yük ve sunucu hatası yeniden denenir. Saf fonksiyondur.
public func classifyClaudeResponse(status: Int, data: Data, model: String, requestID: String?) -> LLMOutcome {
    let body: String = String(decoding: data, as: UTF8.self)
    switch status {
    case 200..<300:
        do {
            return .success(try parseClaudeStream(data: data, model: model))
        } catch let error as LLMError {
            if case .streamFailed(let errorType, _, _) = error, isRetryableStreamError(errorType: errorType) {
                return .retryable(error)
            }
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
private struct RawStopDetails: Decodable {
    let category: String?
}

private struct RawStreamEvent: Decodable {
    let type: String
    let delta: RawStreamDelta?
    let error: RawStreamError?
}

/// `content_block_delta` (`type`, `text`) ve `message_delta` (`stop_reason`, `stop_details`) aynı alanı kullanır.
private struct RawStreamDelta: Decodable {
    let type: String?
    let text: String?
    let stop_reason: String?
    let stop_details: RawStopDetails?
}

private struct RawStreamError: Decodable {
    let type: String
    let message: String
}

