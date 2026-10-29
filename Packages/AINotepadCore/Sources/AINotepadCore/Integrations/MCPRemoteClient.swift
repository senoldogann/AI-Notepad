import CryptoKit
import Foundation
import os

/// Uzak MCP sunucusuna bağlantı (Streamable HTTP): sunucu adresi, dinamik kayıtla alınan istemci kimliği ve OAuth
/// jetonları. Anahtar Zinciri'nde saklanır (jetonlar içerir).
public struct MCPConnection: Sendable, Equatable, Codable {
    public let serverURL: URL
    /// Dinamik istemci kaydıyla (RFC 7591) sunucudan alınan istemci kimliği; uygulamaya gömülü değildir.
    public let clientID: String
    /// Jetonun alındığı yetkilendirme sunucusunun jeton adresi (yenileme için).
    public let tokenEndpoint: URL
    public let tokens: OAuthTokens

    public init(serverURL: URL, clientID: String, tokenEndpoint: URL, tokens: OAuthTokens) {
        self.serverURL = serverURL
        self.clientID = clientID
        self.tokenEndpoint = tokenEndpoint
        self.tokens = tokens
    }

    public func with(tokens newTokens: OAuthTokens) -> MCPConnection {
        MCPConnection(serverURL: serverURL, clientID: clientID, tokenEndpoint: tokenEndpoint, tokens: newTokens)
    }
}

/// Bilinen uzak MCP sunucuları (resmi, uygulama kaydı gerektirmeyen OAuth'lu).
public enum MCPService: String, Sendable, Codable, CaseIterable {
    case notion
    case linear
    case atlassian

    public var displayName: String {
        switch self {
        case .notion: "Notion"
        case .linear: "Linear"
        case .atlassian: "Jira"
        }
    }

    public var serverURL: URL {
        switch self {
        // Sabit, geçerli adresler.
        case .notion: URL(string: "https://mcp.notion.com/mcp")!
        case .linear: URL(string: "https://mcp.linear.app/mcp")!
        // v2: Atlassian'ın önerdiği adres; kimliksiz istekte OAuth keşif bilgisini (RFC 9728) verir.
        case .atlassian: URL(string: "https://mcp.atlassian.com/v2/mcp")!
        }
    }
}

/// Uzak MCP hataları. Jetonlar hiçbir zaman hataya girmez.
public enum MCPRemoteError: Error, Equatable {
    /// Sunucu kimlik doğrulama istiyor ama yetkilendirme bilgisini (RFC 9728) vermedi.
    case noAuthorizationMetadata(server: String)
    /// Yetkilendirme sunucusu dinamik istemci kaydını desteklemiyor.
    case noDynamicRegistration(server: String)
    case http(server: String, status: Int, body: String)
    case network(server: String, reason: String)
    case invalidResponse(server: String, reason: String)
    /// JSON-RPC hata yanıtı.
    case rpc(server: String, code: Int, message: String)
    /// Araç çağrısı hata döndü (`isError`).
    case toolFailed(server: String, tool: String, message: String)
    /// Beklenen araç sunucuda yok (araç adları değişmiş olabilir).
    case toolMissing(server: String, tool: String)
    /// Oturum bitti ya da geri alındı: yeniden bağlanmak gerekir.
    case expired(server: String)
    /// Kullanıcı tarayıcıda izin vermedi (`reason` sağlayıcının hata açıklamasıdır).
    case denied(server: String, reason: String)
    /// Tarayıcıdaki giriş süresinde tamamlanmadı.
    case signInTimedOut
    /// Dönüş bu girişe ait değil (`state` farklı): başka bir denemeden ya da sekmeden geldi.
    case foreignCallback(server: String)
    /// Yetkilendirme sunucusu jeton geri alma adresi (RFC 7009 `revocation_endpoint`) bildirmiyor.
    case noRevocationEndpoint(server: String)
}

private let mcpRemoteLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "MCPRemote")
private let mcpProtocolVersion: String = "2025-06-18"

/// Ağ hatasının MCP karşılığı: iptal edilen istek (kullanıcı girişten vazgeçti, görev iptal edildi) ağ hatası değildir,
/// `CancellationError` olur ve hata olarak gösterilmez. Saf fonksiyondur.
func mcpNetworkError(error: URLError, server: String) -> any Error {
    guard error.code != .cancelled else {
        return CancellationError()
    }
    return MCPRemoteError.network(server: server, reason: error.localizedDescription)
}

// MARK: OAuth keşfi ve dinamik kayıt

/// Yetkilendirme sunucusunun bilgileri (RFC 8414).
public struct AuthorizationServerMetadata: Sendable, Equatable, Decodable {
    public let issuer: String?
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let registrationEndpoint: URL?
    /// Jeton geri alma adresi (RFC 7009); sunucu bildirmediyse nil.
    public let revocationEndpoint: URL?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case revocationEndpoint = "revocation_endpoint"
    }
}

struct ProtectedResourceMetadata: Decodable, Equatable {
    let resource: String?
    let authorizationServers: [URL]

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
    }
}

/// Keşfedilen bilgilerin denetimi: tüm adresler https, korunan kaynak gerçekten bu sunucu (RFC 9728 §3.3) ve
/// yetkilendirme sunucusunun `issuer` değeri bilgisinin alındığı kimlikle aynı (RFC 8414 §3.3). Böylece ele geçmiş ya da
/// yanıltıcı bir yanıt, giriş kodunu ve jetonları başka bir adrese yönlendiremez. Saf fonksiyondur.
func validateDiscovery(resource: ProtectedResourceMetadata, issuer: URL, metadata: AuthorizationServerMetadata, server: URL) throws {
    let name: String = server.host() ?? server.absoluteString
    let trimmed: (String) -> String = { (text: String) -> String in text.hasSuffix("/") ? String(text.dropLast()) : text }
    guard let declared = resource.resource, trimmed(declared) == trimmed(server.absoluteString) else {
        throw MCPRemoteError.invalidResponse(server: name, reason: "korunan kaynak bu sunucu değil: \(resource.resource ?? "yok")")
    }
    guard let stated = metadata.issuer, trimmed(stated) == trimmed(issuer.absoluteString) else {
        throw MCPRemoteError.invalidResponse(server: name, reason: "yetkilendirme sunucusu kimliği uyuşmuyor: \(metadata.issuer ?? "yok")")
    }
    let addresses: [URL] = [issuer, metadata.authorizationEndpoint, metadata.tokenEndpoint]
        + [metadata.registrationEndpoint, metadata.revocationEndpoint].compactMap { $0 }
    guard let insecure = addresses.first(where: { $0.scheme?.lowercased() != "https" }) else {
        return
    }
    throw MCPRemoteError.invalidResponse(server: name, reason: "güvenli olmayan adres: \(insecure.absoluteString)")
}

/// `WWW-Authenticate` başlığındaki `resource_metadata` adresi (RFC 9728). Saf fonksiyondur.
func resourceMetadataURL(wwwAuthenticate: String) -> URL? {
    guard let match = wwwAuthenticate.firstMatch(of: /resource_metadata="([^"]+)"/) else {
        return nil
    }
    return URL(string: String(match.1))
}

/// Korunan kaynağın iyi bilinen bilgi adresi: `https://host/.well-known/oauth-protected-resource/<yol>`. Saf fonksiyondur.
func wellKnownResourceMetadataURL(server: URL) -> URL? {
    var components: URLComponents = URLComponents()
    components.scheme = server.scheme
    components.host = server.host()
    components.port = server.port
    let path: String = server.path()
    components.path = "/.well-known/oauth-protected-resource" + (path == "/" ? "" : path)
    return components.url
}

/// Yetkilendirme sunucusunun iyi bilinen bilgi adresleri (önce RFC 8414, sonra OpenID). Saf fonksiyondur.
func authorizationMetadataURLs(issuer: URL) -> [URL] {
    var components: URLComponents = URLComponents()
    components.scheme = issuer.scheme
    components.host = issuer.host()
    components.port = issuer.port
    let path: String = issuer.path() == "/" ? "" : issuer.path()
    return ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"].compactMap { (prefix: String) -> URL? in
        components.path = prefix + path
        return components.url
    }
}

private func getJSON<Value: Decodable>(_ type: Value.Type, url: URL, server: String) async throws -> Value {
    var request: URLRequest = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue(mcpProtocolVersion, forHTTPHeaderField: "mcp-protocol-version")
    let (data, response): (Data, URLResponse)
    do {
        (data, response) = try await URLSession.shared.data(for: request)
    } catch let error as URLError {
        throw mcpNetworkError(error: error, server: server)
    }
    let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        throw MCPRemoteError.http(server: server, status: status, body: String(decoding: data.prefix(400), as: UTF8.self))
    }
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw MCPRemoteError.invalidResponse(server: server, reason: "\(Value.self): \(error.localizedDescription)")
    }
}

/// Sunucunun yetkilendirme sunucusunu bulur: kimliksiz bir istekle 401 ve `resource_metadata` alınır (yoksa iyi
/// bilinen adres denenir), oradan yetkilendirme sunucusunun bilgileri okunur.
public func discoverAuthorization(server: URL, clientName: String) async throws -> AuthorizationServerMetadata {
    let name: String = server.host() ?? server.absoluteString
    var probe: URLRequest = URLRequest(url: server)
    probe.httpMethod = "POST"
    probe.timeoutInterval = 20
    probe.setValue("application/json", forHTTPHeaderField: "content-type")
    probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "accept")
    probe.setValue(mcpProtocolVersion, forHTTPHeaderField: "mcp-protocol-version")
    probe.httpBody = try JSONEncoder().encode(JSONRPCRequest(id: 1, method: "initialize", params: initializeParams(clientName: clientName)))
    let response: URLResponse
    do {
        (_, response) = try await URLSession.shared.data(for: probe)
    } catch let error as URLError {
        throw mcpNetworkError(error: error, server: name)
    }
    let header: String = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
    guard let metadataURL = resourceMetadataURL(wwwAuthenticate: header) ?? wellKnownResourceMetadataURL(server: server) else {
        throw MCPRemoteError.noAuthorizationMetadata(server: name)
    }
    guard metadataURL.scheme?.lowercased() == "https" else {
        throw MCPRemoteError.invalidResponse(server: name, reason: "güvenli olmayan adres: \(metadataURL.absoluteString)")
    }
    let resource: ProtectedResourceMetadata = try await getJSON(ProtectedResourceMetadata.self, url: metadataURL, server: name)
    guard let issuer = resource.authorizationServers.first else {
        throw MCPRemoteError.noAuthorizationMetadata(server: name)
    }
    var lastError: MCPRemoteError = .noAuthorizationMetadata(server: name)
    for candidate in authorizationMetadataURLs(issuer: issuer) {
        let metadata: AuthorizationServerMetadata
        do {
            metadata = try await getJSON(AuthorizationServerMetadata.self, url: candidate, server: name)
        } catch let error as MCPRemoteError {
            lastError = error
            continue
        }
        try validateDiscovery(resource: resource, issuer: issuer, metadata: metadata, server: server)
        return metadata
    }
    throw lastError
}

private struct RegistrationRequest: Encodable {
    let clientName: String
    let redirectURIs: [String]
    let grantTypes: [String]
    let responseTypes: [String]
    let tokenEndpointAuthMethod: String

    enum CodingKeys: String, CodingKey {
        case clientName = "client_name"
        case redirectURIs = "redirect_uris"
        case grantTypes = "grant_types"
        case responseTypes = "response_types"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
    }
}

private struct RegistrationResponse: Decodable {
    let clientID: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
    }
}

/// Dinamik istemci kaydı (RFC 7591): gizli anahtarsız (PKCE) yerel uygulama olarak kaydolur, istemci kimliği döner.
/// `clientName`: servisin izin ekranında ve bağlı uygulamalar listesinde görünen ad (uygulamanın görünen adı).
public func registerClient(metadata: AuthorizationServerMetadata, redirectURI: String, server: String, clientName: String) async throws -> String {
    guard let endpoint = metadata.registrationEndpoint else {
        throw MCPRemoteError.noDynamicRegistration(server: server)
    }
    var request: URLRequest = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONEncoder().encode(RegistrationRequest(
        clientName: clientName, redirectURIs: [redirectURI], grantTypes: ["authorization_code", "refresh_token"],
        responseTypes: ["code"], tokenEndpointAuthMethod: "none"
    ))
    let (data, response): (Data, URLResponse)
    do {
        (data, response) = try await URLSession.shared.data(for: request)
    } catch let error as URLError {
        throw mcpNetworkError(error: error, server: server)
    }
    let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        throw MCPRemoteError.http(server: server, status: status, body: String(decoding: data.prefix(400), as: UTF8.self))
    }
    do {
        return try JSONDecoder().decode(RegistrationResponse.self, from: data).clientID
    } catch {
        throw MCPRemoteError.invalidResponse(server: server, reason: "kayıt yanıtı: \(error.localizedDescription)")
    }
}

/// Sunucunun giriş adresi: PKCE S256, `state` ve hedef kaynak (RFC 8707 `resource`). Saf fonksiyondur.
public func mcpAuthorizeURL(metadata: AuthorizationServerMetadata, clientID: String, redirectURI: String, pkce: PKCEPair, state: String, resource: URL) -> URL? {
    guard var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
        return nil
    }
    components.queryItems = (components.queryItems ?? []) + [
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "client_id", value: clientID),
        URLQueryItem(name: "redirect_uri", value: redirectURI),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "code_challenge", value: pkce.challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "resource", value: resource.absoluteString),
    ]
    return components.url
}

private struct MCPTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

/// Jeton isteği (kod ya da yenileme); 400 `invalid_grant` oturumun bittiğini gösterir.
private func mcpTokens(endpoint: URL, fields: [(String, String)], previousRefresh: String, server: String) async throws -> OAuthTokens {
    var request: URLRequest = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.httpBody = formBody(fields: fields)
    let (data, response): (Data, URLResponse)
    do {
        (data, response) = try await URLSession.shared.data(for: request)
    } catch let error as URLError {
        throw mcpNetworkError(error: error, server: server)
    }
    let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
    let body: String = String(decoding: data.prefix(400), as: UTF8.self)
    if status == 400 || status == 401, body.contains("invalid_grant") || body.contains("invalid_token") {
        throw MCPRemoteError.expired(server: server)
    }
    guard (200..<300).contains(status) else {
        throw MCPRemoteError.http(server: server, status: status, body: body)
    }
    let decoded: MCPTokenResponse
    do {
        decoded = try JSONDecoder().decode(MCPTokenResponse.self, from: data)
    } catch {
        throw MCPRemoteError.invalidResponse(server: server, reason: "jeton yanıtı: \(error.localizedDescription)")
    }
    // Süre verilmeyen jeton süresizdir: sunucu reddederse (401) oturum açılırken yenilenir.
    return OAuthTokens(
        accessToken: decoded.accessToken, refreshToken: decoded.refreshToken ?? previousRefresh,
        expiresAt: decoded.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) } ?? Date.distantFuture
    )
}

/// Giriş kodunu jetonlara çevirir.
public func exchangeMCPCode(metadata: AuthorizationServerMetadata, clientID: String, code: String, verifier: String, redirectURI: String, resource: URL) async throws -> OAuthTokens {
    try await mcpTokens(endpoint: metadata.tokenEndpoint, fields: [
        ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI), ("client_id", clientID),
        ("code_verifier", verifier), ("resource", resource.absoluteString),
    ], previousRefresh: "", server: resource.host() ?? resource.absoluteString)
}

/// Erişim jetonunu yeniler; yenileme jetonu yoksa `expired`.
public func refreshMCPConnection(connection: MCPConnection) async throws -> MCPConnection {
    let server: String = connection.serverURL.host() ?? connection.serverURL.absoluteString
    guard !connection.tokens.refreshToken.isEmpty else {
        throw MCPRemoteError.expired(server: server)
    }
    let tokens: OAuthTokens = try await mcpTokens(endpoint: connection.tokenEndpoint, fields: [
        ("grant_type", "refresh_token"), ("refresh_token", connection.tokens.refreshToken), ("client_id", connection.clientID),
        ("resource", connection.serverURL.absoluteString),
    ], previousRefresh: connection.tokens.refreshToken, server: server)
    return connection.with(tokens: tokens)
}

// MARK: Jeton geri alma (RFC 7009)

/// Geri alma denemesi sayısı (ağ hatası, 429 ve 5xx'te; geri alma tekrarlanabilir bir istektir).
let mcpRevocationAttempts: Int = 3

/// Geri alma isteği: yenileme jetonu varsa o (sunucu aynı izinle verilen erişim jetonlarını da geçersiz kılar), yoksa
/// erişim jetonu; gizli anahtarsız (PKCE) istemci olduğu için yalnızca `client_id` gönderilir. Saf fonksiyondur.
func mcpRevocationRequest(endpoint: URL, connection: MCPConnection) -> URLRequest {
    let hasRefresh: Bool = !connection.tokens.refreshToken.isEmpty
    var request: URLRequest = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
    request.httpBody = formBody(fields: [
        ("token", hasRefresh ? connection.tokens.refreshToken : connection.tokens.accessToken),
        ("token_type_hint", hasRefresh ? "refresh_token" : "access_token"),
        ("client_id", connection.clientID),
    ])
    return request
}

/// Bağlantının OAuth iznini yetkilendirme sunucusunda geri alır (bağlantı kaldırılırken): sunucu yeniden keşfedilir,
/// bildirdiği `revocation_endpoint`'e jeton gönderilir (bkz. `mcpRevocationRequest`). Keşfedilen jeton adresi
/// bağlantınınkiyle aynı olmalı: jeton yalnızca onu veren sunucuya gider. Geri alma adresi yoksa `noRevocationEndpoint`.
/// Ağ hatası, 429 ve 5xx'te uyarıyla yeniden denenir, sonra son hata fırlar; diğer retler (4xx) hemen fırlar. Sunucu
/// geçersiz ya da zaten geri alınmış jeton için de 200 döner (RFC 7009 §2.2).
public func revokeMCPConnection(connection: MCPConnection, clientName: String) async throws {
    let server: String = connection.serverURL.host() ?? connection.serverURL.absoluteString
    let metadata: AuthorizationServerMetadata = try await discoverAuthorization(server: connection.serverURL, clientName: clientName)
    guard metadata.tokenEndpoint == connection.tokenEndpoint else {
        throw MCPRemoteError.invalidResponse(server: server, reason: "yetkilendirme sunucusu değişmiş: \(metadata.tokenEndpoint.absoluteString)")
    }
    guard let endpoint = metadata.revocationEndpoint else {
        throw MCPRemoteError.noRevocationEndpoint(server: server)
    }
    let request: URLRequest = mcpRevocationRequest(endpoint: endpoint, connection: connection)
    var lastError: MCPRemoteError = .network(server: server, reason: "deneme yapılmadı")
    for attempt in 1...mcpRevocationAttempts {
        do {
            let (data, response): (Data, URLResponse) = try await URLSession.shared.data(for: request)
            let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                mcpRemoteLogger.info("MCP izni geri alındı, sunucu: \(server, privacy: .public)")
                return
            }
            let failure: MCPRemoteError = .http(server: server, status: status, body: String(decoding: data.prefix(400), as: UTF8.self))
            guard !isPermanentHTTPRejection(status: status) else {
                throw failure
            }
            lastError = failure
        } catch let error as URLError where error.code != .cancelled {
            lastError = .network(server: server, reason: error.localizedDescription)
        } catch let error as URLError {
            throw mcpNetworkError(error: error, server: server)
        }
        mcpRemoteLogger.warning("MCP izni geri alınamadı, sunucu: \(server, privacy: .public), deneme: \(attempt, privacy: .public), hata: \(String(describing: lastError), privacy: .private)")
        if attempt < mcpRevocationAttempts {
            try await Task.sleep(for: .seconds(Double(attempt)))
        }
    }
    throw lastError
}

// MARK: JSON-RPC (Streamable HTTP)

private struct JSONRPCRequest: Encodable {
    let jsonrpc: String = "2.0"
    let id: Int
    let method: String
    let params: JSONValue
}

private struct JSONRPCNotification: Encodable {
    let jsonrpc: String = "2.0"
    let method: String
}

private struct JSONRPCError: Decodable {
    let code: Int
    let message: String
}

private struct JSONRPCResponse: Decodable {
    let id: Int?
    let result: JSONValue?
    let error: JSONRPCError?
}

/// `initialize` parametreleri; `clientName` uygulamanın görünen adıdır (AI-Notepad ya da Gistsmith). Saf fonksiyondur.
private func initializeParams(clientName: String) -> JSONValue {
    .object([
        "protocolVersion": .string(mcpProtocolVersion),
        "capabilities": .object([:]),
        "clientInfo": .object(["name": .string(clientName), "version": .string("1.0")]),
    ])
}

/// SSE gövdesindeki olayların verileri: bir olayın birden çok `data:` satırı "\n" ile birleşir, olaylar boş satırla
/// ayrılır. Swift'te "\r\n" tek karakterdir; satırlar her tür satır sonuna göre bölünür. Saf fonksiyondur.
func serverSentEventData(body: String) -> [String] {
    let lines: [Substring] = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    var events: [String] = []
    var current: [String] = []
    for line in lines + [""] {
        if line.isEmpty {
            if !current.isEmpty {
                events.append(current.joined(separator: "\n"))
            }
            current = []
        } else if line.hasPrefix("data:") {
            let value: Substring = line.dropFirst(5)
            current.append(String(value.hasPrefix(" ") ? value.dropFirst() : value))
        }
    }
    return events
}

/// Yanıt gövdesinden verilen kimlikli JSON-RPC yanıtı: düz JSON ya da SSE (`data:` satırları). Saf fonksiyondur.
func jsonRPCResponse(body: String, contentType: String, id: Int, server: String) throws -> JSONValue {
    let candidates: [String] = contentType.contains("text/event-stream") ? serverSentEventData(body: body) : [body]
    for candidate in candidates {
        let decoded: JSONRPCResponse
        do {
            decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(candidate.utf8))
        } catch {
            // Akışta JSON-RPC yanıtı olmayan satır (ör. boş olay): sonrakine bakılır.
            continue
        }
        guard decoded.id == id else {
            // Akıştaki başka mesaj (bildirim, ilerleme): sonraki satıra bakılır.
            continue
        }
        if let error = decoded.error {
            throw MCPRemoteError.rpc(server: server, code: error.code, message: error.message)
        }
        return decoded.result ?? .null
    }
    throw MCPRemoteError.invalidResponse(server: server, reason: "yanıtta \(id) kimlikli sonuç yok")
}

/// Uzak MCP oturumu: başlatır, araçları listeler ve çağırır. Her işlem kısa ömürlü bir oturumla yapılır (uygulama
/// sürekli bağlı kalmaz).
public struct MCPRemoteSession: Sendable {
    public let serverURL: URL
    private let accessToken: String
    private let sessionID: String?

    private var serverName: String { serverURL.host() ?? serverURL.absoluteString }

    /// Oturumu açar (`initialize` + `notifications/initialized`); `clientName` sunucuya bildirilen uygulama adıdır.
    /// 401 `expired`.
    public static func open(serverURL: URL, accessToken: String, clientName: String) async throws -> MCPRemoteSession {
        let bare: MCPRemoteSession = MCPRemoteSession(serverURL: serverURL, accessToken: accessToken, sessionID: nil)
        let (_, sessionID): (JSONValue, String?) = try await bare.call(id: 1, method: "initialize", params: initializeParams(clientName: clientName))
        let session: MCPRemoteSession = MCPRemoteSession(serverURL: serverURL, accessToken: accessToken, sessionID: sessionID)
        try await session.notify(method: "notifications/initialized")
        return session
    }

    private init(serverURL: URL, accessToken: String, sessionID: String?) {
        self.serverURL = serverURL
        self.accessToken = accessToken
        self.sessionID = sessionID
    }

    private func request(body: Data) -> URLRequest {
        var request: URLRequest = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "accept")
        request.setValue(mcpProtocolVersion, forHTTPHeaderField: "mcp-protocol-version")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "mcp-session-id")
        }
        request.httpBody = body
        return request
    }

    private func call(id: Int, method: String, params: JSONValue) async throws -> (JSONValue, String?) {
        let body: Data = try JSONEncoder().encode(JSONRPCRequest(id: id, method: method, params: params))
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request(body: body))
        } catch let error as URLError {
            throw mcpNetworkError(error: error, server: serverName)
        }
        let http: HTTPURLResponse? = response as? HTTPURLResponse
        let status: Int = http?.statusCode ?? 0
        if status == 401 {
            throw MCPRemoteError.expired(server: serverName)
        }
        guard (200..<300).contains(status) else {
            throw MCPRemoteError.http(server: serverName, status: status, body: String(decoding: data.prefix(400), as: UTF8.self))
        }
        let result: JSONValue = try jsonRPCResponse(
            body: String(decoding: data, as: UTF8.self), contentType: http?.value(forHTTPHeaderField: "content-type") ?? "",
            id: id, server: serverName
        )
        return (result, http?.value(forHTTPHeaderField: "mcp-session-id") ?? sessionID)
    }

    private func notify(method: String) async throws {
        let body: Data = try JSONEncoder().encode(JSONRPCNotification(method: method))
        do {
            let (data, response): (Data, URLResponse) = try await URLSession.shared.data(for: request(body: body))
            let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw MCPRemoteError.http(server: serverName, status: status, body: String(decoding: data.prefix(400), as: UTF8.self))
            }
        } catch let error as URLError {
            throw mcpNetworkError(error: error, server: serverName)
        }
    }

    /// Sunucunun araçları (ad, açıklama, girdi şeması).
    public func listTools() async throws -> [MCPRemoteTool] {
        var tools: [MCPRemoteTool] = []
        var cursor: String?
        var id: Int = 2
        repeat {
            let params: JSONValue = cursor.map { JSONValue.object(["cursor": .string($0)]) } ?? .object([:])
            let (result, _): (JSONValue, String?) = try await call(id: id, method: "tools/list", params: params)
            guard case .object(let object) = result, case .array(let items) = object["tools"] ?? .array([]) else {
                throw MCPRemoteError.invalidResponse(server: serverName, reason: "tools/list biçimi")
            }
            tools += items.compactMap(MCPRemoteTool.init(json:))
            if case .string(let next) = object["nextCursor"] {
                cursor = next
            } else {
                cursor = nil
            }
            id += 1
        } while cursor != nil && id < 12
        guard cursor == nil else {
            throw MCPRemoteError.invalidResponse(server: serverName, reason: "araç listesi 10 sayfadan uzun")
        }
        return tools
    }

    /// Aracı çağırır; sonucun metin içeriği döner. Araç hata bildirirse `toolFailed`.
    public func callTool(name: String, arguments: JSONValue) async throws -> String {
        let (result, _): (JSONValue, String?) = try await call(id: 100, method: "tools/call", params: .object(["name": .string(name), "arguments": arguments]))
        let text: String = toolResultText(result: result)
        if case .object(let object) = result, object["isError"] == .bool(true) {
            throw MCPRemoteError.toolFailed(server: serverName, tool: name, message: String(text.prefix(400)))
        }
        return text
    }
}

/// Sunucudaki bir araç.
public struct MCPRemoteTool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    init?(json: JSONValue) {
        guard case .object(let object) = json, case .string(let name) = object["name"] else {
            return nil
        }
        self.name = name
        if case .string(let description) = object["description"] {
            self.description = description
        } else {
            self.description = ""
        }
        inputSchema = object["inputSchema"] ?? .object([:])
    }
}

/// Araç sonucunun metin parçaları (birleştirilmiş). Saf fonksiyondur.
func toolResultText(result: JSONValue) -> String {
    guard case .object(let object) = result, case .array(let content) = object["content"] ?? .array([]) else {
        return ""
    }
    return content.compactMap { (item: JSONValue) -> String? in
        guard case .object(let part) = item, case .string(let text) = part["text"] else {
            return nil
        }
        return text
    }
    .joined(separator: "\n")
}

/// JSON değerini kısa metne çevirir (istem ve log için). Saf fonksiyondur.
public func jsonText(value: JSONValue) -> String {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    } catch {
        // JSONValue her zaman kodlanabilir; buraya düşülmesi bir programlama hatasıdır.
        mcpRemoteLogger.fault("JSON değeri kodlanamadı, hata: \(String(describing: error), privacy: .private)")
        return ""
    }
}

/// Bağlantıyla oturum açar; jeton süresi bitmek üzereyse önce yenilenir. Yenilenen bağlantı oturum kullanılmadan önce
/// `persist(önceki, yeni)` ile hemen saklanır: sunucu yenileme jetonunu döndürdüyse eskisi artık geçersizdir, sonraki
/// işlem başarısız olsa bile yeni jeton kaybolmamalı.
public func openMCPSession(connection: MCPConnection, clientName: String, persist: @Sendable (MCPConnection, MCPConnection) async throws -> Void) async throws -> MCPRemoteSession {
    let current: MCPConnection
    if needsRefresh(tokens: connection.tokens, now: Date()) {
        current = try await refreshMCPConnection(connection: connection)
        try await persist(connection, current)
    } else {
        current = connection
    }
    do {
        return try await MCPRemoteSession.open(serverURL: current.serverURL, accessToken: current.tokens.accessToken, clientName: clientName)
    } catch MCPRemoteError.expired {
        // Jeton süresinden önce geri alınmış olabilir: bir kez yenileyip yeniden denenir.
        let fresh: MCPConnection = try await refreshMCPConnection(connection: current)
        try await persist(current, fresh)
        mcpRemoteLogger.info("MCP jetonu erken yenilendi, sunucu: \(current.serverURL.host() ?? "?", privacy: .public)")
        return try await MCPRemoteSession.open(serverURL: fresh.serverURL, accessToken: fresh.tokens.accessToken, clientName: clientName)
    }
}
