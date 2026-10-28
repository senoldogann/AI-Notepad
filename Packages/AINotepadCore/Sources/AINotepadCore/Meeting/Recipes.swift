import Foundation

/// Tarif: Sor'da "/" ile çalıştırılan kayıtlı istem (Granola'daki "Recipes"). Seçili toplantılarla (`@`) ya da tüm
/// arşivle çalışır. Yerleşikler silinemez; kullanıcınınkiler kaydedilir.
public struct Recipe: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let prompt: String
    public let symbol: String
    public let isBuiltIn: Bool

    public init(id: String, title: String, prompt: String, symbol: String, isBuiltIn: Bool) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.symbol = symbol
        self.isBuiltIn = isBuiltIn
    }
}

/// Yerleşik tarifler (başlık ve istem arayüz dilinde; cevap not dilinde). Saf fonksiyondur.
public func builtInRecipes() -> [Recipe] {
    [
        Recipe(
            id: "takip-epostasi", title: String(localized: "Takip e-postası"),
            prompt: String(localized: "Bu toplantı için katılımcılara gönderilecek kısa bir takip e-postası taslağı yaz: teşekkür, alınan kararlar, kim neyi ne zamana yapacak ve sonraki adım. Konu satırıyla başla. E-postayı toplantının konuşulduğu dilde yaz."),
            symbol: "envelope", isBuiltIn: true
        ),
        Recipe(
            id: "aksiyonlar", title: String(localized: "Aksiyonları listele"),
            prompt: String(localized: "Tüm aksiyonları kişiye göre grupla: kim, ne, ne zamana. Bana düşenleri en üste koy; tarihi belirsiz olanları ayrıca belirt."),
            symbol: "checklist", isBuiltIn: true
        ),
        Recipe(
            id: "gune-hazirlan", title: String(localized: "Bugüne hazırlan"),
            prompt: String(localized: "Bugün ve yarın için hazırlan: son toplantılarda verdiğim sözler ve bana düşen açık işler, bekleyen kararlar ve takip etmem gereken kişiler. Kısa maddeler halinde, önceliğe göre."),
            symbol: "sun.max", isBuiltIn: true
        ),
        Recipe(
            id: "kararlar", title: String(localized: "Kararlar ve gerekçeleri"),
            prompt: String(localized: "Alınan kararları gerekçeleri ve kimin önerdiğiyle listele; ertelenen ya da tartışmalı kalan konuları ayrıca yaz."),
            symbol: "checkmark.seal", isBuiltIn: true
        ),
        Recipe(
            id: "proje-plani", title: String(localized: "Proje planı taslağı"),
            prompt: String(localized: "Konuşulanlardan bir proje planı taslağı çıkar: hedef, kapsam, aşamalar ve tarihleri, sorumlular, riskler ve açık sorular."),
            symbol: "list.bullet.rectangle", isBuiltIn: true
        ),
        Recipe(
            id: "riskler", title: String(localized: "Riskler ve açık sorular"),
            prompt: String(localized: "Toplantılarda dile getirilen riskleri, kaygıları ve yanıtsız kalan soruları listele; her biri için kimin gündeme getirdiğini yaz."),
            symbol: "exclamationmark.triangle", isBuiltIn: true
        ),
    ]
}

/// Soru alanı "/" ile başlıyorsa tarif araması ("/takip" → "takip"); değilse nil. Saf fonksiyondur.
public func recipeQuery(text: String) -> String? {
    guard text.hasPrefix("/"), !text.contains(where: \.isNewline), text.count <= 60 else {
        return nil
    }
    return String(text.dropFirst())
}

/// Başlığında aranan metin geçen tarifler (önce yerleşikler sırasıyla, sonra kullanıcınınkiler); boş aramada hepsi.
/// Saf fonksiyondur.
public func recipeCandidates(recipes: [Recipe], query: String) -> [Recipe] {
    let needle: String = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else {
        return recipes
    }
    return recipes.filter { looselyContains(text: $0.title, needle: needle) }
}

/// Büyük/küçük harf, aksan ve Türkçe ı/i farkı gözetmeden içerir mi ("SATIS" → "Satış"). Saf fonksiyondur.
public func looselyContains(text: String, needle: String) -> Bool {
    let fold: (String) -> String = { (value: String) -> String in
        value.replacing("ı", with: "i").replacing("İ", with: "I")
    }
    return fold(text).range(of: fold(needle), options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: nil) != nil
}

/// Sorudan yeni kullanıcı tarifi: başlık sorunun ilk altı kelimesi. Saf fonksiyondur.
public func recipeFromQuestion(question: String, id: String) -> Recipe {
    let words: [Substring] = question.split(whereSeparator: \.isWhitespace)
    let title: String = words.prefix(6).joined(separator: " ") + (words.count > 6 ? "…" : "")
    return Recipe(id: id, title: title, prompt: question, symbol: "bookmark", isBuiltIn: false)
}

/// Kullanıcı tariflerinin saklandığı ayar anahtarı.
public let userRecipesKey: String = "ask.recipes"

/// Kayıtlı kullanıcı tarifleri; kayıt yoksa boş, okunamıyorsa `StorageError.readFailed`.
public func loadUserRecipes(defaults: UserDefaults) throws -> [Recipe] {
    guard let data = defaults.data(forKey: userRecipesKey) else {
        return []
    }
    do {
        return try JSONDecoder().decode([Recipe].self, from: data)
    } catch {
        throw StorageError.readFailed(path: userRecipesKey, reason: error.localizedDescription)
    }
}

/// Kullanıcı tariflerini saklar.
public func saveUserRecipes(recipes: [Recipe], defaults: UserDefaults) throws {
    do {
        defaults.set(try JSONEncoder().encode(recipes.filter { !$0.isBuiltIn }), forKey: userRecipesKey)
    } catch {
        throw StorageError.writeFailed(path: userRecipesKey, reason: error.localizedDescription)
    }
}

/// Agent Skill dosyası (`SKILL.md`) okunamadı ya da biçimi beklenmedik.
public enum SkillImportError: Error, Equatable {
    /// Ön bilgi (`---` arasındaki `name` ve `description`) yok.
    case missingFrontMatter(file: String)
    /// Gövde boş: tarifte kullanılacak yönerge yok.
    case emptyBody(file: String)
}

/// Agent Skill (`SKILL.md`: `name`/`description` ön bilgisi ve Markdown yönergeler) tarif olur: başlık adın okunur hali,
/// istem açıklama ve yönergeler. Böylece Claude ve diğer araçlar için yazılmış beceriler Sor'da "/" ile kullanılır.
/// Saf fonksiyondur.
public func recipeFromSkill(text: String, file: String, id: String) throws -> Recipe {
    let lines: [Substring] = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
          let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
        throw SkillImportError.missingFrontMatter(file: file)
    }
    let front: [String: String] = lines[1..<end].reduce(into: [String: String]()) { (result: inout [String: String], line: Substring) -> Void in
        let parts: [Substring] = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            return
        }
        result[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    guard let name = front["name"], !name.isEmpty else {
        throw SkillImportError.missingFrontMatter(file: file)
    }
    let body: String = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else {
        throw SkillImportError.emptyBody(file: file)
    }
    let title: String = name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    let prompt: String = [front["description"], body].compactMap { $0 }.joined(separator: "\n\n")
    return Recipe(id: id, title: title, prompt: prompt, symbol: "sparkles", isBuiltIn: false)
}
