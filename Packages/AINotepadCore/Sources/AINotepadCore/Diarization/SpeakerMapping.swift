import Foundation

/// Kalıcı kişi numarası atanmış kelime; zamanlar akışın başından itibaren saniye.
public struct AttributedWord: Sendable, Equatable {
    public let startSec: Double
    public let endSec: Double
    /// "Konuşmacı N"deki N; toplantı boyunca aynı kişi için aynı kalır.
    public let person: Int

    public init(startSec: Double, endSec: Double, person: Int) {
        self.startSec = startSec
        self.endSec = endSec
        self.person = person
    }
}

/// Pencereler arası konuşmacı eşleme durumu: son pencerenin atanmış kelimeleri ve sıradaki numara.
public struct SpeakerMapping: Sendable, Equatable {
    public let words: [AttributedWord]
    public let nextPerson: Int

    public init(words: [AttributedWord], nextPerson: Int) {
        self.words = words
        self.nextPerson = nextPerson
    }

    public static let initial: SpeakerMapping = SpeakerMapping(words: [], nextPerson: 1)
}

/// Yeni bir ayırma penceresinin pencere içi etiketlerini kalıcı kişi numaralarına eşler. Saf fonksiyondur.
///
/// Her (yeni etiket, önceki kişi) çifti için örtüşme, kelimelerin zaman kesişimlerinin toplamıdır.
/// Çiftler örtüşmeye göre büyükten küçüğe açgözlü eşlenir; her etiket ve kişi en fazla bir kez kullanılır.
/// Eşlenmeyen etiketler, pencerede ilk görünme sırasıyla `nextPerson`'dan numara alır.
/// Pencerede kelime yoksa eşleme olduğu gibi döner.
public func applyWindow(mapping: SpeakerMapping, windowWords: [DiarizedWord], windowStartSec: Double) -> SpeakerMapping {
    guard !windowWords.isEmpty else {
        return mapping
    }
    let absolute: [DiarizedWord] = windowWords.map { (word: DiarizedWord) -> DiarizedWord in
        DiarizedWord(text: word.text, startSec: word.startSec + windowStartSec, endSec: word.endSec + windowStartSec, speaker: word.speaker)
    }
    let labelsInOrder: [String] = absolute.reduce(into: [String]()) { (labels: inout [String], word: DiarizedWord) -> Void in
        if !labels.contains(word.speaker) {
            labels.append(word.speaker)
        }
    }
    let matched: [String: Int] = greedyMatches(overlaps: overlapDurations(newWords: absolute, previous: mapping.words))
    let numbered: (persons: [String: Int], nextPerson: Int) = labelsInOrder.reduce(
        into: (persons: matched, nextPerson: mapping.nextPerson)
    ) { (state: inout (persons: [String: Int], nextPerson: Int), label: String) -> Void in
        if state.persons[label] == nil {
            state.persons[label] = state.nextPerson
            state.nextPerson += 1
        }
    }
    let attributed: [AttributedWord] = absolute.map { (word: DiarizedWord) -> AttributedWord in
        // Her etiket yukarıda numara aldı.
        AttributedWord(startSec: word.startSec, endSec: word.endSec, person: numbered.persons[word.speaker]!)
    }
    return SpeakerMapping(words: attributed, nextPerson: numbered.nextPerson)
}

/// Her "Diğerleri" bölümüne, aralığında en uzun konuşan kişiyi atar. "Sen" bölümleri ve kelimesiz
/// bölümler atanmaz. Saf fonksiyondur.
public func assignPersons(segments: [LiveSegment], words: [AttributedWord]) -> [SegmentID: Int] {
    segments
        .filter { (segment: LiveSegment) -> Bool in segment.id.speaker == .others }
        .reduce(into: [SegmentID: Int]()) { (assignments: inout [SegmentID: Int], segment: LiveSegment) -> Void in
            let durations: [Int: Double] = words.reduce(into: [Int: Double]()) { (totals: inout [Int: Double], word: AttributedWord) -> Void in
                let overlap: Double = intersection(startA: segment.startSec, endA: segment.endSec, startB: word.startSec, endB: word.endSec)
                if overlap > 0 {
                    totals[word.person, default: 0] += overlap
                }
            }
            if let best = durations.max(by: { (left: (key: Int, value: Double), right: (key: Int, value: Double)) -> Bool in
                left.value == right.value ? left.key > right.key : left.value < right.value
            }) {
                assignments[segment.id] = best.key
            }
        }
}

/// (yeni etiket, önceki kişi) → örtüşme süresi.
private func overlapDurations(newWords: [DiarizedWord], previous: [AttributedWord]) -> [LabelPerson: Double] {
    newWords.reduce(into: [LabelPerson: Double]()) { (totals: inout [LabelPerson: Double], word: DiarizedWord) -> Void in
        for old in previous {
            let overlap: Double = intersection(startA: word.startSec, endA: word.endSec, startB: old.startSec, endB: old.endSec)
            if overlap > 0 {
                totals[LabelPerson(label: word.speaker, person: old.person), default: 0] += overlap
            }
        }
    }
}

/// Örtüşmeye göre büyükten küçüğe, her etiket ve kişi bir kez kullanılarak eşler.
private func greedyMatches(overlaps: [LabelPerson: Double]) -> [String: Int] {
    let ordered: [(key: LabelPerson, value: Double)] = overlaps.sorted { (left: (key: LabelPerson, value: Double), right: (key: LabelPerson, value: Double)) -> Bool in
        // Eşit örtüşmede sonuç belirli olsun diye etiket ve kişiye göre sırala.
        left.value != right.value ? left.value > right.value
            : (left.key.label, left.key.person) < (right.key.label, right.key.person)
    }
    return ordered.reduce(into: [String: Int]()) { (matches: inout [String: Int], pair: (key: LabelPerson, value: Double)) -> Void in
        if matches[pair.key.label] == nil, !matches.values.contains(pair.key.person) {
            matches[pair.key.label] = pair.key.person
        }
    }
}

private struct LabelPerson: Hashable {
    let label: String
    let person: Int
}

private func intersection(startA: Double, endA: Double, startB: Double, endB: Double) -> Double {
    max(0, min(endA, endB) - max(startA, startB))
}
