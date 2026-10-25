import Foundation

/// Yankı sayılmak için "Sen" bölümünün çevresine bakılan süre.
let echoWindowSec: Double = 3
/// "Sen" kelimelerinin en az bu oranı çevredeki "Diğerleri" metninde geçiyorsa bölüm yankıdır.
let echoSimilarity: Double = 0.6

/// Hoparlörden çıkıp mikrofona giren sesi ("Diğerleri"nin "Sen" altında tekrarı) gizler. Saf fonksiyondur.
///
/// Bir "Sen" bölümü, ±`echoWindowSec` içinde kesişen "Diğerleri" bölümlerinin (geçici dahil) kelimeleriyle
/// karşılaştırılır; kelimelerinin en az `echoSimilarity` oranı eşleşirse gösterilmez. Fince ekler için bir
/// kelime diğerinin başıysa (en az 4 harf) eşleşmiş sayılır. Metni boş "Sen" bölümleri (hata satırları) kalır.
public func suppressEchoes(transcript: [LiveSegment]) -> [LiveSegment] {
    let others: [LiveSegment] = transcript.filter { (segment: LiveSegment) -> Bool in segment.id.speaker == .others }
    return transcript.filter { (segment: LiveSegment) -> Bool in
        segment.id.speaker == .others || !isEcho(segment: segment, others: others)
    }
}

private func isEcho(segment: LiveSegment, others: [LiveSegment]) -> Bool {
    let mine: [String] = words(text: segment.text)
    guard !mine.isEmpty else {
        return false
    }
    let nearby: [String] = others
        .filter { (other: LiveSegment) -> Bool in
            other.startSec <= segment.endSec + echoWindowSec && other.endSec >= segment.startSec - echoWindowSec
        }
        .flatMap { (other: LiveSegment) -> [String] in words(text: other.text) }
    guard !nearby.isEmpty else {
        return false
    }
    let matched: Int = mine.filter { (word: String) -> Bool in
        nearby.contains { (candidate: String) -> Bool in sameWord(left: word, right: candidate) }
    }.count
    return Double(matched) / Double(mine.count) >= echoSimilarity
}

/// Küçük harfli, noktalamasız kelimeler.
private func words(text: String) -> [String] {
    text.lowercased()
        .split { (character: Character) -> Bool in !character.isLetter && !character.isNumber }
        .map(String.init)
}

private func sameWord(left: String, right: String) -> Bool {
    if left == right {
        return true
    }
    let (shorter, longer): (String, String) = left.count <= right.count ? (left, right) : (right, left)
    return shorter.count >= 4 && longer.hasPrefix(shorter)
}
