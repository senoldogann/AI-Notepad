import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

/// Örnekleri 1600'lük parçalar halinde veren ve sonra biten bir akış.
func chunkedStream(samples: [Float]) -> AsyncStream<[Float]> {
    let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    var offset: Int = 0
    while offset < samples.count {
        let end: Int = min(offset + 1600, samples.count)
        continuation.yield(Array(samples[offset..<end]))
        offset = end
    }
    continuation.finish()
    return stream
}

extension ModelTests {
@Suite struct LiveSessionTests {
    @Test func finnishMeetingEndToEnd() async throws {
        let engine: WhisperKitEngine = try await sharedTestEngine.value
        let fixture: [Float] = try loadFixture(name: "fi-meeting")
        let directory: URL = try temporaryDirectory()
        let config: LiveSessionConfig = LiveSessionConfig(
            languageMode: .automatic,
            segmenter: .live,
            recordingDirectory: directory,
            partialIntervalSec: 1.5,
            minPartialSpeechSec: 1.0,
            languageLockAfterSec: 5
        )

        var events: [LiveSessionEvent] = []
        for await event in runLiveSession(
            config: config,
            engine: engine,
            meAudio: chunkedStream(samples: silence(seconds: 10)),
            othersAudio: chunkedStream(samples: fixture)
        ) {
            events.append(event)
        }
        let transcript: [LiveSegment] = events.reduce([]) { (current: [LiveSegment], event: LiveSessionEvent) -> [LiveSegment] in
            applyEvent(transcript: current, event: event)
        }
        let othersText: String = transcript
            .filter { (item: LiveSegment) -> Bool in item.id.speaker == .others && item.isFinal }
            .map(\.text)
            .joined(separator: " ")
            .lowercased()

        #expect(events.contains(.languageLocked(.finnish)))
        #expect(othersText.contains("raportti"), "metin: \(othersText)")
        #expect(!transcript.contains { (item: LiveSegment) -> Bool in item.id.speaker == .me })
        #expect(events.contains(.captureEnded(speaker: .me)))
        #expect(events.contains(.captureEnded(speaker: .others)))
        #expect(try AVAudioFile(forReading: directory.appending(path: "others.caf")).length == AVAudioFramePosition(fixture.count))
        #expect(try AVAudioFile(forReading: directory.appending(path: "me.caf")).length == 160_000)
    }
}
}
