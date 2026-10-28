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
    try llmRequestEncoder().encode(openAIBody(request: request, model: model, effort: effort, stream: false))
}

/// Akışlı (SSE) Chat Completions gövdesi: `openAIRequestBody` ile aynı alanlar, `stream: true`. Saf fonksiyondur.
public func openAIStreamRequestBody(request: LLMRequest, model: String, effort: LLMEffort?) throws -> Data {
    try llmRequestEncoder().encode(openAIBody(request: request, model: model, effort: effort, stream: true))
}

/// Chat Completions isteğinin gövdesi; alan adları API'ninkilerdir. Boş (nil) alanlar gövdeye yazılmaz.
struct OpenAIRequestBody: Encodable {
    struct JSONSchemaFormat: Encodable {
        let name: String
        let strict: Bool
        let schema: JSONValue
    }

    struct ResponseFormat: Encodable {
        let type: String
        let jsonSchema: JSONSchemaFormat

        enum CodingKeys: String, CodingKey {
            case type
            case jsonSchema = "json_schema"
        }
    }

    let model: String
    let maxCompletionTokens: Int
    let messages: [LLMChatMessage]
    let reasoningEffort: String?
    let responseFormat: ResponseFormat?
    /// Gövdede gönderilen `stream` değeri.
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case maxCompletionTokens = "max_completion_tokens"
        case messages
        case reasoningEffort = "reasoning_effort"
        case responseFormat = "response_format"
        case stream
    }
}

/// İki gövdenin ortak kurulumu; `stream` gövdeye olduğu gibi yazılan alandır. Saf fonksiyondur.
private func openAIBody(request: LLMRequest, model: String, effort: LLMEffort?, stream: Bool) throws -> OpenAIRequestBody {
    let system: String = request.jsonSchema.map { (schema: String) -> String in
        "\(request.system)\n\nYanıtı yalnızca bu JSON şemasına uyan tek bir JSON nesnesi olarak yaz; Markdown, kod bloğu ya da başka metin ekleme:\n\(schema)"
    } ?? request.system
    let responseFormat: OpenAIRequestBody.ResponseFormat? = try request.jsonSchema.map { (schemaText: String) throws -> OpenAIRequestBody.ResponseFormat in
        OpenAIRequestBody.ResponseFormat(
            type: "json_schema",
            jsonSchema: OpenAIRequestBody.JSONSchemaFormat(name: "yanit", strict: true, schema: try parsedSchema(text: schemaText))
        )
    }
    return OpenAIRequestBody(
        model: model,
        maxCompletionTokens: openAIMaxTokens(requested: request.maxTokens, effort: effort),
        messages: [LLMChatMessage(role: "system", content: system), LLMChatMessage(role: "user", content: request.userText)],
        reasoningEffort: effort?.rawValue,
        responseFormat: responseFormat,
        stream: stream
    )
}

/// Gönderilecek `max_completion_tokens`: effort seçildiyse model akıl yürütür ve bu tokenlar da sınırdan harcanır,
/// sınır en az `reasoningTokenFloor`. Effort gönderilmese de bazı modeller (ör. gpt-5 ailesi) varsayılan olarak akıl
/// yürütür; kısa isteklerin 1024'lük sınırı düşünmeye harcanıp cevap kesiliyordu. Bu yüzden sınır en az
/// `unspecifiedEffortTokenFloor` (akıl yürütmeyen güncel modellerin çıktı sınırının altında). Saf fonksiyondur.
public func openAIMaxTokens(requested: Int, effort: LLMEffort?) -> Int {
    effort == nil ? max(requested, unspecifiedEffortTokenFloor) : max(requested, reasoningTokenFloor)
}

/// Effort gönderilmediğinde çıktı sınırının alt değeri.
let unspecifiedEffortTokenFloor: Int = 4096

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

/// Akışın (SSE) sonucu: metin parçaları birleştirilir, bitiş nedeni son parçadan gelir. `[DONE]` ya da bitiş nedeni
/// yoksa akış yarıda kalmıştır. Reddetme ve kesilme hatadır; akış içi hata nesnesi `streamFailed`. Saf fonksiyondur.
public func parseOpenAIStream(data: Data, model: String) throws -> String {
    let body: String = String(decoding: data, as: UTF8.self)
    let payloads: [Substring] = body
        .split(whereSeparator: \.isNewline)
        .filter { $0.hasPrefix("data:") }
        .map { $0.dropFirst("data:".count).drop { $0 == " " } }
    let chunks: [RawStreamChunk] = try payloads.filter { $0 != "[DONE]" }.map { (payload: Substring) -> RawStreamChunk in
        do {
            return try JSONDecoder().decode(RawStreamChunk.self, from: Data(payload.utf8))
        } catch {
            throw LLMError.malformed(body: "\(error): \(body)")
        }
    }
    if let failure = chunks.compactMap(\.error).first {
        throw LLMError.streamFailed(errorType: failure.type ?? "error", message: failure.message ?? "", model: model)
    }
    let finish: String? = chunks.compactMap { $0.choices?.first?.finish_reason }.last
    guard payloads.contains("[DONE]") || finish != nil else {
        throw LLMError.malformed(body: body)
    }
    switch finish {
    case "content_filter":
        throw LLMError.refusal(category: "content_filter")
    case "length":
        throw LLMError.truncated(model: model)
    default:
        break
    }
    let text: String = strippingThinkBlock(text: chunks.compactMap { $0.choices?.first?.delta?.content }.joined())
    guard !text.isEmpty else {
        throw LLMError.empty
    }
    return text
}

/// Akışın bir satırındaki yanıt metni parçası; metin parçası değilse nil (bozuk satır da nil: akış bitince tamamı
/// `parseOpenAIStream` ile doğrulanır ve bozukluk orada hata olur). Saf fonksiyondur.
func openAITextDelta(line: Substring) -> String? {
    guard line.hasPrefix("data:") else {
        return nil
    }
    let payload: Substring = line.dropFirst("data:".count).drop { $0 == " " }
    guard payload != "[DONE]", let chunk = try? JSONDecoder().decode(RawStreamChunk.self, from: Data(payload.utf8)) else {
        return nil
    }
    return chunk.choices?.first?.delta?.content
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

/// OpenAI uyumlu akışlı Chat Completions çağrısını hazırlar; sonuç tüm akıştan `parseOpenAIStream` ile çıkar.
func prepareOpenAIStreamCall(config: OpenAICompatibleConfig, request: LLMRequest) throws -> PreparedLLMCall {
    let model: String = openAIModel(config: config, tier: request.tier)
    guard !model.isEmpty else {
        throw LLMError.notConfigured(detail: request.tier == .fast ? String(localized: "çeviri modeli") : String(localized: "özet modeli"))
    }
    var urlRequest: URLRequest = URLRequest(url: openAIChatURL(baseURL: config.baseURL))
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = request.timeoutSec
    let effort: LLMEffort? = request.tier == .fast ? config.fastEffort : config.smartEffort
    urlRequest.httpBody = try openAIStreamRequestBody(request: request, model: model, effort: effort)
    for (field, value) in openAIHeaders(apiKey: config.apiKey) {
        urlRequest.setValue(value, forHTTPHeaderField: field)
    }
    return PreparedLLMCall(urlRequest: urlRequest, model: model, requestIDHeader: "x-request-id") { (status: Int, data: Data, requestID: String?) -> LLMOutcome in
        let body: String = String(decoding: data, as: UTF8.self)
        switch status {
        case 200..<300:
            do {
                return .success(try parseOpenAIStream(data: data, model: model))
            } catch let error as LLMError {
                // Akış ortasındaki aşırı yük ve sunucu hatası Claude'daki gibi yeniden denenir.
                if case .streamFailed(let errorType, _, _) = error, isRetryableStreamError(errorType: errorType) || ["server_error", "rate_limit_exceeded"].contains(errorType) {
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

private struct RawStreamChunk: Decodable {
    let choices: [RawStreamChoice]?
    let error: RawStreamFailure?
}

private struct RawStreamChoice: Decodable {
    let delta: RawStreamContent?
    let finish_reason: String?
}

private struct RawStreamContent: Decodable {
    let content: String?
}

private struct RawStreamFailure: Decodable {
    let type: String?
    let message: String?
}
