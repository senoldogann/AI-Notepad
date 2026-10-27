import Foundation
import Testing
@testable import AINotepadCore

private func destinationRecord(id: String, endedAt: Date, sent: [String]) -> MeetingRecord {
    let base: MeetingRecord = MeetingRecord(
        id: id, title: "T", startedAt: endedAt.addingTimeInterval(-600), endedAt: endedAt, language: nil, status: .done, failureMessage: nil,
        liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
        note: MeetingNote(title: "Not", summary: "Özet", decisions: [], tasks: [], glossary: []), audioDeleted: false, engine: .cloud,
        notice: nil, meNeedsFinalPass: nil
    )
    return sent.reduce(base) { (record: MeetingRecord, destinationID: String) -> MeetingRecord in record.markingSent(destinationID: destinationID) }
}

private func webhookDestination(id: String, autoSend: Bool, createdAt: Date, needsReconnect: Bool) -> NoteDestination {
    NoteDestination(id: id, target: .webhook(URL(string: "https://hooks.zapier.com/x")!), autoSend: autoSend, createdAt: createdAt, needsReconnect: needsReconnect)
}

@Suite struct NoteDestinationTests {
    // Kendiliğinden gönderim: hedef bağlandıktan sonra ve son 7 günde biten, o hedefe gönderilmemiş toplantılar; kapalı
    // ya da yeniden bağlanması gereken hedefe gönderilmez.
    @Test func pendingAutoSendsRespectDestinationState() {
        let now: Date = Date(timeIntervalSince1970: 2_000_000_000)
        let connected: Date = now.addingTimeInterval(-3 * 24 * 3600)
        let destinations: [NoteDestination] = [
            webhookDestination(id: "a", autoSend: true, createdAt: connected, needsReconnect: false),
            webhookDestination(id: "b", autoSend: false, createdAt: connected, needsReconnect: false),
            webhookDestination(id: "c", autoSend: true, createdAt: connected, needsReconnect: true),
        ]
        let records: [MeetingRecord] = [
            destinationRecord(id: "yeni", endedAt: now.addingTimeInterval(-3600), sent: []),
            destinationRecord(id: "gonderildi", endedAt: now.addingTimeInterval(-3600), sent: ["a"]),
            destinationRecord(id: "baglanmadan-once", endedAt: connected.addingTimeInterval(-60), sent: []),
            destinationRecord(id: "cok-eski", endedAt: now.addingTimeInterval(-8 * 24 * 3600), sent: []),
        ]
        let pending: [(meetingID: String, destinationID: String)] = pendingAutoSends(records: records, destinations: destinations, now: now)
        #expect(pending.map { "\($0.meetingID)>\($0.destinationID)" } == ["yeni>a"])
    }

    // Eski tek bağlantı (hesap + webhook) iki hedefe taşınır; taşıma anı bağlanma anıdır (eskiler yeniden gönderilmez).
    @Test func legacyConnectionMigrates() {
        let now: Date = Date(timeIntervalSince1970: 2_000_000_000)
        let connection: ChannelConnection = ChannelConnection(
            service: .slack, tokens: OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: now), workspace: "W",
            channel: ChannelOption(id: "C1", teamID: nil, name: "#genel")
        )
        var counter: Int = 0
        let migrated: [NoteDestination] = migratedDestinations(connection: connection, webhook: URL(string: "https://hooks.zapier.com/x"), autoSend: true, now: now) {
            counter += 1
            return "id\(counter)"
        }
        #expect(migrated.map(\.id) == ["id1", "id2"])
        #expect(migrated.allSatisfy { $0.autoSend && $0.createdAt == now })
        #expect(destinationName(destination: migrated[0]) == "Slack" && destinationDetail(destination: migrated[0]) == "#genel · W")
        #expect(migratedDestinations(connection: nil, webhook: nil, autoSend: true, now: now) { "x" }.isEmpty)
    }

    // Kayıt işaretleri yinelenmez.
    @Test func sentMarksAreUnique() {
        let record: MeetingRecord = destinationRecord(id: "m", endedAt: Date(), sent: ["a", "a", "b"])
        #expect(record.sentDestinationIDs == ["a", "b"])
        let task: NoteTask = NoteTask(owner: "Sen", description: "Rapor", dueDate: nil, isMine: true)
        let marked: MeetingRecord = record.markingTaskSent(trackerID: "lin", task: task).markingTaskSent(trackerID: "lin", task: task)
        #expect(marked.sentTaskKeys == ["lin": [taskKey(task: task)]])
    }
}

/// Anahtar Zinciri'nde ayrı test servisinde: aynı hedefe aynı anda gelen gönderimler jetonu bir kez yeniler; yenileme
/// sürerken hedef kaldırılırsa eski jetonlar geri yazılmaz.
@Suite(.serialized, .enabled(if: keychainTestsAvailable)) struct DestinationVaultTests {
    let service: String = "AINotepad.tests.destinations"

    private func accountDestination(id: String, refresh: String, expiresAt: Date) -> NoteDestination {
        NoteDestination(
            id: id,
            target: .account(ChannelConnection(
                service: .slack, tokens: OAuthTokens(accessToken: "eski", refreshToken: refresh, expiresAt: expiresAt), workspace: "W",
                channel: ChannelOption(id: "C1", teamID: nil, name: "#genel")
            )),
            autoSend: true, createdAt: Date(), needsReconnect: false
        )
    }

    @Test func concurrentSendsRefreshOnce() async throws {
        try deleteSecret(service: service, account: .destinations)
        let counter: RefreshCounter = RefreshCounter()
        let vault: DestinationVault = DestinationVault(service: service, account: .destinations) { (connection: ChannelConnection) async throws -> ChannelConnection in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(200))
            return connection.with(tokens: OAuthTokens(accessToken: "yeni", refreshToken: "r2", expiresAt: Date().addingTimeInterval(3600)))
        }
        try await vault.upsert(accountDestination(id: "d", refresh: "r1", expiresAt: Date().addingTimeInterval(-10)))
        async let first: ChannelConnection = vault.connection(id: "d", force: false)
        async let second: ChannelConnection = vault.connection(id: "d", force: false)
        let results: [ChannelConnection] = try await [first, second]
        #expect(await counter.value == 1)
        #expect(results.allSatisfy { $0.tokens.accessToken == "yeni" })
        let stored: [NoteDestination] = try await vault.all()
        guard case .account(let saved) = stored.first?.target else {
            Issue.record("hedef hesap değil")
            return
        }
        #expect(saved.tokens.refreshToken == "r2")
        try deleteSecret(service: service, account: .destinations)
    }

    @Test func removedDuringRefreshStaysRemoved() async throws {
        try deleteSecret(service: service, account: .destinations)
        let vault: DestinationVault = DestinationVault(service: service, account: .destinations) { (connection: ChannelConnection) async throws -> ChannelConnection in
            try await Task.sleep(for: .milliseconds(300))
            return connection.with(tokens: OAuthTokens(accessToken: "yeni", refreshToken: "r2", expiresAt: Date().addingTimeInterval(3600)))
        }
        try await vault.upsert(accountDestination(id: "d", refresh: "r1", expiresAt: Date().addingTimeInterval(-10)))
        let refresh: Task<ChannelConnection, any Error> = Task { try await vault.connection(id: "d", force: false) }
        try await Task.sleep(for: .milliseconds(50))
        _ = try await vault.remove(id: "d")
        _ = await refresh.result
        #expect(try await vault.all().isEmpty)
        try deleteSecret(service: service, account: .destinations)
    }

    @Test func expiredSessionMarksReconnect() async throws {
        try deleteSecret(service: service, account: .destinations)
        let vault: DestinationVault = DestinationVault(service: service, account: .destinations) { (_: ChannelConnection) async throws -> ChannelConnection in
            throw ChannelAuthError.expired(service: .slack)
        }
        try await vault.upsert(accountDestination(id: "d", refresh: "r1", expiresAt: Date().addingTimeInterval(-10)))
        await #expect(throws: ChannelAuthError.expired(service: .slack)) {
            try await vault.connection(id: "d", force: false)
        }
        #expect(try await vault.all().first?.needsReconnect == true)
        try deleteSecret(service: service, account: .destinations)
    }
}

private actor RefreshCounter {
    private(set) var value: Int = 0

    func increment() {
        value += 1
    }
}
