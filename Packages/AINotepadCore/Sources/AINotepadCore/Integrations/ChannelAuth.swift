import CryptoKit
import Foundation
import os

/// Hesapla tek tıkla bağlanan kanal servisleri. Giriş OAuth + PKCE ile yapılır: uygulamaya gizli anahtar gömülmez,
/// yalnızca geliştirici portallarındaki herkese açık istemci kimliği kullanılır.
/// - Slack: kullanıcı kendi adıyla seçtiği kanala yazar (kullanıcı jetonu, `chat:write`).
/// - Discord: Discord'un sayfasında sunucu ve kanal seçilir; sonuç bir webhook adresidir.
/// - Teams: iş ya da okul hesabıyla giriş, Microsoft Graph üzerinden seçilen kanala yazar.
public enum ChannelService: String, Sendable, Codable, CaseIterable {
    case slack
    case discord
    case teams

    /// Arayüzdeki adı.
    public var displayName: String {
        switch self {
        case .slack: "Slack"
        case .discord: "Discord"
        case .teams: "Microsoft Teams"
        }
    }
}

/// Geliştirici portallarında kayıtlı AI-Notepad uygulamalarının istemci kimlikleri (gizli değildir; PKCE kullanılır).
/// Boşsa o servis henüz kaydedilmemiştir. Saf fonksiyondur.
public func channelClientID(service: ChannelService) -> String {
    switch service {
    case .slack: ""
    case .discord: ""
    case .teams: ""
    }
}

/// Girişin döndüğü adres şeması (`ainotepad://oauth/<servis>`); portallarda yönlendirme adresi olarak kayıtlıdır.
public let oauthCallbackScheme: String = "ainotepad"

/// Servisin yönlendirme adresi. Saf fonksiyondur.
public func oauthRedirectURI(service: ChannelService) -> String {
    "\(oauthCallbackScheme)://oauth/\(service.rawValue)"
}

/// Kanal girişi ya da gönderimi başarısız. Jetonlar hiçbir zaman hataya girmez.
public enum ChannelAuthError: Error, Equatable {
    /// Servisin istemci kimliği uygulamada yok (geliştirici portalında kayıt bekliyor).
    case notConfigured(service: ChannelService)
    /// Kullanıcı girişte izin vermedi ya da kurum yöneticisi onayı gerekiyor.
    case denied(service: ChannelService, reason: String)
    /// Dönüşteki `state` gönderilenle aynı değil (başka bir girişin yanıtı).
    case stateMismatch(service: ChannelService)
    /// HTTP hatası; gövde hata ayıklama içindir (jeton içermez).
    case http(service: ChannelService, status: Int, body: String)
    /// Servis isteği reddetti (Slack `ok: false`).
    case api(service: ChannelService, error: String)
    case network(service: ChannelService, reason: String)
    case invalidResponse(service: ChannelService, reason: String)
    /// Oturumun süresi doldu ya da erişim geri alındı: yeniden bağlanmak gerekir.
    case expired(service: ChannelService)
    /// Hesapta yazılabilecek kanal yok.
    case noChannels(service: ChannelService)
}

// MARK: PKCE ve giriş adresi

/// PKCE çifti: doğrulayıcı girişten sonra jeton alırken gönderilir, meydan okuma giriş adresine girer.
public struct PKCEPair: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
}

/// RFC 7636 S256 meydan okuması: doğrulayıcının SHA-256'sı, base64url (dolgu yok). Saf fonksiyondur.
public func pkceChallenge(verifier: String) -> String {
    base64URL(data: Data(SHA256.hash(data: Data(verifier.utf8))))
}

/// Rastgele PKCE çifti (32 bayt → 43 karakterlik doğrulayıcı).
public func makePKCEPair() -> PKCEPair {
    let verifier: String = randomToken()
    return PKCEPair(verifier: verifier, challenge: pkceChallenge(verifier: verifier))
}

/// Girişi bu isteğe bağlayan rastgele `state`.
public func makeOAuthState() -> String {
    randomToken()
}

private func randomToken() -> String {
    var generator: SystemRandomNumberGenerator = SystemRandomNumberGenerator()
    return base64URL(data: Data((0..<32).map { (_: Int) -> UInt8 in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }))
}

private func base64URL(data: Data) -> String {
    data.base64EncodedString()
        .replacing("+", with: "-")
        .replacing("/", with: "_")
        .replacing("=", with: "")
}

/// Microsoft Graph izinleri: takım ve kanal listesi, kanala mesaj; `offline_access` oturumun yenilenmesi için.
let teamsScopes: String = "offline_access User.Read Team.ReadBasic.All Channel.ReadBasic.All ChannelMessage.Send"

/// Slack kullanıcı izinleri: kanala kendi adınla yazma ve üyesi olduğun kanalları listeleme.
let slackUserScopes: String = "chat:write,channels:read,groups:read"

/// Servisin giriş sayfası (PKCE S256 ve `state` ile). Saf fonksiyondur.
public func channelAuthorizeURL(service: ChannelService, clientID: String, pkce: PKCEPair, state: String) -> URL {
    var components: URLComponents = URLComponents()
    components.scheme = "https"
    var items: [URLQueryItem] = [
        URLQueryItem(name: "client_id", value: clientID),
        URLQueryItem(name: "redirect_uri", value: oauthRedirectURI(service: service)),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "code_challenge", value: pkce.challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    switch service {
    case .slack:
        components.host = "slack.com"
        components.path = "/oauth/v2/authorize"
        items.append(URLQueryItem(name: "user_scope", value: slackUserScopes))
    case .discord:
        components.host = "discord.com"
        components.path = "/oauth2/authorize"
        items += [URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "scope", value: "webhook.incoming")]
    case .teams:
        // Teams kanalları yalnızca iş ve okul hesaplarında: kişisel Microsoft hesapları baştan elenir.
        components.host = "login.microsoftonline.com"
        components.path = "/organizations/oauth2/v2.0/authorize"
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: teamsScopes),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
    }
    components.queryItems = items
    // Sabit, geçerli bileşenlerden kurulur; nil olamaz.
    return components.url!
}

/// Girişten dönen adresten yetki kodu: `error` varsa `denied`, `state` farklıysa `stateMismatch`, kod yoksa
/// `invalidResponse`. Saf fonksiyondur.
public func oauthCallbackCode(service: ChannelService, url: URL, expectedState: String) throws -> String {
    let items: [URLQueryItem] = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let value: (String) -> String? = { (name: String) -> String? in items.first { $0.name == name }?.value }
    if let error = value("error") {
        throw ChannelAuthError.denied(service: service, reason: value("error_description") ?? error)
    }
    guard value("state") == expectedState else {
        throw ChannelAuthError.stateMismatch(service: service)
    }
    guard let code = value("code"), !code.isEmpty else {
        throw ChannelAuthError.invalidResponse(service: service, reason: "dönüş adresinde kod yok")
    }
    return code
}

// MARK: Bağlantı

/// Erişim ve yenileme jetonları; erişim jetonu `expiresAt`'ta biter.
public struct OAuthTokens: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
}

/// Yazılabilecek bir kanal (Teams'te takımıyla).
public struct ChannelOption: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let teamID: String?
    /// Arayüzdeki adı: Slack'te "#genel", Teams'te "Takım › Genel".
    public let name: String
}

/// Hesapla kurulan kanal bağlantısı (Slack ya da Teams); Anahtar Zinciri'nde JSON olarak saklanır.
public struct ChannelConnection: Sendable, Equatable, Codable {
    public let service: ChannelService
    public let tokens: OAuthTokens
    /// Slack çalışma alanı ya da Teams kuruluşu (bilinmiyorsa boş).
    public let workspace: String
    public let channel: ChannelOption

    public init(service: ChannelService, tokens: OAuthTokens, workspace: String, channel: ChannelOption) {
        self.service = service
        self.tokens = tokens
        self.workspace = workspace
        self.channel = channel
    }

    public func with(tokens: OAuthTokens) -> ChannelConnection {
        ChannelConnection(service: service, tokens: tokens, workspace: workspace, channel: channel)
    }
}

/// Girişten sonra, kanal seçilmeden önceki oturum.
public struct ChannelSignIn: Sendable, Equatable {
    public let service: ChannelService
    public let tokens: OAuthTokens
    public let workspace: String
}

/// Bağlantıyı Anahtar Zinciri'ne yazılacak metne çevirir. Saf fonksiyondur.
public func encodeChannelConnection(connection: ChannelConnection) throws -> String {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(connection), as: UTF8.self)
}

/// Anahtar Zinciri'ndeki metinden bağlantı. Saf fonksiyondur.
public func decodeChannelConnection(text: String) throws -> ChannelConnection {
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(ChannelConnection.self, from: Data(text.utf8))
}

/// Erişim jetonu 2 dakika içinde bitiyorsa yenilenmeli. Saf fonksiyondur.
public func needsRefresh(tokens: OAuthTokens, now: Date) -> Bool {
    tokens.expiresAt.timeIntervalSince(now) < 120
}

// MARK: HTTP

private let channelLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Channel")
private let channelAttempts: Int = 3

/// Form gövdesi (`application/x-www-form-urlencoded`): harf, rakam ve `-._~` dışındaki her şey kodlanır. Saf
/// fonksiyondur.
func formBody(fields: [(String, String)]) -> Data {
    let allowed: CharacterSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let encode: (String) -> String = { (text: String) -> String in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
    return Data(fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
}

private func formRequest(url: URL, fields: [(String, String)]) -> URLRequest {
    var request: URLRequest = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
    request.httpBody = formBody(fields: fields)
    return request
}

private func bearerRequest(url: URL, token: String, method: String, json: Data?) -> URLRequest {
    var request: URLRequest = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 30
    request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
    if let json {
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        request.httpBody = json
    }
    return request
}

/// İsteği gönderir: 408/429/5xx ve ağ hataları 3 deneme (1, 2 sn bekleyerek, uyarı logu); diğer 4xx kesin hata.
/// Adres ve gövde jeton içerebildiği için loga yalnızca servis ve yol yazılır.
private func channelData(service: ChannelService, request: URLRequest) async throws -> Data {
    let path: String = request.url?.path() ?? "?"
    var lastError: ChannelAuthError = .network(service: service, reason: "deneme yapılmadı")
    for attempt in 1...channelAttempts {
        do {
            let (data, response): (Data, URLResponse) = try await URLSession.shared.data(for: request)
            let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                return data
            }
            let body: String = String(decoding: data.prefix(600), as: UTF8.self)
            guard isRetryableLLMStatus(status: status) else {
                throw ChannelAuthError.http(service: service, status: status, body: body)
            }
            lastError = .http(service: service, status: status, body: body)
        } catch let error as URLError where error.code != .cancelled {
            lastError = .network(service: service, reason: error.localizedDescription)
        }
        channelLogger.warning("Kanal isteği başarısız, servis: \(service.rawValue, privacy: .public), yol: \(path, privacy: .private), deneme: \(attempt, privacy: .public), hata: \(String(describing: lastError), privacy: .private)")
        if attempt < channelAttempts {
            try await Task.sleep(for: .seconds(Double(attempt)))
        }
    }
    throw lastError
}

/// Jetonla yapılan istek: 401 oturumun bittiğini gösterir (`expired`, yeniden bağlan).
private func authorizedChannelData(service: ChannelService, request: URLRequest) async throws -> Data {
    do {
        return try await channelData(service: service, request: request)
    } catch ChannelAuthError.http(_, 401, _) {
        throw ChannelAuthError.expired(service: service)
    }
}

private func decode<Value: Decodable>(_ type: Value.Type, service: ChannelService, data: Data) throws -> Value {
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw ChannelAuthError.invalidResponse(service: service, reason: "\(Value.self): \(error.localizedDescription)")
    }
}

// MARK: Slack

/// Slack yanıtlarının ortak alanları: `ok: false` ise `error`.
private struct SlackStatus: Decodable {
    let ok: Bool
    let error: String?
}

/// Slack jeton yanıtı: ilk girişte kullanıcı jetonu `authed_user` içindedir, yenilemede üst düzeydedir.
struct SlackTokenResponse: Decodable {
    struct User: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    struct Team: Decodable {
        let name: String?
    }

    let ok: Bool
    let error: String?
    let authedUser: User?
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let team: Team?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case authedUser = "authed_user"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case team
    }
}

/// Slack jeton yanıtından jetonlar: kullanıcı jetonu (ilk giriş `authed_user`, yenileme üst düzey). Jeton dönüşümü
/// zorunludur (masaüstü yönlendirmesi), yenileme jetonu ya da süre yoksa `invalidResponse`. Saf fonksiyondur.
func slackTokens(response: SlackTokenResponse, now: Date) throws -> OAuthTokens {
    guard response.ok else {
        throw slackAPIError(code: response.error ?? "bilinmeyen")
    }
    let access: String? = response.authedUser?.accessToken ?? response.accessToken
    let refresh: String? = response.authedUser?.refreshToken ?? response.refreshToken
    let expiresIn: Int? = response.authedUser?.expiresIn ?? response.expiresIn
    guard let access, let refresh, let expiresIn else {
        throw ChannelAuthError.invalidResponse(service: .slack, reason: "jeton, yenileme jetonu ya da süre yok")
    }
    return OAuthTokens(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(TimeInterval(expiresIn)))
}

/// Slack hata kodundan hata: oturumla ilgili kodlar `expired` (yeniden bağlan). Saf fonksiyondur.
func slackAPIError(code: String) -> ChannelAuthError {
    let sessionErrors: Set<String> = ["invalid_auth", "token_expired", "token_revoked", "account_inactive", "invalid_refresh_token", "not_authed"]
    return sessionErrors.contains(code) ? .expired(service: .slack) : .api(service: .slack, error: code)
}

private let slackAPI: URL = URL(string: "https://slack.com/api/")!

/// Slack girişinin kodunu kullanıcı jetonuna çevirir (gizli anahtarsız, PKCE doğrulayıcısıyla).
public func exchangeSlackCode(code: String, verifier: String, clientID: String) async throws -> ChannelSignIn {
    let data: Data = try await channelData(service: .slack, request: formRequest(url: slackAPI.appending(path: "oauth.v2.access"), fields: [
        ("client_id", clientID), ("code", code), ("code_verifier", verifier), ("redirect_uri", oauthRedirectURI(service: .slack)),
    ]))
    let response: SlackTokenResponse = try decode(SlackTokenResponse.self, service: .slack, data: data)
    return ChannelSignIn(service: .slack, tokens: try slackTokens(response: response, now: Date()), workspace: response.team?.name ?? "")
}

private struct SlackConversations: Decodable {
    struct Channel: Decodable {
        let id: String
        let name: String?
        let isArchived: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case isArchived = "is_archived"
        }
    }

    struct Metadata: Decodable {
        let nextCursor: String?

        enum CodingKeys: String, CodingKey {
            case nextCursor = "next_cursor"
        }
    }

    let ok: Bool
    let error: String?
    let channels: [Channel]?
    let responseMetadata: Metadata?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case channels
        case responseMetadata = "response_metadata"
    }
}

/// Kullanıcının üyesi olduğu açık ve özel kanallar (ada göre); en çok 10 sayfa (2000 kanal).
public func listSlackChannels(token: String) async throws -> [ChannelOption] {
    var options: [ChannelOption] = []
    var cursor: String = ""
    for _ in 0..<10 {
        var components: URLComponents = URLComponents(url: slackAPI.appending(path: "users.conversations"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "types", value: "public_channel,private_channel"),
            URLQueryItem(name: "exclude_archived", value: "true"),
            URLQueryItem(name: "limit", value: "200"),
        ] + (cursor.isEmpty ? [] : [URLQueryItem(name: "cursor", value: cursor)])
        let data: Data = try await authorizedChannelData(service: .slack, request: bearerRequest(url: components.url!, token: token, method: "GET", json: nil))
        let page: SlackConversations = try decode(SlackConversations.self, service: .slack, data: data)
        guard page.ok else {
            throw slackAPIError(code: page.error ?? "bilinmeyen")
        }
        options += (page.channels ?? []).filter { $0.isArchived != true }.map { ChannelOption(id: $0.id, teamID: nil, name: "#\($0.name ?? $0.id)") }
        cursor = page.responseMetadata?.nextCursor ?? ""
        if cursor.isEmpty {
            break
        }
    }
    return options.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

/// Erişim jetonunu yeniler (dönen yeni yenileme jetonu eskisinin yerine geçer).
public func refreshSlackTokens(tokens: OAuthTokens, clientID: String) async throws -> OAuthTokens {
    let data: Data = try await channelData(service: .slack, request: formRequest(url: slackAPI.appending(path: "oauth.v2.access"), fields: [
        ("client_id", clientID), ("grant_type", "refresh_token"), ("refresh_token", tokens.refreshToken),
    ]))
    return try slackTokens(response: try decode(SlackTokenResponse.self, service: .slack, data: data), now: Date())
}

private struct SlackPost: Encodable {
    let channel: String
    let text: String
    let mrkdwn: Bool
    let unfurlLinks: Bool

    enum CodingKeys: String, CodingKey {
        case channel
        case text
        case mrkdwn
        case unfurlLinks = "unfurl_links"
    }
}

/// Notu kanala kullanıcının adıyla yazar.
func postSlackMessage(connection: ChannelConnection, text: String) async throws {
    let body: Data = try JSONEncoder().encode(SlackPost(channel: connection.channel.id, text: text, mrkdwn: true, unfurlLinks: false))
    let data: Data = try await authorizedChannelData(
        service: .slack, request: bearerRequest(url: slackAPI.appending(path: "chat.postMessage"), token: connection.tokens.accessToken, method: "POST", json: body)
    )
    let status: SlackStatus = try decode(SlackStatus.self, service: .slack, data: data)
    guard status.ok else {
        throw slackAPIError(code: status.error ?? "bilinmeyen")
    }
}

// MARK: Discord

private struct DiscordTokenResponse: Decodable {
    struct Webhook: Decodable {
        let url: String
    }

    let webhook: Webhook?
}

/// Discord girişinin kodunu webhook adresine çevirir: kanal Discord'un sayfasında seçildi, adres yanıtta gelir.
public func exchangeDiscordCode(code: String, verifier: String, clientID: String) async throws -> URL {
    let data: Data = try await channelData(service: .discord, request: formRequest(url: URL(string: "https://discord.com/api/oauth2/token")!, fields: [
        ("client_id", clientID), ("grant_type", "authorization_code"), ("code", code), ("code_verifier", verifier),
        ("redirect_uri", oauthRedirectURI(service: .discord)),
    ]))
    guard let text = try decode(DiscordTokenResponse.self, service: .discord, data: data).webhook?.url else {
        throw ChannelAuthError.invalidResponse(service: .discord, reason: "yanıtta webhook yok")
    }
    return try webhookURL(text: text)
}

// MARK: Microsoft Teams

private struct MicrosoftTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private let microsoftTokenURL: URL = URL(string: "https://login.microsoftonline.com/organizations/oauth2/v2.0/token")!

/// Microsoft jeton isteği; geçersiz yenileme jetonu (`invalid_grant`) `expired`.
private func microsoftTokens(fields: [(String, String)], previousRefresh: String?) async throws -> OAuthTokens {
    let data: Data
    do {
        data = try await channelData(service: .teams, request: formRequest(url: microsoftTokenURL, fields: fields))
    } catch ChannelAuthError.http(let service, 400, let body) where body.contains("invalid_grant") && previousRefresh != nil {
        channelLogger.warning("Microsoft oturumu yenilenemedi, servis: \(service.rawValue, privacy: .public), yanıt: \(body, privacy: .private)")
        throw ChannelAuthError.expired(service: .teams)
    }
    let response: MicrosoftTokenResponse = try decode(MicrosoftTokenResponse.self, service: .teams, data: data)
    guard let refresh = response.refreshToken ?? previousRefresh else {
        throw ChannelAuthError.invalidResponse(service: .teams, reason: "yenileme jetonu yok (offline_access verilmedi)")
    }
    return OAuthTokens(accessToken: response.accessToken, refreshToken: refresh, expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)))
}

/// Microsoft girişinin kodunu jetonlara çevirir (gizli anahtarsız, PKCE doğrulayıcısıyla).
public func exchangeTeamsCode(code: String, verifier: String, clientID: String) async throws -> ChannelSignIn {
    let tokens: OAuthTokens = try await microsoftTokens(fields: [
        ("client_id", clientID), ("grant_type", "authorization_code"), ("code", code), ("code_verifier", verifier),
        ("redirect_uri", oauthRedirectURI(service: .teams)), ("scope", teamsScopes),
    ], previousRefresh: nil)
    return ChannelSignIn(service: .teams, tokens: tokens, workspace: "")
}

/// Erişim jetonunu yeniler.
public func refreshTeamsTokens(tokens: OAuthTokens, clientID: String) async throws -> OAuthTokens {
    try await microsoftTokens(fields: [
        ("client_id", clientID), ("grant_type", "refresh_token"), ("refresh_token", tokens.refreshToken), ("scope", teamsScopes),
    ], previousRefresh: tokens.refreshToken)
}

private struct GraphList: Decodable {
    struct Item: Decodable {
        let id: String
        let displayName: String?
    }

    let value: [Item]
}

private let graphAPI: URL = URL(string: "https://graph.microsoft.com/v1.0/")!

/// Graph yolundaki kimlik (Teams kanal kimliklerinde `:` ve `@` var) yol için kodlanır. Saf fonksiyondur.
func graphPathComponent(id: String) -> String {
    id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? id
}

private func graphURL(path: String) -> URL {
    // Yol kodlanmış bileşenlerden kurulur; geçerli bir adrestir.
    URL(string: path, relativeTo: graphAPI)!.absoluteURL
}

/// Üyesi olunan takımların kanalları ("Takım › Kanal", ada göre).
public func listTeamsChannels(token: String) async throws -> [ChannelOption] {
    let teamsData: Data = try await authorizedChannelData(service: .teams, request: bearerRequest(url: graphURL(path: "me/joinedTeams"), token: token, method: "GET", json: nil))
    var options: [ChannelOption] = []
    for team in try decode(GraphList.self, service: .teams, data: teamsData).value {
        let data: Data = try await authorizedChannelData(
            service: .teams, request: bearerRequest(url: graphURL(path: "teams/\(graphPathComponent(id: team.id))/channels"), token: token, method: "GET", json: nil)
        )
        let teamName: String = team.displayName ?? team.id
        options += try decode(GraphList.self, service: .teams, data: data).value.map {
            ChannelOption(id: $0.id, teamID: team.id, name: "\(teamName) › \($0.displayName ?? $0.id)")
        }
    }
    return options.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

private struct GraphMessage: Encodable {
    struct Body: Encodable {
        let contentType: String
        let content: String
    }

    let body: Body
}

/// Notu kanala HTML mesaj olarak yazar.
func postTeamsMessage(connection: ChannelConnection, html: String) async throws {
    guard let teamID = connection.channel.teamID else {
        throw ChannelAuthError.invalidResponse(service: .teams, reason: "kanalın takımı yok")
    }
    let body: Data = try JSONEncoder().encode(GraphMessage(body: GraphMessage.Body(contentType: "html", content: html)))
    let path: String = "teams/\(graphPathComponent(id: teamID))/channels/\(graphPathComponent(id: connection.channel.id))/messages"
    _ = try await authorizedChannelData(service: .teams, request: bearerRequest(url: graphURL(path: path), token: connection.tokens.accessToken, method: "POST", json: body))
}

// MARK: Ortak

/// Servisin kanallarını listeler; boşsa `noChannels`.
public func listChannels(signIn: ChannelSignIn) async throws -> [ChannelOption] {
    let options: [ChannelOption]
    switch signIn.service {
    case .slack:
        options = try await listSlackChannels(token: signIn.tokens.accessToken)
    case .teams:
        options = try await listTeamsChannels(token: signIn.tokens.accessToken)
    case .discord:
        throw ChannelAuthError.invalidResponse(service: .discord, reason: "Discord'da kanal girişte seçilir")
    }
    guard !options.isEmpty else {
        throw ChannelAuthError.noChannels(service: signIn.service)
    }
    return options
}

/// Süresi bitmek üzereyse jetonları yeniler; bitmiyorsa bağlantı aynen döner.
public func refreshedConnection(connection: ChannelConnection, now: Date) async throws -> ChannelConnection {
    guard needsRefresh(tokens: connection.tokens, now: now) else {
        return connection
    }
    let clientID: String = channelClientID(service: connection.service)
    switch connection.service {
    case .slack:
        return connection.with(tokens: try await refreshSlackTokens(tokens: connection.tokens, clientID: clientID))
    case .teams:
        return connection.with(tokens: try await refreshTeamsTokens(tokens: connection.tokens, clientID: clientID))
    case .discord:
        throw ChannelAuthError.invalidResponse(service: .discord, reason: "Discord bağlantısı webhook adresidir")
    }
}

/// Toplantı notunu bağlı kanala gönderir: Slack'e görevler önde Slack biçiminde, Teams'e HTML.
public func postNote(connection: ChannelConnection, record: MeetingRecord, note: MeetingNote) async throws {
    switch connection.service {
    case .slack:
        try await postSlackMessage(connection: connection, text: slackText(markdown: webhookText(record: record, note: note)))
    case .teams:
        try await postTeamsMessage(connection: connection, html: notesHTML(record: record, note: note))
    case .discord:
        throw ChannelAuthError.invalidResponse(service: .discord, reason: "Discord bağlantısı webhook adresidir")
    }
}
