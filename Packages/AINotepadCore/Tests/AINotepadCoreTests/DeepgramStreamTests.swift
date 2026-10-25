import Foundation
import Testing
@testable import AINotepadCore

/// Örnekleri verilen boyutta parçalar halinde veren ve sonra biten bir akış.
func chunkedStream(samples: [Float], chunkSize: Int) -> AsyncStream<[Float]> {
    let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    var offset: Int = 0
    while offset < samples.count {
        let end: Int = min(offset + chunkSize, samples.count)
        continuation.yield(Array(samples[offset..<end]))
        offset = end
    }
    continuation.finish()
    return stream
}

/// Metinde Arap ya da Kiril harfi var mı (multi modunda yanlış yazı denetimi).
func containsArabicOrCyrillic(text: String) -> Bool {
    text.unicodeScalars.contains { (scalar: Unicode.Scalar) -> Bool in
        (0x0600...0x06FF).contains(scalar.value) || (0x0400...0x04FF).contains(scalar.value)
    }
}

@Suite struct DeepgramTimelineTests {
    @Test func timelineOffsetsAcrossReconnects() {
        #expect(absoluteTime(deepgramSec: 2.5, connectionStartSample: 160_000, sampleRate: 16000) == 12.5)
    }
}

extension CloudTests {
@Suite struct DeepgramStreamTests {
    @Test func streamsFinnishDialog() async throws {
        let key: String = try cloudKey(account: .deepgram)
        let audio: AsyncStream<[Float]> = chunkedStream(samples: try loadFixture(name: "fi-dialog"), chunkSize: 3200)
        var finals: [(text: String, start: Double)] = []
        var failures: [String] = []
        for await event in startDeepgramStream(apiKey: key, language: .finnish, audio: audio).events {
            switch event {
            case .final(let text, let start, _): finals.append((text, start))
            case .failed(let message): failures.append(message)
            case .partial: break
            }
        }
        let joined: String = finals.map(\.text).joined(separator: " ").lowercased()
        #expect(failures.isEmpty, "hatalar: \(failures)")
        #expect(finals.count >= 2, "kesin: \(finals)")
        #expect(joined.contains("raportti") || joined.contains("raportin"), "metin: \(joined)")
        #expect(finals.map(\.start) == finals.map(\.start).sorted())
        #expect(!containsArabicOrCyrillic(text: joined), "metin: \(joined)")
    }

    // Otomatik mod: İngilizce başlayan akış Fince'ye geçince Fince metin gelmeli.
    @Test func switchesLanguageMidStream() async throws {
        let key: String = try cloudKey(account: .deepgram)
        let (audio, input): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let stream: DeepgramStream = startDeepgramStream(apiKey: key, language: .english, audio: audio)
        await stream.switchLanguage(to: .finnish)
        let fixture: [Float] = try loadFixture(name: "fi-dialog")
        for offset in stride(from: 0, to: fixture.count, by: 3200) {
            input.yield(Array(fixture[offset..<min(offset + 3200, fixture.count)]))
        }
        input.finish()
        var finals: [String] = []
        for await event in stream.events {
            if case .final(let text, _, _) = event { finals.append(text) }
            if case .failed(let message) = event { Issue.record("hata: \(message)") }
        }
        let joined: String = finals.joined(separator: " ").lowercased()
        #expect(joined.contains("raportti") || joined.contains("raportin"), "metin: \(joined)")
    }

    @Test func invalidKeyFailsWithStatus() async throws {
        let audio: AsyncStream<[Float]> = chunkedStream(samples: silence(seconds: 1), chunkSize: 3200)
        var events: [StreamingEvent] = []
        for await event in startDeepgramStream(apiKey: "gecersiz", language: .finnish, audio: audio).events {
            events.append(event)
        }
        guard case .failed(let message) = events.first else {
            Issue.record("ilk olay hata değil: \(events)")
            return
        }
        #expect(message.contains("401"), "mesaj: \(message)")
    }
}
}
