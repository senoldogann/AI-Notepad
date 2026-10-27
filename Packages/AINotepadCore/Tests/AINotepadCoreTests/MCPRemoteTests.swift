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
        let tools: [MCPRemoteTool] = ["create_issue", "list_teams", "delete_issue", "update_issue", "search_documentation", "createJiraIssue", "getAccessibleAtlassianResources", "deleteJiraIssue"]
            .compactMap { MCPRemoteTool(json: .object(["name": .string($0)])) }
        #expect(trackerAgentTools(tools: tools, service: .linear).map(\.name) == ["create_issue", "list_teams", "createJiraIssue"])
        #expect(trackerAgentTools(tools: tools, service: .atlassian).map(\.name) == ["create_issue", "createJiraIssue", "getAccessibleAtlassianResources"])
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
