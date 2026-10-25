import Foundation
import Testing
@testable import AINotepadCore

@Suite struct HallucinationFilterTests {
    @Test func dropsKnownStandalonePhrases() {
        #expect(dropHallucination(text: " Kiitos.") == "")
        #expect(dropHallucination(text: "Kiitos katsomisesta!") == "")
        #expect(dropHallucination(text: "Thank you.") == "")
        #expect(dropHallucination(text: "Thanks for watching!") == "")
    }

    @Test func keepsRealSentencesContainingPhrases() {
        #expect(dropHallucination(text: "Kiitos, aloitetaan kokous.") == "Kiitos, aloitetaan kokous.")
        #expect(dropHallucination(text: "Thank you for the report.") == "Thank you for the report.")
    }
}
