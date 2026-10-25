import Foundation
import Testing
@testable import AINotepadCore

@Suite struct ElevenLabsParsingTests {
    let response: Data = Data("""
    {"language_code":"fin","language_probability":0.98,"text":"Hei Moi","words":[
      {"text":"Hei","start":0.1,"end":0.4,"type":"word","speaker_id":"speaker_0","logprob":-0.1},
      {"text":" ","start":0.4,"end":0.4,"type":"spacing","speaker_id":"speaker_0","logprob":-0.1},
      {"text":"Moi","start":0.9,"end":1.2,"type":"word","speaker_id":"speaker_1","logprob":-0.2}]}
    """.utf8)

    @Test func parsesWordsAndSkipsSpacing() throws {
        let result: DiarizationResult = try parseElevenLabsResponse(data: response)
        #expect(result.words == [
            DiarizedWord(text: "Hei", startSec: 0.1, endSec: 0.4, speaker: "speaker_0"),
            DiarizedWord(text: "Moi", startSec: 0.9, endSec: 1.2, speaker: "speaker_1"),
        ])
        #expect(result.languageCode == "fin")
        #expect(result.languageProbability == 0.98)
    }

    @Test func wordWithoutSpeakerThrows() {
        let body: String = #"{"words":[{"text":"Hei","start":0.1,"end":0.4,"type":"word"}]}"#
        #expect(throws: CloudSTTError.malformedMessage(service: "elevenlabs", body: body)) {
            try parseElevenLabsResponse(data: Data(body.utf8))
        }
    }

    @Test func languageCodes() {
        #expect(elevenLabsLanguageCode(languageMode: .automatic) == nil)
        #expect(elevenLabsLanguageCode(languageMode: .fixed(.finnish)) == "fin")
        #expect(elevenLabsLanguageCode(languageMode: .fixed(.english)) == "eng")
        #expect(meetingLanguage(elevenLabsCode: "fin") == .finnish)
        #expect(meetingLanguage(elevenLabsCode: "eng") == .english)
        #expect(meetingLanguage(elevenLabsCode: "swe") == nil)
    }
}

extension CloudTests {
@Suite struct ElevenLabsTests {
    @Test func diarizesDialogIntoSeveralSpeakers() async throws {
        let result: DiarizationResult = try await diarizeWithElevenLabs(
            apiKey: try cloudKey(account: .elevenlabs),
            samples: try loadFixture(name: "fi-dialog"),
            languageMode: .automatic
        )
        #expect(!result.words.isEmpty)
        #expect(Set(result.words.map(\.speaker)).count >= 2, "konuşmacılar: \(Set(result.words.map(\.speaker)))")
        #expect(result.languageCode == "fin")
    }

    @Test func invalidKeyThrowsWithStatus() async {
        do {
            _ = try await diarizeWithElevenLabs(apiKey: "gecersiz", samples: silence(seconds: 1), languageMode: .automatic)
            Issue.record("hata bekleniyordu")
        } catch CloudSTTError.http(let service, let status, _) {
            #expect(service == "elevenlabs")
            #expect(status == 401)
        } catch {
            Issue.record("beklenmeyen hata: \(error)")
        }
    }
}
}
