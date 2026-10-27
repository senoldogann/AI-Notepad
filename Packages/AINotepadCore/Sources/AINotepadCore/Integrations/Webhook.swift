import Foundation
import os

/// Webhook'un gittiği servis: biçim servise göre seçilir (Slack metin, Discord içerik, Teams Adaptive Card; diğerleri
/// — Zapier, Make, n8n… — metin ve yapılandırılmış toplantı).
public enum WebhookKind: Sendable, Equatable {
    case slack
    case discord
    case teams
    /// Zoom Team Chat "Incoming Webhook" uygulaması: adres + doğrulama anahtarı (adresin `#` sonrası parçasında saklanır,
    /// istekte `authorization` başlığı olarak gider; parça sunucuya gönderilmez).
    case zoom
    case generic
}

/// Webhook gönderilemedi. Adres gizli anahtar içerdiği için hatada yalnızca sunucu adı yer alır.
public enum WebhookError: Error, Equatable {
    case invalidURL
    case http(host: String, status: Int, body: String)
    case network(host: String, reason: String)
}

/// Adresten servis. Saf fonksiyondur.
public func webhookKind(url: URL) -> WebhookKind {
    let host: String = url.host()?.lowercased() ?? ""
    if host == "hooks.slack.com" {
        return .slack
    }
    if (host == "discord.com" || host == "discordapp.com" || host.hasSuffix(".discord.com")) && url.path().hasPrefix("/api/webhooks") {
        return .discord
    }
    // Teams kanal webhook'ları artık Power Automate iş akışlarıyla (logic.azure.com, powerplatform.com) gelir.
    if host.hasSuffix(".webhook.office.com") || host.hasSuffix(".logic.azure.com") || host.hasSuffix(".powerplatform.com") {
        return .teams
    }
    if host == "integrations.zoom.us" && url.path().hasPrefix("/chat/webhooks/incomingwebhook") {
        return .zoom
    }
    return .generic
}

/// Kullanıcının yapıştırdığı webhook adresi: yalnızca https (ve yerel denemeler için http://localhost/127.0.0.1).
/// Geçersizse `invalidURL`. Saf fonksiyondur.
public func webhookURL(text: String) throws -> URL {
    let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(),
          scheme == "https" || (scheme == "http" && (host == "localhost" || host == "127.0.0.1")) else {
        throw WebhookError.invalidURL
    }
    return url
}

/// Yapılandırılmış toplantı (Zapier, Make, n8n gibi servisler alanları ayrı ayrı kullanabilsin).
public struct WebhookMeeting: Sendable, Equatable, Encodable {
    public let id: String
    public let title: String
    public let startedAt: Date
    public let durationMinutes: Int?
    public let language: String?
    public let summary: String
    public let decisions: [String]
    public let tasks: [WebhookTask]
    public let outline: [WebhookOutlineItem]
}

public struct WebhookTask: Sendable, Equatable, Encodable {
    public let owner: String
    public let description: String
    public let dueDate: String?
    public let isMine: Bool
}

public struct WebhookOutlineItem: Sendable, Equatable, Encodable {
    public let startSec: Double
    public let title: String
    public let summary: String
}

/// Toplantının yapılandırılmış hali. Saf fonksiyondur.
public func webhookMeeting(record: MeetingRecord, note: MeetingNote) -> WebhookMeeting {
    WebhookMeeting(
        id: record.id, title: note.title, startedAt: record.startedAt, durationMinutes: meetingDurationMinutes(record: record),
        language: record.language?.rawValue, summary: note.summary, decisions: note.decisions,
        tasks: note.tasks.map { WebhookTask(owner: $0.owner, description: $0.description, dueDate: $0.dueDate, isMine: $0.isMine) },
        outline: (note.outline ?? []).map { WebhookOutlineItem(startSec: $0.startSec, title: $0.title, summary: $0.summary) }
    )
}

/// Markdown'ı Slack biçimine çevirir: `&`, `<`, `>` kaçışlanır (toplantı metnindeki `<!channel>` ya da `<@U…>` kanalı
/// etiketleyemez), başlıklar ve `**kalın**` tek yıldızlı kalın, yapılacak kutuları madde işareti. Saf fonksiyondur.
public func slackText(markdown: String) -> String {
    markdown
        .replacing("&", with: "&amp;")
        .replacing("<", with: "&lt;")
        .replacing(">", with: "&gt;")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { (line: Substring) -> String in
            let text: String = String(line)
            if let heading = text.firstMatch(of: /^#{1,6}\s+(.+)$/) {
                return "*\(heading.1)*"
            }
            return text
                .replacing(/^- \[ \]\s/, with: "• ")
                .replacing(/^-\s/, with: "• ")
                .replacing(/\*\*(.+?)\*\*/) { (match: Regex<(Substring, Substring)>.Match) -> String in "*\(match.output.1)*" }
        }
        .joined(separator: "\n")
}

/// Discord mesaj sınırı (karakter).
let discordContentLimit: Int = 2000

/// Webhook metni: başlık ve tarih, önce görevler (sana düşenler başta), sonra kararlar, özet ve konu akışı. Kanalda
/// en çok görevler okunur; Discord sınırında kesilen kısım sondaki özet ve konu akışı olur, görevler değil. Saf
/// fonksiyondur.
public func webhookText(record: MeetingRecord, note: MeetingNote) -> String {
    let date: String = record.startedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(Locale(identifier: "tr")))
    var lines: [String] = ["# \(note.title)", "", "_\(date)_", ""]
    let tasks: [NoteTask] = note.tasks.filter(\.isMine) + note.tasks.filter { !$0.isMine }
    if !tasks.isEmpty {
        lines += ["## " + String(localized: "Görevler"), ""] + tasks.map { (task: NoteTask) -> String in
            "- [ ] **\(task.owner)** — \(task.description)\(task.dueDate.map { " (\($0))" } ?? "")"
        } + [""]
    }
    if !note.decisions.isEmpty {
        lines += ["## " + String(localized: "Kararlar"), ""] + note.decisions.map { "- \($0)" } + [""]
    }
    lines += ["## " + String(localized: "Özet"), "", note.summary, ""]
    if let outline = note.outline, !outline.isEmpty {
        lines += ["## " + String(localized: "Konu akışı"), ""] + outline.map { "- [\(timestamp(seconds: $0.startSec))] \($0.title) — \($0.summary)" }
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Gönderilecek gövde: servise uygun biçimde webhook metni (Türkçe), genel webhook'ta ayrıca yapılandırılmış toplantı.
/// Saf fonksiyondur.
public func webhookPayload(kind: WebhookKind, record: MeetingRecord, note: MeetingNote) throws -> Data {
    let markdown: String = webhookText(record: record, note: note)
    let encoder: JSONEncoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    switch kind {
    case .slack:
        return try encoder.encode(["text": slackText(markdown: markdown)])
    case .discord:
        let content: String = markdown.count > discordContentLimit ? String(markdown.prefix(discordContentLimit - 1)) + "…" : markdown
        return try encoder.encode(DiscordMessage(content: content, allowedMentions: DiscordAllowedMentions(parse: [])))
    case .teams:
        return try encoder.encode(TeamsMessage(markdown: markdown))
    case .zoom:
        return try encoder.encode(ZoomMessage(title: note.title, markdown: markdown))
    case .generic:
        return try encoder.encode(GenericWebhookBody(text: markdown, meeting: webhookMeeting(record: record, note: note)))
    }
}

/// Discord mesajı; `allowed_mentions.parse` boş: toplantı metnindeki `@everyone`, `@here` ya da kullanıcı etiketleri
/// kimseyi uyarmaz.
private struct DiscordMessage: Encodable {
    let content: String
    let allowedMentions: DiscordAllowedMentions

    enum CodingKeys: String, CodingKey {
        case content
        case allowedMentions = "allowed_mentions"
    }
}

private struct DiscordAllowedMentions: Encodable {
    let parse: [String]
}

/// Zoom Team Chat mesajı (`?format=full`): başlık ve tek metin bölümü.
private struct ZoomMessage: Encodable {
    struct Content: Encodable {
        let head: Head
        let body: [Section]
    }

    struct Head: Encodable {
        let text: String
    }

    struct Section: Encodable {
        let type: String
        let text: String
    }

    let content: Content

    init(title: String, markdown: String) {
        content = Content(head: Head(text: title), body: [Section(type: "message", text: markdown)])
    }
}

/// Zoom webhook adresi: yapıştırılan adres `format=full` ile, doğrulama anahtarı `#` sonrası parçada. Adres Zoom'un
/// gelen webhook adresi değilse ya da anahtar boşsa `invalidURL`. Saf fonksiyondur.
public func zoomWebhookURL(address: String, token: String) throws -> URL {
    let trimmedToken: String = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(url: try webhookURL(text: address), resolvingAgainstBaseURL: false), !trimmedToken.isEmpty else {
        throw WebhookError.invalidURL
    }
    components.queryItems = (components.queryItems ?? []).filter { $0.name != "format" } + [URLQueryItem(name: "format", value: "full")]
    components.fragment = trimmedToken
    guard let url = components.url, webhookKind(url: url) == .zoom else {
        throw WebhookError.invalidURL
    }
    return url
}

private struct GenericWebhookBody: Encodable {
    let text: String
    let meeting: WebhookMeeting
}

/// Teams (Power Automate "webhook isteği alındığında kanala gönder") Adaptive Card mesajı.
private struct TeamsMessage: Encodable {
    let type: String = "message"
    let attachments: [TeamsAttachment]

    init(markdown: String) {
        attachments = [TeamsAttachment(content: TeamsCard(body: [TeamsTextBlock(text: teamsCardText(markdown: markdown))]))]
    }
}

private struct TeamsAttachment: Encodable {
    let contentType: String = "application/vnd.microsoft.card.adaptive"
    let content: TeamsCard
}

private struct TeamsCard: Encodable {
    let type: String = "AdaptiveCard"
    let version: String = "1.4"
    let body: [TeamsTextBlock]

    enum CodingKeys: String, CodingKey {
        case type
        case version
        case body
        case schema = "$schema"
    }

    func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("http://adaptivecards.io/schemas/adaptive-card.json", forKey: .schema)
        try container.encode(type, forKey: .type)
        try container.encode(version, forKey: .version)
        try container.encode(body, forKey: .body)
    }
}

private struct TeamsTextBlock: Encodable {
    let type: String = "TextBlock"
    let text: String
    let wrap: Bool = true
}

/// Adaptive Card metni: kart başlık (`#`) ve yapılacak kutusu (`- [ ]`) biçimini tanımaz, ham görünüyordu; başlıklar
/// kalın satır, kutular madde işareti olur. Saf fonksiyondur.
func teamsCardText(markdown: String) -> String {
    markdown
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { (line: Substring) -> String in
            if let heading = String(line).firstMatch(of: /^#{1,6}\s+(.+)$/) {
                return "**\(heading.1)**"
            }
            return String(line).replacing(/^- \[ \]\s/, with: "- ")
        }
        .joined(separator: "\n")
}

private let webhookLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Webhook")
private let webhookAttempts: Int = 3

/// Gövdeyi JSON olarak gönderir. Yalnızca istek sunucuya ulaşmadıysa (bağlantı kurulamadı) ya da 429'da 3 deneme (1, 2 sn
/// bekleyerek, uyarı logu): zaman aşımı ve 5xx'te sunucu mesajı almış olabilir, yeniden deneme notu kanala iki kez
/// düşürürdü. Adres gizli olduğu için log ve hatada yalnızca sunucu adı yer alır.
/// Discord'da girişle oluşturulan webhook'u siler (bağlantı kaldırılınca sunucuda kullanılabilir adres kalmasın).
/// Zaten silinmişse (404) hata değildir.
public func deleteDiscordWebhook(url: URL) async throws {
    let host: String = url.host() ?? "?"
    var request: URLRequest = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.timeoutInterval = 30
    do {
        let (data, response): (Data, URLResponse) = try await URLSession.shared.data(for: request)
        let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) || status == 404 else {
            throw WebhookError.http(host: host, status: status, body: String(decoding: data.prefix(500), as: UTF8.self))
        }
    } catch let error as URLError {
        throw WebhookError.network(host: host, reason: error.localizedDescription)
    }
}

public func sendWebhook(url: URL, payload: Data) async throws {
    let host: String = url.host() ?? "?"
    var request: URLRequest = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    if webhookKind(url: url) == .zoom, let token = url.fragment(percentEncoded: false) {
        request.setValue(token, forHTTPHeaderField: "authorization")
    }
    request.httpBody = payload
    var lastError: WebhookError = .network(host: host, reason: "deneme yapılmadı")
    for attempt in 1...webhookAttempts {
        do {
            let (data, response): (Data, URLResponse) = try await URLSession.shared.data(for: request)
            let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                return
            }
            let error: WebhookError = .http(host: host, status: status, body: String(decoding: data.prefix(500), as: UTF8.self))
            guard status == 429 else {
                throw error
            }
            lastError = error
        } catch let error as URLError where isSafeToRetryPost(code: error.code) {
            lastError = .network(host: host, reason: error.localizedDescription)
        } catch let error as URLError where error.code != .cancelled {
            throw WebhookError.network(host: host, reason: error.localizedDescription)
        }
        webhookLogger.warning("Webhook gönderilemedi, deneme: \(attempt, privacy: .public), sunucu: \(host, privacy: .public), hata: \(String(describing: lastError), privacy: .private)")
        if attempt < webhookAttempts {
            try await Task.sleep(for: .seconds(Double(attempt)))
        }
    }
    throw lastError
}
