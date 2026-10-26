import Foundation

/// İşaretlenen an (kayıt sırasında "İşaretle" ya da sonradan transkriptte): toplantının başından saniye.
public struct Highlight: Sendable, Equatable, Codable {
    public let startSec: Double

    public init(startSec: Double) {
        self.startSec = startSec
    }
}

/// İşaretin kapsadığı aralık: düğmeye söz bittikten biraz sonra basılır; 20 sn öncesinden 10 sn sonrasına.
let highlightWindow: (before: Double, after: Double) = (20, 10)

/// İşaretli anlara düşen bölümlerin başına "★" koyar (not istemi bunları öne çıkarır). Saf fonksiyondur.
public func markingHighlights(segments: [StoredSegment], highlights: [Highlight]) -> [StoredSegment] {
    guard !highlights.isEmpty else {
        return segments
    }
    return segments.map { (segment: StoredSegment) -> StoredSegment in
        let marked: Bool = highlights.contains { (highlight: Highlight) -> Bool in
            segment.endSec >= highlight.startSec - highlightWindow.before && segment.startSec <= highlight.startSec + highlightWindow.after
        }
        return marked
            ? StoredSegment(key: segment.key, speaker: segment.speaker, person: segment.person, startSec: segment.startSec, endSec: segment.endSec, text: "★ " + segment.text, words: segment.words)
            : segment
    }
}

/// Paragrafta işaret var mı. Saf fonksiyondur.
public func isHighlighted(paragraph: TranscriptParagraph, highlights: [Highlight]) -> Bool {
    highlights.contains { $0.startSec >= paragraph.startSec - 1 && $0.startSec <= paragraph.endSec + highlightWindow.after }
}

/// Paragrafın işaretini açar/kapatır: işaret varsa kaldırılır, yoksa paragrafın başına eklenir. Saf fonksiyondur.
public func togglingHighlight(highlights: [Highlight], paragraph: TranscriptParagraph) -> [Highlight] {
    isHighlighted(paragraph: paragraph, highlights: highlights)
        ? highlights.filter { !($0.startSec >= paragraph.startSec - 1 && $0.startSec <= paragraph.endSec + highlightWindow.after) }
        : (highlights + [Highlight(startSec: paragraph.startSec)]).sorted { $0.startSec < $1.startSec }
}
