import Foundation
import Testing
@testable import AINotepadCore

@Suite struct PostMeetingFixTests {
    @Test func userFacingMessagesAreTurkishAndActionable() {
        #expect(userFacingMessage(error: LLMError.http(status: 401, body: "x", model: "claude-opus-5-5", requestID: nil)).contains("Anthropic anahtarı geçersiz"))
        #expect(userFacingMessage(error: LLMError.http(status: 429, body: "x", model: "claude-opus-5-5", requestID: nil)).contains("HTTP 429"))
        #expect(userFacingMessage(error: CloudSTTError.http(service: "elevenlabs", status: 401, body: "x")).contains("ElevenLabs anahtarı geçersiz"))
        #expect(userFacingMessage(error: KeychainError.notFound(service: "AINotepad", account: "anthropic")).contains("Ayarlar"))
        #expect(!userFacingMessage(error: LLMError.empty).contains("operation couldn"))
    }

    // Son geçiş bölümleri canlı bölümlerden farklı sınırlarla gelir; Türkçesi zaman kesişimiyle taşınır.
    @Test func translationsAlignToFinalSegmentsByTime() {
        let live: [StoredSegment] = [
            StoredSegment(key: "others-0", speaker: .others, person: nil, startSec: 0, endSec: 3, text: "a"),
            StoredSegment(key: "others-1", speaker: .others, person: nil, startSec: 3, endSec: 6, text: "b"),
            StoredSegment(key: "me-0", speaker: .me, person: nil, startSec: 6, endSec: 8, text: "c"),
        ]
        let final: [StoredSegment] = [
            StoredSegment(key: "final-0", speaker: .others, person: 1, startSec: 0.2, endSec: 5.8, text: "a b"),
            StoredSegment(key: "final-1", speaker: .others, person: 2, startSec: 20, endSec: 22, text: "d"),
        ]
        let aligned: [String: String] = alignTranslations(final: final, live: live, translations: ["others-0": "A", "others-1": "B", "me-0": "C"])
        #expect(aligned == ["final-0": "A B"])
    }
}
