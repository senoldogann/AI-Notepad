import Foundation

/// Model sınıfının OpenAI uyumlu sağlayıcıdaki modeli. Saf fonksiyondur.
public func openAIModel(config: OpenAICompatibleConfig, tier: LLMTier) -> String {
    switch tier {
    case .fast: config.fastModel
    case .smart: config.smartModel
    }
}

/// `{temel adres}/chat/completions`. Saf fonksiyondur.
public func openAIChatURL(baseURL: URL) -> URL {
    baseURL.appending(path: "chat/completions")
}

/// Chat Completions gövdesi: sistem + kullanıcı mesajı, `max_completion_tokens`, şema varsa katı
/// `response_format: json_schema`. Bazı uyumlu sunucular (ör. Ollama'daki modeller) `response_format`'ı
/// uygulamadığı için şema sistem mesajında da verilir. Örnekleme parametreleri gönderilmez. Saf fonksiyondur.
public func openAIRequestBody(request: LLMRequest, model: String, effort: LLMEffort?) throws -> Data {
    let system: String = request.jsonSchema.map { (schema: String) -> String in
        "\(request.system)\n\nYanıtı yalnızca bu JSON şemasına uyan tek bir JSON nesnesi olarak yaz; Markdown, kod bloğu ya da başka metin ekleme:\n\(schema)"
    } ?? request.system
    var body: [String: Any] = [
        "model": model,
        "max_completion_tokens": openAIMaxTokens(requested: request.maxTokens, effort: effort),
        "stream": false,
        "messages": [
            ["role": "system", "content": system],
            ["role": "user", "content": request.userText],
        ],
    ]
    if let effort {
        body["reasoning_effort"] = effort.rawValue
    }
    if let schemaText = request.jsonSchema {
        body["response_format"] = [
            "type": "json_schema",
            "json_schema": ["name": "yanit", "strict": true, "schema": try parsedSchema(text: schemaText)],
        ]
    }
    return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
}

/// Gönderilecek `max_completion_tokens`: effort seçildiyse model akıl yürütür ve bu tokenlar da sınırdan harcanır,
/// sınır en az `reasoningTokenFloor`; effort yoksa (akıl yürütmeyen modeller daha büyük sınırı 400 ile reddedebilir)
/// isteğin sınırı. Saf fonksiyondur.
public func openAIMaxTokens(requested: Int, effort: LLMEffort?) -> Int {
    effort == nil ? requested : max(requested, reasoningTokenFloor)
}

/// İstek başlıkları; anahtar yoksa (Ollama) yetkilendirme başlığı gönderilmez. Saf fonksiyondur.
public func openAIHeaders(apiKey: String?) -> [String: String] {
    var headers: [String: String] = ["content-type": "application/json"]
    if let apiKey, !apiKey.isEmpty {
        headers["authorization"] = "Bearer \(apiKey)"
    }
    return headers
}

/// İlk seçeneğin metnini döndürür. Reddetme (`refusal` ya da `content_filter`) ve `length` kesilmesi hatadır.
public func parseOpenAIResponse(data: Data, model: String) throws -> String {
    let body: String = String(decoding: data, as: UTF8.self)
    guard let raw = try? JSONDecoder().decode(RawChatCompletion.self, from: data), let choice = raw.choices.first else {
        throw LLMError.malformed(body: body)
    }
    if let refusal = choice.message.refusal, !refusal.isEmpty {
        throw LLMError.refusal(category: nil)
    }
    switch choice.finish_reason {
    case "content_filter":
        throw LLMError.refusal(category: "content_filter")
    case "length":
        throw LLMError.truncated(model: model)
    default:
        break
    }
    let text: String = strippingThinkBlock(text: choice.message.content ?? "")
    guard !text.isEmpty else {
        throw LLMError.empty
    }
    return text
}

/// Bazı uyumlu sunucuların (akıl yürüten yerel modeller) cevabın başına koyduğu `<think>…</think>` bölümünü atar;
/// çeviri ya da JSON bu bölümle başlarsa panelde düşünme metni görünür, not ayrıştırılamazdı. Saf fonksiyondur.
public func strippingThinkBlock(text: String) -> String {
    let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("<think>"), let end = trimmed.range(of: "</think>") else {
        return trimmed
    }
    return String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Durum koduna ve gövdeye göre sonucu belirler; kurallar Claude ile aynıdır. Saf fonksiyondur.
public func classifyOpenAIResponse(status: Int, data: Data, model: String, requestID: String?) -> LLMOutcome {
    let body: String = String(decoding: data, as: UTF8.self)
    switch status {
    case 200..<300:
        do {
            return .success(try parseOpenAIResponse(data: data, model: model))
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

/// OpenAI uyumlu Chat Completions çağrısını hazırlar.
func prepareOpenAICall(config: OpenAICompatibleConfig, request: LLMRequest) throws -> PreparedLLMCall {
    let model: String = openAIModel(config: config, tier: request.tier)
    guard !model.isEmpty else {
        throw LLMError.notConfigured(detail: request.tier == .fast ? String(localized: "çeviri modeli") : String(localized: "özet modeli"))
    }
    var urlRequest: URLRequest = URLRequest(url: openAIChatURL(baseURL: config.baseURL))
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = request.timeoutSec
    let effort: LLMEffort? = request.tier == .fast ? config.fastEffort : config.smartEffort
    urlRequest.httpBody = try openAIRequestBody(request: request, model: model, effort: effort)
    for (field, value) in openAIHeaders(apiKey: config.apiKey) {
        urlRequest.setValue(value, forHTTPHeaderField: field)
    }
    return PreparedLLMCall(urlRequest: urlRequest, model: model, requestIDHeader: "x-request-id") { (status: Int, data: Data, requestID: String?) -> LLMOutcome in
        classifyOpenAIResponse(status: status, data: data, model: model, requestID: requestID)
    }
}

// OpenAI JSON alan adları snake_case olduğu için ara tipler aynı adları kullanır.
private struct RawChatCompletion: Decodable {
    let choices: [RawChoice]
}

private struct RawChoice: Decodable {
    let message: RawMessage
    let finish_reason: String?
}

private struct RawMessage: Decodable {
    let content: String?
    let refusal: String?
}
