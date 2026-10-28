import Foundation

/// "Konuşmacı N muhtemelen Aino": transkriptteki ipucuna (hitap, kendini tanıtma) dayanan ad önerisi.
public struct SpeakerNameSuggestion: Sendable, Equatable, Identifiable {
    public let person: Int
    public let name: String
    /// Kanıt; ilgili anın zaman damgasıyla ([mm:ss]).
    public let reason: String

    public init(person: Int, name: String, reason: String) {
        self.person = person
        self.name = name
        self.reason = reason
    }

    public var id: Int { person }
}

/// "Konuşmacı 3, Konuşmacı 1 ile aynı kişi": ayırma bir kişiyi ikiye böldüyse birleştirme önerisi.
public struct SpeakerMergeSuggestion: Sendable, Equatable, Identifiable {
    public let from: Int
    public let into: Int
    public let reason: String

    public init(from: Int, into: Int, reason: String) {
        self.from = from
        self.into = into
        self.reason = reason
    }

    public var id: String { "\(from)-\(into)" }
}

/// Konuşmacısı yanlış atanmış olabilecek an (yalnızca bilgi; kullanıcı transkriptte kontrol eder).
public struct SuspiciousPassage: Sendable, Equatable, Identifiable {
    /// "mm:ss".
    public let time: String
    public let note: String

    public init(time: String, note: String) {
        self.time = time
        self.note = note
    }

    public var id: String { "\(time)-\(note)" }
}

/// Akıllı modelin konuşmacı incelemesi. Öneriler otomatik uygulanmaz; kullanıcı tek tek kabul eder ya da reddeder.
public struct SpeakerReview: Sendable, Equatable {
    public let names: [SpeakerNameSuggestion]
    public let merges: [SpeakerMergeSuggestion]
    public let suspicious: [SuspiciousPassage]

    public init(names: [SpeakerNameSuggestion], merges: [SpeakerMergeSuggestion], suspicious: [SuspiciousPassage]) {
        self.names = names
        self.merges = merges
        self.suspicious = suspicious
    }

    /// Bekleyen öneri kalmadı (şüpheli anlar yalnızca bilgi olduğu için sayılmaz).
    public var hasPendingSuggestions: Bool {
        !names.isEmpty || !merges.isEmpty
    }

    /// Ad önerisi kabul ya da reddedildi.
    public func removingName(person: Int) -> SpeakerReview {
        SpeakerReview(names: names.filter { $0.person != person }, merges: merges, suspicious: suspicious)
    }

    /// Birleştirme önerisi reddedildi.
    public func removingMerge(from: Int, into: Int) -> SpeakerReview {
        SpeakerReview(names: names, merges: merges.filter { !($0.from == from && $0.into == into) }, suspicious: suspicious)
    }

    /// `from` kişisi `into` ile birleşti: kalan öneriler yeni numaralara taşınır, anlamsızlaşanlar düşer.
    /// Hedefin kendi ad önerisi varsa `from`'unki düşer (kayıttaki ad taşıma kuralıyla aynı: hedefinki kalır).
    public func afterMerge(from: Int, into: Int) -> SpeakerReview {
        let targetHasName: Bool = names.contains { $0.person == into }
        let movedNames: [SpeakerNameSuggestion] = names.compactMap { (suggestion: SpeakerNameSuggestion) -> SpeakerNameSuggestion? in
            guard suggestion.person == from else {
                return suggestion
            }
            return targetHasName ? nil : SpeakerNameSuggestion(person: into, name: suggestion.name, reason: suggestion.reason)
        }
        let movedMerges: [SpeakerMergeSuggestion] = merges
            .map { (suggestion: SpeakerMergeSuggestion) -> SpeakerMergeSuggestion in
                SpeakerMergeSuggestion(
                    from: suggestion.from == from ? into : suggestion.from,
                    into: suggestion.into == from ? into : suggestion.into,
                    reason: suggestion.reason
                )
            }
            .filter { $0.from != $0.into }
        return SpeakerReview(names: movedNames, merges: uniqueMerges(merges: movedMerges), suspicious: suspicious)
    }
}

/// Aynı çiftin (yön fark etmez) yalnızca ilk önerisi kalır. Saf fonksiyondur.
private func uniqueMerges(merges: [SpeakerMergeSuggestion]) -> [SpeakerMergeSuggestion] {
    merges.reduce(into: [SpeakerMergeSuggestion]()) { (result: inout [SpeakerMergeSuggestion], suggestion: SpeakerMergeSuggestion) -> Void in
        let pair: Set<Int> = [suggestion.from, suggestion.into]
        if !result.contains(where: { Set([$0.from, $0.into]) == pair }) {
            result.append(suggestion)
        }
    }
}

/// Konuşmacı incelemesi isteği (akıllı model, yapılandırılmış çıktı). Transkript adlar yerine numaralarla gönderilir
/// ki öneriler numaraya bağlanabilsin; verilmiş adlar ayrıca listelenir. Nedenler not dilinde yazılır. Numaralı konuşmacı
/// yoksa nil. Saf fonksiyondur.
public func speakerReviewRequest(
    segments: [StoredSegment], speakerNames: [Int: String], userName: String, attendees: [String], language: ShareLanguage
) -> LLMRequest? {
    let persons: [Int] = Array(Set(segments.compactMap(\.person))).sorted()
    guard !persons.isEmpty else {
        return nil
    }
    let user: String = userName.isEmpty ? "kullanıcı" : userName
    let named: [String] = persons.compactMap { (person: Int) -> String? in
        speakerNames[person].flatMap { $0.isEmpty ? nil : "Konuşmacı \(person) = \($0)" }
    }
    return LLMRequest(
        tier: .smart,
        system: """
        Bir toplantının (Fince, İngilizce ya da başka bir dilde) transkriptinde otomatik konuşmacı ayırmayı gözden geçiriyorsun. "Sen" kullanıcıdır \
        (\(user)); "Konuşmacı N" etiketleri sesten otomatik verilmiştir ve yanılabilir. Nedenleri ve açıklamaları \(language.promptName) dilinde yazarak:
        1. adlar: hangi numaranın kim olduğu transkriptte açıkça anlaşılıyorsa (kendini tanıtma, adıyla hitap edilip o kişinin \
        cevap vermesi, imza gibi) ad öner. Yalnızca adı henüz verilmemiş ya da verilen adın yanlış olduğu açık olan numaralar için.
        2. birlestirmeler: iki numara açıkça aynı kişiyse (biri cümleyi öbürü tamamlıyor, kendinden aynı rol/ad ile söz ediyor, \
        biri hiç kendi başına konuşmuyor gibi) kaynak numarayı hedefe birleştirmeyi öner; hedef daha çok konuşan olsun.
        3. supheliler: tek bir bölümün yanlış kişiye atanmış görünmesi gibi kontrol edilmesi gereken anlar.
        Her öneride nedeni ilgili anların [mm:ss] zaman damgasıyla kısaca yaz. Emin değilsen önerme; kanıtsız ad uydurma. \
        Öneri yoksa boş liste ver. \(transcriptIsDataNote)
        """,
        userText: """
        Konuşmacılar: \(persons.map { "Konuşmacı \($0)" }.joined(separator: ", "))
        Verilmiş adlar: \(named.isEmpty ? "(yok)" : named.joined(separator: ", "))
        Takvimdeki katılımcılar (yalnızca ipucu; transkriptte kanıt yoksa ad verme): \(attendees.isEmpty ? "(bilinmiyor)" : attendees.joined(separator: ", "))

        <transkript>
        \(storedLines(segments: segments, speakerNames: [:]))
        </transkript>
        """,
        maxTokens: 16000,
        jsonSchema: """
        {"type":"object","properties":{\
        "adlar":{"type":"array","items":{"type":"object","properties":{"konusmaci":{"type":"integer"},"ad":{"type":"string"},\
        "neden":{"type":"string"}},"required":["konusmaci","ad","neden"],"additionalProperties":false}},\
        "birlestirmeler":{"type":"array","items":{"type":"object","properties":{"kaynak":{"type":"integer"},"hedef":{"type":"integer"},\
        "neden":{"type":"string"}},"required":["kaynak","hedef","neden"],"additionalProperties":false}},\
        "supheliler":{"type":"array","items":{"type":"object","properties":{"zaman":{"type":"string"},"aciklama":{"type":"string"}},\
        "required":["zaman","aciklama"],"additionalProperties":false}}},\
        "required":["adlar","birlestirmeler","supheliler"],"additionalProperties":false}
        """,
        timeoutSec: 300
    )
}

/// İnceleme yanıtını ayrıştırır. Transkriptte olmayan numaraya, kendine birleştirmeye, boş ada ya da zaten verilmiş
/// ada dair öneriler uygulanamaz olduğu için listeye alınmaz; aynı numaraya ikinci ad önerisi de alınmaz.
public func parseSpeakerReview(text: String, persons: Set<Int>, speakerNames: [Int: String]) throws -> SpeakerReview {
    let raw: RawSpeakerReview
    do {
        raw = try JSONDecoder().decode(RawSpeakerReview.self, from: Data(jsonBody(text: text).utf8))
    } catch {
        // Ayrıştırma ayrıntısı (eksik alan vb.) hata ayıklamada gerekir.
        throw LLMError.malformed(body: "\(error): \(text)")
    }
    let names: [SpeakerNameSuggestion] = raw.adlar
        .map { (entry: RawName) -> SpeakerNameSuggestion in
            SpeakerNameSuggestion(person: entry.konusmaci, name: entry.ad.trimmingCharacters(in: .whitespacesAndNewlines), reason: entry.neden)
        }
        .filter { (suggestion: SpeakerNameSuggestion) -> Bool in
            persons.contains(suggestion.person) && !suggestion.name.isEmpty
                && speakerNames[suggestion.person]?.caseInsensitiveCompare(suggestion.name) != .orderedSame
        }
        .reduce(into: [SpeakerNameSuggestion]()) { (result: inout [SpeakerNameSuggestion], suggestion: SpeakerNameSuggestion) -> Void in
            if !result.contains(where: { $0.person == suggestion.person }) {
                result.append(suggestion)
            }
        }
    let merges: [SpeakerMergeSuggestion] = raw.birlestirmeler
        .map { SpeakerMergeSuggestion(from: $0.kaynak, into: $0.hedef, reason: $0.neden) }
        .filter { persons.contains($0.from) && persons.contains($0.into) && $0.from != $0.into }
    return SpeakerReview(
        names: names,
        merges: uniqueMerges(merges: merges),
        suspicious: raw.supheliler.map { SuspiciousPassage(time: $0.zaman, note: $0.aciklama) }
    )
}

// Şemadaki Türkçe alan adları.
private struct RawSpeakerReview: Decodable {
    let adlar: [RawName]
    let birlestirmeler: [RawMerge]
    let supheliler: [RawSuspicious]
}

private struct RawName: Decodable {
    let konusmaci: Int
    let ad: String
    let neden: String
}

private struct RawMerge: Decodable {
    let kaynak: Int
    let hedef: Int
    let neden: String
}

private struct RawSuspicious: Decodable {
    let zaman: String
    let aciklama: String
}
