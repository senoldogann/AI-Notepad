import Foundation
import Testing
@testable import AINotepadCore

/// JSON gövdesini sözlük olarak açar.
private func telemetryJSON(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// İstemci telemetrisinin saf parçaları: gönderim izni, olay ve özellik gövdeleri, gün anahtarı.
@Suite struct HostedTelemetryTests {
    // Geliştirici sürümü paylaşım açık olsa da hiçbir şey göndermez; abonelik sürümünde kullanıcının seçimi geçerlidir.
    @Test func developerEditionNeverSends() {
        #expect(!telemetrySendingAllowed(edition: .developer, sharingEnabled: true))
        #expect(!telemetrySendingAllowed(edition: .developer, sharingEnabled: false))
        #expect(!telemetrySendingAllowed(edition: .hosted, sharingEnabled: false))
        #expect(telemetrySendingAllowed(edition: .hosted, sharingEnabled: true))
    }

    // Boş bekleyen olaylar gövde üretmez; sayımlar birleşir, süreler aralığa kırpılır.
    @Test func eventsBodyAggregatesCountsAndClampsDurations() throws {
        let empty: TelemetryPendingEvents = TelemetryPendingEvents(counts: [], durations: [])
        #expect(try hostedTelemetryEventsBody(pending: empty) == nil)
        let pending: TelemetryPendingEvents = addingTelemetryDuration(
            pending: addingTelemetryDuration(
                pending: addingTelemetryCount(pending: addingTelemetryCount(pending: empty, kind: .deepgramSocketDrop), kind: .deepgramSocketDrop),
                kind: .finalPassDuration, seconds: 95.5
            ),
            kind: .noteGenerationDuration, seconds: 200_000
        )
        let body: [String: Any] = try telemetryJSON(try #require(try hostedTelemetryEventsBody(pending: pending)))
        #expect(Set(body.keys) == ["events"])
        let events: [[String: Any]] = try #require(body["events"] as? [[String: Any]])
        #expect(events.count == 3)
        #expect(events[0]["kind"] as? String == "deepgram_socket_drop" && events[0]["count"] as? Int == 2 && events[0]["seconds"] == nil)
        #expect(events[1]["kind"] as? String == "final_pass_duration" && events[1]["seconds"] as? Double == 95.5 && events[1]["count"] == nil)
        #expect(events[2]["seconds"] as? Double == telemetryMaxSeconds)
    }

    // Tek gövdeye sığsın diye en yeni ölçümler tutulur; sayım sınırı aşılmaz.
    @Test func pendingEventsStayWithinServerLimits() throws {
        let many: TelemetryPendingEvents = (0..<200).reduce(TelemetryPendingEvents(counts: [], durations: [])) { (pending: TelemetryPendingEvents, index: Int) -> TelemetryPendingEvents in
            addingTelemetryDuration(pending: pending, kind: .finalPassDuration, seconds: Double(index))
        }
        #expect(many.durations.count == telemetryMaxEventsPerBatch - TelemetryCountKind.allCases.count)
        #expect(many.durations.last?.seconds == 199)
        let capped: TelemetryPendingEvents = (0..<(telemetryMaxCount + 5)).reduce(many) { (pending: TelemetryPendingEvents, _: Int) -> TelemetryPendingEvents in
            addingTelemetryCount(pending: pending, kind: .recordingOverrun)
        }
        #expect(capped.counts.first?.count == telemetryMaxCount)
        let withAllKinds: TelemetryPendingEvents = TelemetryCountKind.allCases.reduce(capped) { (pending: TelemetryPendingEvents, kind: TelemetryCountKind) -> TelemetryPendingEvents in
            addingTelemetryCount(pending: pending, kind: kind)
        }
        let fullBody: [String: Any] = try telemetryJSON(try #require(try hostedTelemetryEventsBody(pending: withAllKinds)))
        let events: [[String: Any]] = try #require(fullBody["events"] as? [[String: Any]])
        #expect(events.count == telemetryMaxEventsPerBatch)
    }

    // Özellik gövdesi her entegrasyon ve dışa aktarma türünü yazar (kullanılmayan 0); hedef dil yalnızca canlı çeviriyle.
    // İçerik taşıyabilecek alan yoktur: yalnızca bilinen anahtarlar.
    @Test func featureBodyIsCompleteAndContentFree() throws {
        let day: String = "2026-10-29"
        let usage: TelemetryFeatureUsage = [
            TelemetryFeature.liveTranslation(.turkish), .ask, .integration(.slack), .integration(.slack), .export(.pdf), .mcp,
        ].reduce(emptyFeatureUsage(day: day)) { (usage: TelemetryFeatureUsage, feature: TelemetryFeature) -> TelemetryFeatureUsage in
            recordingFeature(usage: usage, feature: feature)
        }
        let body: [String: Any] = try telemetryJSON(try hostedFeatureUsageBody(usage: usage))
        #expect(Set(body.keys) == ["day", "liveTranslation", "translationLanguage", "ask", "integrations", "exports", "mcp", "onDeviceLive"])
        #expect(body["day"] as? String == day)
        #expect(body["translationLanguage"] as? String == "tr")
        #expect(body["ask"] as? Bool == true && body["mcp"] as? Bool == true && body["onDeviceLive"] as? Bool == false)
        let integrations: [String: Int] = try #require(body["integrations"] as? [String: Int])
        #expect(Set(integrations.keys) == Set(TelemetryIntegration.allCases.map(\.rawValue)))
        #expect(integrations["slack"] == 2 && integrations["notion"] == 0)
        let exports: [String: Int] = try #require(body["exports"] as? [String: Int])
        #expect(Set(exports.keys) == Set(TelemetryExportFormat.allCases.map(\.rawValue)))
        #expect(exports["pdf"] == 1)

        let quiet: [String: Any] = try telemetryJSON(try hostedFeatureUsageBody(usage: emptyFeatureUsage(day: day)))
        #expect(quiet["translationLanguage"] is NSNull)
        #expect(quiet["liveTranslation"] as? Bool == false)
    }

    // Gün dönünce önceki gün tamamlanmış sayılır ve gönderilmeyi bekler; bugünün kaydı yeniden başlar.
    @Test func featureStateRollsOverAtUTCMidnight() {
        let start: TelemetryFeatureState = TelemetryFeatureState(current: nil, completed: nil)
        let monday: TelemetryFeatureState = recordingFeature(state: start, feature: .ask, today: "2026-10-26")
        #expect(monday.current?.ask == true && monday.completed == nil)
        let tuesday: TelemetryFeatureState = recordingFeature(state: monday, feature: .mcp, today: "2026-10-27")
        #expect(tuesday.completed?.day == "2026-10-26" && tuesday.completed?.ask == true)
        #expect(tuesday.current?.day == "2026-10-27" && tuesday.current?.ask == false && tuesday.current?.mcp == true)
        #expect(rollingFeatureState(state: tuesday, today: "2026-10-27") == tuesday)
        #expect(rollingFeatureState(state: tuesday, today: "2026-10-28").current == nil)
        #expect(telemetryDayKey(date: Date(timeIntervalSince1970: 1_761_868_799)) == "2025-10-30")
        #expect(telemetryDayKey(date: Date(timeIntervalSince1970: 1_761_868_800)) == "2025-10-31")
    }

    // Sürüm başlıkları sunucunun biçimindedir; bozuk paket sürümü açık hatadır.
    @Test func clientInfoMatchesServerFormat() throws {
        let info: HostedClientInfo = try hostedClientInfo(
            shortVersion: "0.1.10", buildNumber: "19", operatingSystem: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 1)
        )
        #expect(info == HostedClientInfo(appVersion: "0.1.10 (19)", osVersion: "macOS 15.4.1"))
        #expect(throws: HostedClientError.invalidAppVersion(value: "? (?)")) {
            try hostedClientInfo(shortVersion: "?", buildNumber: "?", operatingSystem: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        }
    }
}
