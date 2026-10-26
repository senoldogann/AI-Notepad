import Foundation

/// İşaretlenen an: toplantının başından saniye. Kayıt sırasında "İşaretle" ile konan işaretin sonu yoktur (basılan an);
/// transkriptte paragrafa konan işaret paragrafın aralığını taşır.
public struct Highlight: Sendable, Equatable, Codable {
    public let startSec: Double
    public let endSec: Double?

    public init(startSec: Double, endSec: Double?) {
        self.startSec = startSec
        self.endSec = endSec
    }
}

/// Kayıt sırasındaki işaretin kapsadığı aralık: düğmeye söz bittikten biraz sonra basılır; 20 sn öncesinden 10 sn
/// sonrasına.
let highlightWindow: (before: Double, after: Double) = (20, 10)

/// İşaretli anlara düşen bölümlerin başına "★" koyar (not istemi bunları öne çıkarır): paragraf işaretinde paragrafın
/// aralığı, kayıt sırasındaki işarette basılan anın çevresi. Saf fonksiyondur.
public func markingHighlights(segments: [StoredSegment], highlights: [Highlight]) -> [StoredSegment] {
    guard !highlights.isEmpty else {
        return segments
    }
    return segments.map { (segment: StoredSegment) -> StoredSegment in
        let marked: Bool = highlights.contains { (highlight: Highlight) -> Bool in
            let range: (start: Double, end: Double) = highlight.endSec.map { (start: highlight.startSec, end: $0) }
                ?? (start: highlight.startSec - highlightWindow.before, end: highlight.startSec + highlightWindow.after)
            return segment.endSec > range.start && segment.startSec < range.end
        }
        return marked
            ? StoredSegment(key: segment.key, speaker: segment.speaker, person: segment.person, startSec: segment.startSec, endSec: segment.endSec, text: "★ " + segment.text, words: segment.words)
            : segment
    }
}

/// İşaretin ait olduğu paragraf: işaretten önce (ya da tam o anda) başlayan son paragraf; her işaret tek paragrafa
/// düşer. Paragraf yoksa nil. Saf fonksiyondur.
func highlightOwner(highlight: Highlight, paragraphs: [TranscriptParagraph]) -> String? {
    (paragraphs.last { $0.startSec <= highlight.startSec + 0.01 } ?? paragraphs.first)?.id
}

/// İşaretli paragrafların kimlikleri. Saf fonksiyondur.
public func highlightedParagraphIDs(paragraphs: [TranscriptParagraph], highlights: [Highlight]) -> Set<String> {
    Set(highlights.compactMap { highlightOwner(highlight: $0, paragraphs: paragraphs) })
}

/// Paragrafın işaretini açar/kapatır: paragrafa düşen işaretler varsa kaldırılır, yoksa paragrafın aralığıyla eklenir.
/// Saf fonksiyondur.
public func togglingHighlight(highlights: [Highlight], paragraphs: [TranscriptParagraph], paragraph: TranscriptParagraph) -> [Highlight] {
    let owned: [Highlight] = highlights.filter { highlightOwner(highlight: $0, paragraphs: paragraphs) == paragraph.id }
    return owned.isEmpty
        ? (highlights + [Highlight(startSec: paragraph.startSec, endSec: paragraph.endSec)]).sorted { $0.startSec < $1.startSec }
        : highlights.filter { !owned.contains($0) }
}
