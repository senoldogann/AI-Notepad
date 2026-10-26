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
            text: item.element.map(\.text).joined(separator: " ")
        )
    }
}

/// Canlı "Diğerleri" bölümlerinin Türkçelerini, zamanı kesişen son geçiş bölümlerine taşır (sırayla birleştirir);
/// böylece son geçişten sonra da geçmişte Türkçe görünür. Saf fonksiyondur.
public func alignTranslations(final: [StoredSegment], live: [StoredSegment], translations: [String: String]) -> [String: String] {
    let translatedLive: [StoredSegment] = live
        .filter { (segment: StoredSegment) -> Bool in segment.speaker == .others && translations[segment.key] != nil }
        .sorted { $0.startSec < $1.startSec }
    return final.reduce(into: [String: String]()) { (result: inout [String: String], segment: StoredSegment) -> Void in
        let parts: [String] = translatedLive
            .filter { (liveSegment: StoredSegment) -> Bool in
                // Canlı bölümün yarısından fazlası bu son geçiş bölümüne düşüyorsa ona aittir.
                let overlap: Double = min(liveSegment.endSec, segment.endSec) - max(liveSegment.startSec, segment.startSec)
                return overlap > (liveSegment.endSec - liveSegment.startSec) / 2
            }
            .compactMap { translations[$0.key] }
        if !parts.isEmpty {
            result[segment.key] = parts.joined(separator: " ")
        }
    }
}
