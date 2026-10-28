import Foundation
import Testing
@testable import AINotepadCore

/// Not diline göre metin yazdıran her istemin sistem metni (istem adıyla).
private func noteLanguagePrompts(language: ShareLanguage) throws -> [(name: String, system: String)] {
    let live: [LiveSegment] = [block(.others, 0, 5, "Voisitko tehdä diat perjantaiksi?", person: 1), block(.me, 0, 9, "Teen ne.", person: nil)]
    let saved: [StoredSegment] = [stored("final-0", .others, 1, 5, "Voisitko tehdä diat?"), stored("me-0", .me, nil, 9, "Teen ne.")]
    let note: MeetingNote = MeetingNote(
        title: "Diat", summary: "Aino pyysi diat.", decisions: [],
        tasks: [NoteTask(owner: "Doğan", description: "Diat", dueDate: nil, isMine: true)], glossary: []
    )
    return [
        ("çeviri", translationRequest(sentence: "Kuka tekee diat?", context: [], language: language).system),
        ("ne kaçırdım", try #require(missedSummaryRequest(segments: live, nowSec: 12, windowSec: 180, language: language)).system),
        ("canlı soru", try #require(questionRequest(segments: live, question: "Mitä minulta pyydettiin?", language: language)).system),
        ("not", try #require(meetingNoteRequest(
            segments: saved, speakerNames: [1: "Aino"], userName: "Doğan", template: .general, myNotes: "", language: language
        )).system),
        ("not parçası", noteChunkRequest(
            chunk: saved, part: 1, partCount: 2, state: .empty, speakerNames: [:], userName: "Doğan", template: .general, myNotes: "",
            language: language
        ).system),
        ("not özeti", noteOverviewRequest(state: .empty, userName: "Doğan", template: .general, myNotes: "", language: language).system),
        ("not düzenleme", noteEditRequest(
            note: note, instruction: "Kısalt", segments: saved, speakerNames: [:], userName: "Doğan", language: language
        ).system),
        ("arama terimleri", searchTermsRequest(question: "Diat?", history: [], languages: [.finnish, .turkish], language: language).system),
        ("arşiv cevabı", archiveAnswerRequest(
            question: "Diat?", passages: [], history: [], userName: "Doğan", now: Date(timeIntervalSince1970: 1_792_000_000), language: language
        ).system),
        ("konuşmacı incelemesi", try #require(speakerReviewRequest(
            segments: saved, speakerNames: [:], userName: "Doğan", attendees: [], language: language
        )).system),
        ("görev aracı", trackerAgentRequest(
            service: .linear, target: "", tasks: note.tasks, meetingTitle: "Diat", tools: [], transcript: [], language: language
        ).system),
    ]
}

@Suite struct NoteLanguageTests {
    // Seçilen dil her istemde adıyla geçer; Türkçe seçilmediyse istem Türkçe çıktı istemez.
    @Test(arguments: [ShareLanguage.english, .german, .japanese])
    func promptsAskForChosenLanguage(language: ShareLanguage) throws {
        for prompt in try noteLanguagePrompts(language: language) {
            #expect(prompt.system.contains(language.englishName), "dil adı yok: \(prompt.name)")
            #expect(!prompt.system.contains("Türkçe"), "Türkçe istiyor: \(prompt.name)")
            #expect(!prompt.system.contains("Turkish"), "Türkçe istiyor: \(prompt.name)")
        }
    }

    // Türkçe seçiliyken (mevcut kullanıcılar) istemler Türkçe ister.
    @Test func turkishPromptsNameTurkish() throws {
        for prompt in try noteLanguagePrompts(language: .turkish) {
            #expect(prompt.system.contains("Turkish (Türkçe)"), "dil adı yok: \(prompt.name)")
        }
    }

    // Arama terimleri not dilinde ve toplantı dillerinde istenir; not diliyle aynı toplantı dili tekrarlanmaz.
    @Test func searchTermsUseNoteAndMeetingLanguages() {
        let english: String = searchTermsRequest(question: "Diat?", history: [], languages: [.english, .finnish], language: .english).system
        #expect(english.contains("en, fi"))
        let chinese: String = searchTermsRequest(question: "Diat?", history: [], languages: [.chinese, .finnish], language: .chineseSimplified).system
        #expect(chinese.contains("zh-Hans, fi"))
    }
}
