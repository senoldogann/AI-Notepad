import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

@Suite struct MediaImportTests {
    // Gerçek dosyalar: WAV ve (afconvert ile) 44.1 kHz stereo M4A 16 kHz mono AAC'ye dönüşür, süre korunur; sessiz/
    // olmayan dosya anlaşılır hata verir.
    @Test func importsAudioFiles() async throws {
        let fixture: URL = try #require(Bundle.module.url(forResource: "fi-dialog", withExtension: "wav", subdirectory: "Fixtures"))
        let directory: URL = try temporaryDirectory()
        let duration: Double = try await importMediaAudio(source: fixture, destination: directory.appending(path: "a.m4a"))
        let expected: Double = Double(try loadFixture(name: "fi-dialog").count) / 16000
        #expect(abs(duration - expected) < 0.2)
        let file: AVAudioFile = try AVAudioFile(forReading: directory.appending(path: "a.m4a"))
        #expect(file.fileFormat.sampleRate == 16000 && file.fileFormat.channelCount == 1)

        let stereo: URL = directory.appending(path: "stereo.m4a")
        let process: Process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "m4af", "-d", "aac@44100", "-c", "2", fixture.path, stereo.path]
        try process.run()
        process.waitUntilExit()
        let converted: Double = try await importMediaAudio(source: stereo, destination: directory.appending(path: "b.m4a"))
        #expect(abs(converted - expected) < 0.3)

        let text: URL = directory.appending(path: "not-audio.txt")
        try Data("merhaba".utf8).write(to: text)
        await #expect(throws: MediaImportError.self) {
            try await importMediaAudio(source: text, destination: directory.appending(path: "c.m4a"))
        }
    }
}

extension CloudTests {
@Suite struct MediaImportCloudTests {
    // Gerçek uçtan uca: dosya içe aktarılır, ElevenLabs son geçişi konuşmacıları ayırır, Claude notu yazar.
    @Test func importedFileBecomesMeetingWithNote() async throws {
        let fixture: URL = try #require(Bundle.module.url(forResource: "fi-dialog", withExtension: "wav", subdirectory: "Fixtures"))
        let directory: URL = try temporaryDirectory()
        let duration: Double = try await importMediaAudio(source: fixture, destination: directory.appending(path: "others.m4a"))
        let record: MeetingRecord = importedMeetingRecord(id: "import", source: fixture, startedAt: Date(), durationSec: duration, engine: .cloud, template: .general)
        let result: MeetingRecord = await processMeeting(
            record: record, directory: directory,
            finalPass: .run(ElevenLabsFinalTranscriber(apiKey: try cloudKey(account: .elevenlabs), keyterms: [])),
            llm: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))), languageMode: .automatic, userName: "Doğan",
            voiceEmbedder: nil, registry: [], onStep: { (_: ProcessingStep) async -> Void in }
        )
        #expect(result.status == .done, "\(result.failureMessage ?? "")")
        #expect(Set(result.finalSegments.compactMap(\.person)).count >= 2)
        #expect(result.note != nil)
        #expect(result.language == .finnish)
    }

    // İsveççe dosya: dil İsveççe algılanır, not Türkçe yazılır (rapor ve bütçe Türkçe geçer).
    @Test func swedishFileBecomesTurkishNote() async throws {
        let fixture: URL = try #require(Bundle.module.url(forResource: "sv-meeting", withExtension: "wav", subdirectory: "Fixtures"))
        let directory: URL = try temporaryDirectory()
        let duration: Double = try await importMediaAudio(source: fixture, destination: directory.appending(path: "others.m4a"))
        let record: MeetingRecord = importedMeetingRecord(id: "import-sv", source: fixture, startedAt: Date(), durationSec: duration, engine: .cloud, template: .general)
        let result: MeetingRecord = await processMeeting(
            record: record, directory: directory,
            finalPass: .run(ElevenLabsFinalTranscriber(apiKey: try cloudKey(account: .elevenlabs), keyterms: [])),
            llm: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))), languageMode: .automatic, userName: "Doğan",
            voiceEmbedder: nil, registry: [], onStep: { (_: ProcessingStep) async -> Void in }
        )
        #expect(result.status == .done, "\(result.failureMessage ?? "")")
        #expect(result.language == .swedish)
        let note: MeetingNote = try #require(result.note)
        let text: String = (note.summary + " " + note.tasks.map(\.description).joined(separator: " ")).lowercased()
        #expect(["rapor", "bütçe", "sunum"].contains { text.contains($0) }, "not: \(text)")
    }
}
}

@Suite struct AudioLevelTests {
    // Sessizlik 0, tam ölçek sinüs ~1, konuşma düzeyi arada; ölçülü akış parçaları değiştirmeden geçirir.
    @Test func levelsAndMeteredStream() async {
        #expect(audioLevel(samples: [Float](repeating: 0, count: 1600)) == 0)
        let loud: [Float] = (0..<1600).map { Float(sin(Double($0) * 0.1)) }
        #expect(audioLevel(samples: loud) > 0.9)
        let speech: [Float] = loud.map { $0 * 0.05 }
        #expect((0.3...0.8).contains(audioLevel(samples: speech)))
        let (input, sink): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let collected: LevelBox = LevelBox()
        let metered: AsyncStream<[Float]> = meteredStream(audio: input, onLevel: { collected.append($0) })
        sink.yield(loud)
        sink.yield(speech)
        sink.finish()
        var chunks: [[Float]] = []
        for await chunk in metered {
            chunks.append(chunk)
        }
        #expect(chunks == [loud, speech])
        #expect(collected.values.count == 2)
    }
}

/// Seviye geri çağrılarını toplar (testte eşzamanlı erişim için kilitli).
private final class LevelBox: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var stored: [Float] = []

    func append(_ value: Float) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite struct AudioClipTests {
    // İki kayıt aynı aralıkta tek klibe karışır; süre aralık kadar; aralık kayıtların dışındaysa açık hata.
    @Test func exportsMixedClip() async throws {
        let first: URL = try #require(Bundle.module.url(forResource: "fi-meeting", withExtension: "wav", subdirectory: "Fixtures"))
        let second: URL = try #require(Bundle.module.url(forResource: "en-meeting", withExtension: "wav", subdirectory: "Fixtures"))
        let destination: URL = try temporaryDirectory().appending(path: "klip.m4a")
        let range: (start: Double, end: Double) = clipRange(startSec: 1.5, endSec: 5.5)
        try await exportAudioClip(sources: [first, second], startSec: range.start, endSec: range.end, destination: destination)
        let duration: Double = try await AVURLAsset(url: destination).load(.duration).seconds
        #expect(abs(duration - 5) < 0.3, "süre: \(duration)")
        await #expect(throws: AudioClipError.self) {
            try await exportAudioClip(sources: [first], startSec: 600, endSec: 610, destination: try temporaryDirectory().appending(path: "bos.m4a"))
        }
    }
}
