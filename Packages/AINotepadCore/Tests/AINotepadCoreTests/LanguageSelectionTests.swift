import Foundation
import Testing
@testable import AINotepadCore

@Suite struct LanguageSelectionTests {
    @Test func picksHigherOfFinnishAndEnglish() throws {
        #expect(try pickLanguage(logProbs: ["fi": -0.2, "en": -2.0]) == .finnish)
        #expect(try pickLanguage(logProbs: ["fi": -3.0, "en": -0.1]) == .english)
    }

    @Test func ignoresOtherLanguages() throws {
        #expect(try pickLanguage(logProbs: ["et": -0.1, "fi": -1.0, "en": -3.0]) == .finnish)
    }

    @Test func missingCodesThrow() {
        #expect(throws: TranscriptionError.languageProbabilitiesMissing(availableCodes: ["et"])) {
            try pickLanguage(logProbs: ["et": -0.1])
        }
    }

    @Test func votesAccumulateAsProbabilities() throws {
        let votes: LanguageVotes = try addVote(
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
