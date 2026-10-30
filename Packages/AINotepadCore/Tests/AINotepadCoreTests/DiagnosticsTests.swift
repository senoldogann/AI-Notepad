import AINotepadCore
import Foundation
import Testing

@Suite struct DiagnosticsTests {
    // Tanılamaya yol, e-posta, jeton, API anahtarı ve kullanıcı adı girmez; mesaj kısa kalır.
    @Test func redactsPersonalAndSecretParts() {
        let text: String = "Dosya yazılamadı: /Users/ayse/Library/Application Support/AINotepad/x.json, ayse@ornek.com, "
            + "Bearer abc.def, eyJhbGciOi.eyJzdWIiOjF9.c2ln, sk-ant-api03-AbCdEf0123456789xyz, sk_0123456789abcdef0123, Ayşe Yılmaz"
        let redacted: String = redactedDiagnosticText(text: text, userNames: ["ayse", "Ayşe Yılmaz", "a"])
        #expect(!redacted.contains("/Users"))
        #expect(!redacted.contains("ornek.com"))
        #expect(!redacted.contains("abc.def"))
        #expect(!redacted.contains("eyJ"))
        #expect(!redacted.contains("sk-ant") && !redacted.contains("sk_0123"))
        #expect(!redacted.contains("Ayşe Yılmaz"))
        #expect(redacted.contains("‹yol›") && redacted.contains("‹e-posta›") && redacted.contains("‹jeton›") && redacted.contains("‹anahtar›"))
        #expect(redactedDiagnosticText(text: String(repeating: "x", count: 500), userNames: []).count == diagnosticMessageMaxLength)
    }

    // Son hatalar en yeni 50 tanedir, eskiden yeniye.
    @Test func keepsNewestErrors() {
        let entries: [DiagnosticErrorEntry] = (0..<60).reversed().map { (index: Int) -> DiagnosticErrorEntry in
            DiagnosticErrorEntry(date: Date(timeIntervalSince1970: Double(index)), code: "c", message: "\(index)")
        }
        let recent: [DiagnosticErrorEntry] = recentDiagnosticErrors(entries: entries, capacity: diagnosticErrorCapacity)
        #expect(recent.count == 50)
        #expect(recent.first?.message == "10")
        #expect(recent.last?.message == "59")
    }

    // Geri bildirime eklenen tanılama sunucunun mesaj sınırına sığdırılır; kullanıcının mesajı kısaltılmaz.
    @Test func diagnosticsFitFeedbackLimit() throws {
        let report: ReportRequest = try feedbackReport(message: "Merhaba", email: "", diagnostics: nil)
        let long: String = diagnosticsText(
            sections: [DiagnosticsSection(title: "Uygulama", items: (0..<500).map { DiagnosticsItem(label: "satır \($0)", value: "değer") })],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let appended: ReportRequest = try appendingDiagnostics(report: report, diagnosticsText: long, limit: reportMessageLimit)
        let message: String = try #require(appended.message)
        #expect(message.hasPrefix("Merhaba"))
        #expect(reportMessageLength(text: message) <= reportMessageLimit)
        #expect(message.hasSuffix("…"))
        let full: ReportRequest = try feedbackReport(message: String(repeating: "x", count: reportMessageLimit), email: "", diagnostics: nil)
        #expect(throws: ReportError.self) { try appendingDiagnostics(report: full, diagnosticsText: long, limit: reportMessageLimit) }
    }

    // Güncelleme kartı: sürüm notlarının maddeleri sırayla, işaretsiz ve sınırlı; başlık ve paragraflar atlanır.
    @Test func releaseNoteBulletsFromMarkdown() {
        let notes: String = "Intro line.\n\n## What's new\n- **Faster.** Words appear sooner.\n- Import a file.\n\n## Fixes\n* Fewer sign-outs.\n-   \n"
        #expect(releaseNoteBullets(markdown: notes, limit: 10) == ["**Faster.** Words appear sooner.", "Import a file.", "Fewer sign-outs."])
        #expect(releaseNoteBullets(markdown: notes, limit: 2).count == 2)
        #expect(releaseNoteBullets(markdown: "No bullets here.", limit: 4).isEmpty)
    }
}
