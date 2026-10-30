import Foundation
import Testing
@testable import AINotepadCore

/// Saniyelerden paylar (toplam üzerinden).
private func shares(seconds: [(key: SpeakerKey, seconds: Double)]) -> [SpeakerShare] {
    let total: Double = seconds.map(\.seconds).reduce(0, +)
    return seconds.map { SpeakerShare(key: $0.key, seconds: $0.seconds, fraction: $0.seconds / total) }
}

private func person(_ number: Int) -> SpeakerKey {
    SpeakerKey(speaker: .others, person: number)
}

@Suite struct SpeakerGroupsTests {
    // 18 dakikalık haber yayını: iki sunucu ve kısa araya girmeler; kısalar tek girişte toplanır, sıra korunur.
    @Test func newsBroadcastCollapsesShortSpeakers() {
        let all: [SpeakerShare] = shares(seconds: [
            (person(1), 560), (person(2), 420), (person(3), 40), (person(4), 12), (person(5), 9), (person(6), 6), (person(7), 3),
        ])
        let groups: SpeakerGroups = groupedSpeakers(shares: all, speakerNames: [:])
        #expect(groups.major.map(\.key) == [person(1), person(2), person(3)])
        #expect(groups.minor.map(\.key) == [person(4), person(5), person(6), person(7)])
        #expect(groups.minorSeconds == 30)
    }

    // Ad verilen kişi, "Sen" ve ayrılmamış "Diğerleri" hiç toplanmaz.
    @Test func namedMeAndUnsplitAreNeverMinor() {
        let me: SpeakerKey = SpeakerKey(speaker: .me, person: nil)
        let unsplit: SpeakerKey = SpeakerKey(speaker: .others, person: nil)
        let all: [SpeakerShare] = shares(seconds: [(person(1), 900), (person(2), 5), (me, 4), (unsplit, 3), (person(3), 2), (person(4), 1)])
        let groups: SpeakerGroups = groupedSpeakers(shares: all, speakerNames: [2: "Aino", 4: ""])
        #expect(groups.major.map(\.key) == [person(1), person(2), me, unsplit])
        #expect(groups.minor.map(\.key) == [person(3), person(4)])
    }

    // Tek kısa konuşmacı ayrı kalır ("Kısa konuşmalar (1)" sadeleştirmez).
    @Test func singleMinorSpeakerStaysVisible() {
        let all: [SpeakerShare] = shares(seconds: [(person(1), 600), (person(2), 500), (person(3), 4)])
        #expect(groupedSpeakers(shares: all, speakerNames: [:]) == SpeakerGroups(major: all, minor: []))
    }

    // Süre ve pay sınırı birlikte: kısa toplantıda (5 dk) 10 sn %3'ü aşar ve ayrı kalır, 8 sn toplanır; uzun toplantıda
    // 15 sn'den uzun konuşan payı küçük olsa da ayrı kalır.
    @Test func thresholdNeedsBothDurationAndShare() {
        let short: [SpeakerShare] = shares(seconds: [(person(1), 200), (person(2), 82), (person(3), 10), (person(4), 8)])
        #expect(!isMinorSpeaker(share: short[2], speakerNames: [:]))
        #expect(isMinorSpeaker(share: short[3], speakerNames: [:]))
        let long: [SpeakerShare] = shares(seconds: [(person(1), 3000), (person(2), 20)])
        #expect(!isMinorSpeaker(share: long[1], speakerNames: [:]))
    }
}
