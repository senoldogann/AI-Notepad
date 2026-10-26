import Foundation
import Testing

/// Uygulamanın String Catalog'u (kaynak dil Türkçe).
private func catalogURL(name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "App/\(name)")
}

/// Metindeki yer tutucular, sırayla (`%@`, `%lld`…).
private func placeholders(text: String) -> [String] {
    let pattern: Regex = /%(?:\d+\$)?(?:lld|ld|d|@|lf|f)/
    return text.matches(of: pattern).map { String($0.output) }
}

@Suite struct LocalizationCatalogTests {
    // Her arayüz metninin İngilizcesi var ve yer tutucuları kaynakla aynı (eksik ya da fazla %@ çökmeye yol açar).
    @Test func everyStringHasEnglishWithMatchingPlaceholders() throws {
        let data: Data = try Data(contentsOf: catalogURL(name: "Localizable.xcstrings"))
        let catalog: [String: Any] = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["sourceLanguage"] as? String == "tr")
        let strings: [String: Any] = try #require(catalog["strings"] as? [String: Any])
        #expect(strings.count > 300)
        for (key, entry) in strings {
            let english: String? = ((((entry as? [String: Any])?["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            let value: String = try #require(english, "İngilizcesi yok: \(key)")
            #expect(!value.isEmpty, "boş çeviri: \(key)")
            #expect(placeholders(text: value) == placeholders(text: key), "yer tutucular farklı: \(key)")
        }
    }
}
