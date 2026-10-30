import AINotepadCore
import Foundation
import Testing

/// Sunucu biçimindeki hak durumu.
private func entitlements(plan: String, access: String, trialLeft: Int, used: Double) throws -> HostedEntitlements {
    let subscription: String = access == "none" ? "null" : #"{"status":"active","complimentary":false,"currentPeriodEnd":"2026-12-01T00:00:00.000Z","access":"\#(access)","graceEndsAt":null}"#
    let json: String = #"""
    {"userId":"u1","plan":"\#(plan)","trialMeetingsTotal":3,"trialMeetingsLeft":\#(trialLeft),"accountTrialMeetingsLeft":\#(trialLeft),
     "deviceTrialMeetingsLeft":null,"monthlyHoursUsed":\#(used),"monthlyHoursCap":10,"subscription":\#(subscription)}
    """#
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { (decoder: any Decoder) throws -> Date in
        try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(try decoder.singleValueContainer().decode(String.self))
    }
    return try decoder.decode(HostedEntitlements.self, from: Data(json.utf8))
}

/// Toplantı kaydı (yalnızca kuyruk sıralaması için gereken alanlarla).
private func record(id: String, startedAt: Double, status: MeetingStatus) -> MeetingRecord {
    MeetingRecord(
        id: id, title: id, startedAt: Date(timeIntervalSince1970: startedAt), endedAt: nil, language: nil, status: status, failureMessage: nil,
        liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false,
        engine: .local, notice: nil, meNeedsFinalPass: nil
    )
}

@Suite struct HostedOfflineTests {
    // Çevrimdışı izin: kayıt başlatılabilen hak durumundan; abonede süre kalan aylık dakikayla sınırlı.
    @Test func permitFollowsEntitlements() throws {
        let now: Date = Date(timeIntervalSince1970: 1_000_000)
        let trial: HostedOfflinePermit = try #require(hostedOfflinePermit(entitlements: try entitlements(plan: "trial", access: "none", trialLeft: 2, used: 0), now: now))
        #expect(trial == HostedOfflinePermit(userId: "u1", checkedAt: now, maxMinutes: hostedUsualTrialMeetingMinutes))
        let nearCap: HostedOfflinePermit = try #require(hostedOfflinePermit(entitlements: try entitlements(plan: "subscription", access: "active", trialLeft: 0, used: 9.5), now: now))
        #expect(nearCap.maxMinutes == 30)
        #expect(hostedOfflinePermit(entitlements: try entitlements(plan: "trial", access: "none", trialLeft: 0, used: 0), now: now) == nil)
        #expect(hostedOfflinePermit(entitlements: try entitlements(plan: "subscription", access: "active", trialLeft: 0, used: 10), now: now) == nil)
    }

    // İzin aynı hesabın ve en çok 7 günlük olmalı.
    @Test func permitExpiresAndIsPerAccount() {
        let checked: Date = Date(timeIntervalSince1970: 1_000_000)
        let permit: HostedOfflinePermit = HostedOfflinePermit(userId: "u1", checkedAt: checked, maxMinutes: 90)
        #expect(hostedOfflineRecordingMinutes(permit: permit, userId: "u1", now: checked.addingTimeInterval(6 * 86_400), maxAgeSec: hostedOfflinePermitMaxAgeSec) == 90)
        #expect(hostedOfflineRecordingMinutes(permit: permit, userId: "u1", now: checked.addingTimeInterval(8 * 86_400), maxAgeSec: hostedOfflinePermitMaxAgeSec) == nil)
        #expect(hostedOfflineRecordingMinutes(permit: permit, userId: "u2", now: checked, maxAgeSec: hostedOfflinePermitMaxAgeSec) == nil)
        #expect(hostedOfflineRecordingMinutes(permit: nil, userId: "u1", now: checked, maxAgeSec: hostedOfflinePermitMaxAgeSec) == nil)
        #expect(hostedOfflineRecordingMinutes(permit: permit, userId: "u1", now: checked.addingTimeInterval(-60), maxAgeSec: hostedOfflinePermitMaxAgeSec) == nil)
    }

    // Yalnızca ulaşılamama çevrimdışı kayda düşer; sunucunun bilinçli retleri (deneme bitti, sınır) düşmez.
    @Test func onlyUnreachabilityAllowsOfflineStart() {
        #expect(isOfflineStartError(error: HostedClientError.network(path: "/v1/meetings/start", reason: "-1009")))
        #expect(isOfflineStartError(error: HostedAPIError(code: nil, rawCode: "http_502", status: 502, serverMessage: "", path: "/")))
        #expect(isOfflineStartError(error: HostedAPIError(code: .internalError, rawCode: "internal_error", status: 500, serverMessage: "", path: "/")))
        #expect(!isOfflineStartError(error: HostedAPIError(code: .trialExhausted, rawCode: "trial_exhausted", status: 402, serverMessage: "", path: "/")))
        #expect(!isOfflineStartError(error: HostedAPIError(code: .monthlyCapReached, rawCode: "monthly_cap_reached", status: 403, serverMessage: "", path: "/")))
        #expect(!isOfflineStartError(error: HostedClientError.notSignedIn))
    }

    // Eski abone (abonelik bitti, deneme hakkı yok) "deneme bitti" değil "abonelik sona erdi" görür; deneme hakkı
    // kalan eski abone denemeyi kullanabilir.
    @Test func formerSubscriberSeesSubscriptionEnded() throws {
        let json: String = #"""
        {"userId":"u1","plan":"trial","trialMeetingsTotal":3,"trialDays":7,"trialMeetingsLeft":0,"accountTrialMeetingsLeft":0,"deviceTrialMeetingsLeft":null,
         "monthlyHoursUsed":0,"monthlyHoursCap":10,
         "subscription":{"status":"canceled","complimentary":false,"currentPeriodEnd":"2026-10-01T00:00:00.000Z","access":"none","graceEndsAt":null}}
        """#
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { (decoder: any Decoder) throws -> Date in
            try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(try decoder.singleValueContainer().decode(String.self))
        }
        let expired: HostedEntitlements = try decoder.decode(HostedEntitlements.self, from: Data(json.utf8))
        #expect(expired.trialDays == 7)
        #expect(hostedPlanStatus(entitlements: expired) == .expired(endedAt: try Date.ISO8601FormatStyle().parse("2026-10-01T00:00:00Z")))
        #expect(hostedStartBlock(entitlements: expired) == .subscriptionEnded)
        #expect(hostedUsageNotice(entitlements: expired) == nil)
        let withTrial: HostedEntitlements = try decoder.decode(HostedEntitlements.self, from: Data(json.replacingOccurrences(of: #""trialMeetingsLeft":0"#, with: #""trialMeetingsLeft":2"#).utf8))
        #expect(hostedPlanStatus(entitlements: withTrial) == .trial(left: 2, total: 3))
    }

    // Aynı sınır kodu farklı sınırlardan gelir: Sor'un payı dolunca kayıt engellenmiş gibi okunmaz.
    @Test func capMessagesNameTheRightLimit() {
        func message(_ code: HostedErrorCode, _ path: String) -> String {
            hostedErrorMessage(error: HostedAPIError(code: code, rawCode: code.rawValue, status: 429, serverMessage: "", path: path))
        }
        #expect(message(.monthlyCapReached, "/v1/meetings/start").contains("kayıt saatlerin"))
        #expect(message(.monthlyCapReached, "/v1/llm/messages").contains("Kayıt yapmaya devam edebilirsin"))
        #expect(message(.dailyCapReached, "/v1/llm/messages").contains("Kayıt yapmaya devam edebilirsin"))
        #expect(message(.dailyCapReached, "/v1/meetings/start").contains("toplantı sayısına"))
    }

    // Sunucunun reddettiği kayıt bekleme süresince atlanır (sonrakiler denenir), süre dolunca yeniden denenir.
    @Test func rejectedQueuedRecordsCoolDown() {
        let records: [MeetingRecord] = [record(id: "a", startedAt: 1, status: .queued), record(id: "b", startedAt: 2, status: .queued)]
        let now: Date = Date(timeIntervalSince1970: 10_000)
        let rejections: [String: Date] = ["a": now.addingTimeInterval(-60)]
        #expect(hostedQueueCandidates(records: records, rejections: rejections, now: now, cooldownSec: 600).map(\.id) == ["b"])
        #expect(hostedQueueCandidates(records: records, rejections: rejections, now: now.addingTimeInterval(600), cooldownSec: 600).map(\.id) == ["a", "b"])
    }

    // Yarıda kalan çevrimdışı (bağsız) kayıt kuyruğa döner; bağlı kayıt ve diğer durumlar değişmez.
    @Test func unlinkedInterruptedRecordReturnsToQueue() {
        let records: [MeetingRecord] = [
            record(id: "offline", startedAt: 1, status: .interrupted), record(id: "online", startedAt: 2, status: .interrupted), record(id: "bitti", startedAt: 3, status: .done),
        ]
        let result: [MeetingRecord] = queuingUnlinkedInterrupted(records: records, linkedRecordIDs: ["online"])
        #expect(result.map(\.status) == [.queued, .interrupted, .done])
        #expect(result[0].failureMessage == nil)
        #expect(result[0].notice?.contains("yarıda kaldı") == true)
    }

    // Kuyruk en eskiden işlenir; bağ kayıt başına tektir ve en yeniler tutulur; son geçiş zaman aşımı sunucu
    // penceresinden uzundur.
    @Test func queueOrderLinksAndTimeout() {
        let records: [MeetingRecord] = [
            record(id: "b", startedAt: 200, status: .queued), record(id: "a", startedAt: 100, status: .done), record(id: "c", startedAt: 150, status: .queued),
        ]
        // Kendi kayıtları en eskiden; başka hesabın kaydı bu hesapla işlenmez; sahibi bilinmeyen oturumdakinindir.
        let queued: HostedQueuedRecords = hostedQueuedRecords(records: records + [record(id: "d", startedAt: 50, status: .queued)], owners: ["d": "baska", "b": "ben"], userId: "ben")
        #expect(queued.own.map(\.id) == ["c", "b"])
        #expect(queued.foreign.map(\.id) == ["d"])
        #expect(hostedQueuedRecords(records: [record(id: "x", startedAt: 1, status: .done)], owners: [:], userId: "ben").own.isEmpty)
        // Ölü bağ silinir, diğerleri kalır.
        let pair: [HostedMeetingLink] = [
            HostedMeetingLink(recordID: "r1", serverMeetingID: "s1", createdAt: Date(timeIntervalSince1970: 1)),
            HostedMeetingLink(recordID: "r2", serverMeetingID: "s2", createdAt: Date(timeIntervalSince1970: 2)),
        ]
        #expect(removingHostedMeetingLink(links: pair, recordID: "r1").map(\.recordID) == ["r2"])
        var links: [HostedMeetingLink] = []
        for index in 0..<5 {
            links = appendingHostedMeetingLink(links: links, link: HostedMeetingLink(recordID: "r\(index % 3)", serverMeetingID: "s\(index)", createdAt: Date(timeIntervalSince1970: Double(index))), capacity: 2)
        }
        #expect(links.map(\.recordID) == ["r0", "r1"])
        #expect(hostedServerMeetingID(recordID: "r1", links: links) == "s4")
        #expect(hostedServerMeetingID(recordID: "r2", links: links) == nil)
        #expect(hostedTranscribeTimeoutSec(durationSec: 60) >= hostedTranscribeMinimumTimeoutSec)
        #expect(hostedTranscribeTimeoutSec(durationSec: 60) > 15 * 60)
    }
}
