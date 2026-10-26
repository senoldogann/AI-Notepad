import Foundation
import Testing
@testable import AINotepadCore

/// JSON gövdesini sözlüğe çevirir.
func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Varsayılan ayar: çeviri Haiku 5.5 (low), özet ve not Opus 5.5 (medium).
func defaultAnthropicConfig(apiKey: String) -> AnthropicConfig {
    AnthropicConfig(apiKey: apiKey, fastModel: .haiku, smartModel: .opus, fastEffort: .low, smartEffort: .medium)
}

func request(model: ClaudeModel, schema: String?) -> LLMRequest {
    LLMRequest(tier: model == .haiku ? .fast : .smart, system: "sistem", userText: "metin", maxTokens: 1024, jsonSchema: schema, timeoutSec: 20)
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

    @Test func parseJoinsTextSkipsThinking() throws {
        let data: Data = Data(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"Merhaba"},{"type":"text","text":" dünya"}]}"#.utf8)
        #expect(try parseClaudeResponse(data: data, model: "m") == "Merhaba dünya")
    }

    // Yalnızca 408/429/5xx yeniden denenir; 200 içindeki reddetme/bozuk yanıt ve diğer 4xx kesin sonuçtur.
    @Test func classifyRetriesOnlyTransientFailures() {
        let ok: Data = Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"Merhaba"}]}"#.utf8)
        let refusal: Data = Data(#"{"stop_reason":"refusal","stop_details":{"category":"cyber"},"content":[]}"#.utf8)
        #expect(classifyClaudeResponse(status: 200, data: ok, model: "m", requestID: nil) == .success("Merhaba"))
        #expect(classifyClaudeResponse(status: 200, data: refusal, model: "m", requestID: nil) == .final(.refusal(category: "cyber")))
        #expect(classifyClaudeResponse(status: 200, data: Data("{".utf8), model: "m", requestID: nil) == .final(.malformed(body: "{")))
        #expect(classifyClaudeResponse(status: 429, data: Data("x".utf8), model: "m", requestID: "r") == .retryable(.http(status: 429, body: "x", model: "m", requestID: "r")))
        #expect(classifyClaudeResponse(status: 503, data: Data("x".utf8), model: "m", requestID: "r") == .retryable(.http(status: 503, body: "x", model: "m", requestID: "r")))
        #expect(classifyClaudeResponse(status: 401, data: Data("x".utf8), model: "m", requestID: "r") == .final(.http(status: 401, body: "x", model: "m", requestID: "r")))
    }

    @Test func refusalIsError() {
        let data: Data = Data(#"{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"},"content":[]}"#.utf8)
        #expect(throws: LLMError.refusal(category: "cyber")) {
            try parseClaudeResponse(data: data, model: "m")
        }
    }
}

extension CloudTests {
@Suite struct ClaudeCloudTests {
    @Test func haikuAnswers() async throws {
        let text: String = try await sendLLM(
            provider: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))),
            request: LLMRequest(tier: .fast, system: "Yalnızca tek kelimeyle cevap ver.", userText: "Türkiye'nin başkenti?", maxTokens: 64, jsonSchema: nil, timeoutSec: 20)
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
                request: LLMRequest(tier: tier, system: "Yalnızca tek kelimeyle cevap ver.", userText: "Türkiye'nin başkenti?", maxTokens: 4000, jsonSchema: nil, timeoutSec: 120)
            )
            #expect(text.lowercased().contains("ankara"), "model: \(model.rawValue), effort: \(effort.rawValue), metin: \(text)")
        }
    }
}
}
