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
        try await revokeDestination(destination: pasted, clientName: "AI-Notepad")
    }

    // Kayıt işaretleri yinelenmez.
    @Test func sentMarksAreUnique() {
        let record: MeetingRecord = destinationRecord(id: "m", endedAt: Date(), sent: ["a", "a", "b"])
        #expect(record.sentDestinationIDs == ["a", "b"])
        let task: NoteTask = NoteTask(owner: "Sen", description: "Rapor", dueDate: nil, isMine: true)
        let marked: MeetingRecord = record.markingTaskSent(trackerID: "lin", task: task).markingTaskSent(trackerID: "lin", task: task)
        #expect(marked.sentTaskKeys == ["lin": [taskKey(task: task)]])
    }

    /// Bu cihazda bağlı Notion hedefi; kimlik (çalışma alanı, kullanıcı) verilmezse eski sürümde bağlanmış gibidir.
    private func notionDestination(id: String, clientID: String, identity: NotionIdentity?, createdAt: Date) -> NoteDestination {
        let connection: MCPConnection = MCPConnection(
            serverURL: URL(string: "https://mcp.notion.com/mcp")!, clientID: clientID, tokenEndpoint: URL(string: "https://mcp.notion.com/token")!,
            tokens: OAuthTokens(accessToken: "gizli-erisim-\(clientID)", refreshToken: "gizli-yenileme-\(clientID)", expiresAt: createdAt)
        )
        return NoteDestination(id: id, target: .notion(NotionTarget(connection: connection, pageTitle: "Özel sayfalar", identity: identity)), autoSend: true, createdAt: createdAt, needsReconnect: false)
    }

    // Notion'un gönderim anahtarı hesabın çalışma alanı ve kullanıcısıdır: iki Mac'in ayrı kayıtlı (istemci kimliği,
    // jetonlar farklı) bağlantıları aynı anahtarı verir; anahtarda jeton yoktur. Kimliği okunmamış hedefin anahtarı yok.
    @Test func notionSendKeyIsAccountIdentity() throws {
        let now: Date = Date(timeIntervalSince1970: 2_000_000_000)
        let identity: NotionIdentity = NotionIdentity(workspaceID: "ws-1", userID: "user-1")
        let here: NoteDestination = notionDestination(id: "bu-mac", clientID: "c1", identity: identity, createdAt: now)
        let other: NoteDestination = notionDestination(id: "diger-mac", clientID: "c2", identity: identity, createdAt: now)
        let key: String = try #require(destinationSendKey(destination: here))
        #expect(key == "notion:ws-1:user-1" && destinationSendKey(destination: other) == key && !key.contains("gizli"))
        let otherAccount: NoteDestination = notionDestination(id: "x", clientID: "c3", identity: NotionIdentity(workspaceID: "ws-2", userID: "user-1"), createdAt: now)
        #expect(destinationSendKey(destination: otherAccount) != key)
        #expect(destinationSendKey(destination: notionDestination(id: "eski", clientID: "c4", identity: nil, createdAt: now)) == nil)
    }

    // İki Mac aynı Notion hesabına kendiliğinden gönderiyor: diğer Mac'in işareti (kendi hedef kimliği + hesap anahtarı)
    // burada ikinci gönderimi önler; farklı hesaba gönderim sürer. Eski sürümün kaydı (yalnızca hedef kimliği) da tanınır.
    @Test func notionMarkFromOtherMacPreventsSecondSend() {
        let now: Date = Date(timeIntervalSince1970: 2_000_000_000)
        let connected: Date = now.addingTimeInterval(-86_400)
        let identity: NotionIdentity = NotionIdentity(workspaceID: "ws-1", userID: "user-1")
        let here: NoteDestination = notionDestination(id: "bu-mac", clientID: "c1", identity: identity, createdAt: connected)
        let sentElsewhere: MeetingRecord = destinationRecord(id: "diger", endedAt: now.addingTimeInterval(-60), sent: ["diger-mac", "notion:ws-1:user-1"])
        let otherAccount: MeetingRecord = destinationRecord(id: "baska-hesap", endedAt: now.addingTimeInterval(-60), sent: ["diger-mac", "notion:ws-2:user-9"])
        let legacy: MeetingRecord = destinationRecord(id: "eski", endedAt: now.addingTimeInterval(-60), sent: ["bu-mac"])
        #expect(wasSent(record: sentElsewhere, destination: here) && wasSent(record: legacy, destination: here))
        #expect(!wasSent(record: otherAccount, destination: here))
        let pending: [(meetingID: String, destinationID: String)] = pendingAutoSends(records: [sentElsewhere, otherAccount, legacy], destinations: [here], now: now)
        #expect(pending.map(\.meetingID) == ["baska-hesap"])
        // Kimliği henüz okunmamış (eski sürümde bağlanan) hedef yalnızca kendi kimliğiyle denetlenir.
        let unresolved: NoteDestination = notionDestination(id: "bu-mac", clientID: "c1", identity: nil, createdAt: connected)
        #expect(!wasSent(record: sentElsewhere, destination: unresolved) && wasSent(record: legacy, destination: unresolved))
    }

    // Eski sürümün Anahtar Zinciri'ndeki Notion hedefi (kimlik alanı yok) okunur; kimlikli hedef olduğu gibi geri okunur.
    @Test func legacyNotionTargetDecodesWithoutIdentity() throws {
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacy: Data = Data(#"{"connection":{"serverURL":"https:\/\/mcp.notion.com\/mcp","clientID":"c","tokenEndpoint":"https:\/\/mcp.notion.com\/token","tokens":{"accessToken":"a","refreshToken":"r","expiresAt":"2033-05-18T03:33:20Z"}},"pageTitle":"Özel sayfalar"}"#.utf8)
        let decoded: NotionTarget = try decoder.decode(NotionTarget.self, from: legacy)
        #expect(decoded.identity == nil && decoded.connection.clientID == "c")
        let resolved: NotionTarget = decoded.with(identity: NotionIdentity(workspaceID: "w", userID: "u"))
        #expect(try decoder.decode(NotionTarget.self, from: encoder.encode(resolved)) == resolved)
        #expect(resolved.with(connection: decoded.connection).identity == resolved.identity)
    }

    // `notion-get-self` çıktısından çalışma alanı ve kullanıcı; JSON çevresinde açıklama metni olabilir.
    @Test func notionIdentityIsParsedFromGetSelf() throws {
        let json: String = #"{"workspace":{"id":"ws-1","name":"Ekip"},"user":{"type":"person","id":"user-1","name":"Ş","email":"s@example.com"}}"#
        #expect(try parseNotionIdentity(text: json) == NotionIdentity(workspaceID: "ws-1", userID: "user-1"))
        #expect(try parseNotionIdentity(text: "Connected workspace:\n\(json)\n") == NotionIdentity(workspaceID: "ws-1", userID: "user-1"))
        #expect(throws: MCPRemoteError.self) { try parseNotionIdentity(text: "Yetki yok") }
        #expect(throws: MCPRemoteError.self) { try parseNotionIdentity(text: #"{"workspace":{"id":""},"user":{"id":"u"}}"#) }
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
        let vault: DestinationVault = DestinationVault(service: service, account: .destinations, clientName: "AI-Notepad") { (connection: ChannelConnection) async throws -> ChannelConnection in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(200))
            return connection.with(tokens: OAuthTokens(accessToken: "yeni", refreshToken: "r2", expiresAt: Date().addingTimeInterval(3600)))
        }
        try await vault.upsert(accountDestination(id: "d", refresh: "r1", expiresAt: Date().addingTimeInterval(-10)))
        async let first: ChannelConnection = vault.connection(id: "d")
        async let second: ChannelConnection = vault.connection(id: "d")
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
        // Yenileme başlayınca haber verir: kaldırma sabit bir beklemeyle değil, yenileme gerçekten sürerken yapılır
        // (yüklü makinede 50 ms yetmeyebiliyordu).
        let (started, startedSignal): (AsyncStream<Void>, AsyncStream<Void>.Continuation) = AsyncStream<Void>.makeStream()
        let vault: DestinationVault = DestinationVault(service: service, account: .destinations, clientName: "AI-Notepad") { (connection: ChannelConnection) async throws -> ChannelConnection in
            startedSignal.yield()
            try await Task.sleep(for: .milliseconds(300))
            return connection.with(tokens: OAuthTokens(accessToken: "yeni", refreshToken: "r2", expiresAt: Date().addingTimeInterval(3600)))
        }
        try await vault.upsert(accountDestination(id: "d", refresh: "r1", expiresAt: Date().addingTimeInterval(-10)))
        let refresh: Task<ChannelConnection, any Error> = Task { try await vault.connection(id: "d") }
        var signals: AsyncStream<Void>.Iterator = started.makeAsyncIterator()
        await signals.next()
        _ = try await vault.remove(id: "d")
        _ = await refresh.result
        #expect(try await vault.all().isEmpty)
        try deleteSecret(service: service, account: .destinations)
    }

    @Test func expiredSessionMarksReconnect() async throws {
        try deleteSecret(service: service, account: .destinations)
        let vault: DestinationVault = DestinationVault(service: service, account: .destinations, clientName: "AI-Notepad") { (_: ChannelConnection) async throws -> ChannelConnection in
            throw ChannelAuthError.expired(service: .slack)
        }
        try await vault.upsert(accountDestination(id: "d", refresh: "r1", expiresAt: Date().addingTimeInterval(-10)))
        await #expect(throws: ChannelAuthError.expired(service: .slack)) {
            try await vault.connection(id: "d")
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
        let vault: DestinationVault = DestinationVault(service: service, account: .destinations, clientName: "AI-Notepad") { (connection: ChannelConnection) async throws -> ChannelConnection in connection }
        let original: MCPConnection = mcpConnection(refresh: "n1")
        try await vault.upsert(NoteDestination(id: "n", target: .notion(NotionTarget(connection: original, pageTitle: "P", identity: nil)), autoSend: true, createdAt: Date(), needsReconnect: false))
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
        let vault: DestinationVault = DestinationVault(service: service, account: .destinations, clientName: "AI-Notepad") { (connection: ChannelConnection) async throws -> ChannelConnection in connection }
        let destination: NoteDestination = NoteDestination(
            id: "n", target: .notion(NotionTarget(connection: mcpConnection(refresh: "n1"), pageTitle: "P", identity: nil)), autoSend: true, createdAt: Date(), needsReconnect: false
        )
        try await vault.upsert(destination)
        let reconnected: NoteDestination = destination.with(target: .notion(NotionTarget(connection: mcpConnection(refresh: "yeni"), pageTitle: "P", identity: nil)))
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
            serverURL: URL(string: "https://mcp.linear.app/mcp")!, clientID: "c-\(refresh)", tokenEndpoint: URL(string: "https://mcp.linear.app/token")!,
            tokens: OAuthTokens(accessToken: "a-\(refresh)", refreshToken: refresh, expiresAt: Date().addingTimeInterval(3600))
        )
    }

    // Yeniden bağlanınca araç kimliği ve hedef korunur, hesap kimliği boşalır (yeniden okunur); yerini alan eski izin
    // (başka istemci kaydı) geri alınmak üzere döner.
    @Test func reconnectKeepsIdentityAndRefreshIsStored() async throws {
        try deleteSecret(service: service, account: .taskTrackers)
        let vault: TrackerVault = TrackerVault(service: service, clientName: "AI-Notepad")
        let first: TrackerConnectResult = try await vault.connect(service: .linear, connection: connection(refresh: "r1"), newID: "id-1")
        #expect(first.replaced == nil)
        try await vault.setTarget(id: first.tracker.id, target: "Eng")
        let second: TrackerConnectResult = try await vault.connect(service: .linear, connection: connection(refresh: "r2"), newID: "id-2")
        #expect(second.tracker.id == "id-1" && second.tracker.target == "Eng" && second.tracker.identity == nil)
        #expect(second.replaced?.clientID == "c-r1" && second.replaced?.tokens.refreshToken == "r1")
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

/// Görev araçlarının cihazlar arası gönderim anahtarı, işaretleri ve yerini alan iznin seçimi (saf fonksiyonlar).
@Suite struct TrackerSendKeyTests {
    private let rapor: NoteTask = NoteTask(owner: "Sen", description: "Raporu yaz", dueDate: nil, isMine: true)
    private let butce: NoteTask = NoteTask(owner: "Aino", description: "Bütçeyi gönder", dueDate: nil, isMine: false)

    private func connection(clientID: String) -> MCPConnection {
        MCPConnection(
            serverURL: URL(string: "https://mcp.linear.app/mcp")!, clientID: clientID, tokenEndpoint: URL(string: "https://mcp.linear.app/token")!,
            tokens: OAuthTokens(accessToken: "gizli-erisim-\(clientID)", refreshToken: "gizli-yenileme-\(clientID)", expiresAt: Date(timeIntervalSince1970: 0))
        )
    }

    private func tracker(id: String, service: MCPService, target: String, accountID: String?) -> TaskTracker {
        TaskTracker(id: id, service: service, connection: connection(clientID: id), target: target, identity: accountID.map { TrackerIdentity(accountID: $0) })
    }

    private func meeting() -> MeetingRecord {
        MeetingRecord(
            id: "m", title: "T", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, language: nil, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
            note: MeetingNote(title: "Not", summary: "Özet", decisions: [], tasks: [rapor, butce], glossary: []), audioDeleted: false, engine: .cloud,
            notice: nil, meNeedsFinalPass: nil
        )
    }

    // Anahtar servis, hesap ve hedeften çıkar (hedefte büyük/küçük harf ve boşluk fark etmez); jeton içermez. Hesap
    // kimliği okunmamış araç ya da görev aracı olmayan servis anahtar vermez.
    @Test func sendKeyIsServiceAccountAndTarget() throws {
        let linear: TaskTracker = tracker(id: "bu-mac", service: .linear, target: "  Mobil   Ekip ", accountID: "user-1")
        let key: String = try #require(trackerSendKey(tracker: linear))
        #expect(key == "linear:user-1:mobil ekip" && !key.contains("gizli"))
        #expect(trackerSendKey(tracker: tracker(id: "diger-mac", service: .linear, target: "mobil ekip", accountID: "user-1")) == key)
        #expect(trackerSendKey(tracker: tracker(id: "j", service: .atlassian, target: "OPS", accountID: "acc-1")) == "jira:acc-1:ops")
        #expect(trackerSendKey(tracker: tracker(id: "x", service: .linear, target: "Web", accountID: "user-1")) != key)
        #expect(trackerSendKey(tracker: tracker(id: "eski", service: .linear, target: "", accountID: nil)) == nil)
        #expect(trackerSendKey(tracker: tracker(id: "n", service: .notion, target: "", accountID: "user-1")) == nil)
        #expect(trackerMarkKeys(tracker: linear) == ["bu-mac", key])
        #expect(trackerMarkKeys(tracker: tracker(id: "eski", service: .linear, target: "", accountID: nil)) == ["eski"])
    }

    // Bir Mac'te açılan görev iki anahtarla işaretlenir: aynı hesap ve hedefle bağlı diğer Mac'in aracı (farklı cihaz
    // kimliği) onu gönderilmiş görür; başka hedefe bağlı araç görmez. Eski kayıt (yalnızca cihaz kimliği) de tanınır.
    @Test func marksAreSeenFromOtherMacAndLegacyRecordsAreUnderstood() {
        let here: TaskTracker = tracker(id: "bu-mac", service: .linear, target: "Eng", accountID: "user-1")
        let other: TaskTracker = tracker(id: "diger-mac", service: .linear, target: "eng", accountID: "user-1")
        let otherTeam: TaskTracker = tracker(id: "diger-mac", service: .linear, target: "Web", accountID: "user-1")
        let marked: MeetingRecord = markingTasksSent(record: meeting(), tracker: here, tasks: [rapor])
        #expect(Set(marked.sentTaskKeys?.keys.map { $0 } ?? []) == ["bu-mac", "linear:user-1:eng"])
        #expect(isTaskSent(record: marked, tracker: here, task: rapor) && isTaskSent(record: marked, tracker: other, task: rapor))
        #expect(!isTaskSent(record: marked, tracker: other, task: butce) && !isTaskSent(record: marked, tracker: otherTeam, task: rapor))
        let legacy: MeetingRecord = meeting().markingTaskSent(trackerID: "bu-mac", task: butce)
        #expect(isTaskSent(record: legacy, tracker: here, task: butce))
        let unresolved: TaskTracker = tracker(id: "bu-mac", service: .linear, target: "Eng", accountID: nil)
        #expect(isTaskSent(record: legacy, tracker: unresolved, task: butce) && !isTaskSent(record: marked, tracker: tracker(id: "u", service: .linear, target: "Eng", accountID: nil), task: rapor))
        // İşaretler tekrarlanınca yinelenmez.
        #expect(markingTasksSent(record: marked, tracker: here, tasks: [rapor]) == marked)
    }

    // Eski sürümün Anahtar Zinciri'ndeki aracı (kimlik alanı yok) okunur; jeton yenilenince hesap kimliği korunur.
    @Test func legacyTrackerDecodesWithoutIdentity() throws {
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy: Data = Data(#"{"id":"t","service":"linear","target":"Eng","connection":{"serverURL":"https:\/\/mcp.linear.app\/mcp","clientID":"c","tokenEndpoint":"https:\/\/mcp.linear.app\/token","tokens":{"accessToken":"a","refreshToken":"r","expiresAt":"2033-05-18T03:33:20Z"}}}"#.utf8)
        let decoded: TaskTracker = try decoder.decode(TaskTracker.self, from: legacy)
        #expect(decoded.identity == nil && decoded.target == "Eng")
        let resolved: TaskTracker = decoded.with(identity: TrackerIdentity(accountID: "user-1"))
        #expect(resolved.with(connection: connection(clientID: "c")).identity == resolved.identity)
        #expect(resolved.with(target: "Web").identity == resolved.identity)
    }

    // Hesap kimliği aracın çıktısından: Jira `account_id`, Linear `id`; alt nesnede de bulunur; kimliksiz çıktı hatadır.
    @Test func accountIdentityIsParsed() throws {
        #expect(trackerIdentityLookup(service: .linear)?.tool == "get_user" && trackerIdentityLookup(service: .atlassian)?.tool == "atlassianUserInfo")
        #expect(trackerIdentityLookup(service: .notion) == nil)
        let jira: String = #"{"account_id":"acc-1","email":"s@example.com","name":"Ş"}"#
        #expect(try parseTrackerIdentity(text: jira, server: "s") == TrackerIdentity(accountID: "acc-1"))
        #expect(try parseTrackerIdentity(text: "Kullanıcı:\n{\"user\":{\"id\":\"user-1\",\"name\":\"Ş\"}}", server: "s") == TrackerIdentity(accountID: "user-1"))
        #expect(throws: MCPRemoteError.self) { try parseTrackerIdentity(text: "bulunamadı", server: "s") }
        #expect(throws: MCPRemoteError.self) { try parseTrackerIdentity(text: #"{"name":"Ş"}"#, server: "s") }
    }

    // Yeniden bağlanınca eski izin yalnızca başka istemci kaydıysa geri alınır (aynı kayıt aynı izindir).
    @Test func replacedGrantIsOnlyADifferentRegistration() {
        let old: MCPConnection = connection(clientID: "eski")
        #expect(replacedGrant(old: old, new: connection(clientID: "yeni")) == old)
        #expect(replacedGrant(old: old, new: connection(clientID: "eski")) == nil)
    }
}

private actor RefreshCounter {
    private(set) var value: Int = 0

    func increment() {
        value += 1
    }
}
