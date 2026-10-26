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
