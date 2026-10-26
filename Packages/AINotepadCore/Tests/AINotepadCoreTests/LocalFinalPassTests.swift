import Foundation
import Testing
@testable import AINotepadCore

@Suite struct SpeakerAttributionTests {
    @Test func wordsTakeOverlappingOrNearestTurn() {
        let words: [TimedWord] = [
            TimedWord(text: "Hei", startSec: 0.1, endSec: 0.5),
            TimedWord(text: "kaikki", startSec: 0.9, endSec: 1.4),
            TimedWord(text: "Kiitos", startSec: 3.0, endSec: 3.4),
            TimedWord(text: "loppu", startSec: 9.0, endSec: 9.3),
        ]
        let turns: [SpeakerTurn] = [
            SpeakerTurn(speaker: 0, startSec: 0, endSec: 1.0),
            SpeakerTurn(speaker: 1, startSec: 1.0, endSec: 4.0),
        ]
        #expect(attributeSpeakers(words: words, turns: turns).map(\.speaker) == ["speaker_0", "speaker_1", "speaker_1", "speaker_1"])
        #expect(attributeSpeakers(words: words, turns: []).allSatisfy { $0.speaker == "speaker_0" })
    }
}

extension ModelTests {
@Suite struct LocalFinalPassTests {
    // İnternetsiz son geçiş: WhisperKit kelimeleri + SpeakerKit konuşmacıları; LLM yoksa not hatası ama metin kalır.
    // Pyannote kümelemesi 12 sn'lik diyalogda konuşmacıları ayıramaz (gerçek toplantılar dakikalarca sürer):
    // diyalog dört kez art arda verilir (~48 sn).
    @Test func localPassSeparatesSpeakers() async throws {
        let directory: URL = try temporaryDirectory()
        let dialog: [Float] = try loadFixture(name: "fi-dialog")
        let others: CafRecorder = try CafRecorder(fileURL: directory.appending(path: "others.caf"))
        try others.append(samples: dialog + dialog + dialog + dialog)
        others.close()
        let recording: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: "Toplantı", startedAt: Date(), endedAt: Date(), language: nil, status: .processing,
            failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false,
            engine: .local, notice: nil
        )
        let result: MeetingRecord = await processMeeting(
            record: recording, directory: directory,
            finalPass: .run(LocalFinalTranscriber(modelsDirectory: try AppPaths.modelsDirectory(), modelName: liveWhisperModel)),
            llm: nil, languageMode: .automatic, userName: "Doğan",
            onStep: { (_: ProcessingStep) async -> Void in }
        )
        let text: String = result.finalSegments.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("raport"), "metin: \(text), hata: \(result.failureMessage ?? "")")
        #expect(Set(result.finalSegments.compactMap(\.person)).count >= 2, "bölümler: \(result.finalSegments)")
        #expect(result.language == .finnish)
        #expect(result.failureMessage?.contains("LLM") == true)
    }
}
}
