import Foundation
import Testing
@testable import AINotepadCore

/// JSON gövdesini sözlüğe çevirir.
func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Varsayılan ayar: çeviri Haiku 5.5 (low), özet ve not Haiku 5.5 (medium).
func defaultAnthropicConfig(apiKey: String) -> AnthropicConfig {
    AnthropicConfig(apiKey: apiKey, fastModel: .haiku, smartModel: .haiku, fastEffort: .low, smartEffort: .medium)
}

/// Claude akışı (SSE): verilen olay yükleri `data:` satırları olarak.
func sse(_ events: [String]) -> Data {
    Data(events.map { "event: x\ndata: \($0)\n\n" }.joined().utf8)
}

/// Metin parçaları ve durma nedeniyle tam bir akış.
func completeStream(texts: [String], stopReason: String) -> Data {
    sse([#"{"type":"message_start","message":{}}"#]
        + texts.map { #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#($0)"}}"# }
        + [#"{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)"}}"#, #"{"type":"message_stop"}"#])
}

func request(model: ClaudeModel, schema: String?) -> LLMRequest {
    LLMRequest(purpose: .note, tier: model == .haiku ? .fast : .smart, system: "sistem", userText: "metin", maxTokens: 1024, jsonSchema: schema, timeoutSec: 20)
}

@Suite struct ClaudeClientTests {
    @Test func haikuBodyDisablesThinkingLowEffort() throws {
        let body: [String: Any] = try jsonObject(claudeRequestBody(request: request(model: .haiku, schema: nil), model: .haiku, effort: .low))
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect(body["max_tokens"] as? Int == 1024)
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(body["fallbacks"] == nil)
        #expect(body["temperature"] == nil)
        #expect(body["system"] as? String == "sistem")
        let messages: [[String: Any]] = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "metin")
    }

    @Test func opusBodyHasFallbacksAndNoThinking() throws {
        let body: [String: Any] = try jsonObject(claudeRequestBody(request: request(model: .opus, schema: nil), model: .opus, effort: .medium))
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["thinking"] == nil)
        #expect(body["fallbacks"] as? String == "default")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "medium")
    }

    @Test func opusHeadersIncludeFallbackBeta() {
        let opus: [String: String] = claudeHeaders(apiKey: "k", model: .opus)
        #expect(opus["anthropic-beta"] == "server-side-fallback-2026-07-01")
        #expect(opus["anthropic-version"] == "2026-10-21")
        #expect(opus["x-api-key"] == "k")
        #expect(claudeHeaders(apiKey: "k", model: .haiku)["anthropic-beta"] == nil)
    }

    // Düşünmeyi kapatma modele göre değişir; yanlış alan 400 döndürür.
    @Test func thinkingAndFallbackRulesPerModel() {
        #expect(claudeThinking(model: .haiku, tier: .fast, effort: .low) == ["type": "disabled"])
        #expect(claudeThinking(model: .sonnet, tier: .fast, effort: .high) == ["type": "between_tools"])
        #expect(claudeThinking(model: .haiku, tier: .fast, effort: .xhigh) == nil)
        #expect(claudeThinking(model: .opus, tier: .fast, effort: .low) == nil)
        #expect(claudeThinking(model: .fable, tier: .fast, effort: .low) == nil)
        #expect(claudeThinking(model: .haiku, tier: .smart, effort: .low) == nil)
        #expect(!claudeSupportsServerFallback(model: .haiku))
        #expect(ClaudeModel.allCases.filter { claudeSupportsServerFallback(model: $0) } == [.sonnet, .opus, .fable])
    }

    @Test func schemaGoesToOutputConfigFormat() throws {
        let schema: String = #"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"],"additionalProperties":false}"#
        let body: [String: Any] = try jsonObject(claudeRequestBody(request: request(model: .opus, schema: schema), model: .opus, effort: .medium))
        let format: [String: Any] = try #require((body["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect((format["schema"] as? [String: Any])?["type"] as? String == "object")
    }

    // Şema olduğu gibi gider: tam sayılar tam sayı kalır (ör. `maxItems`); JSON nesnesi olmayan şema reddedilir.
    @Test func schemaNumbersStayIntegersAndInvalidSchemaIsRejected() throws {
        let schema: String = #"{"type":"array","maxItems":3,"items":{"type":"number","minimum":0.5}}"#
        let body: String = String(decoding: try claudeRequestBody(request: request(model: .opus, schema: schema), model: .opus, effort: .medium), as: UTF8.self)
        #expect(body.contains(#""maxItems":3"#) && body.contains(#""minimum":0.5"#))
        #expect(throws: LLMError.self) { try claudeRequestBody(request: request(model: .opus, schema: "[1]"), model: .opus, effort: .medium) }
        #expect(throws: LLMError.self) { try claudeRequestBody(request: request(model: .opus, schema: "{bozuk"), model: .opus, effort: .medium) }
    }

    // Düşünme açıkken `max_tokens` en az 64.000 (düşünme de bu sınırdan harcar); kapalıyken isteğin sınırı.
    @Test func thinkingRaisesTokenLimit() throws {
        let opus: [String: Any] = try jsonObject(claudeRequestBody(request: request(model: .opus, schema: nil), model: .opus, effort: .max))
        #expect(opus["max_tokens"] as? Int == 64000)
        #expect(opus["stream"] as? Bool == true)
        #expect(claudeMaxTokens(requested: 1024, thinking: ["type": "disabled"]) == 1024)
        #expect(claudeMaxTokens(requested: 16000, thinking: nil) == 64000)
    }

    @Test func streamJoinsTextSkipsThinking() throws {
        let data: Data = sse([
            #"{"type":"message_start","message":{}}"#,
            #"{"type":"ping"}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"..."}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Merhaba"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" dünya"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#,
        ])
        #expect(try parseClaudeStream(data: data, model: "m") == "Merhaba dünya")
    }

    // Yalnızca 408/429/5xx ve akış içi aşırı yük yeniden denenir; reddetme, kesilme, yarım akış ve diğer 4xx kesindir.
    @Test func classifyRetriesOnlyTransientFailures() {
        let refusal: Data = sse([#"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}}"#, #"{"type":"message_stop"}"#])
        let overloaded: Data = sse([#"{"type":"message_start","message":{}}"#, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#])
        let cutOff: Data = sse([#"{"type":"message_start","message":{}}"#, #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"yarım"}}"#])
        #expect(classifyClaudeResponse(status: 200, data: completeStream(texts: ["Merhaba"], stopReason: "end_turn"), model: "m", requestID: nil) == .success("Merhaba"))
        #expect(classifyClaudeResponse(status: 200, data: refusal, model: "m", requestID: nil) == .final(.refusal(category: "cyber")))
        #expect(classifyClaudeResponse(status: 200, data: completeStream(texts: ["yarım"], stopReason: "max_tokens"), model: "m", requestID: nil) == .final(.truncated(model: "m")))
        #expect(classifyClaudeResponse(status: 200, data: overloaded, model: "m", requestID: nil) == .retryable(.streamFailed(errorType: "overloaded_error", message: "Overloaded", model: "m")))
        if case .final(.malformed) = classifyClaudeResponse(status: 200, data: cutOff, model: "m", requestID: nil) {} else {
            Issue.record("bitmeyen akış kesin hata olmalı")
        }
        #expect(classifyClaudeResponse(status: 429, data: Data("x".utf8), model: "m", requestID: "r") == .retryable(.http(status: 429, body: "x", model: "m", requestID: "r")))
        #expect(classifyClaudeResponse(status: 503, data: Data("x".utf8), model: "m", requestID: "r") == .retryable(.http(status: 503, body: "x", model: "m", requestID: "r")))
        #expect(classifyClaudeResponse(status: 401, data: Data("x".utf8), model: "m", requestID: "r") == .final(.http(status: 401, body: "x", model: "m", requestID: "r")))
    }
}

extension CloudTests {
@Suite struct ClaudeCloudTests {
    @Test func haikuAnswers() async throws {
        let text: String = try await sendLLM(
            provider: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))),
            request: LLMRequest(purpose: .note, tier: .fast, system: "Yalnızca tek kelimeyle cevap ver.", userText: "Türkiye'nin başkenti?", maxTokens: 64, jsonSchema: nil, timeoutSec: 20)
        )
        #expect(text.lowercased().contains("ankara"), "metin: \(text)")
    }

    @Test func invalidKeyThrows401() async {
        do {
            _ = try await sendLLM(provider: .anthropic(defaultAnthropicConfig(apiKey: "gecersiz")), request: request(model: .haiku, schema: nil))
            Issue.record("hata bekleniyordu")
        } catch LLMError.http(let status, _, let model, let requestID) {
            #expect(status == 401)
            #expect(model == "claude-haiku-5-5")
            #expect(requestID != nil)
        } catch {
            Issue.record("beklenmeyen: \(error)")
        }
    }

    // Her model, hızlı ve akıllı sınıfta seçilebilen effort ile gerçek API'de kabul edilmeli (yanlış alan 400 verir).
    @Test(arguments: ClaudeModel.allCases)
    func everyModelAcceptsSettingsBody(model: ClaudeModel) async throws {
        let key: String = try cloudKey(account: .anthropic)
        for (tier, effort) in [(LLMTier.fast, LLMEffort.low), (.fast, .xhigh), (.smart, .medium)] {
            let config: AnthropicConfig = AnthropicConfig(apiKey: key, fastModel: model, smartModel: model, fastEffort: effort, smartEffort: effort)
            let text: String = try await sendLLM(
                provider: .anthropic(config),
                request: LLMRequest(purpose: .note, tier: tier, system: "Yalnızca tek kelimeyle cevap ver.", userText: "Türkiye'nin başkenti?", maxTokens: 4000, jsonSchema: nil, timeoutSec: 120)
            )
            #expect(text.lowercased().contains("ankara"), "model: \(model.rawValue), effort: \(effort.rawValue), metin: \(text)")
        }
    }
}
}
