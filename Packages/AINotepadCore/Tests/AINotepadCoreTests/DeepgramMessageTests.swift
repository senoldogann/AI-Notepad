import Foundation
import Testing
@testable import AINotepadCore

@Suite struct DeepgramMessageTests {
    func result(isFinal: Bool) -> Data {
        Data("""
        {"type":"Results","start":4.2,"duration":4.0,"is_final":\(isFinal),"speech_final":false,
         "channel":{"alternatives":[{"transcript":"Hei","words":[]}]}}
        """.utf8)
    }

    @Test func parsesInterimResult() throws {
        #expect(try parseDeepgramMessage(data: result(isFinal: false))
            == .results(DeepgramResult(startSec: 4.2, endSec: 8.2, transcript: "Hei", isFinal: false)))
    }

    @Test func parsesFinalResult() throws {
        #expect(try parseDeepgramMessage(data: result(isFinal: true))
            == .results(DeepgramResult(startSec: 4.2, endSec: 8.2, transcript: "Hei", isFinal: true)))
    }

    @Test func parsesMetadata() throws {
        #expect(try parseDeepgramMessage(data: Data(#"{"type":"Metadata","request_id":"r1"}"#.utf8)) == .metadata(requestID: "r1"))
    }

    @Test func unknownTypeIsOther() throws {
        #expect(try parseDeepgramMessage(data: Data(#"{"type":"SpeechStarted"}"#.utf8)) == .other(type: "SpeechStarted"))
    }

    @Test func malformedThrows() {
        #expect(throws: CloudSTTError.malformedMessage(service: "deepgram", body: "{nope")) {
            try parseDeepgramMessage(data: Data("{nope".utf8))
        }
    }

    @Test func urlHasStreamingParameters() throws {
        let query: String = try #require(deepgramListenURL(language: .finnish).query)
        for part in ["language=fi", "model=nova-3", "encoding=linear16", "sample_rate=16000", "channels=1", "interim_results=true", "smart_format=true"] {
            #expect(query.contains(part), "eksik: \(part)")
        }
        #expect(!query.contains("multi"))
    }

    @Test func urlUsesEnForEnglish() throws {
        #expect(try #require(deepgramListenURL(language: .english).query).contains("language=en"))
    }
}
