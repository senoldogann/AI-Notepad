import Foundation

/// Bir "Sen" bölümünün yankı sayılması için süresinin en az bu oranı "Diğerleri" konuşmasıyla aynı anda olmalı:
/// yankı hoparlörden aynı anda duyulur; soruyu tekrar eden cevap ise sorudan sonra gelir ve korunur.
let echoTimeCoverage: Double = 0.5
/// "Sen" metninin harf üçlülerinin en az bu oranı, aynı sırayla, eş zamanlı "Diğerleri" metninde geçiyorsa yankıdır.
let echoSimilarity: Double = 0.6

/// Yankı karşılaştırmasında bir bölüm: konuşmacı, zaman ve metin.
private struct EchoCandidate {
    let isMe: Bool
    let startSec: Double
    let endSec: Double
    let text: String
}

/// Hoparlörden çıkıp mikrofona giren sesi ("Diğerleri"nin "Sen" altında tekrarı) gizler. Saf fonksiyondur.
///
/// Bir "Sen" bölümü yankıdır: (1) süresinin en az `echoTimeCoverage` oranı "Diğerleri" bölümleriyle (geçici dahil)
/// aynı anda ve (2) eş zamanlı "Diğerleri" metniyle sıralı harf üçlüsü benzerliği en az `echoSimilarity`. İki tanıyıcı
/// aynı sesi farklı yazabildiği için (Fince bileşik kelimeler: "lehdistä tilaisuuteen" ↔ "lehdistötilaisuuteen",
/// ekler: "kaudelle" ↔ "hallituskaudelle") karşılaştırma kelime değil, boşluksuz harf üçlüleri üzerindendir.
/// Metni boş "Sen" bölümleri (hata satırları) kalır.
public func suppressEchoes(transcript: [LiveSegment]) -> [LiveSegment] {
    let candidates: [EchoCandidate] = transcript.map { (segment: LiveSegment) -> EchoCandidate in
        EchoCandidate(isMe: segment.id.speaker == .me, startSec: segment.startSec, endSec: segment.endSec, text: segment.text)
    }
    let echoes: Set<Int> = echoIndices(candidates: candidates)
    return transcript.enumerated().filter { !echoes.contains($0.offset) }.map(\.element)
}

/// Saklanan bölümlerde (canlı "Sen" + son geçiş "Diğerleri") yankıyı gizler: Toplantılar, not ve dışa aktarma
/// canlı panelle aynı metni görür. Saf fonksiyondur.
public func suppressStoredEchoes(segments: [StoredSegment]) -> [StoredSegment] {
    let candidates: [EchoCandidate] = segments.map { (segment: StoredSegment) -> EchoCandidate in
        EchoCandidate(isMe: segment.speaker == .me, startSec: segment.startSec, endSec: segment.endSec, text: segment.text)
    }
    let echoes: Set<Int> = echoIndices(candidates: candidates)
    return segments.enumerated().filter { !echoes.contains($0.offset) }.map(\.element)
}

/// Yankı olan "Sen" bölümlerinin sıra numaraları. "Diğerleri" bir kez başlangıca göre sıralanır; her "Sen" bölümü için
/// yalnızca zamanca çakışabilecekler (ikili aramayla) taranır — uzun toplantıda her güncellemede tüm çiftler
/// karşılaştırılmasın.
private func echoIndices(candidates: [EchoCandidate]) -> Set<Int> {
    let others: [EchoCandidate] = candidates
        .filter { !$0.isMe }
        .sorted { (left: EchoCandidate, right: EchoCandidate) -> Bool in left.startSec < right.startSec }
    let longest: Double = others.map { $0.endSec - $0.startSec }.max() ?? 0
    return Set(candidates.enumerated().compactMap { (item: (offset: Int, element: EchoCandidate)) -> Int? in
        guard item.element.isMe else {
            return nil
        }
        let simultaneous: [EchoCandidate] = overlapping(sortedOthers: others, longest: longest, mine: item.element)
        return isEcho(mine: item.element, simultaneous: simultaneous) ? item.offset : nil
    })
}

/// `mine` ile zamanca çakışan "Diğerleri" bölümleri (başlangıca göre sıralı). Çakışan bir bölüm `mine` bitmeden başlar ve
/// en uzun bölüm süresinden daha önce başlamış olamaz; aralık ikili aramayla bulunur. Saf fonksiyondur.
private func overlapping(sortedOthers: [EchoCandidate], longest: Double, mine: EchoCandidate) -> [EchoCandidate] {
    let upper: Int = firstIndex(sorted: sortedOthers, startingAtOrAfter: mine.endSec)
    let lower: Int = firstIndex(sorted: sortedOthers, startingAtOrAfter: mine.startSec - longest)
    guard lower < upper else {
        return []
    }
    return sortedOthers[lower..<upper].filter { (other: EchoCandidate) -> Bool in other.endSec > mine.startSec }
}

/// Başlangıcı `seconds`'tan küçük olmayan ilk bölümün sırası (yoksa dizinin sonu). Saf fonksiyondur.
private func firstIndex(sorted: [EchoCandidate], startingAtOrAfter seconds: Double) -> Int {
    var low: Int = 0
    var high: Int = sorted.count
    while low < high {
        let middle: Int = (low + high) / 2
        if sorted[middle].startSec < seconds {
            low = middle + 1
        } else {
            high = middle
        }
    }
    return low
}

private func isEcho(mine: EchoCandidate, simultaneous: [EchoCandidate]) -> Bool {
    let duration: Double = mine.endSec - mine.startSec
    guard duration > 0, coveredDuration(intervals: simultaneous, from: mine.startSec, to: mine.endSec) / duration >= echoTimeCoverage else {
        return false
    }
    let mineGrams: [String] = trigramSequence(text: mine.text)
    guard !mineGrams.isEmpty else {
        return false
    }
    let otherGrams: [String] = trigramSequence(text: simultaneous.map(\.text).joined(separator: " "))
    return Double(commonSubsequenceLength(left: mineGrams, right: otherGrams)) / Double(mineGrams.count) >= echoSimilarity
}

/// Sıralı aralıkların [from, to] içinde kapladığı toplam süre (örtüşenler bir kez sayılır).
private func coveredDuration(intervals: [EchoCandidate], from: Double, to: Double) -> Double {
    var covered: Double = 0
    var reached: Double = from
    for interval in intervals {
        let start: Double = max(interval.startSec, reached)
        let end: Double = min(interval.endSec, to)
        if end > start {
            covered += end - start
            reached = end
        }
    }
    return covered
}

/// En uzun ortak alt dizinin uzunluğu (sıra korunarak eşleşen öğe sayısı).
private func commonSubsequenceLength(left: [String], right: [String]) -> Int {
    guard !left.isEmpty, !right.isEmpty else {
        return 0
    }
    var previous: [Int] = [Int](repeating: 0, count: right.count + 1)
    for item in left {
        var current: [Int] = [Int](repeating: 0, count: right.count + 1)
        for (index, candidate) in right.enumerated() {
            current[index + 1] = item == candidate ? previous[index] + 1 : max(previous[index + 1], current[index])
        }
        previous = current
    }
    return previous[right.count]
}

/// Metnin sıralı harf üçlüleri (küçük harf, noktalamasız, boşluksuz); üç harften kısa metinde metnin kendisi.
func trigramSequence(text: String) -> [String] {
    let letters: [Character] = Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
    guard letters.count >= 3 else {
        return letters.isEmpty ? [] : [String(letters)]
    }
    return (0...(letters.count - 3)).map { String(letters[$0..<($0 + 3)]) }
}
