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
        let slack: [String: String] = try JSONDecoder().decode([String: String].self, from: webhookPayload(kind: .slack, record: sampleRecord(), note: sampleNote))
        #expect(slack["text"]?.contains("*Bütçe toplantısı*") == true && slack["text"]?.contains("**") == false)
        let teams: [String: Any] = try #require(JSONSerialization.jsonObject(with: webhookPayload(kind: .teams, record: sampleRecord(), note: sampleNote)) as? [String: Any])
        let card: [String: Any] = try #require(((teams["attachments"] as? [[String: Any]])?.first?["content"]) as? [String: Any])
        #expect(card["type"] as? String == "AdaptiveCard")
        let generic: [String: Any] = try #require(JSONSerialization.jsonObject(with: webhookPayload(kind: .generic, record: sampleRecord(), note: sampleNote)) as? [String: Any])
        let meeting: [String: Any] = try #require(generic["meeting"] as? [String: Any])
        #expect(meeting["durationMinutes"] as? Int == 30 && (meeting["tasks"] as? [[String: Any]])?.first?["isMine"] as? Bool == true)
        // Discord: uzun notta görevler kesilmez (önce gelir), etiketler kimseyi uyarmaz; Slack'te <!channel> kaçışlanır.
        let long: MeetingNote = MeetingNote(
            title: "T", summary: "@everyone " + String(repeating: "a", count: 5000), decisions: [],
            tasks: [NoteTask(owner: "Senol", description: "Sunumu hazırlamak", dueDate: nil, isMine: true)], glossary: []
        )
        let discord: [String: Any] = try #require(JSONSerialization.jsonObject(with: webhookPayload(kind: .discord, record: sampleRecord(), note: long)) as? [String: Any])
        let content: String = try #require(discord["content"] as? String)
        #expect(content.count <= 2000 && content.contains("Sunumu hazırlamak"))
        #expect((discord["allowed_mentions"] as? [String: [String]])?["parse"] == [])
        let injected: MeetingNote = MeetingNote(title: "T", summary: "<!channel> A & B", decisions: [], tasks: [], glossary: [])
        let slackInjected: [String: String] = try JSONDecoder().decode([String: String].self, from: webhookPayload(kind: .slack, record: sampleRecord(), note: injected))
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
        let html: String = meetingHTML(record: sampleRecord(), note: note, language: nil)
        #expect(html.contains("&lt;script&gt;") && !html.contains("<script>"))
        #expect(html.contains("A &amp; B") && html.contains("Senol") && html.contains("Perşembe"))
        #expect(meetingHTML(record: sampleRecord(), note: note, language: .german).contains("Entscheidungen"))
    }
}

/// Gerçek HTTP: `AINOTEPAD_WEBHOOK_TEST_URL` (ör. yerel bir dinleyici) verilmişse genel webhook gövdesi gönderilir.
let webhookTestURL: String? = ProcessInfo.processInfo.environment["AINOTEPAD_WEBHOOK_TEST_URL"]

@Suite(.enabled(if: webhookTestURL != nil))
struct WebhookLiveTests {
    @Test func postsToRealEndpoint() async throws {
        let url: URL = try webhookURL(text: try #require(webhookTestURL))
        try await sendWebhook(url: url, payload: webhookPayload(kind: webhookKind(url: url), record: sampleRecord(), note: sampleNote))
    }

    // Reddeden sunucu: hata sunucu adı ve durum koduyla, adres (gizli anahtar) olmadan.
    @Test func rejectionReportsHostAndStatus() async throws {
        let url: URL = try webhookURL(text: try #require(webhookTestURL)).appending(path: "reddet")
        await #expect(throws: WebhookError.self) {
            try await sendWebhook(url: url, payload: Data("{}".utf8))
        }
    }
}
