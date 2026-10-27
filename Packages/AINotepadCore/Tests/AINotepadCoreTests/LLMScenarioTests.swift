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

/// Gerçek konuşma yoğunluğunda (dakikada ~1.700 karakter) toplantı: her 4 dakikalık turda `longMeetingSegments`'in
/// görev ve kararlarının arasına görev ya da karar içermeyen ayrıntılı tartışma girer. Tur başına beklenen: 3 görev
/// (2'si kullanıcının), 1 karar. Saf fonksiyondur.
func realisticMeetingSegments(rounds: Int) -> [StoredSegment] {
    let roundSec: Double = 240
    let fillers: [(Int, Int) -> String] = [
        { "Asiakkaan kanssa käytiin läpi vaiheen \($0) vaatimuksia, ja heillä oli kysymyksiä integraatiosta numero \($1) sekä sen rajapinnoista." },
        { "Teknisesti vaiheessa \($0) on vielä \($1) avointa tikettiä, mutta suurin osa niistä on pieniä käyttöliittymän korjauksia ja tekstimuutoksia." },
        { "Testiympäristössä vaiheen \($0) suorituskyky parani noin \($1) prosenttia, kun tietokantakyselyt optimoitiin viime viikolla." },
        { "Käyttäjähaastatteluissa nousi esiin, että vaiheen \($0) näkymä \($1) on joillekin vaikea löytää, mutta se ei ole kriittinen asia." },
        { "Vaiheen \($0) dokumentaatiossa on nyt \($1) sivua, ja rakenne noudattaa samaa mallia kuin aiemmissa vaiheissa." },
        { "Integraatiotesteissä vaiheen \($0) osalta ajettiin \($1) skenaariota, ja ne menivät pääosin läpi ilman suurempia ongelmia." },
        { "Asiakkaan yhteyshenkilö mainitsi, että vaiheen \($0) raportointi on ollut selkeää ja kuukausikatsaus numero \($1) oli hyödyllinen." },
        { "Infrapuolella vaiheen \($0) palvelimet ovat olleet vakaita, käyttöaste on ollut noin \($1) prosenttia ruuhka-aikoina." },
        { "Vaiheen \($0) käännöksissä on vielä \($1) kohtaa tarkistamatta, mutta käännöstoimisto on jo työn alla eikä se vaadi meiltä toimia." },
    ]
    return longMeetingSegments(rounds: rounds).enumerated().flatMap { (item: (offset: Int, element: StoredSegment)) -> [StoredSegment] in
        let topic: Int = item.offset / 9 + 1
        let lineInRound: Int = item.offset % 9
        let slot: Double = roundSec / 9
        let key: StoredSegment = item.element
        // Her ana satırın ardından 5 tartışma satırı (aynı tur ve zaman diliminde).
        let filler: [StoredSegment] = (0..<5).map { (index: Int) -> StoredSegment in
            let at: Double = key.startSec + slot * Double(index + 1) / 6
            let text: String = fillers[(lineInRound * 5 + index) % fillers.count](topic, (topic * 7 + index * 3) % 40 + 2)
            return StoredSegment(key: "\(key.key)-f\(index)", speaker: .others, person: (index % 2) + 1, startSec: at, endSec: at + slot / 7, text: text, words: nil)
        }
        return [key] + filler
    }
}

/// Fikstürdeki işlerin notta bulunma durumu.
struct TaskCoverage {
    let covered: Int
    /// "doküman 3" gibi bulunamayan iş ve aşama.
    let missing: [String]
}

/// Her aşamanın üç işini (özet gönderme, doküman kontrolü, risk listesi) Türkçe görev açıklamalarında arar; "1, 2 ve 3.
/// aşama" gibi toplu madde her aşamayı kapsar. Saf fonksiyondur.
func taskCoverage(tasks: [NoteTask], phases: Int) -> TaskCoverage {
    let kinds: [(String, [String])] = [("özet", ["özet"]), ("doküman", ["dokü", "belge"]), ("risk", ["risk"])]
    let numbers: [(NoteTask, Set<Int>)] = tasks.map { (task: NoteTask) -> (NoteTask, Set<Int>) in
        let found: [Int] = task.description.split { !$0.isNumber }.compactMap { Int($0) }
        return (task, Set(found))
    }
    let missing: [String] = (1...phases).flatMap { (phase: Int) -> [String] in
        kinds.compactMap { (kind: (String, [String])) -> String? in
            let present: Bool = numbers.contains { (item: (NoteTask, Set<Int>)) -> Bool in
                item.1.contains(phase) && kind.1.contains { item.0.description.lowercased().contains($0) }
            }
            return present ? nil : "\(kind.0) \(phase)"
        }
    }
    return TaskCoverage(covered: phases * kinds.count - missing.count, missing: missing)
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

    // Her model, notta sunulan en yüksek effort'ta (high; xhigh/max gerçek toplantıda notu kesiyordu) 1 saatlik
    // toplantının notunu eksiksiz yazmalı.
    @Test(arguments: ClaudeModel.allCases)
    func oneHourNoteAtHighestOfferedEffort(model: ClaudeModel) async throws {
        let request: LLMRequest = try #require(meetingNoteRequest(segments: longMeetingSegments(rounds: 15), speakerNames: [1: "Aino", 2: "Mikko"], userName: "Doğan", template: .general))
        let started: ContinuousClock.Instant = .now
        // Uygulamayla aynı yol: boş/bozuk not yeniden istenir.
        let note: MeetingNote = try await requestStructured(provider: try anthropic(model: model, effort: .high), request: request) { (text: String) throws -> MeetingNote in
            try parseMeetingNote(text: text)
        }
        print("SENARYO not \(model.rawValue) high: \(ContinuousClock.now - started), görev: \(note.tasks.count)")
        #expect(note.tasks.contains { $0.isMine }, "not: \(note)")
        #expect(!note.decisions.isEmpty)
    }

    // Asistan istekleri ve konuşmacı incelemesi de sunulan en yüksek effort'ta uzun toplantıda kesilmeden
    // ayrıştırılabilmeli.
    @Test func assistantRequestsAtHighEffort() async throws {
        let provider: LLMProvider = try anthropic(model: .haiku, effort: .high)
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
            provider: provider, request: try #require(speakerReviewRequest(segments: stored, speakerNames: [:], userName: "Doğan", attendees: []))
        ) { (text: String) throws -> SpeakerReview in try parseSpeakerReview(text: text, persons: [1, 2], speakerNames: [:]) }
        #expect(review.names.contains { $0.person == 2 && $0.name == "Mikko" }, "adlar: \(review.names)")
    }

    // Gerçek yoğunlukta uzun toplantı: tek istekte model 2 saatte 90 görevin yalnızca 33'ünü yazıyordu; parça parça (her
    // parça öncekileri bağlam olarak görür) her aşamanın üç işi (kullanıcının özet gönderme ve doküman kontrolü, Mikko'nun
    // risk listesi) notta Türkçe ve doğru sahiple bulunmalı.
    @Test(arguments: [30, 60])
    func realisticLongMeetingKeepsEveryTask(rounds: Int) async throws {
        let segments: [StoredSegment] = realisticMeetingSegments(rounds: rounds)
        let provider: LLMProvider = try anthropic(model: .haiku, effort: .medium)
        let started: ContinuousClock.Instant = .now
        let note: MeetingNote = try #require(try await writeMeetingNote(segments: segments, speakerNames: [1: "Aino", 2: "Mikko"], userName: "Doğan", template: .general, llm: provider, progressFile: try temporaryDirectory().appending(path: "note-progress.json")))
        let coverage: TaskCoverage = taskCoverage(tasks: note.tasks, phases: rounds)
        print("SENARYO gerçek yoğunluk \(rounds * 4) dk, \(segments.map(\.text.count).reduce(0, +)) karakter: \(ContinuousClock.now - started), görev \(note.tasks.count), kapsanan iş \(coverage.covered)/\(rounds * 3), eksik: \(coverage.missing.prefix(12))")
        #expect(Double(coverage.covered) >= Double(rounds * 3) * 0.9, "eksik: \(coverage.missing)")
        // Kullanıcının işleri "benim" işaretli ve sahibi adıyla.
        #expect(note.tasks.filter(\.isMine).allSatisfy { $0.owner == "Doğan" }, "sahipler: \(Set(note.tasks.filter(\.isMine).map(\.owner)))")
        #expect(!note.summary.isEmpty)
        // Konu akışı: genel özet parça aralıklarından bölümler çıkarır; sıralı ve toplantı süresi içinde.
        let outline: [OutlineItem] = note.outline ?? []
        print("SENARYO akış: \(outline.map { "\(timestamp(seconds: $0.startSec)) \($0.title)" })")
        #expect(outline.count >= 5, "akış: \(outline)")
        #expect(outline.map(\.startSec) == outline.map(\.startSec).sorted())
        #expect((outline.last?.startSec ?? 0) <= (segments.last?.endSec ?? 0))
    }

    // OpenAI uyumlu yol: akıl yürütme effort'u seçiliyken 1 saatlik toplantının notu kesilmeden ve ayrıştırılabilir gelmeli.
    @Test(.enabled(if: ollamaModel != nil))
    func oneHourNoteOnOpenAICompatibleWithEffort() async throws {
        let model: String = try #require(ollamaModel)
        let provider: LLMProvider = .openAICompatible(OpenAICompatibleConfig(
            baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, fastModel: model, smartModel: model, fastEffort: .high, smartEffort: .high
        ))
        let request: LLMRequest = try #require(meetingNoteRequest(segments: longMeetingSegments(rounds: 15), speakerNames: [1: "Aino", 2: "Mikko"], userName: "Doğan", template: .general))
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

@Suite struct ChunkedNoteTests {
    // Parçalar sınırı aşmaz (tek dev bölüm hariç), hiçbir bölüm atlanmaz, sıra korunur.
    @Test func chunksKeepEverySegmentInOrder() {
        let segments: [StoredSegment] = realisticMeetingSegments(rounds: 10)
        let chunks: [[StoredSegment]] = noteChunks(segments: segments, maxChars: 20_000)
        #expect(chunks.count > 1)
        #expect(chunks.flatMap { $0 } == segments)
        #expect(chunks.allSatisfy { $0.count == 1 || $0.map(\.text.count).reduce(0, +) <= 20_000 })
    }

    // Transkriptte "Sen" kullanıcıdır: "Sen" ya da kullanıcının adıyla yazılmış görev adıyla ve "benim" olur.
    @Test func userTasksGetNameAndMine() {
        #expect(normalizedTask(task: NoteTask(owner: "Sen", description: "Rapor", dueDate: nil, isMine: false), userName: "Doğan")
            == NoteTask(owner: "Doğan", description: "Rapor", dueDate: nil, isMine: true))
        #expect(normalizedTask(task: NoteTask(owner: "doğan", description: "Rapor", dueDate: nil, isMine: false), userName: "Doğan").isMine)
        #expect(normalizedTask(task: NoteTask(owner: "Mikko", description: "Risk", dueDate: nil, isMine: false), userName: "Doğan").owner == "Mikko")
    }

    // Değişiklik numarası bağlamdaki listeye göre uygulanır; iptal düşer; yeniler sona; sözlükte terim bir kez.
    @Test func applyChunkUpdatesCancelsAndAppends() {
        let state: ChunkedNoteState = ChunkedNoteState(
            partSummaries: ["[00:00–10:00] Giriş."], decisions: ["A"],
            tasks: [NoteTask(owner: "Sen", description: "Rapor", dueDate: "Cuma", isMine: true), NoteTask(owner: "Aino", description: "Slayt", dueDate: nil, isMine: false)],
            glossary: [GlossaryEntry(term: "raportti", meaning: "rapor")]
        )
        let chunk: NoteChunk = NoteChunk(
            summary: "Erteleme.", decisions: ["B"],
            newTasks: [NoteTask(owner: "Mikko", description: "Bütçe", dueDate: nil, isMine: false)],
            changedTasks: [TaskChange(number: 1, description: "Rapor", dueDate: "Pazartesi", isCancelled: false), TaskChange(number: 2, description: "", dueDate: nil, isCancelled: true), TaskChange(number: 9, description: "yok", dueDate: nil, isCancelled: true)],
            glossary: [GlossaryEntry(term: "Raportti", meaning: "rapor"), GlossaryEntry(term: "budjetti", meaning: "bütçe")]
        )
        let next: ChunkedNoteState = applyNoteChunk(state: state, chunk: chunk, startSec: 600, endSec: 1200)
        #expect(next.tasks == [NoteTask(owner: "Sen", description: "Rapor", dueDate: "Pazartesi", isMine: true), NoteTask(owner: "Mikko", description: "Bütçe", dueDate: nil, isMine: false)])
        #expect(next.decisions == ["A", "B"])
        #expect(next.glossary.map(\.term) == ["raportti", "budjetti"])
        #expect(next.partSummaries.last == "[10:00–20:00] Erteleme.")
    }
}
