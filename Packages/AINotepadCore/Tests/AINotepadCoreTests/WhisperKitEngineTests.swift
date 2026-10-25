import Foundation
import Testing
@testable import AINotepadCore

extension ModelTests {
@Suite struct WhisperKitEngineTests {

    @Test func detectsFinnish() async throws {
        let engine: WhisperKitEngine = try await sharedTestEngine.value
        let logProbs: [String: Float] = try await engine.detectLanguage(samples: loadFixture(name: "fi-meeting"))
        #expect(pickLanguage(logProbs: logProbs) == .finnish)
    }

    @Test func detectsEnglish() async throws {
        let engine: WhisperKitEngine = try await sharedTestEngine.value
        let logProbs: [String: Float] = try await engine.detectLanguage(samples: loadFixture(name: "en-meeting"))
        #expect(pickLanguage(logProbs: logProbs) == .english)
    }

    @Test func transcribesFinnishKeywords() async throws {
        let engine: WhisperKitEngine = try await sharedTestEngine.value
        let text: String = try await engine.transcribe(samples: loadFixture(name: "fi-meeting"), language: .finnish)
        #expect(text.lowercased().contains("raportti"), "metin: \(text)")
        #expect(text.lowercased().contains("esitykse"), "metin: \(text)")
    }

    @Test func transcribesEnglishKeywords() async throws {
        let engine: WhisperKitEngine = try await sharedTestEngine.value
        let text: String = try await engine.transcribe(samples: loadFixture(name: "en-meeting"), language: .english)
        #expect(text.lowercased().contains("report"), "metin: \(text)")
        #expect(text.lowercased().contains("presentation"), "metin: \(text)")
    }

    @Test func transcribeReturnsEmptyForNoise() async throws {
        let engine: WhisperKitEngine = try await sharedTestEngine.value
        let noise: [Float] = whiteNoise(seconds: 3, amplitude: 0.005, seed: 42)
        let text: String = try await engine.transcribe(samples: noise, language: .finnish)
        #expect(text.isEmpty, "metin: \(text)")
    }
}
}
