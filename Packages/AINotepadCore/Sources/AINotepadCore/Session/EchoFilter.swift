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

/// Yankı olan "Sen" bölümlerinin sıra numaraları.
private func echoIndices(candidates: [EchoCandidate]) -> Set<Int> {
    let others: [EchoCandidate] = candidates.filter { !$0.isMe }
    return Set(candidates.enumerated().compactMap { (item: (offset: Int, element: EchoCandidate)) -> Int? in
        item.element.isMe && isEcho(mine: item.element, others: others) ? item.offset : nil
    })
}

private func isEcho(mine: EchoCandidate, others: [EchoCandidate]) -> Bool {
    let duration: Double = mine.endSec - mine.startSec
    let simultaneous: [EchoCandidate] = others
        .filter { (other: EchoCandidate) -> Bool in other.startSec < mine.endSec && other.endSec > mine.startSec }
        .sorted { (left: EchoCandidate, right: EchoCandidate) -> Bool in left.startSec < right.startSec }
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
