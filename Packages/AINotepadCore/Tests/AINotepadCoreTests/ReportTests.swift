import Foundation
import Testing
@testable import AINotepadCore

@Suite struct ReportTests {
    // Geri bildirim kırpılır; boş e-posta ve istenmeyen tanılama gönderilmez; sınırlar ve e-posta kuralı sunucununkiyle aynı.
    @Test func feedbackReportValidation() throws {
        let diagnostics: ReportDiagnostics = ReportDiagnostics(appVersion: "0.1.3 (4)", os: "macOS Version 26.1 (Build 25B78)")
        #expect(try feedbackReport(message: "  Not yazılmadı.\n", email: " ", diagnostics: nil)
            == ReportRequest(kind: .feedback, message: "Not yazılmadı.", email: nil, appVersion: nil, os: nil, payload: nil))
        #expect(try feedbackReport(message: "Merhaba", email: "aino@ornek.fi", diagnostics: diagnostics)
            == ReportRequest(kind: .feedback, message: "Merhaba", email: "aino@ornek.fi", appVersion: "0.1.3 (4)", os: "macOS Version 26.1 (Build 25B78)", payload: nil))
        #expect(throws: ReportError.emptyMessage) { try feedbackReport(message: " \n", email: "", diagnostics: nil) }
        #expect(throws: ReportError.invalidEmail) { try feedbackReport(message: "x", email: "aino@ornek", diagnostics: nil) }
        #expect(throws: ReportError.invalidEmail) { try feedbackReport(message: "x", email: "a b@ornek.fi", diagnostics: nil) }
        // Sunucunun `z.email()` kuralı: ASCII yerel kısım, boş noktalı parça yok, alan adı harf/rakamla başlar, uzantı ≥ 2 harf.
        for rejected in ["doğan@ornek.fi", "a@b.c", "a..b@ornek.fi", "a@-x.fi", "\"a\"@x.com"] {
            #expect(throws: ReportError.invalidEmail) { try feedbackReport(message: "x", email: rejected, diagnostics: nil) }
        }
        #expect(isPlausibleEmail(text: "first.last+tag@sub.example.com"))
        #expect(try feedbackReport(message: String(repeating: "a", count: reportMessageLimit), email: "", diagnostics: nil).message?.count == reportMessageLimit)
        // Sunucu UTF-16 birimi sayar: emoji iki birimdir.
        #expect(throws: ReportError.messageTooLong(count: reportMessageLimit + 2, limit: reportMessageLimit)) {
            try feedbackReport(message: String(repeating: "a", count: reportMessageLimit) + "🙂", email: "", diagnostics: nil)
        }
        let encoded: [String: String] = try JSONDecoder().decode([String: String].self, from: try JSONEncoder().encode(try feedbackReport(message: "x", email: "", diagnostics: nil)))
        #expect(encoded == ["kind": "feedback", "message": "x"])
    }

    // Rapor sunucusu https olmalı.
    @Test func reportsBaseURLRequiresHTTPS() throws {
        #expect(try reportsAPIBaseURL(value: "https://api.gistsmith.com").absoluteString == "https://api.gistsmith.com")
        #expect(throws: HostedClientError.insecureBaseURL(url: "http://localhost:8787")) { try reportsAPIBaseURL(value: "http://localhost:8787") }
        #expect(throws: HostedClientError.invalidBaseURL(value: "")) { try reportsAPIBaseURL(value: "") }
    }
}
