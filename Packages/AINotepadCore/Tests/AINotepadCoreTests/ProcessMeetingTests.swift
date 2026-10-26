import Foundation
import Testing
@testable import AINotepadCore

/// İşleme adımlarını sırayla toplar.
@MainActor
final class StepLog {
    var steps: [ProcessingStep] = []
}

extension CloudTests {
@Suite struct ProcessMeetingTests {
    @Test func processesRecordedMeetingIntoNote() async throws {
        let directory: URL = try temporaryDirectory()
        let others: CafRecorder = try CafRecorder(fileURL: directory.appending(path: "others.caf"))
        try others.append(samples: try loadFixture(name: "fi-dialog"))
        others.close()
        let me: CafRecorder = try CafRecorder(fileURL: directory.appending(path: "me.caf"))
        try me.append(samples: silence(seconds: 3))
        me.close()
        let recording: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: "Toplantı", startedAt: Date(), endedAt: Date(), language: nil, status: .processing,
            failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil
        )

        let log: StepLog = await StepLog()
        let result: MeetingRecord = await processMeeting(
            record: recording,
            directory: directory,
            finalPass: .run(ElevenLabsFinalTranscriber(apiKey: try cloudKey(account: .elevenlabs))),
            llm: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))),
            languageMode: .automatic,
            userName: "Doğan",
            onStep: { (step: ProcessingStep) async -> Void in log.steps.append(step) }
        )

        // Arayüz ilerlemesi adımları sırayla alır.
        #expect(await log.steps == [.convertingAudio, .finalPass, .writingNote])
        #expect(result.status == .done, "hata: \(result.failureMessage ?? "")")
        #expect(!result.finalSegments.isEmpty)
        #expect(result.note != nil)
        #expect(result.title == result.note?.title)
        #expect(result.language == .finnish)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "others.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "others.caf").path))
    }

    @Test func missingAnthropicKeyFailsButKeepsTranscript() async throws {
        let directory: URL = try temporaryDirectory()
        let others: CafRecorder = try CafRecorder(fileURL: directory.appending(path: "others.caf"))
        try others.append(samples: try loadFixture(name: "fi-dialog"))
        others.close()
        let recording: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: "Toplantı", startedAt: Date(), endedAt: Date(), language: nil, status: .processing,
            failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil
        )
        let result: MeetingRecord = await processMeeting(
            record: recording, directory: directory, finalPass: .run(ElevenLabsFinalTranscriber(apiKey: try cloudKey(account: .elevenlabs))),
            llm: nil, languageMode: .automatic, userName: "Doğan",
            onStep: { (_: ProcessingStep) async -> Void in }
        )
        #expect(result.status == .failed)
        #expect(!result.finalSegments.isEmpty)
        #expect(result.failureMessage?.contains("LLM") == true)
    }
}
}
