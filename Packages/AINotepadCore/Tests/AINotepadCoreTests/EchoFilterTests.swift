import Foundation
import Testing
@testable import AINotepadCore

func timed(_ speaker: Speaker, _ index: Int, _ start: Double, _ end: Double, _ text: String) -> LiveSegment {
    LiveSegment(id: SegmentID(speaker: speaker, index: index), startSec: start, endSec: end, text: text, isFinal: true, failureMessage: nil, person: nil)
}

@Suite struct EchoFilterTests {
    @Test func hidesMeSegmentRepeatingOthers() {
        let others: LiveSegment = timed(.others, 0, 10, 14, "Tässä lähetyksessä tapaamme Jarnon joka valmentaa koripalloa")
        let echo: LiveSegment = timed(.me, 0, 10.5, 12, "Tässä lähetyksessä tapaamme Jarnon")
        #expect(suppressEchoes(transcript: [others, echo]) == [others])
    }

    @Test func hidesShortGreetingEcho() {
        let others: LiveSegment = timed(.others, 0, 1, 2, "Moi!")
        let echo: LiveSegment = timed(.me, 0, 1.2, 2, "Moi!")
        #expect(suppressEchoes(transcript: [others, echo]) == [others])
    }

    @Test func keepsOwnDifferentSpeech() {
        let others: LiveSegment = timed(.others, 0, 10, 14, "Tässä lähetyksessä tapaamme Jarnon")
        let mine: LiveSegment = timed(.me, 0, 11, 13, "Minulla on kysymys raportista")
        #expect(suppressEchoes(transcript: [others, mine]) == [others, mine])
    }

    @Test func keepsSameWordsFarApartInTime() {
        let others: LiveSegment = timed(.others, 0, 10, 12, "Kiitos paljon")
        let mine: LiveSegment = timed(.me, 0, 30, 31, "Kiitos paljon")
        #expect(suppressEchoes(transcript: [others, mine]) == [others, mine])
    }

    @Test func matchesAcrossDifferentSegmentBoundaries() {
        // Diğerleri iki bölüme, yankı tek bölüme bölünmüş.
        let first: LiveSegment = timed(.others, 0, 0, 3, "ja selvitämme")
        let second: LiveSegment = timed(.others, 1, 3, 6, "mitä ilmastonmuutos tarkoittaa")
        let echo: LiveSegment = timed(.me, 0, 1, 6, "ja selvitämme mitä ilmastonmuutosta")
        #expect(suppressEchoes(transcript: [first, second, echo]) == [first, second])
    }
}
