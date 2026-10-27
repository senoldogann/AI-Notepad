import Foundation
import FoundationModels
import Testing
@testable import AINotepadCore

@Suite struct OnDeviceLLMTests {
    @Test func mapsAvailabilityToReason() {
        #expect(onDeviceUnavailableReason(availability: .available) == nil)
        #expect(onDeviceUnavailableReason(availability: .unavailable(.deviceNotEligible)) == .deviceNotEligible)
        #expect(onDeviceUnavailableReason(availability: .unavailable(.appleIntelligenceNotEnabled)) == .appleIntelligenceNotEnabled)
        #expect(onDeviceUnavailableReason(availability: .unavailable(.modelNotReady)) == .modelNotReady)
    }

    // Her neden kullanıcıya ne yapacağını ayrı bir cümleyle söyler.
    @Test func eachReasonHasItsOwnMessage() {
        let reasons: [OnDeviceUnavailableReason] = [.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unknown(detail: "x")]
        let messages: [String] = reasons.map { onDeviceUnavailableMessage(reason: $0) }
        #expect(Set(messages).count == reasons.count)
        #expect(messages[1].contains("Apple Intelligence"))
        #expect(userFacingMessage(error: OnDeviceLLMError.unavailable(reason: .modelNotReady)) == messages[2])
    }

    // Model Türkçe ve İngilizceyi destekler, Fince'yi desteklemez (ölçüm: macOS 26.6); Norveççe modelde "nb".
    @Test func checksMeetingLanguageSupport() {
        let codes: Set<String> = ["tr", "en", "de", "nb"]
        #expect(onDeviceSupports(language: .turkish, languageCodes: codes))
        #expect(onDeviceSupports(language: .norwegian, languageCodes: codes))
        #expect(!onDeviceSupports(language: .finnish, languageCodes: codes))
        #expect(onDeviceLanguageWarning(language: .english, languageCodes: codes) == nil)
        #expect(onDeviceLanguageWarning(language: .finnish, languageCodes: codes) != nil)
    }

    @Test func limitsResponseToRemainingContext() throws {
        #expect(try onDeviceResponseTokens(requested: 16000, promptTokens: 2000, contextTokens: 4096) == 2096)
        #expect(try onDeviceResponseTokens(requested: 300, promptTokens: 1000, contextTokens: 4096) == 300)
        #expect(throws: OnDeviceLLMError.contextTooLong(promptTokens: 3800, contextTokens: 4096)) {
            try onDeviceResponseTokens(requested: 16000, promptTokens: 3800, contextTokens: 4096)
        }
    }

    // Girinti ve satır sonunda bölünmüş cümleler birleşir; maddeler ve etiketler kendi satırında kalır.
    @Test func compactsInstructions() {
        let system: String = """
        Toplantı notu çıkarıyorsun. Kullanıcının adı Ada;
        transkriptte "Sen" odur.
            Kurallar:
            - Çıktının tamamı Türkçe: özet ve
              görevler Türkçe.

            - Uydurma.
        <transkript>
        """
        #expect(compactedInstructions(system: system) == """
        Toplantı notu çıkarıyorsun. Kullanıcının adı Ada; transkriptte "Sen" odur. Kurallar:
        - Çıktının tamamı Türkçe: özet ve görevler Türkçe.
        - Uydurma.
        <transkript>
        """)
    }

    // Alan sırası `required` sırasıdır (model alanları bu sırayla yazar); enum seçenekleri korunur.
    @Test func parsesSchemasUsedByTheApp() throws {
        guard case .object(let properties) = try parseJSONSchema(text: meetingNoteSchema) else {
            Issue.record("not şeması nesne değil")
            return
        }
        #expect(properties.map(\.name) == ["baslik", "ozet", "kararlar", "gorevler", "sozluk", "akis"])
        #expect(properties.allSatisfy { (property: JSONSchemaProperty) -> Bool in property.isRequired })
        #expect(properties[3].node == .array(item: .object(properties: [
            JSONSchemaProperty(name: "sahip", node: .string(choices: nil), isRequired: true),
            JSONSchemaProperty(name: "aciklama", node: .string(choices: nil), isRequired: true),
            JSONSchemaProperty(name: "tarih", node: .string(choices: nil), isRequired: true),
            JSONSchemaProperty(name: "benimMi", node: .boolean, isRequired: true),
        ])))
        guard case .object(let tracker) = try parseJSONSchema(text: trackerAgentSchema) else {
            Issue.record("araç şeması nesne değil")
            return
        }
        #expect(tracker.first?.node == .string(choices: ["call", "done"]))
        #expect(throws: LLMError.self) { try parseJSONSchema(text: #"{"type":"object","properties":{"a":{"type":"null"}}}"#) }
        #expect(throws: LLMError.self) { try parseJSONSchema(text: "şema değil") }
    }

    // Bulutta parça 20 bin karakter; 4096 token'lık cihaz içi modelde parça, özet ve arşiv bağlama sığacak kadar küçük.
    @Test func sizesChunksByProvider() {
        let cloud: NoteLimits = noteLimits(provider: .anthropic(AnthropicConfig(apiKey: "k", fastModel: .haiku, smartModel: .haiku, fastEffort: .low, smartEffort: .high)))
        #expect(cloud == NoteLimits(chunkChars: 20_000, summaryChars: nil, archiveChars: 60_000))
        let local: NoteLimits = noteLimits(provider: .onDevice(OnDeviceConfig(contextTokens: 4096)))
        #expect((1_500...4_000).contains(local.chunkChars), "parça: \(local.chunkChars)")
        #expect((1_000...3_000).contains(local.summaryChars ?? 0), "özet: \(local.summaryChars ?? 0)")
        #expect((3_000...8_000).contains(local.archiveChars), "arşiv: \(local.archiveChars)")
        // Daha büyük bağlamda parça büyür.
        #expect(noteLimits(provider: .onDevice(OnDeviceConfig(contextTokens: 8192))).chunkChars > local.chunkChars)
    }

    @Test func condensesPartSummariesButKeepsTasks() {
        let task: NoteTask = NoteTask(owner: "Ada", description: "Raporu gönder", dueDate: nil, isMine: true)
        let state: ChunkedNoteState = ChunkedNoteState(
            partSummaries: (0..<4).map { "[0\($0):00–0\($0 + 1):00] Bütçe ve pazarlama planı konuşuldu, takvim üzerinde anlaşıldı ve herkes görevini aldı." },
            decisions: ["Bütçe artar."], tasks: [task], glossary: []
        )
        let condensed: ChunkedNoteState = condensedNoteState(state: state, maxChars: 200)
        #expect(condensed.partSummaries.count == 4)
        #expect(condensed.partSummaries.allSatisfy { $0.count <= 50 && $0.hasSuffix("…") && $0.hasPrefix("[0") })
        #expect(condensed.tasks == [task] && condensed.decisions == state.decisions)
        #expect(condensedNoteState(state: state, maxChars: 10_000) == state)
    }
}

@Suite struct AppleSpeechChoiceTests {
    private let speech: [String] = ["de_DE", "en_GB", "en_US", "fr_FR"]
    private let dictation: [String] = ["de_DE", "en_US", "fi_FI", "nb_NO", "tr_TR"]

    // SpeechTranscriber destekliyorsa o; değilse (Fince, Türkçe) dikte modeli; ikisi de değilse nil.
    @Test func prefersSpeechTranscriberThenDictation() {
        #expect(appleSpeechChoice(language: .english, speechLocales: speech, dictationLocales: dictation, regionCode: "FI") == AppleSpeechChoice(kind: .speech, localeIdentifier: "en_GB"))
        #expect(appleSpeechChoice(language: .english, speechLocales: speech, dictationLocales: dictation, regionCode: "US") == AppleSpeechChoice(kind: .speech, localeIdentifier: "en_US"))
        #expect(appleSpeechChoice(language: .german, speechLocales: speech, dictationLocales: dictation, regionCode: nil) == AppleSpeechChoice(kind: .speech, localeIdentifier: "de_DE"))
        #expect(appleSpeechChoice(language: .finnish, speechLocales: speech, dictationLocales: dictation, regionCode: "FI") == AppleSpeechChoice(kind: .dictation, localeIdentifier: "fi_FI"))
        #expect(appleSpeechChoice(language: .norwegian, speechLocales: speech, dictationLocales: dictation, regionCode: nil) == AppleSpeechChoice(kind: .dictation, localeIdentifier: "nb_NO"))
        #expect(appleSpeechChoice(language: .estonian, speechLocales: speech, dictationLocales: dictation, regionCode: nil) == nil)
    }
}

/// Gerçek cihaz içi modellerle (Apple Intelligence ve konuşma tanıma) çalışan test; yalnızca bu değişken "1" ise.
let onDeviceTestsEnabled: Bool = ProcessInfo.processInfo.environment["AINOTEPAD_ONDEVICE_TESTS"] == "1"

@Suite(.enabled(if: onDeviceTestsEnabled), .serialized)
struct OnDeviceModelTests {
    // Uçtan uca, internetsiz: İngilizce toplantı cihaz içi konuşma tanımayla yazıya dökülür ve cihaz içi modelle Türkçe
    // not yazılır; Fince diyalog yazıya dökülür ama model Fince'yi desteklemediği için not açık bir hatayla reddedilir.
    @Test func writesNoteFromFixturesOnDevice() async throws {
        let llm: LLMProvider = .onDevice(try onDeviceConfig())
        let engine: AppleSpeechEngine = AppleSpeechEngine()

        let english: String = try await engine.transcribe(samples: loadFixture(name: "en-meeting"), language: .english)
        #expect(english.lowercased().contains("report"), "metin: \(english)")
        let note: MeetingNote = try #require(try await writeMeetingNote(
            segments: [stored("final-0", .others, 1, 0, english)], speakerNames: [1: "Aino"], userName: "Ada", template: .general, myNotes: "",
            llm: llm, progressFile: try temporaryDirectory().appending(path: "note-progress.json")
        ))
        #expect(!note.title.isEmpty && !note.summary.isEmpty, "not: \(note)")

        let finnish: String = try await engine.transcribe(samples: loadFixture(name: "fi-dialog"), language: .finnish)
        #expect(finnish.lowercased().contains("raport"), "metin: \(finnish)")
        await #expect(throws: OnDeviceLLMError.unsupportedLanguage(detail: "Unsupported language.")) {
            _ = try await writeMeetingNote(
                segments: [stored("final-0", .others, 1, 0, finnish)], speakerNames: [:], userName: "Ada", template: .general, myNotes: "",
                llm: llm, progressFile: try temporaryDirectory().appending(path: "note-progress.json")
            )
        }

        // Son geçiş (ve içe aktarma) dosyanın tamamını zamanlı bölümlerle yazıya döker.
        let file: URL = try #require(Bundle.module.url(forResource: "fi-dialog", withExtension: "wav", subdirectory: "Fixtures"))
        let final: FinalPassResult = try await AppleSpeechFinalTranscriber(primaryLanguage: .finnish).transcribeFinal(audioURL: file, languageMode: .automatic)
        #expect(final.segments.map(\.text).joined(separator: " ").lowercased().contains("raport"), "bölümler: \(final.segments)")
        #expect(final.segments.allSatisfy { (segment: StoredSegment) -> Bool in segment.endSec > segment.startSec })

        // En büyük parça (sınır kadar İngilizce metin) önceki özetler doluyken bağlama sığar.
        let limits: NoteLimits = noteLimits(provider: llm)
        let sentence: String = "We reviewed the budget and the marketing plan for next year and agreed on the schedule. "
        let chunk: [StoredSegment] = (0..<(limits.chunkChars / sentence.count)).map { stored("final-\($0)", .others, $0 % 2 + 1, Double($0 * 5), sentence) }
        let summaries: [String] = Array(repeating: "[00:00–02:00] The team reviewed the budget, agreed on the schedule and assigned the slides to Aino.", count: 30)
        let state: ChunkedNoteState = condensedNoteState(
            state: ChunkedNoteState(partSummaries: summaries, decisions: [], tasks: [], glossary: []), maxChars: limits.summaryChars ?? 0
        )
        let request: LLMRequest = noteChunkRequest(
            chunk: chunk, part: 31, partCount: 40, state: state, speakerNames: [:], userName: "Ada", template: .general, myNotes: ""
        )
        let part: NoteChunk = try await requestStructured(provider: llm, request: request) { (text: String) throws -> NoteChunk in
            try parseNoteChunk(text: text)
        }
        #expect(!part.summary.isEmpty)
    }
}
