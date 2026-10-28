import Foundation

/// Sunucunun kullandığı tek model (sunucuda sabittir; istemci model göndermez).
public let hostedModelName: String = "claude-haiku-5-5"

/// Yapay zekâ çağrısının kimliği: erişim jetonu ve çağrının bağlı olduğu toplantı oturumu.
public struct HostedLLMCredentials: Sendable, Equatable {
    public let accessToken: String
    public let meetingID: String

    public init(accessToken: String, meetingID: String) {
        self.accessToken = accessToken
        self.meetingID = meetingID
    }
}

/// Çağrı anında geçerli jetonu ve açık toplantıyı veren kaynak (bkz. `HostedClient`).
public protocol HostedLLMCredentialSource: AnyObject, Sendable {
    /// Geçerli (gerekirse yenilenmiş) erişim jetonu ve toplantı; giriş yoksa `notSignedIn`, toplantı yoksa
    /// `noActiveMeeting`.
    func llmCredentials() async throws -> HostedLLMCredentials
}

/// Abonelik sunucusu sağlayıcısı: adres ve kimlik kaynağı. Kaynak aynı nesneyse eşittir.
public struct HostedLLMConfig: Sendable, Equatable {
    public let baseURL: URL
    public let credentials: any HostedLLMCredentialSource

    public init(baseURL: URL, credentials: any HostedLLMCredentialSource) {
        self.baseURL = baseURL
        self.credentials = credentials
    }

    public static func == (lhs: HostedLLMConfig, rhs: HostedLLMConfig) -> Bool {
        lhs.baseURL == rhs.baseURL && lhs.credentials === rhs.credentials
    }
}

/// İsteğin effort'u: kayıt sırasında beklenen istekler (canlı çeviri, "Ne kaçırdım?", toplantı sorusu, arama terimleri)
/// `low`, not yazma ve düzenleme `medium`. Sunucu yalnızca bu ikisini kabul eder. Saf fonksiyondur.
public func hostedEffort(tier: LLMTier) -> LLMEffort {
    switch tier {
    case .fast, .live: .low
    case .smart: .medium
    }
}

/// Sunucunun izin verdiği istek gövdesi: zorunlu `effort`, `system`, tek kullanıcı mesajı, `max_tokens`, isteğe bağlı
/// `output_config.format` ve `stream`. Model, düşünme ve örnekleme alanları gönderilmez.
struct HostedLLMRequestBody: Encodable {
    struct OutputConfig: Encodable {
        let format: ClaudeRequestBody.OutputFormat
    }

    let effort: String
    let system: String
    let messages: [LLMChatMessage]
    let maxTokens: Int
    let outputConfig: OutputConfig?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case effort
        case system
        case messages
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
        case stream
    }
}

/// İstek gövdesi; her zaman akışlıdır (Anthropic olayları aynen gelir, `classifyClaudeResponse` ile çözülür). Saf
/// fonksiyondur.
public func hostedLLMRequestBody(request: LLMRequest, effort: LLMEffort) throws -> Data {
    let format: ClaudeRequestBody.OutputFormat? = try request.jsonSchema.map { (schemaText: String) throws -> ClaudeRequestBody.OutputFormat in
        ClaudeRequestBody.OutputFormat(type: "json_schema", schema: try parsedSchema(text: schemaText))
    }
    let body: HostedLLMRequestBody = HostedLLMRequestBody(
        effort: effort.rawValue,
        system: request.system,
        messages: [LLMChatMessage(role: "user", content: request.userText)],
        maxTokens: request.maxTokens,
        outputConfig: format.map { HostedLLMRequestBody.OutputConfig(format: $0) },
        stream: true
    )
    return try llmRequestEncoder().encode(body)
}

/// `POST /v1/llm/messages` isteği: bearer jeton, toplantı başlığı (`x-meeting-id`) ve gövde. Saf fonksiyondur.
public func hostedLLMURLRequest(baseURL: URL, credentials: HostedLLMCredentials, request: LLMRequest) throws -> URLRequest {
    var urlRequest: URLRequest = URLRequest(url: baseURL.appending(path: "v1/llm/messages"))
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = request.timeoutSec
    urlRequest.httpBody = try hostedLLMRequestBody(request: request, effort: hostedEffort(tier: request.tier))
    urlRequest.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "authorization")
    urlRequest.setValue(credentials.meetingID, forHTTPHeaderField: "x-meeting-id")
    urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
    return urlRequest
}

/// Yanıtı sınıflandırır: 2xx gövde Anthropic akışıdır (Claude ile aynı kurallar); başarısız durumda sunucunun hata
/// kodu `LLMError.hosted` olur, geçici olanlar yeniden denenir. Saf fonksiyondur.
public func classifyHostedLLMResponse(status: Int, data: Data, requestID: String?) -> LLMOutcome {
    guard (200..<300).contains(status) else {
        let error: HostedAPIError = parseHostedAPIError(status: status, data: data, path: "/v1/llm/messages")
        return isRetryableHostedError(error: error) ? .retryable(.hosted(error)) : .final(.hosted(error))
    }
    return classifyClaudeResponse(status: status, data: data, model: hostedModelName, requestID: requestID)
}

/// Abonelik sunucusu çağrısını hazırlar: jeton ve toplantı çağrı anında alınır (jeton gerekirse yenilenir).
func prepareHostedCall(config: HostedLLMConfig, request: LLMRequest) async throws -> PreparedLLMCall {
    let credentials: HostedLLMCredentials = try await config.credentials.llmCredentials()
    return PreparedLLMCall(
        urlRequest: try hostedLLMURLRequest(baseURL: config.baseURL, credentials: credentials, request: request),
        model: hostedModelName,
        // Destek için Cloudflare istek kimliği.
        requestIDHeader: "cf-ray"
    ) { (status: Int, data: Data, requestID: String?) -> LLMOutcome in
        classifyHostedLLMResponse(status: status, data: data, requestID: requestID)
    }
}
