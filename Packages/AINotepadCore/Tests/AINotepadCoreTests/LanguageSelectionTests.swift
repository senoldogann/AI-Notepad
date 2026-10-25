import Foundation
import Testing
@testable import AINotepadCore

@Suite struct LanguageSelectionTests {
    @Test func picksHigherOfFinnishAndEnglish() {
        #expect(pickLanguage(logProbs: ["fi": -0.2, "en": -2.0]) == .finnish)
        #expect(pickLanguage(logProbs: ["fi": -3.0, "en": -0.1]) == .english)
    }

    @Test func ignoresOtherLanguages() {
        #expect(pickLanguage(logProbs: ["et": -0.1, "fi": -1.0, "en": -3.0]) == .finnish)
    }

    // WhisperKit yalnızca en olası dili döndürür: kısa Fince bölüm "et" gelebilir.
    @Test func topLanguageOutsideFinnishEnglishGivesNoVote() {
        #expect(pickLanguage(logProbs: ["et": -0.1]) == nil)
        #expect(addVote(votes: LanguageVotes(finnish: 0.7, english: 0), logProbs: ["et": -0.1]) == LanguageVotes(finnish: 0.7, english: 0))
    }

    @Test func singleKeyVoteCountsOnlyThatLanguage() {
        let votes: LanguageVotes = addVote(votes: .empty, logProbs: ["en": Float(log(0.9))])
        #expect(abs(votes.english - 0.9) < 1e-6)
        #expect(votes.finnish == 0)
    }

    @Test func segmentLanguageUsesDetectionThenLeaderThenFinnish() {
        let englishLead: LanguageVotes = LanguageVotes(finnish: 0.1, english: 0.8)
        #expect(resolveSegmentLanguage(detected: .finnish, votes: englishLead) == .finnish)
        #expect(resolveSegmentLanguage(detected: nil, votes: englishLead) == .english)
        #expect(resolveSegmentLanguage(detected: nil, votes: .empty) == .finnish)
    }

    @Test func votesAccumulateAsProbabilities() {
        let votes: LanguageVotes = addVote(
            votes: .empty,
            logProbs: ["fi": Float(log(0.8)), "en": Float(log(0.1))]
        )
        #expect(abs(votes.finnish - 0.8) < 1e-6)
        #expect(abs(votes.english - 0.1) < 1e-6)
    }

    @Test func noLockBeforeThreshold() {
        let votes: LanguageVotes = LanguageVotes(finnish: 1.5, english: 0.4)
        #expect(lockedLanguage(votes: votes, elapsedSec: 29.9, lockAfterSec: 30) == nil)
    }

    @Test func locksToMajorityAfterThreshold() {
        let votes: LanguageVotes = LanguageVotes(finnish: 1.5, english: 0.4)
        #expect(lockedLanguage(votes: votes, elapsedSec: 30, lockAfterSec: 30) == .finnish)
    }

    @Test func noLockWithoutVotes() {
        #expect(lockedLanguage(votes: .empty, elapsedSec: 100, lockAfterSec: 30) == nil)
    }

    @Test func leadingIsNilWhenEmpty() {
        #expect(leadingLanguage(votes: .empty) == nil)
        #expect(leadingLanguage(votes: LanguageVotes(finnish: 0.2, english: 0.9)) == .english)
    }
}
