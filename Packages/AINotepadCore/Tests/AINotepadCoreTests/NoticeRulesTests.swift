import AINotepadCore
import Foundation
import Testing

@Suite struct NoticeRulesTests {
    // Aynı mesaj ekranda iki kez görünmez: başka yerde gösterilen ya da çözülmüş hata şeritten düşer; tekrarlar bir
    // kez, en yeni üç tane kalır.
    @Test func errorBannerNeverRepeatsAMessage() {
        let errors: [String] = ["a", "giriş yap", "b", "a", "c", "d"]
        #expect(visibleErrorMessages(errors: errors, shownElsewhere: ["giriş yap"], resolved: []) == ["a", "c", "d"])
        #expect(visibleErrorMessages(errors: ["giriş yap"], shownElsewhere: [], resolved: ["giriş yap"]).isEmpty)
        #expect(visibleErrorMessages(errors: ["x", "x"], shownElsewhere: [], resolved: []) == ["x"])
    }

    // Kayıt başlayamama nedeni hak durumundan: deneme bitti, aylık sınır doldu; ek sürede kayıt yapılabilir.
    @Test func startBlockFollowsEntitlements() throws {
        func decoded(_ text: String) throws -> HostedEntitlements {
            try testHostedDecoder().decode(HostedEntitlements.self, from: Data(text.utf8))
        }
        let subscriber: String = #"""
        {"userId":"u","plan":"subscription","trialMeetingsTotal":3,"trialMeetingsLeft":0,"accountTrialMeetingsLeft":0,"deviceTrialMeetingsLeft":null,
         "monthlyHoursUsed":10,"monthlyHoursCap":10,
         "subscription":{"status":"past_due","complimentary":false,"currentPeriodEnd":"2026-11-20T00:00:00.000Z","access":"grace","graceEndsAt":"2026-11-27T00:00:00.000Z"}}
        """#
        #expect(hostedStartBlock(entitlements: try decoded(subscriber)) == .monthlyCapReached)
        #expect(hostedStartBlock(entitlements: try decoded(subscriber.replacingOccurrences(of: #""monthlyHoursUsed":10"#, with: #""monthlyHoursUsed":4"#))) == nil)
        // Hiç abone olmamış deneme hesabı; eski abone (abonelik bitti, deneme yok) "abonelik sona erdi".
        let trial: String = subscriber.replacingOccurrences(
            of: #"{"status":"past_due","complimentary":false,"currentPeriodEnd":"2026-11-20T00:00:00.000Z","access":"grace","graceEndsAt":"2026-11-27T00:00:00.000Z"}"#, with: "null"
        )
        #expect(hostedStartBlock(entitlements: try decoded(trial)) == .trialEnded)
        #expect(hostedStartBlock(entitlements: try decoded(subscriber.replacingOccurrences(of: #""access":"grace""#, with: #""access":"none""#))) == .subscriptionEnded)
        #expect(hostedStartBlock(entitlements: try decoded(trial.replacingOccurrences(of: #""trialMeetingsLeft":0"#, with: #""trialMeetingsLeft":2"#))) == nil)
    }

    // Hak durumu uygulama öne gelince yalnızca eskidiyse yeniden okunur.
    @Test func refreshIsDueOnlyWhenStale() {
        let now: Date = Date(timeIntervalSince1970: 10_000)
        #expect(isHostedRefreshDue(lastRefresh: nil, now: now, intervalSec: hostedStaleRefreshIntervalSec))
        #expect(!isHostedRefreshDue(lastRefresh: now.addingTimeInterval(-30), now: now, intervalSec: hostedStaleRefreshIntervalSec))
        #expect(isHostedRefreshDue(lastRefresh: now.addingTimeInterval(-61), now: now, intervalSec: hostedStaleRefreshIntervalSec))
    }
}

/// Sunucunun tarih biçimi (kesirli saniyeli ISO 8601).
private func testHostedDecoder() -> JSONDecoder {
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { (decoder: any Decoder) throws -> Date in
        try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(try decoder.singleValueContainer().decode(String.self))
    }
    return decoder
}
