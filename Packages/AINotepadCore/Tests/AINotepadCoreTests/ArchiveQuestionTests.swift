import Foundation
import Testing
@testable import AINotepadCore

/// İki toplantılık arşiv: kahve makinesi bilgisi yalnızca ilk toplantının Fince transkriptinde (notta yok).
private func archive() -> [MeetingRecord] {
    let first: MeetingRecord = MeetingRecord(
        id: "a", title: "Toplantı", startedAt: Date(timeIntervalSince1970: 1_790_000_000), endedAt: nil, language: .finnish,
        status: .done, failureMessage: nil, liveSegments: [],
        finalSegments: [
            stored("final-0", .others, 1, 0, "Huomenta. Käydään läpi viikon asiat."),
            stored("final-1", .others, 2, 30, "Kahvikone on taas rikki. Minä tilaan uuden kahvinkeittimen ensi maanantaina."),
            stored("final-2", .others, 1, 60, "Hyvä, kiitos Mikko. Sitten myyntiluvut."),
        ],
        translations: [:], speakerNames: [1: "Aino", 2: "Mikko"],
        note: MeetingNote(title: "Haftalık ekip toplantısı", summary: "Ekip haftalık işleri ve satış rakamlarını konuştu.", decisions: [], tasks: [], glossary: []),
        audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
    let second: MeetingRecord = MeetingRecord(
        id: "b", title: "Toplantı", startedAt: Date(timeIntervalSince1970: 1_791_000_000), endedAt: nil, language: .finnish,
        status: .done, failureMessage: nil, liveSegments: [],
        finalSegments: [stored("final-0", .others, 1, 0, "Ensi vuoden budjetti kasvaa kymmenen prosenttia.")],
        translations: [:], speakerNames: [:],
        note: MeetingNote(title: "Bütçe planlaması", summary: "Gelecek yılın bütçesi yüzde 10 artacak.", decisions: ["Bütçe %10 artacak."], tasks: [], glossary: []),
        audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
    return [second, first]
}

@Suite struct ArchiveQuestionTests {
    // Fince köklerle eşleşen transkript parçası seçilir; eşleşme yoksa en yeni notlar; sınır aşılmaz; kaynaklar parçalara bağlanır.
    @Test func retrievalAndSources() throws {
        let passages: [ArchivePassage] = archivePassages(records: archive())
        #expect(passages.filter { $0.kind == .note }.count == 2)
        let coffee: [ArchivePassage] = relevantPassages(passages: passages, terms: ["kahvikone", "kahvinkeitin", "kahve makinesi"], maxChars: 10_000)
        #expect(coffee.first?.meetingID == "a" && coffee.first?.kind == .transcript && coffee.first?.text.contains("Kahvikone") == true)
        #expect(relevantPassages(passages: passages, terms: ["xyzzy"], maxChars: 10_000).map(\.id) == ["a-note", "b-note"])
        #expect(relevantPassages(passages: passages, terms: ["xyzzy"], maxChars: 80).count == 1)
        // Kaynak işaretleri ilk geçiş sırasıyla numaralanır; geçersizler atılır; akışta yarım işaret görünmez.
        let both: [ArchivePassage] = Array(passages.prefix(2))
        let answer: ArchiveAnswer = citedAnswer(text: "Mikko yenisini sipariş edecek [2][9]. Bütçe artacak [1, 2] [", passages: both)
        #expect(answer.text == "Mikko yenisini sipariş edecek [1]. Bütçe artacak [2][1]")
        #expect(answer.sources.map(\.id) == [both[1].id, both[0].id])
        #expect(citedAnswer(text: "Kaikki [1-2].", passages: both).text == "Kaikki [1][2].")
    }
}

@Suite struct ArchiveScopeTests {
    // Kapsam: etiket yoksa boş (tüm arşiv), varsa etiket sırasıyla o toplantılar; olmayan toplantı hatadır (genişlemez).
    @Test func scopeFollowsSelectedMeetings() throws {
        let records: [MeetingRecord] = archive()
        #expect(try archiveScope(records: records, meetingIDs: []).isEmpty)
        #expect(try archiveScope(records: records, meetingIDs: ["a", "b"]).map(\.id) == ["a", "b"])
        #expect(throws: ArchiveScopeError.meetingsNotFound(ids: ["silinmis"])) {
            try archiveScope(records: records, meetingIDs: ["a", "silinmis"])
        }
    }

    // Etiketli soruda okunan parçalar (ve bu yüzden kaynaklar) yalnız o toplantılardan: önceki turun başka toplantıdan
    // gelen kaynağı devam sorusunda okunmaz; tüm arşive sorulunca okunur.
    @Test func scopedQuestionReadsOnlySelectedMeetings() throws {
        let all: [MeetingRecord] = archive()
        let budget: ArchivePassage = try #require(archivePassages(records: all).first { $0.meetingID == "b" && $0.kind == .note })
        let history: [ArchiveTurn] = [ArchiveTurn(question: "Bütçe ne olacak?", answer: "Yüzde 10 artacak [1].", sources: [budget])]
        let scoped: [MeetingRecord] = try archiveScope(records: all, meetingIDs: ["a"])
        let read: [ArchivePassage] = questionPassages(question: "Peki bunu kim üstlendi?", terms: ["budjetti", "kahvikone"], history: history, records: scoped, maxChars: 60_000)
        #expect(!read.isEmpty && read.allSatisfy { $0.meetingID == "a" }, "\(read.map(\.id))")
        let sources: [ArchivePassage] = citedAnswer(text: "Mikko [1][2][3][4].", passages: read).sources
        #expect(sources.allSatisfy { $0.meetingID == "a" })
        let unscoped: [ArchivePassage] = questionPassages(question: "Peki bunu kim üstlendi?", terms: ["kahvikone"], history: history, records: all, maxChars: 60_000)
        #expect(unscoped.contains(budget))
    }

    // Kopyalanan cevap: kalın işaretleri atılır, [n] kalır, altında numaralı kaynak başlıkları (not ya da zaman).
    @Test func copiedAnswerHasPlainTextAndSourceTitles() throws {
        let passages: [ArchivePassage] = archivePassages(records: archive())
        let note: ArchivePassage = try #require(passages.first { $0.meetingID == "b" && $0.kind == .note })
        let transcript: ArchivePassage = try #require(passages.first { $0.meetingID == "a" && $0.kind == .transcript })
        let answer: ArchiveAnswer = ArchiveAnswer(text: "**Bütçe** %10 artacak [1].\n- Mikko kahve makinesini alacak [2].", sources: [note, transcript])
        let locale: Locale = Locale(identifier: "tr_TR")
        let date: (Date) -> String = { (value: Date) -> String in value.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)) }
        #expect(archiveAnswerPlainText(answer: answer, sourcesHeading: "Kaynaklar", noteLabel: "not", locale: locale) == """
        Bütçe %10 artacak [1].
        - Mikko kahve makinesini alacak [2].

        Kaynaklar
        [1] Bütçe planlaması · \(date(note.meetingDate)) · not
        [2] Haftalık ekip toplantısı · \(date(transcript.meetingDate)) · \(timestamp(seconds: transcript.startSec))
        """)
        #expect(archiveAnswerPlainText(answer: ArchiveAnswer(text: "Bilgi yok.", sources: []), sourcesHeading: "Kaynaklar", noteLabel: "not", locale: locale) == "Bilgi yok.")
    }

    // Etiketli soru geçmişe kapsamıyla yazılır ve aynen geri okunur (sohbet yeniden açılınca etiketler görünür).
    @Test func askHistoryKeepsMentionScope() throws {
        let directory: URL = try temporaryDirectory()
        let source: ArchivePassage = try #require(archivePassages(records: archive()).first { $0.meetingID == "a" })
        let turn: AskConversationTurn = AskConversationTurn(
            id: UUID(), question: "Kim ne üstlendi?", scopeMeetingIDs: ["a", "b"], scopeTitles: ["Haftalık ekip toplantısı", "Bütçe planlaması"],
            recipeTitle: nil, startedAt: Date(timeIntervalSince1970: 1_792_000_000), finishedAt: Date(timeIntervalSince1970: 1_792_000_006),
            terms: [], readPassages: [], answer: "Mikko [1].", sources: [source], modelName: "Claude"
        )
        let conversation: AskConversation = askConversation(existing: nil, id: UUID(), turns: [turn], now: Date(timeIntervalSince1970: 1_792_000_006))
        try saveAskConversation(conversation: conversation, directory: directory)
        let loaded: AskHistoryLoadResult = try loadAskConversations(directory: directory)
        #expect(loaded.failures.isEmpty)
        #expect(loaded.conversations == [conversation])
        #expect(loaded.conversations.first?.turns.first?.scopeMeetingIDs == ["a", "b"])
        #expect(loaded.conversations.first?.turns.first?.scopeTitles == ["Haftalık ekip toplantısı", "Bütçe planlaması"])
    }
}

extension CloudTests {
@Suite struct ArchiveQuestionCloudTests {
    // Gerçek model: Türkçe soru, cevabı yalnızca Fince transkriptte olan bilgi; doğru kişi ve toplantı kaynak gösterilir.
    @Test func turkishQuestionFindsFinnishTranscript() async throws {
        let provider: LLMProvider = .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic)))
        let answer: ArchiveAnswer = try await askArchive(
            question: "Kahve makinesi bozulduğunda ne yapılmasına karar verildi, kim ilgilenecek?",
            history: [], records: archive(), userName: "Senol", language: .turkish, llm: provider, maxChars: 60_000, now: Date(timeIntervalSince1970: 1_792_000_000)
        ) { (_: ArchiveProgress) -> Void in }
        #expect(answer.text.contains("Mikko"), "\(answer.text)")
        #expect(answer.sources.contains { $0.meetingID == "a" }, "\(answer.sources.map(\.id))")
    }

    // Gerçek model: "@" ile seçilen toplantıya soru; arama terimi istenmez (toplantı sığar), tüm kaynaklar o toplantıdan.
    @Test func mentionedMeetingAnswersFromItOnly() async throws {
        let provider: LLMProvider = .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic)))
        let events: ProgressBox = ProgressBox()
        let answer: ArchiveAnswer = try await askAboutMeetings(
            question: "Bu toplantıda neler konuşuldu?", history: [], records: archive().filter { $0.id == "a" }, userName: "Senol", language: .turkish, llm: provider,
            maxChars: 60_000, now: Date(timeIntervalSince1970: 1_792_000_000)
        ) { (progress: ArchiveProgress) -> Void in
            events.append(progress)
        }
        #expect(!answer.sources.isEmpty && answer.sources.allSatisfy { $0.meetingID == "a" }, "\(answer.sources.map(\.id))")
        #expect(events.values.contains { if case .searchTerms(let terms) = $0 { return terms.isEmpty } else { return false } })
        let text: String = answer.text.lowercased()
        #expect(text.contains("kahve") || text.contains("mikko"), "\(answer.text)")
    }

    // Gerçek model: "Takip e-postası" tarifi seçilen toplantıya; konu satırıyla başlayan, işi üstleneni (Mikko) anan taslak.
    @Test func followUpEmailRecipe() async throws {
        let provider: LLMProvider = .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic)))
        let recipe: Recipe = try #require(builtInRecipes().first { $0.id == "takip-epostasi" })
        let answer: ArchiveAnswer = try await askAboutMeetings(
            question: recipe.prompt, history: [], records: archive().filter { $0.id == "a" }, userName: "Senol", language: .turkish, llm: provider,
            maxChars: 60_000, now: Date(timeIntervalSince1970: 1_792_000_000)
        ) { (_: ArchiveProgress) -> Void in }
        let text: String = answer.text.lowercased()
        #expect(text.contains("mikko"), "\(answer.text)")
        #expect(text.contains("aihe") || text.contains("subject") || text.contains("konu"), "\(answer.text)")
    }

    // Gerçek model: devam sorusu ("bunu") önceki konuşmadan anlaşılır; adımlar sırayla bildirilir ve cevap parça parça akar.
    @Test func followUpStreamsWithSteps() async throws {
        let provider: LLMProvider = .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic)))
        let events: ProgressBox = ProgressBox()
        let earlier: [ArchivePassage] = archivePassages(records: archive()).filter { $0.text.contains("Kahvikone") }
        let answer: ArchiveAnswer = try await askArchive(
            question: "Peki bunu kim halledecek ve ne zaman?",
            history: [ArchiveTurn(question: "Kahve makinesiyle ilgili ne konuşuldu?", answer: "Haftalık ekip toplantısında kahve makinesinin yine bozulduğu söylendi [1].", sources: earlier)],
            records: archive(), userName: "Senol", language: .turkish, llm: provider, maxChars: 60_000, now: Date(timeIntervalSince1970: 1_792_000_000)
        ) { (progress: ArchiveProgress) -> Void in
            events.append(progress)
        }
        let all: [ArchiveProgress] = events.values
        #expect(answer.text.contains("Mikko"), "\(answer.text)")
        #expect(answer.text.lowercased().contains("pazartesi"), "\(answer.text)")
        #expect(answer.text.contains("[1]") && answer.sources.contains { $0.meetingID == "a" }, "\(answer.text)")
        guard case .searchTerms = all.first, case .passages = all.dropFirst().first else {
            Issue.record("adımlar sırasız: \(all.count)")
            return
        }
        let partials: Int = all.filter { if case .answer = $0 { true } else { false } }.count
        #expect(partials > 3, "akış parça sayısı: \(partials)")
    }

    // Gerçek model: Mikko'yla yapılacak toplantı için brifing, önceki toplantıda Mikko'nun üstlendiği işi bulur.
    @Test func briefingFindsEarlierCommitments() async throws {
        let provider: LLMProvider = .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic)))
        let meeting: CalendarMeeting = CalendarMeeting(id: "c", title: "Viikkopalaveri", start: Date(timeIntervalSince1970: 1_792_000_000), end: Date(timeIntervalSince1970: 1_792_001_800), attendees: ["Mikko"], joinURL: nil)
        let answer: ArchiveAnswer = try await askArchive(
            question: briefingQuestion(meeting: meeting), history: [], records: archive(), userName: "Senol", language: .turkish, llm: provider, maxChars: 60_000,
            now: Date(timeIntervalSince1970: 1_791_999_000)
        ) { (_: ArchiveProgress) -> Void in }
        let text: String = answer.text.lowercased()
        #expect(text.contains("kahve") || text.contains("kahvi"), "\(answer.text)")
        #expect(answer.sources.contains { $0.meetingID == "a" }, "\(answer.sources.map(\.id))")
    }
}
}

/// İlerleme bildirimlerini toplar (testte eşzamanlı erişim için kilitli).
private final class ProgressBox: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var stored: [ArchiveProgress] = []

    func append(_ value: ArchiveProgress) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [ArchiveProgress] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite struct SkillImportTests {
    // Depodaki AI-Notepad becerisi tarif olur; ön bilgisi olmayan dosya açık hatayla reddedilir.
    @Test func skillBecomesRecipe() throws {
        let text: String = """
        ---
        name: weekly-review
        description: "Haftalık toplantı özeti"
        ---

        # Haftalık özet

        Son 7 günün toplantılarını özetle.
        """
        let recipe: Recipe = try recipeFromSkill(text: text, file: "SKILL.md", id: "s1")
        #expect(recipe.title == "Weekly Review" && !recipe.isBuiltIn)
        #expect(recipe.prompt.hasPrefix("Haftalık toplantı özeti") && recipe.prompt.contains("Son 7 günün"))
        #expect(throws: SkillImportError.missingFrontMatter(file: "x.md")) { try recipeFromSkill(text: "# başlık", file: "x.md", id: "s2") }
        let bundled: String = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../skills/ai-notepad-meetings/SKILL.md"), encoding: .utf8)
        #expect(try recipeFromSkill(text: bundled, file: "SKILL.md", id: "s3").title == "Ai Notepad Meetings")
    }
}
