import Foundation
import Testing
@testable import AINotepadCore

@Suite struct OllamaDetectionTests {
    // Gömme modelleri seçilmez; yerel bilinen aile buluttan önce gelir.
    @Test func recommendationPrefersLocalChatModels() {
        let names: [String] = ["mxbai-embed-large:latest", "gpt-oss:120b-cloud", "bonsai-2:9b", "qwen3.5:9b", "bge-m3:latest"]
        #expect(recommendedOllamaModel(names: names) == "qwen3.5:9b")
        #expect(recommendedOllamaModel(names: ["gpt-oss:20b-cloud", "bge-m3:latest"]) == "gpt-oss:20b-cloud")
        #expect(recommendedOllamaModel(names: ["bge-m3:latest"]) == nil)
    }

    // Gerçek Ollama (yerelde çalışıyorsa): yüklü modeller listelenir; kapalı bir adres anlaşılır hata verir.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AINOTEPAD_OLLAMA_MODEL"] != nil))
    func listsInstalledModels() async throws {
        let models: [String] = try await ollamaModels(baseURL: URL(string: "http://localhost:11434/v1")!)
        #expect(models.contains(ProcessInfo.processInfo.environment["AINOTEPAD_OLLAMA_MODEL"]!))
        await #expect(throws: OllamaError.self) {
            try await ollamaModels(baseURL: URL(string: "http://localhost:9")!)
        }
    }
}
