import Foundation

/// Aynı kaynaktan ve aynı kişiden art arda gelen bölümlerin oluşturduğu blok.
public struct SpeakerBlock: Sendable, Equatable, Identifiable {
    /// Bloğun ilk bölümünün kimliği.
    public let id: SegmentID
    public let speaker: Speaker
    /// "Konuşmacı N"; atanmadıysa nil.
    public let person: Int?
    public let startSec: Double
    public let segments: [LiveSegment]
}

/// Konuşmacının arayüzdeki ve kopyalanan metindeki adı (arayüz dilinde): kişi atandıysa "Konuşmacı N".
public func speakerLabel(speaker: Speaker, person: Int?) -> String {
    switch (speaker, person) {
    case (_, .some(let number)): String(localized: "Konuşmacı \(number)")
    case (.me, nil): String(localized: "Sen")
    case (.others, nil): String(localized: "Diğerleri")
    }
}

/// LLM istemlerindeki etiket: arayüz dilinden bağımsız Türkçe (sistem istemi "Sen"i kullanıcı olarak tanımlar).
public func promptSpeakerLabel(speaker: Speaker, person: Int?) -> String {
    switch (speaker, person) {
    case (_, .some(let number)): "Konuşmacı \(number)"
    case (.me, nil): "Sen"
    case (.others, nil): "Diğerleri"
    }
}

/// Sıralı transkripti bloklara gruplar: konuşmacı ya da kişi değişince ya da blok `paragraphMaxSec`'i geçince yeni
/// blok (toplantı sayfasındaki paragraflarla aynı; saatlerce tek konuşmacı tek dev blok olup her güncellemede baştan
/// çizilmesin). Bölümler önce gruplara toplanır, bloklar sonda bir kez kurulur (her bölümde blok kopyalamak uzun
/// toplantıda karesel büyürdü). Saf fonksiyondur.
public func groupBySpeaker(transcript: [LiveSegment]) -> [SpeakerBlock] {
    var groups: [[LiveSegment]] = []
    for segment in transcript {
        if let first = groups.last?.first, first.id.speaker == segment.id.speaker, first.person == segment.person,
           segment.startSec - first.startSec < paragraphMaxSec {
            groups[groups.count - 1].append(segment)
        } else {
            groups.append([segment])
        }
    }
    return groups.compactMap { (group: [LiveSegment]) -> SpeakerBlock? in
        guard let first = group.first else {
            return nil
        }
        return SpeakerBlock(id: first.id, speaker: first.id.speaker, person: first.person, startSec: first.startSec, segments: group)
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
            return "[\(timestamp(seconds: block.startSec))] \(speakerLabel(speaker: block.speaker, person: block.person)): \(text)"
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

/// `timestamp(seconds:)` biçimindeki metni ("02:05", "1:02:05") saniyeye çevirir; biçim tutmazsa nil. Saf fonksiyondur.
public func timestampSeconds(text: String) -> Double? {
    let parts: [Int] = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ":").compactMap { Int($0) }
    guard (2...3).contains(parts.count), parts.count == text.filter({ $0 == ":" }).count + 1, parts.allSatisfy({ $0 >= 0 }) else {
        return nil
    }
    return Double(parts.reduce(0) { (total: Int, part: Int) -> Int in total * 60 + part })
}
