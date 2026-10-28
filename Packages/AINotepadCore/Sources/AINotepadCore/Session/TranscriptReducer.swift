import Foundation

/// Olayı transkripte uygular. Saf fonksiyondur.
///
/// Aynı kimlikli bölüm yerinde güncellenir ve atanmış kişi numarasını korur; boş metinli ve hatasız
/// kesin bölüm silinir (konuşma yokmuş demektir); liste başlangıç zamanına göre sıralı tutulur.
/// Kişi ataması ilgili bölümlerin `person` alanını günceller.
public func applyEvent(transcript: [LiveSegment], event: LiveSessionEvent) -> [LiveSegment] {
    switch event {
    case .segment(let incoming):
        return applySegment(transcript: transcript, incoming: incoming)
    case .speakersAssigned(let assignments):
        return transcript.map { (segment: LiveSegment) -> LiveSegment in
            assignments[segment.id].map { (person: Int) -> LiveSegment in withPerson(segment: segment, person: person) } ?? segment
        }
    case .languageLocked, .captureEnded, .recordingFailed, .streamFailed, .streamIncomplete, .diarizationFailed:
        return transcript
    }
}

private func applySegment(transcript: [LiveSegment], incoming update: LiveSegment) -> [LiveSegment] {
    let previousPerson: Int? = transcript.first { (existing: LiveSegment) -> Bool in existing.id == update.id }?.person
    let incoming: LiveSegment = update.person == nil ? withPerson(segment: update, person: previousPerson) : update
    let others: [LiveSegment] = transcript.filter { (existing: LiveSegment) -> Bool in existing.id != incoming.id }
    let isEmptyFinal: Bool = incoming.isFinal && incoming.text.isEmpty && incoming.failureMessage == nil
    let updated: [LiveSegment] = isEmptyFinal ? others : others + [incoming]
    return updated.sorted { (left: LiveSegment, right: LiveSegment) -> Bool in
        left.startSec == right.startSec ? left.id.speaker == .me && right.id.speaker == .others : left.startSec < right.startSec
    }
}

private func withPerson(segment: LiveSegment, person: Int?) -> LiveSegment {
    LiveSegment(
        id: segment.id,
        startSec: segment.startSec,
        endSec: segment.endSec,
        text: segment.text,
        isFinal: segment.isFinal,
        failureMessage: segment.failureMessage,
        person: person
    )
}
