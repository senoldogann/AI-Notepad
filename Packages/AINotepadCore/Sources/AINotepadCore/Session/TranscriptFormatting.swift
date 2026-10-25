import Foundation

/// Aynı kaynaktan (Sen / Diğerleri) art arda gelen bölümlerin oluşturduğu blok.
public struct SpeakerBlock: Sendable, Equatable, Identifiable {
    /// Bloğun ilk bölümünün kimliği.
    public let id: SegmentID
    public let speaker: Speaker
    public let startSec: Double
    public let segments: [LiveSegment]
}

/// Konuşmacının arayüzdeki ve kopyalanan metindeki adı.
public func speakerLabel(speaker: Speaker) -> String {
    switch speaker {
    case .me: "Sen"
    case .others: "Diğerleri"
    }
}

/// Sıralı transkripti, konuşmacı değiştikçe yeni blok başlayacak şekilde gruplar. Saf fonksiyondur.
public func groupBySpeaker(transcript: [LiveSegment]) -> [SpeakerBlock] {
    transcript.reduce(into: [SpeakerBlock]()) { (blocks: inout [SpeakerBlock], segment: LiveSegment) -> Void in
        if let last = blocks.last, last.speaker == segment.id.speaker {
            blocks[blocks.count - 1] = SpeakerBlock(
                id: last.id,
                speaker: last.speaker,
                startSec: last.startSec,
                segments: last.segments + [segment]
            )
        } else {
            blocks.append(SpeakerBlock(id: segment.id, speaker: segment.id.speaker, startSec: segment.startSec, segments: [segment]))
        }
    }
}

/// Blokları panoya kopyalanacak düz metne çevirir: `[mm:ss] Etiket: metin`, bloklar arasında boş satır.
/// Yazıya dökülemeyen ve boş bölümler atlanır.
public func plainText(blocks: [SpeakerBlock]) -> String {
    blocks
        .compactMap { (block: SpeakerBlock) -> String? in
            let text: String = block.segments
                .filter { (segment: LiveSegment) -> Bool in segment.failureMessage == nil && !segment.text.isEmpty }
                .map(\.text)
                .joined(separator: " ")
            guard !text.isEmpty else {
                return nil
            }
            return "[\(timestamp(seconds: block.startSec))] \(speakerLabel(speaker: block.speaker)): \(text)"
        }
        .joined(separator: "\n\n")
}

/// `mm:ss`, bir saati geçince `h:mm:ss`.
public func timestamp(seconds: Double) -> String {
    let total: Int = max(0, Int(seconds))
    let hours: Int = total / 3600
    let minutes: Int = (total % 3600) / 60
    let secs: Int = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%02d:%02d", minutes, secs)
}
