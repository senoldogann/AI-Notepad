import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

func w(_ text: String, _ start: Double, _ end: Double, _ speaker: String) -> DiarizedWord {
    DiarizedWord(text: text, startSec: start, endSec: end, speaker: speaker)
}

@Suite struct FinalTranscriptTests {
    @Test func splitsOnSpeakerChangeAndGap() {
        let words: [DiarizedWord] = [
            w("Hyvää", 0, 0.4, "speaker_1"), w("huomenta.", 0.5, 1.0, "speaker_1"),
            w("Kiitos.", 1.2, 1.6, "speaker_0"),
            w("Hienoa.", 4.0, 4.5, "speaker_0"),
        ]
        let segments: [StoredSegment] = finalSegments(words: words, gapSec: 1.5)
        #expect(segments.map(\.text) == ["Hyvää huomenta.", "Kiitos.", "Hienoa."])
        #expect(segments.map(\.startSec) == [0, 1.2, 4.0])
        #expect(segments.map(\.endSec) == [1.0, 1.6, 4.5])
        #expect(segments.map(\.key) == ["final-0", "final-1", "final-2"])
        #expect(segments.allSatisfy { $0.speaker == .others })
    }

    @Test func personsNumberedByAppearance() {
        let words: [DiarizedWord] = [w("a", 0, 1, "speaker_3"), w("b", 1, 2, "speaker_0"), w("c", 2, 3, "speaker_3")]
        #expect(finalSegments(words: words, gapSec: 1.5).map(\.person) == [1, 2, 1])
    }
}

extension CloudTests {
@Suite struct FullFileDiarizationTests {
    @Test func fullFileDiarization() async throws {
        let directory: URL = try temporaryDirectory()
        let caf: URL = directory.appending(path: "others.caf")
        let m4a: URL = directory.appending(path: "others.m4a")
        let recorder: CafRecorder = try CafRecorder(fileURL: caf)
        try recorder.append(samples: try loadFixture(name: "fi-dialog"))
        recorder.close()
        try convertToM4A(source: caf, destination: m4a)

        let result: DiarizationResult = try await diarizeFile(
            apiKey: try cloudKey(account: .elevenlabs), fileURL: m4a, mimeType: "audio/mp4", languageMode: .automatic, timeoutSec: 300
        )
        let segments: [StoredSegment] = finalSegments(words: result.words, gapSec: 1.5)
        #expect(Set(segments.compactMap(\.person)).count >= 2)
        #expect(segments.map(\.text).joined(separator: " ").lowercased().contains("raport"))
    }
}
}
