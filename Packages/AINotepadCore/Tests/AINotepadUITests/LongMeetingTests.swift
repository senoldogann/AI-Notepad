import Foundation
import Testing
import AINotepadCore
@testable import AINotepadUI

@Suite struct LongMeetingTests {
    /// 4 saatlik canlı transkript (5 sn'de bir bölüm); `mixed` ise "Sen" ve iki kişi karışık, değilse tek konuşmacı.
    private func fourHourTranscript(mixed: Bool) -> [LiveSegment] {
        (0..<2900).map { (index: Int) -> LiveSegment in
            let isMe: Bool = mixed && index % 3 == 0
            return LiveSegment(
                id: SegmentID(speaker: isMe ? .me : .others, index: index), startSec: Double(index) * 5, endSec: Double(index) * 5 + 4.5,
                text: "Tämä on lause numero \(index) ja siinä on muutama sana lisää.", isFinal: true, failureMessage: nil,
                person: isMe ? nil : (mixed ? (index % 2) + 1 : nil)
            )
        }
    }

    // Panel her yeni bölümde görünümü yeniden kurar: 4 saatte de bir güncelleme kısa sürmeli ve tek konuşmacı tek dev
    // blok olmamalı (önce gruplama karesel büyüyor, yankı filtresi tüm çiftleri karşılaştırıyordu).
    @Test(arguments: [false, true])
    func fourHourViewStateStaysFast(mixed: Bool) {
        let transcript: [LiveSegment] = fourHourTranscript(mixed: mixed)
        let started: ContinuousClock.Instant = .now
        let state: LiveViewState = makeLiveViewState(
            transcript: transcript, translations: [:], displayMode: .bilingual, failedTranslations: [], assistantCard: nil,
            phase: .recording, newPersonNumber: 3, isPaused: false, isMicMuted: false, canStart: false, startedAt: nil,
            statusText: "", languageText: "", errors: []
        )
        let elapsed: Duration = ContinuousClock.now - started
        #expect(elapsed < .milliseconds(100), "güncelleme \(elapsed) sürdü")
        #expect(state.blocks.allSatisfy { ($0.segments.last?.startSec ?? 0) - $0.startSec < 60 })
    }
}
