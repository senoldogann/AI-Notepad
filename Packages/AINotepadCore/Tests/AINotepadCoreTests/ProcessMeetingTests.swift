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
            failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )

        let log: StepLog = await StepLog()
        let result: MeetingRecord = await processMeeting(
            record: recording,
            directory: directory,
            finalPass: .run(ElevenLabsFinalTranscriber(apiKey: try cloudKey(account: .elevenlabs), keyterms: ["Aino", "raportti"])),
            llm: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))),
            languageMode: .automatic,
            userName: "Doğan",
            noteLanguage: .turkish, voiceEmbedder: nil, registry: [],
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

    // Son geçiş durdurulursa (sunucu güncel değil) not canlı metinden yazılmaz: toplantı başarısız, neden görünür.
    @Test func stoppedFinalPassFailsWithoutWritingNote() async throws {
        let directory: URL = try temporaryDirectory()
        let recording: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: "Toplantı", startedAt: Date(), endedAt: Date(), language: .finnish, status: .processing,
            failureMessage: nil, liveSegments: longMeetingSegments(rounds: 1),
            finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let result: MeetingRecord = await processMeeting(
            record: recording, directory: directory, finalPass: .stop(HostedClientError.serverOutdated(path: "/v1/meetings/{id}/reprocess")),
            llm: nil, languageMode: .automatic, userName: "Doğan", noteLanguage: .turkish, voiceEmbedder: nil, registry: [],
            onStep: { (_: ProcessingStep) async -> Void in }
        )
        #expect(result.status == .failed)
        #expect(result.note == nil)
        #expect(result.failureMessage?.contains("Tekrar işle") == true)
    }

    // Son geçiş başarısız olursa (ör. ElevenLabs kotası/anahtarı) not yine canlı metinden yazılır, uyarı kalır.
    @Test func finalPassFailureStillWritesNoteFromLiveText() async throws {
        let directory: URL = try temporaryDirectory()
        let others: CafRecorder = try CafRecorder(fileURL: directory.appending(path: "others.caf"))
        try others.append(samples: try loadFixture(name: "fi-dialog"))
        others.close()
        let recording: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: "Toplantı", startedAt: Date(), endedAt: Date(), language: .finnish, status: .processing,
            failureMessage: nil, liveSegments: longMeetingSegments(rounds: 1),
            finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let result: MeetingRecord = await processMeeting(
            record: recording, directory: directory, finalPass: .run(ElevenLabsFinalTranscriber(apiKey: "gecersiz", keyterms: [])),
            llm: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))), languageMode: .automatic, userName: "Doğan",
            noteLanguage: .turkish, voiceEmbedder: nil, registry: [],
            onStep: { (_: ProcessingStep) async -> Void in }
        )
        #expect(result.status == .done, "hata: \(result.failureMessage ?? "")")
        #expect(result.note != nil)
        #expect(result.finalSegments.isEmpty)
        #expect(result.notice?.contains("Tekrar işle") == true, "uyarı: \(result.notice ?? "")")
    }

    // Ağ gidip "Sen"in canlı akışı koptuysa "Sen" kaydı da son geçişten geçer: konuşma not ve transkriptte kaybolmaz.
    @Test func brokenLiveStreamTranscribesOwnAudio() async throws {
        let directory: URL = try temporaryDirectory()
        let me: CafRecorder = try CafRecorder(fileURL: directory.appending(path: "me.caf"))
        try me.append(samples: try loadFixture(name: "fi-dialog"))
        me.close()
        let recording: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: "Toplantı", startedAt: Date(), endedAt: Date(), language: .finnish, status: .processing,
            failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false,
            engine: .cloud, notice: nil, meNeedsFinalPass: true
        )
        let result: MeetingRecord = await processMeeting(
            record: recording, directory: directory, finalPass: .run(ElevenLabsFinalTranscriber(apiKey: try cloudKey(account: .elevenlabs), keyterms: ["Aino", "raportti"])),
            llm: nil, languageMode: .fixed(.finnish), userName: "Doğan",
            noteLanguage: .turkish, voiceEmbedder: nil, registry: [],
            onStep: { (_: ProcessingStep) async -> Void in }
        )
        let mine: [StoredSegment] = meetingSegments(record: result).filter { $0.speaker == .me }
        #expect(!mine.isEmpty, "uyarı: \(result.notice ?? "")")
        #expect(mine.allSatisfy { $0.person == nil })
    }

    @Test func missingAnthropicKeyFailsButKeepsTranscript() async throws {
        let directory: URL = try temporaryDirectory()
        let others: CafRecorder = try CafRecorder(fileURL: directory.appending(path: "others.caf"))
        try others.append(samples: try loadFixture(name: "fi-dialog"))
        others.close()
        let recording: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: "Toplantı", startedAt: Date(), endedAt: Date(), language: nil, status: .processing,
            failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let result: MeetingRecord = await processMeeting(
            record: recording, directory: directory, finalPass: .run(ElevenLabsFinalTranscriber(apiKey: try cloudKey(account: .elevenlabs), keyterms: ["Aino", "raportti"])),
            llm: nil, languageMode: .automatic, userName: "Doğan",
            noteLanguage: .turkish, voiceEmbedder: nil, registry: [],
            onStep: { (_: ProcessingStep) async -> Void in }
        )
        #expect(result.status == .failed)
        #expect(!result.finalSegments.isEmpty)
        #expect(result.failureMessage?.contains("LLM") == true)
    }
}
}
