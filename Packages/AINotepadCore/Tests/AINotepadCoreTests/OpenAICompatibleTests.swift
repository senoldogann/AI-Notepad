import Foundation
import Testing
@testable import AINotepadCore

private let sampleConfig: OpenAICompatibleConfig = OpenAICompatibleConfig(
    baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, fastModel: "hizli", smartModel: "akilli", fastEffort: nil, smartEffort: nil
)

@Suite struct OpenAICompatibleTests {
    @Test func bodyHasSystemUserAndStrictSchema() throws {
        let request: LLMRequest = LLMRequest(
            tier: .smart, system: "sistem", userText: "metin", maxTokens: 512,
            jsonSchema: #"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"],"additionalProperties":false}"#, timeoutSec: 30
        )
        let body: [String: Any] = try jsonObject(openAIRequestBody(request: request, model: openAIModel(config: sampleConfig, tier: request.tier), effort: .high))
        #expect(body["model"] as? String == "akilli")
        // Effort seçiliyse akıl yürütme de sınırdan harcar: en az 64.000; effort yoksa da en az 4096 (varsayılan düşünme).
        #expect(body["max_completion_tokens"] as? Int == 64000)
        #expect(openAIMaxTokens(requested: 512, effort: nil) == 4096)
        #expect(openAIMaxTokens(requested: 16000, effort: nil) == 16000)
        #expect(body["temperature"] == nil)
        #expect(body["effort"] == nil)
        #expect(body["reasoning_effort"] as? String == "high")
        let messages: [[String: Any]] = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect((messages[0]["content"] as? String)?.contains("JSON şemasına") == true)
        let format: [String: Any] = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect((format["json_schema"] as? [String: Any])?["strict"] as? Bool == true)
    }

    @Test func modelPerTierAndURL() {
        #expect(openAIModel(config: sampleConfig, tier: .fast) == "hizli")
        #expect(openAIChatURL(baseURL: sampleConfig.baseURL).absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(openAIHeaders(apiKey: nil)["authorization"] == nil)
        #expect(openAIHeaders(apiKey: "k")["authorization"] == "Bearer k")
    }

    @Test func parseHandlesRefusalLengthAndText() throws {
        let ok: Data = Data(#"{"choices":[{"message":{"content":" Merhaba "},"finish_reason":"stop"}]}"#.utf8)
        let length: Data = Data(#"{"choices":[{"message":{"content":"yar"},"finish_reason":"length"}]}"#.utf8)
        let refusal: Data = Data(#"{"choices":[{"message":{"content":null,"refusal":"Yardım edemem"},"finish_reason":"stop"}]}"#.utf8)
        #expect(try parseOpenAIResponse(data: ok, model: "m") == "Merhaba")
        #expect(throws: LLMError.truncated(model: "m")) { try parseOpenAIResponse(data: length, model: "m") }
        #expect(throws: LLMError.refusal(category: nil)) { try parseOpenAIResponse(data: refusal, model: "m") }
        #expect(classifyOpenAIResponse(status: 503, data: Data("x".utf8), model: "m", requestID: nil) == .retryable(.http(status: 503, body: "x", model: "m", requestID: nil)))
    }

    // Yerel modeller cevabı `<think>` ile başlatabilir ve JSON'u çite sarabilir; not yine ayrıştırılmalı.
    @Test func thinkBlockAndCodeFenceAreRemoved() throws {
        let fenced: Data = Data(#"{"choices":[{"message":{"content":"<think>şemaya bakayım</think>\n```json\n{\"konu\":\"Rapor\",\"kararlar\":[],\"sendenIstenenler\":[\"Slaytlar\"]}\n```"},"finish_reason":"stop"}]}"#.utf8)
        let summary: MissedSummary = try parseMissedSummary(text: try parseOpenAIResponse(data: fenced, model: "m"))
        #expect(summary == MissedSummary(topic: "Rapor", decisions: [], askedOfYou: ["Slaytlar"]))
        #expect(strippingThinkBlock(text: "Merhaba") == "Merhaba")
        #expect(jsonBody(text: "{\"a\":1}") == "{\"a\":1}")
    }

    @Test func missingModelIsNotConfigured() async {
        let config: OpenAICompatibleConfig = OpenAICompatibleConfig(baseURL: sampleConfig.baseURL, apiKey: nil, fastModel: "", smartModel: "akilli", fastEffort: nil, smartEffort: nil)
        await #expect(throws: LLMError.notConfigured(detail: "çeviri modeli")) {
            _ = try await sendLLM(provider: .openAICompatible(config), request: translationRequest(sentence: "Hei", context: [], language: .turkish))
        }
    }
}

/// Yerel Ollama'ya gerçek çağrı; yalnızca `AINOTEPAD_OLLAMA_MODEL` (ör. "bonsai-2:9b") verilmişse çalışır.
let ollamaModel: String? = ProcessInfo.processInfo.environment["AINOTEPAD_OLLAMA_MODEL"]

@Suite(.enabled(if: ollamaModel != nil), .serialized)
struct OllamaTests {
    private func config() throws -> OpenAICompatibleConfig {
        let model: String = try #require(ollamaModel)
        return OpenAICompatibleConfig(baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, fastModel: model, smartModel: model, fastEffort: nil, smartEffort: nil)
    }

    @Test func translatesFinnishSentence() async throws {
        let text: String = try await sendLLM(
            provider: .openAICompatible(try config()),
            request: LLMRequest(tier: .fast, system: "Cümleyi Türkçeye çevir; yalnızca çeviriyi yaz.", userText: "Hyvää huomenta kaikille.", maxTokens: 4000, jsonSchema: nil, timeoutSec: 120)
        )
        #expect(!text.isEmpty)
    }

    // Akışlı yol: metin parça parça gelir, sondaki doğrulama tam metni verir (düşünme bölümü görünmez).
    @Test func streamsAnswer() async throws {
        let parts: StreamBox = StreamBox()
        let text: String = try await streamLLM(
            provider: .openAICompatible(try config()),
            request: LLMRequest(tier: .smart, system: "Türkçe cevap ver.", userText: "Fince'de 'günaydın' nasıl denir? İki cümleyle anlat.", maxTokens: 4000, jsonSchema: nil, timeoutSec: 180)
        ) { (partial: String) -> Void in
            parts.append(partial)
        }
        #expect(!text.isEmpty && parts.values.count > 1, "parça: \(parts.values.count)")
        #expect(parts.values.allSatisfy { !$0.contains("<think>") })
    }

    @Test func structuredMissedSummary() async throws {
        let segments: [LiveSegment] = [
            LiveSegment(id: SegmentID(speaker: .others, index: 0), startSec: 0, endSec: 4, text: "Päätimme, että raportti valmistuu perjantaina.", isFinal: true, failureMessage: nil, person: 1),
            LiveSegment(id: SegmentID(speaker: .others, index: 1), startSec: 5, endSec: 9, text: "Doğan, voisitko tehdä diat?", isFinal: true, failureMessage: nil, person: 1),
        ]
        let request: LLMRequest = try #require(missedSummaryRequest(segments: segments, nowSec: 10, windowSec: 180, language: .turkish))
        // Uygulamayla aynı yol: şemaya uymayan yanıt (yerel modeller arada bir alan atlar) yeniden istenir.
        let summary: MissedSummary = try await requestStructured(provider: .openAICompatible(try config()), request: request) { (text: String) throws -> MissedSummary in
            try parseMissedSummary(text: text)
        }
        #expect(!summary.topic.isEmpty)
    }
}

@Suite struct LLMSettingsTests {
    @Test func validatesBaseURLAndModels() throws {
        let config: OpenAICompatibleConfig = try openAICompatibleConfig(baseURLText: " http://localhost:11434/v1 ", apiKey: "", fastModel: "a", smartModel: "b", fastEffort: nil, smartEffort: nil)
        #expect(config.baseURL.absoluteString == "http://localhost:11434/v1")
        #expect(config.apiKey == nil)
        #expect(throws: LLMError.self) { try openAICompatibleConfig(baseURLText: "localhost", apiKey: nil, fastModel: "a", smartModel: "b", fastEffort: nil, smartEffort: nil) }
        // Ağdaki adrese şifresiz http reddedilir (anahtar ve toplantı metni açık giderdi); bu bilgisayar ve https kabul.
        #expect(throws: LLMError.self) { try openAICompatibleConfig(baseURLText: "http://192.168.1.10:11434/v1", apiKey: "k", fastModel: "a", smartModel: "b", fastEffort: nil, smartEffort: nil) }
        #expect(throws: LLMError.self) { try openAICompatibleConfig(baseURLText: "http://ollama.local:11434/v1", apiKey: nil, fastModel: "a", smartModel: "b", fastEffort: nil, smartEffort: nil) }
        #expect((try? openAICompatibleConfig(baseURLText: "http://127.0.0.1:11434/v1", apiKey: nil, fastModel: "a", smartModel: "b", fastEffort: nil, smartEffort: nil)) != nil)
        #expect(throws: LLMError.self) { try openAICompatibleConfig(baseURLText: "https://api.openai.com/v1", apiKey: "k", fastModel: "", smartModel: "b", fastEffort: nil, smartEffort: nil) }
    }
}

/// Akış parçalarını toplar (testte eşzamanlı erişim için kilitli).
private final class StreamBox: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var stored: [String] = []

    func append(_ value: String) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
