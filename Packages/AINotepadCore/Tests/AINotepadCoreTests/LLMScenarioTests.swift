import Foundation
import Testing
@testable import AINotepadCore

/// Pahalı senaryo testleri (uzun toplantı × her model × en yüksek effort) yalnızca bu değişken de "1" ise çalışır;
/// sıradan bulut testlerine her çalıştırmada bu maliyet binmesin.
let scenarioTestsEnabled: Bool = ProcessInfo.processInfo.environment["AINOTEPAD_SCENARIO_TESTS"] == "1"

/// Bir turu ~4 dakikalık Fince toplantı: Aino yönetir, Mikko rapor verir, kullanıcıdan ("Sen") iş istenir.
/// `rounds` tur art arda dizilir (15 tur ≈ 1 saat); her turun konusu, tarihi ve sayıları farklıdır ki model
/// tekrarı tek maddeye indirmesin. Saf fonksiyondur.
func longMeetingSegments(rounds: Int) -> [StoredSegment] {
    let roundSec: Double = 240
    return (0..<rounds).flatMap { (round: Int) -> [StoredSegment] in
        let start: Double = Double(round) * roundSec
        let topic: Int = round + 1
        let day: Int = (round % 20) + 1
        let lines: [(Speaker, Int?, String)] = [
            (.others, 1, "Seuraava aihe on numero \(topic): asiakasprojektin vaihe \(topic) ja sen aikataulu."),
            (.others, 2, "Vaiheen \(topic) raportti on lähes valmis, mutta testaus vie vielä noin \(topic + 2) päivää."),
            (.others, 1, "Selvä. Päätetään, että vaiheen \(topic) julkaisu siirretään \(day). marraskuuta."),
            (.me, nil, "Sopii minulle. Voin tarkistaa vaiheen \(topic) dokumentaation ennen sitä."),
            (.others, 2, "Hyvä. Budjetista käytetty on nyt \(40 + topic) prosenttia, joten olemme vielä raameissa."),
            (.others, 1, "Doğan, voisitko lähettää asiakkaalle yhteenvedon vaiheesta \(topic) perjantaihin mennessä?"),
            (.me, nil, "Kyllä, lähetän yhteenvedon vaiheesta \(topic) perjantaina."),
            (.others, 2, "Minä päivitän riskilistan vaiheelle \(topic) ja jaan sen tiimille huomenna."),
            (.others, 1, "Kiitos Mikko. Onko vaiheesta \(topic) muuta kysyttävää? Jos ei, jatketaan."),
        ]
        return lines.enumerated().map { (item: (offset: Int, element: (Speaker, Int?, String))) -> StoredSegment in
            let (speaker, person, text): (Speaker, Int?, String) = item.element
            let at: Double = start + Double(item.offset) * (roundSec / Double(lines.count))
            let key: String = speaker == .me ? "me-\(round)-\(item.offset)" : "final-\(round)-\(item.offset)"
            return StoredSegment(key: key, speaker: speaker, person: person, startSec: at, endSec: at + 20, text: text, words: nil)
        }
    }
}

/// Canlı bölümler (asistan istekleri canlı transkripti kullanır).
func liveSegments(stored: [StoredSegment]) -> [LiveSegment] {
    stored.enumerated().map { (item: (offset: Int, element: StoredSegment)) -> LiveSegment in
        LiveSegment(
            id: SegmentID(speaker: item.element.speaker, index: item.offset), startSec: item.element.startSec, endSec: item.element.endSec,
            text: item.element.text, isFinal: true, failureMessage: nil, person: item.element.person
        )
    }
}

@Suite struct LongMeetingFixtureTests {
    // Fikstür gerçekten uzun: 15 tur ≈ 1 saat, ~135 bölüm.
    @Test func oneHourFixtureHasExpectedShape() {
        let segments: [StoredSegment] = longMeetingSegments(rounds: 15)
        #expect(segments.count == 135)
        #expect((segments.map(\.endSec).max() ?? 0) >= 3600 - 60)
        #expect(Set(segments.map(\.key)).count == segments.count)
    }
}

extension CloudTests {
@Suite(.enabled(if: scenarioTestsEnabled), .serialized)
struct LLMScenarioTests {
    private func anthropic(model: ClaudeModel, effort: LLMEffort) throws -> LLMProvider {
        .anthropic(AnthropicConfig(apiKey: try cloudKey(account: .anthropic), fastModel: model, smartModel: model, fastEffort: effort, smartEffort: effort))
    }

    // Kullanıcının karşılaştığı hata: düşünme en yüksek effort'ta çıktı sınırını tüketip notu kesiyordu.
    // Her model, en yüksek effort'ta 1 saatlik toplantının notunu eksiksiz yazmalı.
    @Test(arguments: ClaudeModel.allCases)
    func oneHourNoteAtMaxEffort(model: ClaudeModel) async throws {
        let request: LLMRequest = try #require(meetingNoteRequest(segments: longMeetingSegments(rounds: 15), speakerNames: [1: "Aino", 2: "Mikko"], userName: "Doğan"))
        let started: ContinuousClock.Instant = .now
        // Uygulamayla aynı yol: boş/bozuk not yeniden istenir.
        let note: MeetingNote = try await requestStructured(provider: try anthropic(model: model, effort: .max), request: request) { (text: String) throws -> MeetingNote in
            try parseMeetingNote(text: text)
        }
        print("SENARYO not \(model.rawValue) max: \(ContinuousClock.now - started), görev: \(note.tasks.count)")
        #expect(note.tasks.contains { $0.isMine }, "not: \(note)")
        #expect(!note.decisions.isEmpty)
    }

    // Asistan istekleri ve konuşmacı incelemesi de en yüksek effort'ta uzun toplantıda kesilmeden ayrıştırılabilmeli.
    @Test func assistantRequestsAtMaxEffort() async throws {
        let provider: LLMProvider = try anthropic(model: .haiku, effort: .max)
        let stored: [StoredSegment] = longMeetingSegments(rounds: 15)
        let live: [LiveSegment] = liveSegments(stored: stored)
        let nowSec: Double = live.map(\.endSec).max() ?? 0

        let missed: MissedSummary = try await requestStructured(
            provider: provider, request: try #require(missedSummaryRequest(segments: live, nowSec: nowSec, windowSec: 600))
        ) { (text: String) throws -> MissedSummary in try parseMissedSummary(text: text) }
        #expect(!missed.topic.isEmpty)

        let answer: String = try await sendLLM(provider: provider, request: try #require(questionRequest(segments: live, question: "Benden neler istendi?")))
        #expect(!answer.isEmpty)

        let review: SpeakerReview = try await requestStructured(
            provider: provider, request: try #require(speakerReviewRequest(segments: stored, speakerNames: [:], userName: "Doğan"))
        ) { (text: String) throws -> SpeakerReview in try parseSpeakerReview(text: text, persons: [1, 2], speakerNames: [:]) }
        #expect(review.names.contains { $0.person == 2 && $0.name == "Mikko" }, "adlar: \(review.names)")
    }

    // OpenAI uyumlu yol: akıl yürütme effort'u seçiliyken 1 saatlik toplantının notu kesilmeden ve ayrıştırılabilir gelmeli.
    @Test(.enabled(if: ollamaModel != nil))
    func oneHourNoteOnOpenAICompatibleWithEffort() async throws {
        let model: String = try #require(ollamaModel)
        let provider: LLMProvider = .openAICompatible(OpenAICompatibleConfig(
            baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, fastModel: model, smartModel: model, fastEffort: .high, smartEffort: .high
        ))
        let request: LLMRequest = try #require(meetingNoteRequest(segments: longMeetingSegments(rounds: 15), speakerNames: [1: "Aino", 2: "Mikko"], userName: "Doğan"))
        let note: MeetingNote = try await requestStructured(provider: provider, request: request) { (text: String) throws -> MeetingNote in
            try parseMeetingNote(text: text)
        }
        print("SENARYO not \(model) high: görev: \(note.tasks.count)")
        #expect(note.tasks.contains { $0.isMine }, "not: \(note)")
    }

    // Canlı çeviri en yüksek effort'ta da makul sürede dönmeli (sıra tek tek ilerler; yavaşlık birikir).
    @Test(arguments: ClaudeModel.allCases)
    func translationLatencyAtMaxEffort(model: ClaudeModel) async throws {
        let started: ContinuousClock.Instant = .now
        let text: String = try await sendLLM(
            provider: try anthropic(model: model, effort: .max),
            request: translationRequest(sentence: "Voisitko lähettää yhteenvedon perjantaihin mennessä?", context: ["Seuraava aihe on aikataulu."])
        )
        let elapsed: Duration = ContinuousClock.now - started
        print("SENARYO çeviri \(model.rawValue) max: \(elapsed)")
        #expect(!text.isEmpty)
        #expect(elapsed < .seconds(60), "çeviri \(elapsed) sürdü")
    }
}
}
