import Foundation
import Testing
@testable import AINotepadCore

@Suite struct MCPRemoteParsingTests {
    // SSE akışında bildirimler atlanır, istenen kimlikli sonuç bulunur; JSON-RPC hatası açık hataya dönüşür.
    @Test func jsonRPCFromEventStream() throws {
        let body: String = """
        event: message
        data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}

        event: message
        data: {"jsonrpc":"2.0","id":7,"result":{"tools":[]}}
        """.replacing("\n", with: "\r\n")
        #expect(try jsonRPCResponse(body: body, contentType: "text/event-stream", id: 7, server: "s") == .object(["tools": .array([])]))
        #expect(throws: MCPRemoteError.rpc(server: "s", code: -32601, message: "yok")) {
            try jsonRPCResponse(body: #"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"yok"}}"#, contentType: "application/json", id: 3, server: "s")
        }
    }

    // OAuth keşif adresleri ve yerel dönüş isteğinin ayrıştırılması.
    @Test func discoveryAndLoopbackParsing() throws {
        #expect(resourceMetadataURL(wwwAuthenticate: #"Bearer error="invalid_token", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource""#)?.absoluteString
            == "https://mcp.example.com/.well-known/oauth-protected-resource")
        #expect(wellKnownResourceMetadataURL(server: URL(string: "https://mcp.linear.app/mcp")!)?.absoluteString
            == "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp")
        #expect(authorizationMetadataURLs(issuer: URL(string: "https://auth.example.com")!).map(\.absoluteString)
            == ["https://auth.example.com/.well-known/oauth-authorization-server", "https://auth.example.com/.well-known/openid-configuration"])
        let url: URL? = callbackURL(request: "GET /callback?code=abc&state=s1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", redirectURI: "http://127.0.0.1:5555/callback")
        #expect(url?.absoluteString == "http://127.0.0.1:5555/callback?code=abc&state=s1")
        #expect(try mcpCallbackCode(url: try #require(url), expectedState: "s1", server: "x") == "abc")
        #expect(callbackURL(request: "GET /favicon.ico HTTP/1.1\r\n", redirectURI: "http://127.0.0.1:5555/callback") == nil)
        #expect(callbackURL(request: "GET /callback HTTP/1.1\r\n", redirectURI: "http://127.0.0.1:5555/callback")?.absoluteString == "http://127.0.0.1:5555/callback")
        #expect(throws: MCPRemoteError.denied(server: "x", reason: "access_denied")) {
            try mcpCallbackCode(url: URL(string: "http://127.0.0.1:1/callback?error=access_denied&state=s1")!, expectedState: "s1", server: "x")
        }
    }

    // Notion sayfası: başlık özellikte, içerikte tekrar edilmez; ajan yalnızca iş açma araçlarını görür.
    @Test func notionArgumentsAndAgentToolFilter() {
        let record: MeetingRecord = MeetingRecord(
            id: "m", title: "T", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil, language: nil, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let note: MeetingNote = MeetingNote(title: "Bütçe", summary: "Özet metni", decisions: [], tasks: [], glossary: [])
        guard case .object(let root) = notionPageArguments(record: record, note: note), case .array(let pages) = root["pages"],
              case .object(let page) = pages.first, case .string(let content) = page["content"] else {
            Issue.record("biçim")
            return
        }
        #expect(page["properties"] == .object(["title": .string("Bütçe")]))
        #expect(!content.hasPrefix("# Bütçe") && content.contains("Özet metni"))
        // Yalnızca izin listesindeki araçlar: düzenleme, yorum, iş kaydı, bağlantı, proje/etiket oluşturma görünmez.
        let tools: [MCPRemoteTool] = [
            "create_issue", "save_issue", "list_teams", "update_issue", "create_project", "create_issue_label", "create_comment",
            "createJiraIssue", "getAccessibleAtlassianResources", "editJiraIssue", "addCommentToJiraIssue", "addWorklogToJiraIssue", "createIssueLink",
        ]
        .compactMap { MCPRemoteTool(json: .object(["name": .string($0)])) }
        #expect(trackerAgentTools(tools: tools, service: .linear).map(\.name) == ["create_issue", "save_issue", "list_teams"])
        #expect(trackerAgentTools(tools: tools, service: .atlassian).map(\.name) == ["createJiraIssue", "getAccessibleAtlassianResources"])
        // Kimlik taşıyan argüman var olan öğeyi günceller: iş açarken reddedilir.
        #expect(referencesExistingItem(arguments: .object(["id": .string("LIN-1"), "title": .string("x")])))
        #expect(referencesExistingItem(arguments: .object(["issueIdOrKey": .string("PROJ-1")])))
        #expect(!referencesExistingItem(arguments: .object(["title": .string("x"), "team": .string("Eng")])))
    }

    // SSE'de bir olayın birden çok data satırı birleşir.
    @Test func multiLineEventData() throws {
        let body: String = "event: message\ndata: {\"jsonrpc\":\"2.0\",\ndata: \"id\":4,\"result\":{}}\n\n"
        #expect(serverSentEventData(body: body) == ["{\"jsonrpc\":\"2.0\",\n\"id\":4,\"result\":{}}"])
        #expect(try jsonRPCResponse(body: body, contentType: "text/event-stream", id: 4, server: "s") == .object([:]))
    }

    // Yerel dönüş: yalnızca tam /callback yolu ve bu girişin state'i kabul edilir; başkaları dinlemeyi bitirmez.
    @Test func loopbackAcceptsOnlyThisSignIn() {
        let redirect: String = "http://127.0.0.1:5555/callback"
        #expect(loopbackDecision(request: "GET /favicon.ico HTTP/1.1\r\n", redirectURI: redirect, expectedState: "s1") == .notFound)
        #expect(loopbackDecision(request: "GET /callbackXYZ?state=s1 HTTP/1.1\r\n", redirectURI: redirect, expectedState: "s1") == .notFound)
        #expect(loopbackDecision(request: "GET /callback?code=c&state=evil HTTP/1.1\r\n", redirectURI: redirect, expectedState: "s1") == .foreign)
        #expect(loopbackDecision(request: "GET /callback?code=c&state=s1 HTTP/1.1\r\n", redirectURI: redirect, expectedState: "s1")
            == .completed(url: URL(string: "http://127.0.0.1:5555/callback?code=c&state=s1")!, granted: true))
        #expect(loopbackDecision(request: "GET /callback?error=access_denied&state=s1 HTTP/1.1\r\n", redirectURI: redirect, expectedState: "s1")
            == .completed(url: URL(string: "http://127.0.0.1:5555/callback?error=access_denied&state=s1")!, granted: false))
        #expect(loopbackResponse(decision: .foreign).hasPrefix("HTTP/1.1 400"))
    }

    // Keşif denetimi: kaynak bu sunucu, issuer bilginin alındığı kimlik ve tüm adresler https olmalı.
    @Test func discoveryValidation() throws {
        let server: URL = URL(string: "https://mcp.example.com/mcp")!
        let issuer: URL = URL(string: "https://auth.example.com")!
        let resource: ProtectedResourceMetadata = ProtectedResourceMetadata(resource: "https://mcp.example.com/mcp", authorizationServers: [issuer])
        let good: AuthorizationServerMetadata = try JSONDecoder().decode(AuthorizationServerMetadata.self, from: Data(#"{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/a","token_endpoint":"https://auth.example.com/t"}"#.utf8))
        try validateDiscovery(resource: resource, issuer: issuer, metadata: good, server: server)
        let otherIssuer: AuthorizationServerMetadata = try JSONDecoder().decode(AuthorizationServerMetadata.self, from: Data(#"{"issuer":"https://evil.example","authorization_endpoint":"https://auth.example.com/a","token_endpoint":"https://auth.example.com/t"}"#.utf8))
        #expect(throws: MCPRemoteError.self) { try validateDiscovery(resource: resource, issuer: issuer, metadata: otherIssuer, server: server) }
        let insecure: AuthorizationServerMetadata = try JSONDecoder().decode(AuthorizationServerMetadata.self, from: Data(#"{"issuer":"https://auth.example.com","authorization_endpoint":"file:///Applications/X.app","token_endpoint":"https://auth.example.com/t"}"#.utf8))
        #expect(throws: MCPRemoteError.self) { try validateDiscovery(resource: resource, issuer: issuer, metadata: insecure, server: server) }
        let otherResource: ProtectedResourceMetadata = ProtectedResourceMetadata(resource: "https://other.example.com/mcp", authorizationServers: [issuer])
        #expect(throws: MCPRemoteError.self) { try validateDiscovery(resource: otherResource, issuer: issuer, metadata: good, server: server) }
    }
}

extension CloudTests {
/// Gerçek sunucular: Notion, Linear ve Atlassian'ın uzak MCP'si kimliksiz istekte OAuth keşfini (RFC 9728/8414) ve
/// dinamik istemci kaydını sunar; herkese açık bir MCP sunucusunda oturum, araç listesi ve araç çağrısı çalışır.
@Suite struct MCPRemoteLiveTests {
    @Test(arguments: MCPService.allCases)
    func officialServersOfferDynamicRegistration(service: MCPService) async throws {
        let metadata: AuthorizationServerMetadata = try await discoverAuthorization(server: service.serverURL)
        #expect(metadata.registrationEndpoint != nil, "\(service.rawValue): kayıt adresi yok")
        #expect(metadata.authorizationEndpoint.scheme == "https" && metadata.tokenEndpoint.scheme == "https")
    }

    @Test func publicServerSessionListsAndCallsTools() async throws {
        let session: MCPRemoteSession = try await MCPRemoteSession.open(serverURL: URL(string: "https://mcp.deepwiki.com/mcp")!, accessToken: "")
        let tools: [MCPRemoteTool] = try await session.listTools()
        #expect(!tools.isEmpty)
        let structure: String = try await session.callTool(name: "read_wiki_structure", arguments: .object(["repoName": .string("modelcontextprotocol/swift-sdk")]))
        #expect(!structure.isEmpty)
    }
}
}
