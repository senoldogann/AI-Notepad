import Foundation

/// Olayı transkripte uygular. Saf fonksiyondur.
///
/// Aynı kimlikli bölüm yerinde güncellenir; boş metinli ve hatasız kesin bölüm silinir
/// (konuşma yokmuş demektir); liste başlangıç zamanına göre sıralı tutulur.
public func applyEvent(transcript: [LiveSegment], event: LiveSessionEvent) -> [LiveSegment] {
    guard case .segment(let incoming) = event else {
        return transcript
    }
    let others: [LiveSegment] = transcript.filter { (existing: LiveSegment) -> Bool in existing.id != incoming.id }
    let isEmptyFinal: Bool = incoming.isFinal && incoming.text.isEmpty && incoming.failureMessage == nil
    let updated: [LiveSegment] = isEmptyFinal ? others : others + [incoming]
    return updated.sorted { (left: LiveSegment, right: LiveSegment) -> Bool in
        left.startSec == right.startSec ? left.id.speaker == .me && right.id.speaker == .others : left.startSec < right.startSec
    }
}
