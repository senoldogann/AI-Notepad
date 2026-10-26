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

    // Gerçek toplantıdan: iki tanıyıcı bileşik kelimeyi ve eki farklı böldü; kelime karşılaştırması kaçırıyordu.
    @Test func hidesEchoWithDifferentWordSplits() {
        let first: LiveSegment = timed(.others, 0, 0, 3, "Täältä lehdistötilaisuuteen. Me ollaan tänään")
        let second: LiveSegment = timed(.others, 1, 3, 7, "aiheena perussuomalaisten säästöt tulevalle hallituskaudelle.")
        let echoOne: LiveSegment = timed(.me, 0, 0.2, 3, "Täältä lehdistä tilaisuuteen Myyhon tänään")
        let echoTwo: LiveSegment = timed(.me, 1, 6, 7, "kaudelle.")
        #expect(suppressEchoes(transcript: [first, echoOne, second, echoTwo]) == [first, second])
    }

    // Saklanan toplantıda da ("Sen" canlı, "Diğerleri" son geçiş) aynı süzme yapılır.
    @Test func storedSegmentsAreFilteredToo() {
        let others: StoredSegment = StoredSegment(key: "final-0", speaker: .others, person: 1, startSec: 0, endSec: 3, text: "Täältä lehdistötilaisuuteen. Me ollaan tänään", words: nil)
        let echo: StoredSegment = StoredSegment(key: "me-0", speaker: .me, person: nil, startSec: 0.2, endSec: 3, text: "Täältä lehdistä tilaisuuteen Myyhon tänään", words: nil)
        let mine: StoredSegment = StoredSegment(key: "me-1", speaker: .me, person: nil, startSec: 20, endSec: 22, text: "Minulla on kysymys raportista", words: nil)
        #expect(suppressStoredEchoes(segments: [others, echo, mine]) == [others, mine])
    }

    // Soruyu tekrar eden gerçek cevap sorudan sonra gelir: yankı değildir, nota girmeli.
    @Test func keepsReplyRepeatingTheQuestion() {
        let question: LiveSegment = timed(.others, 0, 0, 3, "Doğan, voitko tehdä diat perjantaiksi?")
        let reply: LiveSegment = timed(.me, 0, 3.3, 5, "Joo, teen diat perjantaiksi")
        let english: LiveSegment = timed(.others, 1, 10, 13, "Can you send the report by Friday?")
        let answer: LiveSegment = timed(.me, 1, 13.2, 15.5, "Yes, I can send the report by Friday")
        #expect(suppressEchoes(transcript: [question, reply, english, answer]) == [question, reply, english, answer])
    }
}
