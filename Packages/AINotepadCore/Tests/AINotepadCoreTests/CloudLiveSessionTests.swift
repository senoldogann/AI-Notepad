import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

/// Örnekleri gerçek zaman hızında (3200 örnek / 0,2 sn) veren akış.
func pacedStream(samples: [Float]) -> AsyncStream<[Float]> {
    let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    Task {
        for offset in stride(from: 0, to: samples.count, by: 3200) {
            continuation.yield(Array(samples[offset..<min(offset + 3200, samples.count)]))
            try await Task.sleep(for: .milliseconds(200))
        }
        continuation.finish()
    }
    return stream
}

func cloudConfig(
    directory: URL,
    firstDiarizationAfterSec: Double,
    diarizationIntervalSec: Double,
    minDiarizationAudioSec: Double,
    elevenLabsKey: String
) throws -> CloudSessionConfig {
    CloudSessionConfig(
        languageMode: .automatic,
        recordingDirectory: directory,
        deepgramKey: try cloudKey(account: .deepgram),
        elevenLabsKey: elevenLabsKey,
        firstDiarizationAfterSec: firstDiarizationAfterSec,
        diarizationIntervalSec: diarizationIntervalSec,
        diarizationWindowSec: 120,
        minDiarizationAudioSec: minDiarizationAudioSec,
        languageConfidence: 0.8
    )
}

func collect(events: AsyncStream<LiveSessionEvent>) async -> [LiveSessionEvent] {
    var all: [LiveSessionEvent] = []
    for await event in events {
        all.append(event)
    }
    return all
}

func finalOthersText(events: [LiveSessionEvent]) -> String {
    events.reduce([LiveSegment]()) { applyEvent(transcript: $0, event: $1) }
        .filter { (segment: LiveSegment) -> Bool in segment.id.speaker == .others && segment.isFinal }
        .map(\.text)
        .joined(separator: " ")
        .lowercased()
}

func failures(events: [LiveSessionEvent]) -> [LiveSessionEvent] {
    events.filter { (event: LiveSessionEvent) -> Bool in
        switch event {
        case .streamFailed, .diarizationFailed, .recordingFailed: true
        default: false
        }
    }
}

extension CloudTests {
@Suite struct CloudLiveSessionTests {
    @Test func finnishDialogEndToEnd() async throws {
        let fixture: [Float] = try loadFixture(name: "fi-dialog")
        let directory: URL = try temporaryDirectory()
        // Yalnızca oturum sonundaki son pencere çalışır.
        let config: CloudSessionConfig = try cloudConfig(directory: directory, firstDiarizationAfterSec: 1000, diarizationIntervalSec: 1000, minDiarizationAudioSec: 5, elevenLabsKey: try cloudKey(account: .elevenlabs))
        let events: [LiveSessionEvent] = await collect(events: runCloudLiveSession(
            config: config,
            meAudio: pacedStream(samples: silence(seconds: 12)),
            othersAudio: pacedStream(samples: fixture)
        ))

        let text: String = finalOthersText(events: events)
        #expect(text.contains("raportti") || text.contains("raportin"), "metin: \(text)")
        let persons: Set<Int> = events.reduce(into: Set<Int>()) { (found: inout Set<Int>, event: LiveSessionEvent) -> Void in
            if case .speakersAssigned(let assignments) = event { found.formUnion(assignments.values) }
        }
        #expect(persons.count >= 2, "kişiler: \(persons)")
        #expect(events.contains(.captureEnded(speaker: .me)))
        #expect(events.contains(.captureEnded(speaker: .others)))
        #expect(failures(events: events).isEmpty, "hatalar: \(failures(events: events))")
        #expect(try AVAudioFile(forReading: directory.appending(path: "others.caf")).length == AVAudioFramePosition(fixture.count))
    }

    @Test func englishMeetingSwitchesLanguage() async throws {
        let english: [Float] = try loadFixture(name: "en-meeting")
        let others: [Float] = english + english
        let config: CloudSessionConfig = try cloudConfig(directory: try temporaryDirectory(), firstDiarizationAfterSec: 5, diarizationIntervalSec: 1000, minDiarizationAudioSec: 3, elevenLabsKey: try cloudKey(account: .elevenlabs))
        let events: [LiveSessionEvent] = await collect(events: runCloudLiveSession(
            config: config,
            meAudio: pacedStream(samples: silence(seconds: Double(others.count) / 16000)),
            othersAudio: pacedStream(samples: others)
        ))

        #expect(events.contains(.languageLocked(.english)))
        let text: String = finalOthersText(events: events)
        #expect(text.contains("presentation"), "metin: \(text)")
        #expect(failures(events: events).isEmpty, "hatalar: \(failures(events: events))")
    }

    // Geçersiz anahtar her pencerede aynı hatayı üretmemeli: bir kez bildirilir, ayırma durur.
    @Test func invalidElevenLabsKeyReportsOnce() async throws {
        let config: CloudSessionConfig = try cloudConfig(directory: try temporaryDirectory(), firstDiarizationAfterSec: 2, diarizationIntervalSec: 3, minDiarizationAudioSec: 1, elevenLabsKey: "gecersiz")
        let fixture: [Float] = try loadFixture(name: "fi-dialog")
        let events: [LiveSessionEvent] = await collect(events: runCloudLiveSession(
            config: config,
            meAudio: pacedStream(samples: silence(seconds: Double(fixture.count) / 16000)),
            othersAudio: pacedStream(samples: fixture)
        ))
        let diarizationFailures: [LiveSessionEvent] = events.filter { (event: LiveSessionEvent) -> Bool in
            if case .diarizationFailed = event { return true }
            return false
        }
        #expect(diarizationFailures.count == 1, "hatalar: \(diarizationFailures)")
        #expect(finalOthersText(events: events).contains("raport"), "metin akmaya devam etmeli")
    }

    // Durdurma anında süren konuşmacı ayırma isteği sahte "iptal" hatası üretmemeli.
    @Test func stopDuringDiarizationIsClean() async throws {
        let fixture: [Float] = try loadFixture(name: "fi-dialog")
        let config: CloudSessionConfig = try cloudConfig(directory: try temporaryDirectory(), firstDiarizationAfterSec: 13, diarizationIntervalSec: 1000, minDiarizationAudioSec: 1, elevenLabsKey: try cloudKey(account: .elevenlabs))
        let events: [LiveSessionEvent] = await collect(events: runCloudLiveSession(
            config: config,
            meAudio: pacedStream(samples: silence(seconds: Double(fixture.count) / 16000)),
            othersAudio: pacedStream(samples: fixture)
        ))
        #expect(failures(events: events).isEmpty, "hatalar: \(failures(events: events))")
    }
}
}
