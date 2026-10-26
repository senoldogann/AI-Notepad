import Foundation
import Testing
@testable import AINotepadCore

/// JSON gövdesini sözlüğe çevirir.
func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

func request(model: ClaudeModel, schema: String?) -> ClaudeRequest {
    ClaudeRequest(model: model, system: "sistem", userText: "metin", maxTokens: 1024, effort: model == .haiku ? "low" : "medium", jsonSchema: schema, timeoutSec: 20)
}

@Suite struct ClaudeClientTests {
    @Test func haikuBodyDisablesThinkingLowEffort() throws {
        let body: [String: Any] = try jsonObject(claudeRequestBody(request: request(model: .haiku, schema: nil)))
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
        let body: [String: Any] = try jsonObject(claudeRequestBody(request: request(model: .opus, schema: nil)))
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

    @Test func schemaGoesToOutputConfigFormat() throws {
        let schema: String = #"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"],"additionalProperties":false}"#
        let body: [String: Any] = try jsonObject(claudeRequestBody(request: request(model: .opus, schema: schema)))
        let format: [String: Any] = try #require((body["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect((format["schema"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test func parseJoinsTextSkipsThinking() throws {
        let data: Data = Data(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"Merhaba"},{"type":"text","text":" dünya"}]}"#.utf8)
        #expect(try parseClaudeResponse(data: data) == "Merhaba dünya")
    }

    // Yalnızca 429/5xx yeniden denenir; 200 içindeki reddetme/bozuk yanıt ve diğer 4xx kesin sonuçtur.
    @Test func classifyRetriesOnlyTransientFailures() {
        let ok: Data = Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"Merhaba"}]}"#.utf8)
        let refusal: Data = Data(#"{"stop_reason":"refusal","stop_details":{"category":"cyber"},"content":[]}"#.utf8)
        #expect(classifyClaudeResponse(status: 200, data: ok) == .success("Merhaba"))
        #expect(classifyClaudeResponse(status: 200, data: refusal) == .final(.refusal(category: "cyber")))
        #expect(classifyClaudeResponse(status: 200, data: Data("{".utf8)) == .final(.malformed(body: "{")))
        #expect(classifyClaudeResponse(status: 429, data: Data("x".utf8)) == .retryable(.http(status: 429, body: "x")))
        #expect(classifyClaudeResponse(status: 503, data: Data("x".utf8)) == .retryable(.http(status: 503, body: "x")))
        #expect(classifyClaudeResponse(status: 401, data: Data("x".utf8)) == .final(.http(status: 401, body: "x")))
    }

    @Test func refusalIsError() {
        let data: Data = Data(#"{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"},"content":[]}"#.utf8)
        #expect(throws: LLMError.refusal(category: "cyber")) {
            try parseClaudeResponse(data: data)
        }
    }
}

extension CloudTests {
@Suite struct ClaudeCloudTests {
    @Test func haikuAnswers() async throws {
        let text: String = try await sendClaude(
            apiKey: try cloudKey(account: .anthropic),
            request: ClaudeRequest(model: .haiku, system: "Yalnızca tek kelimeyle cevap ver.", userText: "Türkiye'nin başkenti?", maxTokens: 64, effort: "low", jsonSchema: nil, timeoutSec: 20)
        )
        #expect(text.lowercased().contains("ankara"), "metin: \(text)")
    }

    @Test func invalidKeyThrows401() async {
        do {
            _ = try await sendClaude(apiKey: "gecersiz", request: request(model: .haiku, schema: nil))
            Issue.record("hata bekleniyordu")
        } catch LLMError.http(let status, _) {
            #expect(status == 401)
        } catch {
            Issue.record("beklenmeyen: \(error)")
        }
    }
}
}
