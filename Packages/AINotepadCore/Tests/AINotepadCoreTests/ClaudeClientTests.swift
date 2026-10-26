import Foundation
import Testing
@testable import AINotepadCore

/// JSON gövdesini sözlüğe çevirir.
func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

func request(model: ClaudeModel, schema: String?) -> ClaudeRequest {
    ClaudeRequest(model: model, system: "sistem", userText: "metin", maxTokens: 1024, effort: model == .haiku ? "low" : "medium", jsonSchema: schema)
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
            request: ClaudeRequest(model: .haiku, system: "Yalnızca tek kelimeyle cevap ver.", userText: "Türkiye'nin başkenti?", maxTokens: 64, effort: "low", jsonSchema: nil)
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
