import Foundation
import Testing
@testable import AINotepadCore

private let finnishEnglish: [MeetingLanguage] = [.finnish, .english]

@Suite struct LanguageSelectionTests {
    @Test func picksHigherAmongCandidates() {
        #expect(pickLanguage(logProbs: ["fi": -0.2, "en": -2.0], candidates: finnishEnglish) == .finnish)
        #expect(pickLanguage(logProbs: ["fi": -3.0, "en": -0.1], candidates: finnishEnglish) == .english)
        // İsveççe toplantı: aday İsveççe ise seçilir.
        #expect(pickLanguage(logProbs: ["sv": -0.1, "en": -2.0], candidates: automaticCandidates(primary: .swedish)) == .swedish)
    }

    // WhisperKit yalnızca en olası dili döndürür: kısa Fince bölüm "et" gelebilir; aday değilse oy vermez.
    @Test func languagesOutsideCandidatesAreIgnored() {
        #expect(pickLanguage(logProbs: ["et": -0.1, "fi": -1.0, "en": -3.0], candidates: finnishEnglish) == .finnish)
        #expect(pickLanguage(logProbs: ["et": -0.1], candidates: finnishEnglish) == nil)
        let votes: LanguageVotes = LanguageVotes(scores: [.finnish: 0.7])
        #expect(addVote(votes: votes, logProbs: ["et": -0.1], candidates: finnishEnglish) == votes)
    }

    @Test func votesAccumulateAsProbabilities() {
        let votes: LanguageVotes = addVote(votes: .empty, logProbs: ["fi": Float(log(0.8)), "en": Float(log(0.1))], candidates: finnishEnglish)
        #expect(abs((votes.scores[.finnish] ?? 0) - 0.8) < 1e-6)
        #expect(abs((votes.scores[.english] ?? 0) - 0.1) < 1e-6)
    }

    @Test func segmentLanguageUsesDetectionThenLeaderThenPrimary() {
        let englishLead: LanguageVotes = LanguageVotes(scores: [.finnish: 0.1, .english: 0.8])
        #expect(resolveSegmentLanguage(detected: .finnish, votes: englishLead, candidates: finnishEnglish) == .finnish)
        #expect(resolveSegmentLanguage(detected: nil, votes: englishLead, candidates: finnishEnglish) == .english)
        #expect(resolveSegmentLanguage(detected: nil, votes: .empty, candidates: automaticCandidates(primary: .german)) == .german)
    }

    @Test func locksToMajorityAfterThreshold() {
        let votes: LanguageVotes = LanguageVotes(scores: [.finnish: 1.5, .english: 0.4])
        #expect(lockedLanguage(votes: votes, elapsedSec: 29.9, lockAfterSec: 30, candidates: finnishEnglish) == nil)
        #expect(lockedLanguage(votes: votes, elapsedSec: 30, lockAfterSec: 30, candidates: finnishEnglish) == .finnish)
        #expect(lockedLanguage(votes: .empty, elapsedSec: 100, lockAfterSec: 30, candidates: finnishEnglish) == nil)
        #expect(leadingLanguage(votes: LanguageVotes(scores: [.finnish: 0.2, .english: 0.9]), candidates: finnishEnglish) == .english)
    }

    // ElevenLabs kodları (ISO 639-3) toplantı diline; desteklenmeyen dil nil.
    @Test func elevenLabsCodesMapToLanguages() {
        #expect(meetingLanguage(elevenLabsCode: "fin") == .finnish)
        #expect(meetingLanguage(elevenLabsCode: "swe") == .swedish)
        #expect(meetingLanguage(elevenLabsCode: "zho") == .chinese)
        #expect(meetingLanguage(elevenLabsCode: "xyz") == nil)
        #expect(elevenLabsLanguageCode(languageMode: .fixed(.german)) == "deu")
        #expect(Set(MeetingLanguage.allCases.map(\.elevenLabsCode)).count == MeetingLanguage.allCases.count)
    }
}
