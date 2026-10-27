import CryptoKit
import Foundation
import os

/// Notun gittiği yer: hesapla kurulan kanal (Slack, Teams), webhook adresi (Discord, Zoom, Slack/Teams iş akışı,
/// Zapier, Make, n8n) ya da Notion sayfası.
public enum DestinationTarget: Sendable, Equatable, Codable {
    case account(ChannelConnection)
    case webhook(URL)
    case notion(NotionTarget)
}

/// Bağlı bir not hedefi. Birden çok hedef aynı anda bağlı olabilir (ör. ekip için Slack, CRM için Zapier); her birinin
/// kendiliğinden gönderimi ayrıdır.
public struct NoteDestination: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let target: DestinationTarget
    /// Not hazır olunca kendiliğinden gönderilir.
    public let autoSend: Bool
    /// Bağlandığı an: kendiliğinden gönderim yalnızca bundan sonra biten toplantılar için yapılır (yeni bağlanan hedefe
    /// eski toplantılar yığılmasın).
    public let createdAt: Date
    /// Oturum bitti (yenileme reddedildi): kullanıcı yeniden bağlanana dek kendiliğinden gönderilmez.
    public let needsReconnect: Bool

    public init(id: String, target: DestinationTarget, autoSend: Bool, createdAt: Date, needsReconnect: Bool) {
        self.id = id
        self.target = target
        self.autoSend = autoSend
        self.createdAt = createdAt
        self.needsReconnect = needsReconnect
    }

    public func with(target newTarget: DestinationTarget) -> NoteDestination {
        NoteDestination(id: id, target: newTarget, autoSend: autoSend, createdAt: createdAt, needsReconnect: needsReconnect)
    }

    public func with(autoSend newAutoSend: Bool) -> NoteDestination {
        NoteDestination(id: id, target: target, autoSend: newAutoSend, createdAt: createdAt, needsReconnect: needsReconnect)
    }

    public func with(needsReconnect newValue: Bool) -> NoteDestination {
        NoteDestination(id: id, target: target, autoSend: autoSend, createdAt: createdAt, needsReconnect: newValue)
    }
}

/// Hedefin arayüzdeki adı. Saf fonksiyondur.
public func destinationName(destination: NoteDestination) -> String {
    switch destination.target {
    case .account(let connection): connection.service.displayName
    case .webhook(let url):
        switch webhookKind(url: url) {
        case .slack: "Slack"
        case .discord: "Discord"
        case .teams: "Microsoft Teams"
        case .zoom: "Zoom Team Chat"
        case .generic: url.host() ?? "Webhook"
        }
    case .notion: "Notion"
    }
}

/// Hedefin ayrıntısı: kanal ve çalışma alanı, webhook sunucusu ya da Notion sayfası (gizli kısım gösterilmez). Saf
/// fonksiyondur.
public func destinationDetail(destination: NoteDestination) -> String {
    switch destination.target {
    case .account(let connection): [connection.channel.name, connection.workspace].filter { !$0.isEmpty }.joined(separator: " · ")
    case .webhook(let url): url.host() ?? ""
    case .notion(let target): target.pageTitle
    }
}

/// Kendiliğinden gönderim için geriye bakılan en uzun süre: çevrimdışıyken kaçan gönderimler bu süre içinde telafi
/// edilir, daha eskisi gönderilmez.
public let autoSendLookbackSec: TimeInterval = 7 * 24 * 3600

/// Gönderilmesi gereken (toplantı, hedef) çiftleri: hedefin kendiliğinden gönderimi açık ve oturumu geçerli, toplantı
/// bitmiş ve notu var, hedef bağlandıktan sonra ve son 7 günde bitmiş, o hedefe daha önce gönderilmemiş. Kaçan
/// gönderimler (ağ yoktu, uygulama kapandı) böylece açılışta ve saatte bir telafi edilir. Saf fonksiyondur.
public func pendingAutoSends(records: [MeetingRecord], destinations: [NoteDestination], now: Date) -> [(meetingID: String, destinationID: String)] {
    let active: [NoteDestination] = destinations.filter { $0.autoSend && !$0.needsReconnect }
    return records
        .filter { $0.status == .done && $0.note != nil }
        .flatMap { (record: MeetingRecord) -> [(meetingID: String, destinationID: String)] in
            let finished: Date = record.endedAt ?? record.startedAt
            guard now.timeIntervalSince(finished) <= autoSendLookbackSec else {
                return []
            }
            let sent: [String] = record.sentDestinationIDs ?? []
            return active
                .filter { (destination: NoteDestination) -> Bool in
                    let key: String? = destinationSendKey(destination: destination)
                    return finished >= destination.createdAt && !sent.contains(destination.id) && !(key.map { sent.contains($0) } ?? false)
                }
                .map { (meetingID: record.id, destinationID: $0.id) }
        }
}

/// Hedefin cihazdan bağımsız kimliği: aynı kanal ya da webhook başka bir Mac'te de bağlıysa (hedef kimlikleri cihaza
/// özeldir) gönderildi işareti iCloud'la oraya da ulaşır, not iki kez gitmez. Notion bağlantısı cihaza özel kayıtla
/// kurulduğu için kimliği yoktur (nil). Webhook adresi gizli olduğu için yalnızca özeti kullanılır. Saf fonksiyondur.
public func destinationSendKey(destination: NoteDestination) -> String? {
    switch destination.target {
    case .account(let connection):
        return "\(connection.service.rawValue):\(connection.channel.teamID ?? connection.workspace):\(connection.channel.id)"
    case .webhook(let url):
        let digest: SHA256.Digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return "webhook:" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    case .notion:
        return nil
    }
}

/// Eski sürümün tek bağlantısından (hesap ya da webhook adresi) hedef listesi. Taşınan hedef `createdAt` olarak şimdiyi
/// alır: eski toplantılar yeniden gönderilmez. Saf fonksiyondur.
public func migratedDestinations(connection: ChannelConnection?, webhook: URL?, autoSend: Bool, now: Date, newID: () -> String) -> [NoteDestination] {
    let targets: [DestinationTarget] = [connection.map { DestinationTarget.account($0) }, webhook.map { DestinationTarget.webhook($0) }].compactMap { $0 }
    return targets.map { NoteDestination(id: newID(), target: $0, autoSend: autoSend, createdAt: now, needsReconnect: false) }
}

/// Hedef listesi hataları.
public enum DestinationError: Error, Equatable {
    /// Hedef bulunamadı (bu arada kaldırıldı).
    case notFound(id: String)
    /// Hedef hesap bağlantısı değil (kanal listesi yalnızca Slack ve Teams'te).
    case notAnAccount(id: String)
}

private let destinationLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Destinations")

/// Hedeflerin Anahtar Zinciri'ndeki deposu (jetonlar içerdiği için) ve hesap jetonlarının yenilenmesi. Aynı hedefin
/// yenilemesi tek seferde yapılır: aynı anda gelen gönderimler aynı yenilemeyi bekler (Slack yenileme jetonu tek
/// kullanımlık). Yenileme sürerken hedef kaldırılır ya da yeniden bağlanırsa yeni jetonlar yazılmaz.
public actor DestinationVault {
    private let service: String
    private let account: SecretAccount
    private let refresher: @Sendable (ChannelConnection) async throws -> ChannelConnection
    private var refreshes: [String: Task<ChannelConnection, any Error>] = [:]
    /// Notion hedefinde sıradaki işlem (bir öncekinin bitmesini bekler).
    private let notionQueue: KeyedSerialQueue = KeyedSerialQueue()
    /// Süren Notion işleminin bu hedefe yazdığı son yenileme jetonu: oturum reddedilirse hedefin hâlâ bu işlemin
    /// bağlantısı olduğu (kullanıcı bu arada yeniden bağlanmadığı) böyle anlaşılır.
    private var notionWritten: [String: String] = [:]

    /// `refresher`: uygulamada `refreshConnectionTokens`; testte sayaçlı yenileyici.
    public init(service: String, account: SecretAccount, refresher: @escaping @Sendable (ChannelConnection) async throws -> ChannelConnection) {
        self.service = service
        self.account = account
        self.refresher = refresher
    }

    /// Kayıtlı hedefler (yoksa boş).
    public func all() throws -> [NoteDestination] {
        let text: String
        do {
            text = try readSecret(service: service, account: account)
        } catch KeychainError.notFound {
            return []
        }
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([NoteDestination].self, from: Data(text.utf8))
        } catch {
            throw StorageError.readFailed(path: "\(service)/\(account.rawValue)", reason: error.localizedDescription)
        }
    }

    private func store(_ destinations: [NoteDestination]) throws {
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let data: Data = try encoder.encode(destinations)
        try saveSecret(service: service, account: account, value: String(decoding: data, as: UTF8.self))
    }

    /// Hedefi ekler (aynı kimlik varsa yerini alır).
    public func upsert(_ destination: NoteDestination) throws {
        let current: [NoteDestination] = try all()
        let updated: [NoteDestination] = current.contains(where: { $0.id == destination.id })
            ? current.map { $0.id == destination.id ? destination : $0 }
            : current + [destination]
        try store(updated)
    }

    /// Hedefi kaldırır; kaldırılan hedef (servis tarafında kapatmak için) döner.
    public func remove(id: String) throws -> NoteDestination {
        let current: [NoteDestination] = try all()
        guard let removed = current.first(where: { $0.id == id }) else {
            throw DestinationError.notFound(id: id)
        }
        refreshes[id]?.cancel()
        refreshes[id] = nil
        try store(current.filter { $0.id != id })
        return removed
    }

    /// Hesap hedefinin geçerli bağlantısı: jeton bitmek üzereyse (ya da `force`) yenilenir ve yazılır. Aynı hedefin
    /// süren yenilemesi varsa onu bekler. Oturum reddedilirse hedef "yeniden bağlan" olarak işaretlenir.
    public func connection(id: String, force: Bool) async throws -> ChannelConnection {
        if let running = refreshes[id] {
            return try await running.value
        }
        guard let destination = try all().first(where: { $0.id == id }) else {
            throw DestinationError.notFound(id: id)
        }
        guard case .account(let connection) = destination.target else {
            throw DestinationError.notAnAccount(id: id)
        }
        guard force || needsRefresh(tokens: connection.tokens, now: Date()) else {
            return connection
        }
        let refresher: @Sendable (ChannelConnection) async throws -> ChannelConnection = self.refresher
        let task: Task<ChannelConnection, any Error> = Task { try await refresher(connection) }
        refreshes[id] = task
        defer {
            // Bu arada hedef kaldırılıp aynı kimlikle yeni bir yenileme başladıysa o silinmez.
            if refreshes[id] == task {
                refreshes[id] = nil
            }
        }
        let fresh: ChannelConnection
        do {
            fresh = try await task.value
        } catch let error as ChannelAuthError {
            if case .expired = error {
                try markReconnect(id: id, refreshToken: connection.tokens.refreshToken)
            }
            throw error
        }
        // Yenileme sürerken hedef kaldırıldı ya da yeniden bağlandıysa eski bağlantının jetonları yazılmaz.
        guard let stored = try all().first(where: { $0.id == id }), case .account(let current) = stored.target,
              current.tokens.refreshToken == connection.tokens.refreshToken else {
            destinationLogger.info("Yenileme sürerken hedef değişti, jetonlar yazılmadı, hedef: \(id, privacy: .public)")
            return fresh
        }
        try upsert(stored.with(target: .account(fresh)).with(needsReconnect: false))
        return fresh
    }

    /// Oturum reddedildi: hedef hâlâ aynı bağlantıysa "yeniden bağlan" olarak işaretlenir.
    private func markReconnect(id: String, refreshToken: String) throws {
        guard let stored = try all().first(where: { $0.id == id }), case .account(let current) = stored.target,
              current.tokens.refreshToken == refreshToken else {
            return
        }
        try upsert(stored.with(needsReconnect: true))
    }

    /// MCP hedefinde (Notion) işlemler sırayla yapılır: aynı hedefe iki gönderim aynı anda jeton yenilemesin. İşlem
    /// jetonu yenilerse verilen `persist` ile hemen saklanır (sonraki adım başarısız olsa bile). Oturum reddedilirse ve
    /// hedef hâlâ bu işlemin bağlantısıysa "yeniden bağlan" olarak işaretlenir; başarıda işaret kalkar.
    public func withNotion(id: String, operation: @escaping @Sendable (NotionTarget, @escaping @Sendable (MCPConnection, MCPConnection) async throws -> Void) async throws -> Void) async throws {
        try await notionQueue.run(key: id) {
            try await self.runNotion(id: id, operation: operation)
        }
    }

    private func runNotion(id: String, operation: @escaping @Sendable (NotionTarget, @escaping @Sendable (MCPConnection, MCPConnection) async throws -> Void) async throws -> Void) async throws {
        guard let stored = try all().first(where: { $0.id == id }), case .notion(let target) = stored.target else {
            throw DestinationError.notFound(id: id)
        }
        let original: String = target.connection.tokens.refreshToken
        notionWritten[id] = original
        defer { notionWritten[id] = nil }
        do {
            try await operation(target) { (previous: MCPConnection, fresh: MCPConnection) async throws -> Void in
                try await self.storeRefreshedNotion(id: id, previous: previous, fresh: fresh)
            }
        } catch MCPRemoteError.expired(let server) {
            try markNotionReconnect(id: id)
            throw MCPRemoteError.expired(server: server)
        }
        try clearReconnect(id: id)
    }

    private func storeRefreshedNotion(id: String, previous: MCPConnection, fresh: MCPConnection) throws {
        guard let stored = try all().first(where: { $0.id == id }), case .notion(let current) = stored.target,
              current.connection.tokens.refreshToken == previous.tokens.refreshToken else {
            destinationLogger.info("Notion yenilemesi sürerken hedef değişti, jetonlar yazılmadı, hedef: \(id, privacy: .public)")
            return
        }
        try upsert(stored.with(target: .notion(current.with(connection: fresh))))
        notionWritten[id] = fresh.tokens.refreshToken
    }

    private func markNotionReconnect(id: String) throws {
        guard let stored = try all().first(where: { $0.id == id }), case .notion(let current) = stored.target,
              current.connection.tokens.refreshToken == notionWritten[id] else {
            return
        }
        try upsert(stored.with(needsReconnect: true))
    }

    /// Gönderim başarılı: "yeniden bağlan" işareti kalkar.
    public func clearReconnect(id: String) throws {
        guard let stored = try all().first(where: { $0.id == id }), stored.needsReconnect else {
            return
        }
        try upsert(stored.with(needsReconnect: false))
    }
}

/// Notu hedefe gönderir. Hesap bağlantısında erişim jetonu süresinden önce geri alındıysa (401) bir kez zorla yenilenip
/// yeniden denenir; ikinci ret hedefi "yeniden bağlan" yapar.
public func deliverNote(vault: DestinationVault, destination: NoteDestination, record: MeetingRecord, note: MeetingNote) async throws {
    switch destination.target {
    case .account:
        let connection: ChannelConnection = try await vault.connection(id: destination.id, force: false)
        do {
            try await postNote(connection: connection, record: record, note: note)
        } catch ChannelAuthError.expired {
            let fresh: ChannelConnection = try await vault.connection(id: destination.id, force: true)
            try await postNote(connection: fresh, record: record, note: note)
        }
        try await vault.clearReconnect(id: destination.id)
    case .webhook(let url):
        try await sendWebhook(url: url, payload: try webhookPayload(kind: webhookKind(url: url), record: record, note: note))
    case .notion:
        try await vault.withNotion(id: destination.id) {
            (target: NotionTarget, persist: @escaping @Sendable (MCPConnection, MCPConnection) async throws -> Void) async throws -> Void in
            try await createNotionPage(connection: target.connection, persist: persist, record: record, note: note)
        }
    }
}

/// Kaldırılan hedefi servis tarafında da kapatır: Slack jetonu geri alınır, Discord'da girişle oluşturulan webhook
/// silinir. Webhook adresleri ve Notion'da yapılacak bir şey yok (Notion erişimi kullanıcının çalışma alanında
/// kaldırılır).
public func revokeDestination(destination: NoteDestination) async throws {
    switch destination.target {
    case .account(let connection):
        try await revokeChannelConnection(connection: connection)
    case .webhook(let url):
        if webhookKind(url: url) == .discord {
            try await deleteDiscordWebhook(url: url)
        }
    case .notion:
        return
    }
}
