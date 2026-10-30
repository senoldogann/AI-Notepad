import Foundation

/// Kaydın tamamından gelen konuşmacılı kelimeleri kesin bölümlere ayırır: konuşmacı değiştiğinde ya da
/// iki kelime arasında `gapSec`'ten uzun boşluk olduğunda yeni bölüm. ElevenLabs etiketleri ilk görünme
/// sırasıyla "Konuşmacı 1, 2…" olur. Saf fonksiyondur.
public func finalSegments(words: [DiarizedWord], gapSec: Double) -> [StoredSegment] {
    let persons: [String: Int] = words.reduce(into: [String: Int]()) { (numbers: inout [String: Int], word: DiarizedWord) -> Void in
        if numbers[word.speaker] == nil {
            numbers[word.speaker] = numbers.count + 1
        }
    }
    var groups: [[DiarizedWord]] = []
    for word in words {
        if let last = groups.last?.last, last.speaker == word.speaker, word.startSec - last.endSec <= gapSec {
            groups[groups.count - 1].append(word)
        } else {
            groups.append([word])
        }
    }
    return groups.enumerated().compactMap { (item: (offset: Int, element: [DiarizedWord])) -> StoredSegment? in
        guard let first = item.element.first, let last = item.element.last else {
            return nil
        }
        return StoredSegment(
            key: "final-\(item.offset)",
            speaker: .others,
            person: persons[first.speaker],
            startSec: first.startSec,
            endSec: last.endSec,
            text: item.element.map(\.text).joined(separator: " "),
            words: item.element.map { (word: DiarizedWord) -> StoredWord in
                StoredWord(text: word.text, startSec: word.startSec, endSec: word.endSec)
            }
        )
    }
}

/// Canlı "Diğerleri" çevirilerini, zamanı kesişen son geçiş bölümlerine taşır (sırayla birleştirir); böylece son
/// geçişten sonra da geçmişte Türkçe görünür. Canlı çeviri birim birimdir (bkz. `TranslationUnit`): kapsanan bölümler
/// (boş çeviri) ardından gelen çevirili bölümle tek birim sayılır ve birimin tüm süresi hizalanır. Birim, yarısından
/// fazlası düşen son geçiş bölümüne aittir; hiçbirine yarısı düşmüyorsa (birim iki bölüme bölündü) en çok kesiştiğine.
/// Saf fonksiyondur.
public func alignTranslations(final: [StoredSegment], live: [StoredSegment], translations: [String: String]) -> [String: String] {
    let owners: [(key: String, text: String)] = translatedSpans(live: live, translations: translations)
        .compactMap { (span: TranslatedSpan) -> (key: String, text: String)? in
            let best: (key: String, overlap: Double)? = final
                .map { (segment: StoredSegment) -> (key: String, overlap: Double) in
                    (segment.key, min(span.endSec, segment.endSec) - max(span.startSec, segment.startSec))
                }
                .filter { $0.overlap > 0 }
                .max { $0.overlap < $1.overlap }
            return best.map { (key: $0.key, text: span.text) }
        }
    return owners.reduce(into: [String: String]()) { (result: inout [String: String], owner: (key: String, text: String)) -> Void in
        result[owner.key] = result[owner.key].map { "\($0) \(owner.text)" } ?? owner.text
    }
}

/// Saklanmış bir canlı çevirinin kapsadığı süre ve metni.
private struct TranslatedSpan {
    let startSec: Double
    let endSec: Double
    let text: String
}

/// Çevirili canlı "Diğerleri" bölümlerini birimlere toplar (zaman sırasıyla): kapsanan bölümler (boş çeviri) sonraki
/// çevirili bölüme katılır. Saf fonksiyondur.
private func translatedSpans(live: [StoredSegment], translations: [String: String]) -> [TranslatedSpan] {
    let translated: [StoredSegment] = live
        .filter { (segment: StoredSegment) -> Bool in segment.speaker == .others && translations[segment.key] != nil }
        .sorted { $0.startSec < $1.startSec }
    var spans: [TranslatedSpan] = []
    var coveredStart: Double?
    for segment in translated {
        let text: String = translations[segment.key] ?? ""
        guard !text.isEmpty else {
            coveredStart = coveredStart ?? segment.startSec
            continue
        }
        spans.append(TranslatedSpan(startSec: coveredStart ?? segment.startSec, endSec: segment.endSec, text: text))
        coveredStart = nil
    }
    return spans
}
