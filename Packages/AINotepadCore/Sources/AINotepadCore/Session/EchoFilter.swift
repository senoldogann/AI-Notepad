import Foundation

/// Yankı sayılmak için "Sen" bölümünün çevresine bakılan süre.
let echoWindowSec: Double = 3
/// "Sen" metninin harf üçlülerinin en az bu oranı çevredeki "Diğerleri" metninde geçiyorsa bölüm yankıdır.
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
/// Bir "Sen" bölümü, ±`echoWindowSec` içinde kesişen "Diğerleri" bölümleriyle (geçici dahil) karşılaştırılır.
/// İki tanıyıcı aynı sesi farklı yazabildiği için (Fince bileşik kelimeler: "lehdistä tilaisuuteen" ↔
/// "lehdistötilaisuuteen", ekler: "kaudelle" ↔ "hallituskaudelle") karşılaştırma kelime değil, boşluksuz harf
/// üçlüleri üzerindendir. Metni boş "Sen" bölümleri (hata satırları) kalır.
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
    let mineGrams: Set<String> = trigrams(text: mine.text)
    guard !mineGrams.isEmpty else {
        return false
    }
    let nearbyGrams: Set<String> = others
        .filter { (other: EchoCandidate) -> Bool in
            other.startSec <= mine.endSec + echoWindowSec && other.endSec >= mine.startSec - echoWindowSec
        }
        .reduce(into: Set<String>()) { (grams: inout Set<String>, other: EchoCandidate) -> Void in
            grams.formUnion(trigrams(text: other.text))
        }
    guard !nearbyGrams.isEmpty else {
        return false
    }
    return Double(mineGrams.intersection(nearbyGrams).count) / Double(mineGrams.count) >= echoSimilarity
}

/// Metnin küçük harfli, noktalamasız ve boşluksuz harf üçlüleri. Üç harften kısa metinde metnin kendisi.
func trigrams(text: String) -> Set<String> {
    let letters: [Character] = Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
    guard letters.count >= 3 else {
        return letters.isEmpty ? [] : [String(letters)]
    }
    return Set((0...(letters.count - 3)).map { String(letters[$0..<($0 + 3)]) })
}
