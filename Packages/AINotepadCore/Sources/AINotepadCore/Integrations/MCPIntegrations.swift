import Foundation
import os

private let mcpIntegrationLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "MCPIntegrations")

// MARK: Giriş

/// Uzak MCP sunucusuna tek tıkla giriş: yetkilendirme sunucusu bulunur, AI-Notepad dinamik olarak kaydolur (uygulama
/// kaydı ya da API anahtarı gerekmez), tarayıcıda izin istenir, dönüş yerel adreste yakalanır ve jetonlar alınır.
/// `openBrowser` giriş sayfasını varsayılan tarayıcıda açar.
public func signInToMCP(service: MCPService, openBrowser: @Sendable (URL) async -> Void) async throws -> MCPConnection {
    let server: URL = service.serverURL
    let name: String = server.host() ?? service.displayName
    let metadata: AuthorizationServerMetadata = try await discoverAuthorization(server: server)
    let loopback: LoopbackRedirect = try await LoopbackRedirect.start()
    defer { loopback.stop() }
    let clientID: String = try await registerClient(metadata: metadata, redirectURI: loopback.redirectURI, server: name)
    let pkce: PKCEPair = makePKCEPair()
    let state: String = makeOAuthState()
    guard let authorizeURL = mcpAuthorizeURL(metadata: metadata, clientID: clientID, redirectURI: loopback.redirectURI, pkce: pkce, state: state, resource: server) else {
        throw MCPRemoteError.invalidResponse(server: name, reason: "giriş adresi kurulamadı")
    }
    await openBrowser(authorizeURL)
    let callback: URL = try await loopback.waitForCallback(timeoutSec: 300)
    let code: String = try mcpCallbackCode(url: callback, expectedState: state, server: name)
    let tokens: OAuthTokens = try await exchangeMCPCode(
        metadata: metadata, clientID: clientID, code: code, verifier: pkce.verifier, redirectURI: loopback.redirectURI, resource: server
    )
    mcpIntegrationLogger.info("MCP girişi tamamlandı, servis: \(service.rawValue, privacy: .public)")
    return MCPConnection(serverURL: server, clientID: clientID, tokenEndpoint: metadata.tokenEndpoint, tokens: tokens)
}

/// Dönüş adresinden yetki kodu: `error` varsa `denied`, `state` farklıysa `denied`. Saf fonksiyondur.
func mcpCallbackCode(url: URL, expectedState: String, server: String) throws -> String {
    let items: [URLQueryItem] = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let value: (String) -> String? = { (name: String) -> String? in items.first { $0.name == name }?.value }
    if let error = value("error") {
        throw MCPRemoteError.denied(server: server, reason: value("error_description") ?? error)
    }
    guard value("state") == expectedState else {
        throw MCPRemoteError.denied(server: server, reason: "dönüş başka bir girişe ait")
    }
    guard let code = value("code"), !code.isEmpty else {
        throw MCPRemoteError.invalidResponse(server: server, reason: "dönüş adresinde kod yok")
    }
    return code
}

// MARK: Notion

/// Notion hedefi: Notion MCP bağlantısı. Notlar Notion'da özel sayfa olarak oluşur (üst sayfa seçmek gerekmez).
public struct NotionTarget: Sendable, Equatable, Codable {
    public let connection: MCPConnection
    /// Arayüzdeki açıklama (ör. "Özel sayfalar").
    public let pageTitle: String

    public init(connection: MCPConnection, pageTitle: String) {
        self.connection = connection
        self.pageTitle = pageTitle
    }

    public func with(connection newConnection: MCPConnection) -> NotionTarget {
        NotionTarget(connection: newConnection, pageTitle: pageTitle)
    }
}

/// Notion MCP'nin sayfa oluşturma aracı (Notion'un belgelediği ad).
let notionCreatePagesTool: String = "notion-create-pages"

/// Notion'a yazılacak sayfa: başlık ve Markdown içerik (önce görevler, sonra kararlar, özet ve konu akışı). Saf
/// fonksiyondur.
func notionPageArguments(record: MeetingRecord, note: MeetingNote) -> JSONValue {
    let body: String = webhookText(record: record, note: note)
        // Başlık sayfanın adıdır; içerikte tekrar edilmez.
        .split(separator: "\n", omittingEmptySubsequences: false)
        .dropFirst()
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return .object([
        "pages": .array([
            .object([
                "properties": .object(["title": .string(note.title)]),
                "content": .string(body),
            ]),
        ]),
    ])
}

/// Notu Notion'da yeni sayfa olarak oluşturur; jeton yenilendiyse yeni bağlantı döner (çağıran saklar).
public func createNotionPage(connection: MCPConnection, record: MeetingRecord, note: MeetingNote) async throws -> MCPConnection {
    let opened: (session: MCPRemoteSession, connection: MCPConnection) = try await openMCPSession(connection: connection)
    let tools: [MCPRemoteTool] = try await opened.session.listTools()
    guard tools.contains(where: { $0.name == notionCreatePagesTool }) else {
        throw MCPRemoteError.toolMissing(server: "mcp.notion.com", tool: notionCreatePagesTool)
    }
    _ = try await opened.session.callTool(name: notionCreatePagesTool, arguments: notionPageArguments(record: record, note: note))
    return opened.connection
}

// MARK: Görev araçları (Linear, Jira)

/// Görevlerin gönderildiği araç: Linear ya da Jira (MCP bağlantısıyla).
public struct TaskTracker: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let service: MCPService
    public let connection: MCPConnection
    /// Görevlerin açılacağı takım ya da proje (boşsa aracın varsayılanı); kullanıcı yazar.
    public let target: String

    public init(id: String, service: MCPService, connection: MCPConnection, target: String) {
        self.id = id
        self.service = service
        self.connection = connection
        self.target = target
    }

    public func with(connection newConnection: MCPConnection) -> TaskTracker {
        TaskTracker(id: id, service: service, connection: newConnection, target: target)
    }

    public func with(target newTarget: String) -> TaskTracker {
        TaskTracker(id: id, service: service, connection: connection, target: newTarget)
    }
}

/// Görev araçlarının Anahtar Zinciri'ndeki listesi.
public func loadTaskTrackers(service: String) throws -> [TaskTracker] {
    let text: String
    do {
        text = try readSecret(service: service, account: .taskTrackers)
    } catch KeychainError.notFound {
        return []
    }
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        return try decoder.decode([TaskTracker].self, from: Data(text.utf8))
    } catch {
        throw StorageError.readFailed(path: "\(service)/\(SecretAccount.taskTrackers.rawValue)", reason: error.localizedDescription)
    }
}

/// Görev araçlarını Anahtar Zinciri'ne yazar.
public func saveTaskTrackers(trackers: [TaskTracker], service: String) throws {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .sortedKeys
    try saveSecret(service: service, account: .taskTrackers, value: String(decoding: try encoder.encode(trackers), as: UTF8.self))
}

/// Ajanın bir adımı: araç çağrısı ya da bitiş (özetle).
struct TrackerAgentStep: Decodable, Equatable {
    let action: String
    let tool: String
    let argumentsJSON: String
    let summary: String

    enum CodingKeys: String, CodingKey {
        case action
        case tool
        case argumentsJSON = "arguments_json"
        case summary
    }
}

let trackerAgentSchema: String = """
{"type":"object","properties":{"action":{"type":"string","enum":["call","done"]},"tool":{"type":"string"},\
"arguments_json":{"type":"string"},"summary":{"type":"string"}},"required":["action","tool","arguments_json","summary"],\
"additionalProperties":false}
"""

/// Ajana gösterilecek araçlar: görev açmakla ilgili olanlar (silme ve yönetim araçları hiç gösterilmez). Saf fonksiyondur.
func trackerAgentTools(tools: [MCPRemoteTool], service: MCPService) -> [MCPRemoteTool] {
    let forbidden: [String] = ["delete", "remove", "archive", "transition", "update"]
    let relevant: [String] = service == .atlassian
        ? ["jira", "accessibleatlassianresources", "issue", "project"]
        : ["issue", "team", "project", "user", "label", "status", "cycle"]
    return tools.filter { (tool: MCPRemoteTool) -> Bool in
        let name: String = tool.name.lowercased()
        return !forbidden.contains { name.contains($0) } && relevant.contains { name.contains($0) }
    }
}

/// Ajanın istemi: hedef, görevler, araçlar ve şimdiye dek yapılanlar. Saf fonksiyondur.
func trackerAgentRequest(service: MCPService, target: String, tasks: [NoteTask], meetingTitle: String, tools: [MCPRemoteTool], transcript: [String]) -> LLMRequest {
    let toolText: String = tools.map { (tool: MCPRemoteTool) -> String in
        "- \(tool.name): \(String(tool.description.prefix(300)))\n  input_schema: \(String(jsonText(value: tool.inputSchema).prefix(1500)))"
    }
    .joined(separator: "\n")
    let taskText: String = tasks.enumerated().map { (item: (offset: Int, element: NoteTask)) -> String in
        "\(item.offset + 1). \(item.element.description) (sahip: \(item.element.owner)\(item.element.dueDate.map { ", tarih: \($0)" } ?? ""))"
    }
    .joined(separator: "\n")
    let system: String = """
    You create issues in \(service.displayName) through its MCP tools for tasks from a meeting note. Work step by step: \
    first find the right \(service == .atlassian ? "Jira site (cloudId) and project" : "team") \(target.isEmpty ? "(if there are several, use the first one the user can access)" : "named or matching \"\(target)\""), \
    then create exactly one issue per task with a short title (the task) and a description that mentions the owner, due date \
    and the meeting title. Never delete or modify existing items. Reply with one JSON object per step: action "call" with the \
    tool name and its arguments as a JSON string, or action "done" with an empty tool, "{}" and a Turkish summary listing the \
    created issue keys or links. If something is impossible, return "done" and explain in Turkish.
    """
    let user: String = """
    Toplantı: \(meetingTitle)
    Görevler:
    \(taskText)

    Araçlar:
    \(toolText)

    Şimdiye kadar:
    \(transcript.isEmpty ? "(henüz bir şey yapılmadı)" : transcript.joined(separator: "\n"))
    """
    return LLMRequest(tier: .smart, system: system, userText: user, maxTokens: 2000, jsonSchema: trackerAgentSchema, timeoutSec: 90)
}

/// Görev aracı hataları.
public enum TaskTrackerError: Error, Equatable {
    /// Ajan adım sınırında bitiremedi.
    case unfinished(service: String, summary: String)
    /// Ajan geçersiz argüman üretti.
    case invalidArguments(service: String, tool: String)
}

/// Görevleri araçta iş olarak açar: araçlar listelenir, LLM her adımda bir araç seçer (en çok 10 adım), sonuçlar ona
/// geri verilir. Yalnızca görev açmakla ilgili araçlar görünür; silme/güncelleme araçları hiç sunulmaz. Özet ve
/// (yenilendiyse) bağlantı döner.
public func sendTasksToTracker(tracker: TaskTracker, tasks: [NoteTask], meetingTitle: String, llm: LLMProvider) async throws -> (summary: String, connection: MCPConnection) {
    let opened: (session: MCPRemoteSession, connection: MCPConnection) = try await openMCPSession(connection: tracker.connection)
    let tools: [MCPRemoteTool] = trackerAgentTools(tools: try await opened.session.listTools(), service: tracker.service)
    let allowed: Set<String> = Set(tools.map(\.name))
    var transcript: [String] = []
    for step in 1...10 {
        let request: LLMRequest = trackerAgentRequest(service: tracker.service, target: tracker.target, tasks: tasks, meetingTitle: meetingTitle, tools: tools, transcript: transcript)
        let next: TrackerAgentStep = try await requestStructured(provider: llm, request: request) { (text: String) throws -> TrackerAgentStep in
            try JSONDecoder().decode(TrackerAgentStep.self, from: Data(text.utf8))
        }
        if next.action == "done" {
            mcpIntegrationLogger.info("Görevler araca gönderildi, servis: \(tracker.service.rawValue, privacy: .public), adım: \(step, privacy: .public)")
            return (next.summary, opened.connection)
        }
        guard allowed.contains(next.tool) else {
            transcript.append("\(step). \(next.tool) → HATA: bu araç kullanılamaz; yalnızca listedeki araçlar.")
            continue
        }
        let arguments: JSONValue
        do {
            arguments = try JSONDecoder().decode(JSONValue.self, from: Data(next.argumentsJSON.utf8))
        } catch {
            throw TaskTrackerError.invalidArguments(service: tracker.service.displayName, tool: next.tool)
        }
        do {
            let result: String = try await opened.session.callTool(name: next.tool, arguments: arguments)
            transcript.append("\(step). \(next.tool)(\(String(next.argumentsJSON.prefix(400)))) → \(String(result.prefix(1500)))")
        } catch MCPRemoteError.toolFailed(_, let tool, let message) {
            // Aracın hatası ajana geri verilir: argümanı düzeltip yeniden deneyebilir.
            transcript.append("\(step). \(tool) → HATA: \(message)")
        }
    }
    throw TaskTrackerError.unfinished(service: tracker.service.displayName, summary: transcript.last ?? "")
}
