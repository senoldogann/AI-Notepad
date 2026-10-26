import Foundation

/// Bir "Sen" bölümünün yankı sayılması için süresinin en az bu oranı "Diğerleri" konuşmasıyla aynı anda olmalı:
/// yankı hoparlörden aynı anda duyulur; soruyu tekrar eden cevap ise sorudan sonra gelir ve korunur.
let echoTimeCoverage: Double = 0.5
/// "Sen" metninin harf üçlülerinin en az bu oranı, aynı sırayla, eş zamanlı "Diğerleri" metninde geçiyorsa yankıdır.
let echoSimilarity: Double = 0.6
/// Hoparlörden mikrofona geçen ses ve iki tanıyıcının zaman damgaları arasındaki gecikme payı: yankının son kelimesi
/// ("…vuoden ajan." → "Sen: ajan.") "Diğerleri" bölümü bittikten hemen sonra biter.
let echoLatencySec: Double = 0.5
/// Bu kadar boşlukla art arda gelen "Sen" bölümleri metin karşılaştırmasında birlikte de denenir: tanıyıcı yankıyı
/// farklı bölebilir ("konetyyppiin" → "kone" | "työhön."), tek başına kısa parça hiçbir metinle eşleşmez.
let echoJoinGapSec: Double = 0.5

/// Yankı karşılaştırmasında bir bölüm: konuşmacı, zaman ve metin.
private struct EchoCandidate {
    let isMe: Bool
    let startSec: Double
    let endSec: Double
    let text: String
}

/// Hoparlörden çıkıp mikrofona giren sesi ("Diğerleri"nin "Sen" altında tekrarı) gizler. Saf fonksiyondur.
///
/// Bir "Sen" bölümü yankıdır: (1) süresinin en az `echoTimeCoverage` oranı "Diğerleri" bölümleriyle (geçici dahil,
/// `echoLatencySec` gecikme payıyla) aynı anda ve (2) eş zamanlı "Diğerleri" metniyle sıralı harf üçlüsü benzerliği en
/// az `echoSimilarity` — bölümün kendisiyle ya da bitişiğindeki (`echoJoinGapSec`) "Sen" bölümüyle birlikte. İki tanıyıcı
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

/// Yankı olan "Sen" bölümlerinin sıra numaraları. "Diğerleri" bir kez başlangıca göre sıralanır (bitişleri gecikme
/// payıyla uzatılmış); her "Sen" bölümü için yalnızca zamanca çakışabilecekler (ikili aramayla) taranır — uzun
/// toplantıda her güncellemede tüm çiftler karşılaştırılmasın.
private func echoIndices(candidates: [EchoCandidate]) -> Set<Int> {
    let others: [EchoCandidate] = candidates
        .filter { !$0.isMe }
        .map { EchoCandidate(isMe: false, startSec: $0.startSec, endSec: $0.endSec + echoLatencySec, text: $0.text) }
        .sorted { (left: EchoCandidate, right: EchoCandidate) -> Bool in left.startSec < right.startSec }
    let longest: Double = others.map { $0.endSec - $0.startSec }.max() ?? 0
    let mine: [(offset: Int, element: EchoCandidate)] = candidates.enumerated()
        .filter { $0.element.isMe }
        .sorted { (left: (offset: Int, element: EchoCandidate), right: (offset: Int, element: EchoCandidate)) -> Bool in
            left.element.startSec < right.element.startSec
        }
    return Set(mine.indices.compactMap { (position: Int) -> Int? in
        let segment: EchoCandidate = mine[position].element
        guard timeCoverage(mine: segment, simultaneous: overlapping(sortedOthers: others, longest: longest, mine: segment)) >= echoTimeCoverage else {
            return nil
        }
        let previous: EchoCandidate? = position > 0 ? mine[position - 1].element : nil
        let next: EchoCandidate? = position + 1 < mine.count ? mine[position + 1].element : nil
        let echoes: Bool = textGroups(previous: previous, segment: segment, next: next).contains { (group: EchoCandidate) -> Bool in
            textSimilarity(mine: group, simultaneous: overlapping(sortedOthers: others, longest: longest, mine: group)) >= echoSimilarity
        }
        return echoes ? mine[position].offset : nil
    })
}

/// Metin karşılaştırmasında denenecek gruplar: bölümün kendisi ve `echoJoinGapSec` içinde bitişik önceki/sonraki
/// "Sen" bölümüyle birleşimi. Saf fonksiyondur.
private func textGroups(previous: EchoCandidate?, segment: EchoCandidate, next: EchoCandidate?) -> [EchoCandidate] {
    var groups: [EchoCandidate] = [segment]
    if let previous, segment.startSec - previous.endSec <= echoJoinGapSec {
        groups.append(EchoCandidate(isMe: true, startSec: previous.startSec, endSec: segment.endSec, text: "\(previous.text) \(segment.text)"))
    }
    if let next, next.startSec - segment.endSec <= echoJoinGapSec {
        groups.append(EchoCandidate(isMe: true, startSec: segment.startSec, endSec: next.endSec, text: "\(segment.text) \(next.text)"))
    }
    return groups
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

/// Bölüm süresinin eş zamanlı "Diğerleri" konuşmasıyla kaplanan oranı (süresiz bölümde 0). Saf fonksiyondur.
private func timeCoverage(mine: EchoCandidate, simultaneous: [EchoCandidate]) -> Double {
    let duration: Double = mine.endSec - mine.startSec
    guard duration > 0 else {
        return 0
    }
    return coveredDuration(intervals: simultaneous, from: mine.startSec, to: mine.endSec) / duration
}

/// "Sen" metninin harf üçlülerinden sırayla eş zamanlı "Diğerleri" metninde geçenlerin oranı. Saf fonksiyondur.
private func textSimilarity(mine: EchoCandidate, simultaneous: [EchoCandidate]) -> Double {
    let mineGrams: [String] = trigramSequence(text: mine.text)
    guard !mineGrams.isEmpty else {
        return 0
    }
    let otherGrams: [String] = trigramSequence(text: simultaneous.map(\.text).joined(separator: " "))
    return Double(commonSubsequenceLength(left: mineGrams, right: otherGrams)) / Double(mineGrams.count)
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
