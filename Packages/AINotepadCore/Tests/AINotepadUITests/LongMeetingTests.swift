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
        // Üç ölçümün en kısası: paralel çalışan testler ya da yüklü makine zamanlayıcı gürültüsü katar; ölçülen,
        // kodun kendi hızıdır (karesel büyüme yine sınırı açıkça aşar).
        let runs: [(state: LiveViewState, elapsed: Duration)] = (0..<3).map { (_: Int) -> (state: LiveViewState, elapsed: Duration) in
            let started: ContinuousClock.Instant = .now
            let state: LiveViewState = makeLiveViewState(
                transcript: transcript, translations: [:], displayMode: .bilingual, failedTranslations: [], assistantCard: nil,
                phase: .recording, newPersonNumber: 3, isPaused: false, isMicMuted: false, canToggleMic: true, isInPerson: false, canStart: false, startedAt: nil,
                statusText: "", languageText: "", noteLanguageText: "Türkçe", errors: []
            )
            return (state: state, elapsed: ContinuousClock.now - started)
        }
        let elapsed: Duration = runs.map(\.elapsed).min() ?? .zero
        let state: LiveViewState = runs[0].state
        // Sınır geniş: amaç karesel büyümeyi yakalamak (o zaman saniyeler sürer), yüklü CI makinesinde titremek değil.
        #expect(elapsed < .milliseconds(500), "güncelleme \(elapsed) sürdü")
        #expect(state.blocks.allSatisfy { ($0.segments.last?.startSec ?? 0) - $0.startSec < 60 })
    }
}
