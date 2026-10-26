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
}
}
