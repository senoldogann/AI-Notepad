import Foundation

/// Konuşma tanımaya verilen anahtar terimler (ElevenLabs `keyterms`, Deepgram `keyterm`): toplantılarda geçen adlar ve
/// önemli terimler doğru yazılsın (Fince adlar, kurum içi terimler). Sırayla: kullanıcının adı, son toplantılarda
/// verilen konuşmacı adları, son notların sözlük terimleri. İki servisin kurallarına uyacak biçimde temizlenir (en çok
/// 5 kelime, en çok 40 karakter, `< > { } [ ] \` yok, virgül/noktalı virgül yok — Deepgram bunları tek terim sayar);
/// büyük/küçük harf duyarsız tekilleştirilir, en fazla `limit` terim. Saf fonksiyondur.
public func meetingKeyterms(records: [MeetingRecord], userName: String, limit: Int) -> [String] {
    let names: [String] = records.flatMap { (record: MeetingRecord) -> [String] in
        record.speakerNames.keys.sorted().compactMap { record.speakerNames[$0] }
    }
    let glossary: [String] = records.flatMap { (record: MeetingRecord) -> [String] in
        record.note?.glossary.map(\.term) ?? []
    }
    let candidates: [String] = [userName] + names + glossary
    return candidates
        .compactMap(sanitizedKeyterm)
        .reduce(into: [String]()) { (result: inout [String], term: String) -> Void in
            if !result.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
                result.append(term)
            }
        }
        .prefix(limit)
        .map { $0 }
}

/// Terimi servis kurallarına göre temizler; uymuyorsa nil. Saf fonksiyondur.
func sanitizedKeyterm(_ text: String) -> String? {
    let forbidden: CharacterSet = CharacterSet(charactersIn: "<>{}[]\\,;:\n\r\t")
    let cleaned: String = text.components(separatedBy: forbidden).joined(separator: " ")
        .split(separator: " ").joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count >= 2, cleaned.count <= 40, cleaned.split(separator: " ").count <= 5 else {
        return nil
    }
    return cleaned
}
