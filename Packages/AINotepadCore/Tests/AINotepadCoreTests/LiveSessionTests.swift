import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

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
            languageLockAfterSec: 5,
            candidateLanguages: [.finnish, .english]
        )

        var events: [LiveSessionEvent] = []
        for await event in runLiveSession(
            config: config,
            engine: engine,
            meAudio: chunkedStream(samples: silence(seconds: 10), chunkSize: 1600),
            othersAudio: chunkedStream(samples: fixture, chunkSize: 1600)
        ).events {
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

    // Sabit Fince seçiliyken kullanıcı İngilizceye geçerse sonraki bölümler İngilizce yazılır.
    @Test func userSwitchesLanguage() async throws {
        let engine: WhisperKitEngine = try await sharedTestEngine.value
        let english: [Float] = try loadFixture(name: "en-meeting")
        let config: LiveSessionConfig = LiveSessionConfig(
            languageMode: .fixed(.finnish), segmenter: .live, recordingDirectory: try temporaryDirectory(),
            partialIntervalSec: 1000, minPartialSpeechSec: 1.0, languageLockAfterSec: 5, candidateLanguages: [.finnish, .english]
        )
        let (others, othersInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let handle: LiveSessionHandle = runLiveSession(
            config: config, engine: engine,
            meAudio: chunkedStream(samples: silence(seconds: 1), chunkSize: 1600),
            othersAudio: others
        )
        await handle.setLanguage(.english)
        othersInput.yield(english)
        othersInput.finish()
        let events: [LiveSessionEvent] = await collect(events: handle.events)
        let text: String = finalOthersText(events: events)
        #expect(events.contains(.languageLocked(.english)))
        #expect(text.contains("presentation"), "metin: \(text)")
    }
}
}
