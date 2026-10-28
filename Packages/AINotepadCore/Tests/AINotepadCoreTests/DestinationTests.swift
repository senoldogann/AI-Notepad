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

    // Aynı webhook başka bir Mac'te farklı kimlikle bağlı: oradan gönderilmiş işaret (cihazdan bağımsız anahtar) burada
    // ikinci gönderimi önler.
    @Test func sendKeyPreventsSecondMacSending() throws {
        let now: Date = Date(timeIntervalSince1970: 2_000_000_000)
        let here: NoteDestination = webhookDestination(id: "bu-mac", autoSend: true, createdAt: now.addingTimeInterval(-86_400), needsReconnect: false)
        let other: NoteDestination = webhookDestination(id: "diger-mac", autoSend: true, createdAt: now.addingTimeInterval(-86_400), needsReconnect: false)
        let key: String = try #require(destinationSendKey(destination: other))
        #expect(destinationSendKey(destination: here) == key && !key.contains("zapier"))
        let record: MeetingRecord = destinationRecord(id: "m", endedAt: now.addingTimeInterval(-60), sent: ["diger-mac", key])
        #expect(pendingAutoSends(records: [record], destinations: [here], now: now).isEmpty)
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

    // Discord girişinin webhook'u ayrı türde saklanır; eski sürümün `.webhook` kaydı aynen okunur. İkisinin gönderim
    // anahtarı aynıdır (eski sürümdeki Mac aynı adrese yeniden göndermez). Yapıştırılan Discord adresi kaldırılınca
    // Discord'da silinmez (ağ isteği yapılmaz).
    @Test func discordSignInWebhookIsSeparateAndLegacyDecodes() async throws {
        let url: URL = URL(string: "https://discord.com/api/webhooks/1/abc")!
        let decoder: JSONDecoder = JSONDecoder()
        let legacy: DestinationTarget = try decoder.decode(DestinationTarget.self, from: Data(#"{"webhook":{"_0":"https:\/\/discord.com\/api\/webhooks\/1\/abc"}}"#.utf8))
        #expect(legacy == .webhook(url))
        let signedIn: DestinationTarget = .discordSignIn(url)
        #expect(try decoder.decode(DestinationTarget.self, from: JSONEncoder().encode(signedIn)) == signedIn)
        let now: Date = Date(timeIntervalSince1970: 2_000_000_000)
        let pasted: NoteDestination = NoteDestination(id: "p", target: legacy, autoSend: false, createdAt: now, needsReconnect: false)
        let created: NoteDestination = NoteDestination(id: "s", target: signedIn, autoSend: false, createdAt: now, needsReconnect: false)
        #expect(destinationSendKey(destination: pasted) == destinationSendKey(destination: created))
        #expect(destinationName(destination: created) == "Discord" && destinationDetail(destination: created) == "discord.com")
        try await revokeDestination(destination: pasted)
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

    private func mcpConnection(refresh: String) -> MCPConnection {
        MCPConnection(
            serverURL: URL(string: "https://mcp.notion.com/mcp")!, clientID: "c", tokenEndpoint: URL(string: "https://mcp.notion.com/token")!,
            tokens: OAuthTokens(accessToken: "a-\(refresh)", refreshToken: refresh, expiresAt: Date().addingTimeInterval(3600))
        )
    }

    // Notion: yenilenen jeton işlem sonradan başarısız olsa da saklanır; sonra gelen ret hedefi "yeniden bağlan" yapar.
    @Test func notionRefreshSurvivesFailureAndExpiryMarksReconnect() async throws {
        try deleteSecret(service: service, account: .destinations)
        let vault: DestinationVault = DestinationVault(service: service, account: .destinations) { (connection: ChannelConnection) async throws -> ChannelConnection in connection }
        let original: MCPConnection = mcpConnection(refresh: "n1")
        try await vault.upsert(NoteDestination(id: "n", target: .notion(NotionTarget(connection: original, pageTitle: "P")), autoSend: true, createdAt: Date(), needsReconnect: false))
        await #expect(throws: MCPRemoteError.http(server: "mcp.notion.com", status: 502, body: "")) {
            try await vault.withNotion(id: "n") { (target: NotionTarget, persist: @escaping @Sendable (MCPConnection, MCPConnection) async throws -> Void) async throws -> Void in
                try await persist(target.connection, self.mcpConnection(refresh: "n2"))
                throw MCPRemoteError.http(server: "mcp.notion.com", status: 502, body: "")
            }
        }
        guard case .notion(let saved) = try await vault.all().first?.target else {
            Issue.record("hedef Notion değil")
            return
        }
        #expect(saved.connection.tokens.refreshToken == "n2")
        await #expect(throws: MCPRemoteError.expired(server: "mcp.notion.com")) {
            try await vault.withNotion(id: "n") { (_: NotionTarget, _: @escaping @Sendable (MCPConnection, MCPConnection) async throws -> Void) async throws -> Void in
                throw MCPRemoteError.expired(server: "mcp.notion.com")
            }
        }
        #expect(try await vault.all().first?.needsReconnect == true)
        try deleteSecret(service: service, account: .destinations)
    }

    // Notion: işlem sürerken kullanıcı yeniden bağlandıysa işlemin yenilemesi ve reddi yeni bağlantıya dokunmaz.
    @Test func notionReconnectDuringOperationIsKept() async throws {
        try deleteSecret(service: service, account: .destinations)
        let vault: DestinationVault = DestinationVault(service: service, account: .destinations) { (connection: ChannelConnection) async throws -> ChannelConnection in connection }
        let destination: NoteDestination = NoteDestination(
            id: "n", target: .notion(NotionTarget(connection: mcpConnection(refresh: "n1"), pageTitle: "P")), autoSend: true, createdAt: Date(), needsReconnect: false
        )
        try await vault.upsert(destination)
        let reconnected: NoteDestination = destination.with(target: .notion(NotionTarget(connection: mcpConnection(refresh: "yeni"), pageTitle: "P")))
        await #expect(throws: MCPRemoteError.expired(server: "mcp.notion.com")) {
            try await vault.withNotion(id: "n") { (target: NotionTarget, persist: @escaping @Sendable (MCPConnection, MCPConnection) async throws -> Void) async throws -> Void in
                try await vault.upsert(reconnected)
                try await persist(target.connection, self.mcpConnection(refresh: "n2"))
                throw MCPRemoteError.expired(server: "mcp.notion.com")
            }
        }
        // Tarihler ISO 8601'de saniyeye yuvarlanır: yenileme jetonu ve işaret karşılaştırılır.
        let stored: [NoteDestination] = try await vault.all()
        guard stored.count == 1, case .notion(let kept) = stored[0].target else {
            Issue.record("hedef Notion değil")
            return
        }
        #expect(kept.connection.tokens.refreshToken == "yeni" && !stored[0].needsReconnect)
        try deleteSecret(service: service, account: .destinations)
    }
}

/// Görev araçlarının deposu: yeniden bağlanınca kimlik ve hedef korunur, yenilenen jeton işlem başarısız olsa da saklanır.
@Suite(.serialized, .enabled(if: keychainTestsAvailable)) struct TrackerVaultTests {
    let service: String = "AINotepad.tests.trackers"

    private func connection(refresh: String) -> MCPConnection {
        MCPConnection(
            serverURL: URL(string: "https://mcp.linear.app/mcp")!, clientID: "c", tokenEndpoint: URL(string: "https://mcp.linear.app/token")!,
            tokens: OAuthTokens(accessToken: "a-\(refresh)", refreshToken: refresh, expiresAt: Date().addingTimeInterval(3600))
        )
    }

    @Test func reconnectKeepsIdentityAndRefreshIsStored() async throws {
        try deleteSecret(service: service, account: .taskTrackers)
        let vault: TrackerVault = TrackerVault(service: service)
        let first: TaskTracker = try await vault.connect(service: .linear, connection: connection(refresh: "r1"), newID: "id-1")
        try await vault.setTarget(id: first.id, target: "Eng")
        let second: TaskTracker = try await vault.connect(service: .linear, connection: connection(refresh: "r2"), newID: "id-2")
        #expect(second.id == "id-1" && second.target == "Eng")
        await #expect(throws: TaskTrackerError.partial(service: "Linear", created: [0], total: 2, reason: "x")) {
            try await vault.withTracker(id: "id-1") { (tracker: TaskTracker, persist: @escaping @Sendable (MCPConnection, MCPConnection) async throws -> Void) async throws -> Int in
                try await persist(tracker.connection, self.connection(refresh: "r3"))
                throw TaskTrackerError.partial(service: "Linear", created: [0], total: 2, reason: "x")
            }
        }
        #expect(try await vault.all().map(\.connection.tokens.refreshToken) == ["r3"])
        try deleteSecret(service: service, account: .taskTrackers)
    }
}

private actor RefreshCounter {
    private(set) var value: Int = 0

    func increment() {
        value += 1
    }
}
