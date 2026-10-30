import Foundation
import Testing
@testable import AINotepadCore

private func sampleRecord() -> MeetingRecord {
    MeetingRecord(
        id: "w1", title: "Toplantı", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: Date(timeIntervalSince1970: 1_800_001_800),
        language: .finnish, status: .done, failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
        note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

private let sampleNote: MeetingNote = MeetingNote(
    title: "Bütçe toplantısı", summary: "Pazarlama bütçesi %10 artacak.", decisions: ["Bütçe artırılacak."],
    tasks: [NoteTask(owner: "Senol", description: "Sunumu hazırlamak", dueDate: "Perşembe", isMine: true)], glossary: []
)

@Suite struct WebhookTests {
    // Servis adresten tanınır; geçersiz ya da şifresiz adres reddedilir.
    @Test func kindAndURLValidation() throws {
        #expect(webhookKind(url: try webhookURL(text: "https://hooks.slack.com/services/T/B/x")) == .slack)
        #expect(webhookKind(url: try webhookURL(text: "https://discord.com/api/webhooks/1/abc")) == .discord)
        #expect(webhookKind(url: try webhookURL(text: "https://prod-12.westeurope.logic.azure.com/workflows/x")) == .teams)
        #expect(webhookKind(url: try webhookURL(text: "https://hooks.zapier.com/hooks/catch/1/x")) == .generic)
        #expect(throws: WebhookError.invalidURL) { try webhookURL(text: "http://example.com/hook") }
        #expect(throws: WebhookError.invalidURL) { try webhookURL(text: "kopyala yapıştır") }
    }

    // Her servise kendi biçimi: Slack tek yıldızlı kalın, Teams Adaptive Card, genel webhook'ta yapılandırılmış toplantı.
    @Test func payloadShapes() throws {
        let slack: [String: String] = try JSONDecoder().decode([String: String].self, from: webhookPayload(kind: .slack, record: sampleRecord(), note: sampleNote, appName: "Gistsmith"))
        #expect(slack["text"]?.contains("*Bütçe toplantısı*") == true && slack["text"]?.contains("**") == false)
        let teams: [String: Any] = try #require(JSONSerialization.jsonObject(with: webhookPayload(kind: .teams, record: sampleRecord(), note: sampleNote, appName: "Gistsmith")) as? [String: Any])
        let card: [String: Any] = try #require(((teams["attachments"] as? [[String: Any]])?.first?["content"]) as? [String: Any])
        #expect(card["type"] as? String == "AdaptiveCard")
        let generic: [String: Any] = try #require(JSONSerialization.jsonObject(with: webhookPayload(kind: .generic, record: sampleRecord(), note: sampleNote, appName: "Gistsmith")) as? [String: Any])
        let meeting: [String: Any] = try #require(generic["meeting"] as? [String: Any])
        #expect(meeting["durationMinutes"] as? Int == 30 && (meeting["tasks"] as? [[String: Any]])?.first?["isMine"] as? Bool == true)
        // Discord: uzun notta görevler kesilmez (önce gelir), etiketler kimseyi uyarmaz; Slack'te <!channel> kaçışlanır.
        let long: MeetingNote = MeetingNote(
            title: "T", summary: "@everyone " + String(repeating: "a", count: 5000), decisions: [],
            tasks: [NoteTask(owner: "Senol", description: "Sunumu hazırlamak", dueDate: nil, isMine: true)], glossary: []
        )
        let discord: [String: Any] = try #require(JSONSerialization.jsonObject(with: webhookPayload(kind: .discord, record: sampleRecord(), note: long, appName: "Gistsmith")) as? [String: Any])
        let content: String = try #require(discord["content"] as? String)
        #expect(content.count <= 2000 && content.contains("Sunumu hazırlamak"))
        #expect((discord["allowed_mentions"] as? [String: [String]])?["parse"] == [])
        #expect(discord["username"] as? String == "Gistsmith")
        let injected: MeetingNote = MeetingNote(title: "T", summary: "<!channel> A & B", decisions: [], tasks: [], glossary: [])
        let slackInjected: [String: String] = try JSONDecoder().decode([String: String].self, from: webhookPayload(kind: .slack, record: sampleRecord(), note: injected, appName: "Gistsmith"))
        #expect(slackInjected["text"]?.contains("&lt;!channel&gt; A &amp; B") == true)
    }
}

@Suite struct MeetingPageTests {
    // Paylaşılan sayfa: başlık, özet, görevler; HTML'e karışan metin kaçışlı (sayfayı bozamaz, betik çalıştıramaz).
    @Test func pageEscapesAndContainsSections() {
        let note: MeetingNote = MeetingNote(
            title: "Bütçe <script>alert(1)</script>", summary: "A & B", decisions: ["Karar"],
            tasks: [NoteTask(owner: "Senol", description: "Sunum", dueDate: "Perşembe", isMine: true)], glossary: []
        )
        let html: String = meetingHTML(record: sampleRecord(), note: note, language: nil, appName: "Gistsmith")
        #expect(html.contains("&lt;script&gt;") && !html.contains("<script>"))
        #expect(html.contains("<footer>Gistsmith</footer>"))
        #expect(html.contains("A &amp; B") && html.contains("Senol") && html.contains("Perşembe"))
        #expect(meetingHTML(record: sampleRecord(), note: note, language: .german, appName: "AI-Notepad").contains("Entscheidungen"))
    }

    // Sayfanın dili notun dilidir; sağdan sola dillerde sayfa `dir="rtl"`; çeviride konu akışı ve sözlük o dilin
    // başlıklarıyla kalır.
    @Test func pageLanguageDirectionAndTranslatedSections() {
        let note: MeetingNote = MeetingNote(
            title: "Budget", summary: "S", decisions: [], tasks: [], glossary: [GlossaryEntry(term: "budjetti", meaning: "Budget")]
        ).with(outline: [OutlineItem(startSec: 5, title: "Opening", summary: "Hello.")]).with(language: .english)
        let original: String = meetingHTML(record: sampleRecord(), note: note, language: nil, appName: "Gistsmith")
        #expect(original.contains("<html lang=\"en\">"))
        let arabic: String = meetingHTML(record: sampleRecord(), note: note, language: .arabic, appName: "Gistsmith")
        #expect(arabic.contains("<html lang=\"ar\" dir=\"rtl\">"))
        let german: String = meetingHTML(record: sampleRecord(), note: note, language: .german, appName: "Gistsmith")
        #expect(german.contains("Themenverlauf") && german.contains("Opening") && german.contains("Glossar") && german.contains("budjetti"))
    }
}

/// Gerçek HTTP: `AINOTEPAD_WEBHOOK_TEST_URL` (ör. yerel bir dinleyici) verilmişse genel webhook gövdesi gönderilir.
let webhookTestURL: String? = ProcessInfo.processInfo.environment["AINOTEPAD_WEBHOOK_TEST_URL"]

@Suite(.enabled(if: webhookTestURL != nil))
struct WebhookLiveTests {
    @Test func postsToRealEndpoint() async throws {
        let url: URL = try webhookURL(text: try #require(webhookTestURL))
        try await sendWebhook(url: url, payload: webhookPayload(kind: webhookKind(url: url), record: sampleRecord(), note: sampleNote, appName: "Gistsmith"))
    }

    // Reddeden sunucu: hata sunucu adı ve durum koduyla, adres (gizli anahtar) olmadan.
    @Test func rejectionReportsHostAndStatus() async throws {
        let url: URL = try webhookURL(text: try #require(webhookTestURL)).appending(path: "reddet")
        await #expect(throws: WebhookError.self) {
            try await sendWebhook(url: url, payload: Data("{}".utf8))
        }
    }
}

@Suite struct DestinationTests {
    // Notlar betiği kaçışlı; klasöre yazılan dosya adı güvenli ve dosya gerçekten yazılır.
    @Test func notesAndFolder() throws {
        let note: MeetingNote = MeetingNote(title: "Bütçe \"Q4\" <taslak>", summary: "A & B", decisions: ["Karar"], tasks: [], glossary: [])
        let html: String = notesHTML(record: sampleRecord(), note: note)
        #expect(html.contains("&lt;taslak&gt;") && html.contains("A &amp; B"))
        let script: String = appleNotesScript(html: html, folder: "Gistsmith")
        #expect(script.contains("{body:\"<h1>Bütçe \\\"Q4\\\""))
        #expect(script.contains("make new note at folder \"Gistsmith\""))
        let record: MeetingRecord = sampleRecord().with(note: MeetingNote(title: "Plan: Q4/2026?", summary: "Özet", decisions: [], tasks: [], glossary: []))
        #expect(markdownFileName(record: record).hasSuffix(" Plan  Q4 2026.md"))
        let folder: URL = try temporaryDirectory()
        let file: URL = try exportMarkdown(record: record, folder: folder)
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("# Plan: Q4/2026?"))
    }

    // Başlık değişince klasörde toplantının tek dosyası kalır (eski adlı kopya silinir); aynı dakikadaki başka dosyaya
    // (kullanıcının ya da başka toplantının) dokunulmaz.
    @Test func renamedMeetingKeepsOneFolderCopy() throws {
        let folder: URL = try temporaryDirectory()
        let record: MeetingRecord = sampleRecord().with(note: MeetingNote(title: "Taslak", summary: "Özet", decisions: [], tasks: [], glossary: []))
        let first: URL = try exportMarkdown(record: record, folder: folder)
        let foreign: URL = folder.appending(path: first.lastPathComponent.replacing("Taslak", with: "Kendi notum"))
        try Data("# Kendi notum".utf8).write(to: foreign)
        let renamed: URL = try exportMarkdown(record: record.with(title: "Bütçe planı"), folder: folder)
        let names: Set<String> = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(names == [renamed.lastPathComponent, foreign.lastPathComponent])
        #expect(String(decoding: try Data(contentsOf: renamed), as: UTF8.self).contains("# Bütçe planı"))
    }
}

@Suite struct ChannelAuthTests {
    // RFC 7636 ek B örneği; giriş adresleri PKCE ve servise özgü izinlerle; dönüşte hata, state ve kod denetlenir.
    @Test func pkceAuthorizeAndCallback() throws {
        #expect(pkceChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let pkce: PKCEPair = makePKCEPair()
        #expect(pkce.verifier.count == 43 && pkce.challenge == pkceChallenge(verifier: pkce.verifier))
        let query: (ChannelService) throws -> [String: String] = { (service: ChannelService) throws -> [String: String] in
            let url: URL = channelAuthorizeURL(service: service, clientID: "kimlik", pkce: pkce, state: "s1")
            let items: [URLQueryItem] = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        }
        let slack: [String: String] = try query(.slack)
        #expect(slack["user_scope"] == "chat:write,channels:read,groups:read" && slack["scope"] == nil)
        #expect(slack["redirect_uri"] == "com.senoldogan.ainotepad://oauth/slack" && slack["code_challenge_method"] == "S256" && slack["state"] == "s1")
        #expect(try query(.discord)["scope"] == "webhook.incoming")
        #expect(try query(.teams)["scope"]?.contains("ChannelMessage.Send") == true)
        let callback: (String) -> URL = { (query: String) -> URL in URL(string: "com.senoldogan.ainotepad://oauth/slack?\(query)")! }
        #expect(try oauthCallbackCode(service: .slack, url: callback("code=abc&state=s1"), expectedState: "s1") == "abc")
        #expect(throws: ChannelAuthError.stateMismatch(service: .slack)) {
            try oauthCallbackCode(service: .slack, url: callback("code=abc&state=baska"), expectedState: "s1")
        }
        #expect(throws: ChannelAuthError.denied(service: .slack, reason: "access_denied")) {
            try oauthCallbackCode(service: .slack, url: callback("error=access_denied&state=s1"), expectedState: "s1")
        }
        #expect(String(decoding: formBody(fields: [("a", "x y&z"), ("redirect_uri", "ainotepad://oauth/slack")]), as: UTF8.self)
            == "a=x%20y%26z&redirect_uri=ainotepad%3A%2F%2Foauth%2Fslack")
        #expect(graphPathComponent(id: "19:abc@thread.tacv2") == "19:abc@thread.tacv2")
        #expect(graphPathComponent(id: "a/b?c") == "a%2Fb%3Fc")
    }

    // Slack jetonu ilk girişte `authed_user` içinde, yenilemede üst düzeyde gelir; oturum hataları yeniden bağlanmaya
    // yönlendirir; bağlantı Anahtar Zinciri metnine çevrilip geri okunur.
    @Test func slackTokensAndConnectionStorage() throws {
        let now: Date = Date(timeIntervalSince1970: 1_800_000_000)
        let first: SlackTokenResponse = try JSONDecoder().decode(SlackTokenResponse.self, from: Data(#"""
        {"ok":true,"authed_user":{"id":"U1","access_token":"xoxe.xoxp-1","refresh_token":"xoxe-1-r","expires_in":43200,"token_type":"user"},"team":{"id":"T1","name":"Ekip"}}
        """#.utf8))
        #expect(try slackTokens(response: first, now: now) == OAuthTokens(accessToken: "xoxe.xoxp-1", refreshToken: "xoxe-1-r", expiresAt: now.addingTimeInterval(43200)))
        let refreshed: SlackTokenResponse = try JSONDecoder().decode(SlackTokenResponse.self, from: Data(#"""
        {"ok":true,"access_token":"xoxe.xoxp-2","refresh_token":"xoxe-1-r2","expires_in":43200,"token_type":"user"}
        """#.utf8))
        #expect(try slackTokens(response: refreshed, now: now).refreshToken == "xoxe-1-r2")
        let failed: SlackTokenResponse = try JSONDecoder().decode(SlackTokenResponse.self, from: Data(#"{"ok":false,"error":"invalid_refresh_token"}"#.utf8))
        #expect(throws: ChannelAuthError.expired(service: .slack)) { try slackTokens(response: failed, now: now) }
        #expect(slackAPIError(code: "not_in_channel") == .api(service: .slack, error: "not_in_channel"))
        let connection: ChannelConnection = ChannelConnection(
            service: .teams, tokens: OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: now), workspace: "",
            channel: ChannelOption(id: "19:x@thread.tacv2", teamID: "t", name: "Takım › Genel")
        )
        #expect(try decodeChannelConnection(text: try encodeChannelConnection(connection: connection)) == connection)
        #expect(needsRefresh(tokens: connection.tokens, now: now.addingTimeInterval(-60)))
        #expect(!needsRefresh(tokens: connection.tokens, now: now.addingTimeInterval(-600)))
    }
}

@Suite struct ZoomWebhookTests {
    // Zoom adresi tam biçimle, anahtar parçada; tür tanınır; anahtarsız ya da başka adres reddedilir.
    @Test func zoomAddressAndPayload() throws {
        let url: URL = try zoomWebhookURL(address: " https://integrations.zoom.us/chat/webhooks/incomingwebhook/abc123 ", token: " gizli ")
        #expect(webhookKind(url: url) == .zoom)
        #expect(url.query() == "format=full" && url.fragment() == "gizli")
        #expect(throws: WebhookError.invalidURL) { try zoomWebhookURL(address: "https://integrations.zoom.us/chat/webhooks/incomingwebhook/abc", token: " ") }
        #expect(throws: WebhookError.invalidURL) { try zoomWebhookURL(address: "https://hooks.slack.com/services/x", token: "t") }
        let note: MeetingNote = MeetingNote(title: "Plan", summary: "Özet", decisions: [], tasks: [], glossary: [])
        let json: String = String(decoding: try webhookPayload(kind: .zoom, record: sampleRecord(), note: note, appName: "Gistsmith"), as: UTF8.self)
        #expect(json.contains(#""head":{"text":"Plan"}"#) && json.contains(#""type":"message""#))
    }
}
