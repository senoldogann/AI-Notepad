import Foundation
import Testing

/// Deponun kökü (bu dosya `Packages/AINotepadCore/Tests/AINotepadUITests` içinde).
private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

/// Denetlenen String Catalog'lar (kaynak dil Türkçe), depo köküne göre yol: ortak metinler, iki Mac sürümünün Info.plist
/// katalogları ve iPhone kısayolları; iOS'un Info.plist kataloğu varsa o da.
private func catalogPaths() -> [String] {
    let fixed: [String] = ["App/Localizable.xcstrings", "App/InfoPlist.xcstrings", "App/Hosted/InfoPlist.xcstrings", "iOS/AppShortcuts.xcstrings"]
    let optional: String = "iOS/InfoPlist.xcstrings"
    let hasOptional: Bool = FileManager.default.fileExists(atPath: repositoryRoot().appending(path: optional).path)
    return hasOptional ? fixed + [optional] : fixed
}

/// Metindeki yer tutucular, sırayla (`%@`, `%lld`…, App Intents'in `${applicationName}` gibi adlı olanları da).
private func placeholders(text: String) -> [String] {
    let pattern: Regex = /%(?:\d+\$)?(?:lld|ld|d|@|lf|f)|\$\{[A-Za-z]+\}/
    return text.matches(of: pattern).map { String($0.output) }
}

/// Girdinin verilen dildeki çevirileri: düz çeviri tek metindir, tekil/çoğul biçimli çeviride her biçim ayrı metindir
/// (ör. "1 meeting left", "3 meetings left"); çeviri yoksa boş.
private func translations(entry: [String: Any], language: String) -> [String] {
    guard let localization = (entry["localizations"] as? [String: Any])?[language] as? [String: Any] else {
        return []
    }
    if let value = (localization["stringUnit"] as? [String: Any])?["value"] as? String {
        return [value]
    }
    let plural: [String: Any] = ((localization["variations"] as? [String: Any])?["plural"] as? [String: Any]) ?? [:]
    return plural.keys.sorted().compactMap { (form: String) -> String? in
        ((plural[form] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
    }
}

@Suite struct LocalizationCatalogTests {
    // Her arayüz metninin İngilizcesi var ve yer tutucuları kaynakla aynı (eksik ya da fazla %@ çökmeye yol açar).
    // Kaynak metin Türkçe çeviri varsa odur (Info.plist kataloğunda anahtar bir plist adıdır), yoksa anahtarın kendisi.
    @Test(arguments: catalogPaths())
    func everyStringHasEnglishWithMatchingPlaceholders(path: String) throws {
        let data: Data = try Data(contentsOf: repositoryRoot().appending(path: path))
        let catalog: [String: Any] = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["sourceLanguage"] as? String == "tr", "kaynak dil Türkçe değil: \(path)")
        let strings: [String: Any] = try #require(catalog["strings"] as? [String: Any])
        #expect(!strings.isEmpty, "boş katalog: \(path)")
        for (key, value) in strings {
            let entry: [String: Any] = try #require(value as? [String: Any], "bozuk girdi: \(path) › \(key)")
            // Çevrilmeyecek işaretli metinler (ör. uygulama adı) atlanır.
            if entry["shouldTranslate"] as? Bool == false {
                continue
            }
            let english: [String] = translations(entry: entry, language: "en")
            let source: String = translations(entry: entry, language: "tr").first ?? key
            #expect(!english.isEmpty, "İngilizcesi yok: \(path) › \(key)")
            for text in english {
                #expect(!text.isEmpty, "boş çeviri: \(path) › \(key)")
                #expect(placeholders(text: text) == placeholders(text: source), "yer tutucular farklı: \(path) › \(key) › \(text)")
            }
        }
    }

    // "stale" girdi kalmaz. Xcode yalnızca uygulama hedefinin kodunu tarar; paketteki (AINotepadCore/UI) metinleri
    // görmediği için onları "stale" sanar ve "eskileri temizle" denince siler, İngilizce arayüz bozulur. Paketin
    // kullandığı girdiler "manual", gerçekten kullanılmayanlar silinmiş olmalı.
    @Test func mainCatalogHasNoStaleEntries() throws {
        let data: Data = try Data(contentsOf: repositoryRoot().appending(path: "App/Localizable.xcstrings"))
        let catalog: [String: Any] = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings: [String: Any] = try #require(catalog["strings"] as? [String: Any])
        let stale: [String] = strings.compactMap { (key: String, value: Any) -> String? in
            (value as? [String: Any])?["extractionState"] as? String == "stale" ? key : nil
        }
        #expect(stale.isEmpty, "stale girdiler (kullanılıyorsa \"manual\" yap, kullanılmıyorsa sil): \(stale.sorted())")
    }

    // Uygulamanın ana kataloğu gerçekten dolu (yanlış dosya okunmasın).
    @Test func mainCatalogIsPopulated() throws {
        let data: Data = try Data(contentsOf: repositoryRoot().appending(path: "App/Localizable.xcstrings"))
        let catalog: [String: Any] = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings: [String: Any] = try #require(catalog["strings"] as? [String: Any])
        #expect(strings.count > 300)
    }
}
