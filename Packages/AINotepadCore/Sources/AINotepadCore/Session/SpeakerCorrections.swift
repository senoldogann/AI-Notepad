import Foundation

/// Kullanıcının kayıt sırasında yaptığı konuşmacı düzeltmeleri. Otomatik ayırmanın sonraki atamaları bunları ezmez.
public struct SpeakerCorrections: Sendable, Equatable {
    /// Bölüm → kişi (tek bir bloğu başka konuşmacıya atama).
    public let overrides: [SegmentID: Int]
    /// Kişi → kişi (bir konuşmacının tümünü başkasıyla birleştirme; geçmiş ve gelecek bölümler).
    public let merges: [Int: Int]

    public init(overrides: [SegmentID: Int], merges: [Int: Int]) {
        self.overrides = overrides
        self.merges = merges
    }

    public static let none: SpeakerCorrections = SpeakerCorrections(overrides: [:], merges: [:])

    /// Bölümleri (bir blok) verilen kişiye atar.
    public func assigning(segments: [SegmentID], to person: Int) -> SpeakerCorrections {
        SpeakerCorrections(overrides: overrides.merging(segments.map { ($0, person) }) { $1 }, merges: merges)
    }

    /// `from` kişisini `into` ile birleştirir; `into` başka birine birleşmişse zincir son kişide biter.
    public func merging(person from: Int, into: Int) -> SpeakerCorrections {
        guard from != into else {
            return self
        }
        let target: Int = resolvedPerson(person: into, merges: merges)
        // Önceden `from`'a birleşenler de yeni hedefe gider.
        let updated: [Int: Int] = merges.mapValues { $0 == from ? target : $0 }.merging([from: target]) { $1 }
        return SpeakerCorrections(overrides: overrides.mapValues { $0 == from ? target : $0 }, merges: updated)
    }
}

/// Birleştirme zincirinin son kişisi. Saf fonksiyondur.
func resolvedPerson(person: Int, merges: [Int: Int]) -> Int {
    var current: Int = person
    var visited: Set<Int> = [person]
    while let next = merges[current], !visited.contains(next) {
        visited.insert(next)
        current = next
    }
    return current
}

/// Düzeltmeleri transkripte uygular: önce bölüm ataması, sonra birleştirme. "Sen" bölümleri değişmez. Saf fonksiyondur.
public func applyCorrections(transcript: [LiveSegment], corrections: SpeakerCorrections) -> [LiveSegment] {
    guard corrections != .none else {
        return transcript
    }
    return transcript.map { (segment: LiveSegment) -> LiveSegment in
        guard segment.id.speaker == .others else {
            return segment
        }
        let assigned: Int? = corrections.overrides[segment.id] ?? segment.person
        let person: Int? = assigned.map { resolvedPerson(person: $0, merges: corrections.merges) }
        return LiveSegment(
            id: segment.id, startSec: segment.startSec, endSec: segment.endSec, text: segment.text,
            isFinal: segment.isFinal, failureMessage: segment.failureMessage, person: person
        )
    }
}

/// "Yeni konuşmacı" için kullanılmamış numara: ham transkriptteki, birleştirmelerdeki ve atamalardaki tüm
/// numaraların üstü (birleştirilip kaybolan bir numara yeniden verilirse eski kişiye geri eşlenirdi). Saf fonksiyondur.
public func nextFreePerson(transcript: [LiveSegment], corrections: SpeakerCorrections) -> Int {
    let used: [Int] = transcript.compactMap(\.person)
        + Array(corrections.merges.keys) + Array(corrections.merges.values)
        + Array(corrections.overrides.values)
    return (used.max() ?? 0) + 1
}

/// Transkriptte görünen kişi numaraları (sıralı). Saf fonksiyondur.
public func knownPersons(transcript: [LiveSegment]) -> [Int] {
    Array(Set(transcript.compactMap(\.person))).sorted()
}

/// Kaydedilmiş toplantıda bir konuşmacıyı diğeriyle birleştirir (son geçiş ve canlı bölümler); birleşen kişinin adı
/// hedefte yoksa hedefe taşınır. Saf fonksiyondur.
public func mergingPersons(record: MeetingRecord, from: Int, into: Int) -> MeetingRecord {
    guard from != into else {
        return record
    }
    let remap: (StoredSegment) -> StoredSegment = { (segment: StoredSegment) -> StoredSegment in
        segment.person == from ? segment.with(person: into) : segment
    }
    var names: [Int: String] = record.speakerNames
    if names[into] == nil, let moved = names[from] {
        names[into] = moved
    }
    names[from] = nil
    // Aynı kişinin iki izi birleşir (sesinden tanıma bir sonraki toplantıda bu kişiyi tek iz olarak bilsin).
    let voiceprints: [Int: Voiceprint]? = record.voiceprints.map { (voices: [Int: Voiceprint]) -> [Int: Voiceprint] in
        var merged: [Int: Voiceprint] = voices
        merged[into] = switch (voices[from], voices[into]) {
        case (.some(let moved), .some(let kept)): mergedVoiceprint(kept, moved)
        case (.some(let moved), .none): moved
        case (.none, let kept): kept
        }
        merged[from] = nil
        return merged
    }
    return record
        .with(finalSegments: record.finalSegments.map(remap), language: record.language)
        .with(liveSegments: record.liveSegments.map(remap))
        .with(speakerNames: names)
        .with(voiceprints: voiceprints)
}
