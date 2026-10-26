import Foundation

/// Toplantının okunur transkriptinde bir paragraf: aynı konuşmacının art arda bölümleri.
public struct TranscriptParagraph: Sendable, Equatable, Identifiable {
    /// İlk bölümün saklama anahtarı.
    public let id: String
    public let speaker: Speaker
    public let person: Int?
    public let startSec: Double
    public let endSec: Double
    public let text: String
    /// Bölümlerin Türkçeleri sırayla; hiç yoksa nil.
    public let turkish: String?
}

/// Bir paragraf bu süreyi geçince sonraki bölüm yeni paragraf başlatır (uzun konuşma tek duvar olmasın).
let paragraphMaxSec: Double = 60

/// Toplantının gösterilecek bölümleri: son geçiş varsa "Diğerleri" ondan, "Sen" canlıdan; zamana göre sıralı,
/// boşlar ve hoparlör yankısı süzülmüş. Toplantılar penceresi, not ve dışa aktarma bunu kullanır. Saf fonksiyondur.
public func meetingSegments(record: MeetingRecord) -> [StoredSegment] {
    let segments: [StoredSegment] = record.finalSegments.isEmpty
        ? record.liveSegments
        : record.finalSegments + record.liveSegments.filter { $0.speaker == .me }
    return suppressStoredEchoes(segments: segments
        .filter { !$0.text.isEmpty }
        .sorted { (left: StoredSegment, right: StoredSegment) -> Bool in left.startSec < right.startSec })
}

/// Bölümleri paragraflara toplar: konuşmacı (ya da kişi) değişince ya da paragraf `paragraphMaxSec`'i geçince
/// yeni paragraf. Saf fonksiyondur.
public func transcriptParagraphs(record: MeetingRecord) -> [TranscriptParagraph] {
    let groups: [[StoredSegment]] = meetingSegments(record: record).reduce(into: [[StoredSegment]]()) { (groups: inout [[StoredSegment]], segment: StoredSegment) -> Void in
        if let first = groups.last?.first, first.speaker == segment.speaker, first.person == segment.person,
           segment.startSec - first.startSec < paragraphMaxSec {
            groups[groups.count - 1].append(segment)
        } else {
            groups.append([segment])
        }
    }
    return groups.compactMap { (group: [StoredSegment]) -> TranscriptParagraph? in
        guard let first = group.first, let last = group.last else {
            return nil
        }
        let turkish: [String] = group.compactMap { record.translations[$0.key] }
        return TranscriptParagraph(
            id: first.key, speaker: first.speaker, person: first.person, startSec: first.startSec, endSec: last.endSec,
            text: group.map(\.text).joined(separator: " "),
            turkish: turkish.isEmpty ? nil : turkish.joined(separator: " ")
        )
    }
}

/// Paragrafın etiketi: kullanıcının verdiği ad, yoksa "Konuşmacı N", "Sen" ya da "Diğerleri". Saf fonksiyondur.
public func paragraphLabel(paragraph: TranscriptParagraph, speakerNames: [Int: String]) -> String {
    if let person = paragraph.person, let name = speakerNames[person], !name.isEmpty {
        return name
    }
    return speakerLabel(speaker: paragraph.speaker, person: paragraph.person)
}

/// Toplantı dilinin Türkçe adı. Saf fonksiyondur.
public func meetingLanguageName(language: MeetingLanguage) -> String {
    switch language {
    case .finnish: "Fince"
    case .english: "İngilizce"
    }
}

/// "26 Ekim 2026 10:00 · 42 dk · Fince": sayfa, Markdown ve PDF'in alt başlığı. Saf fonksiyondur.
public func meetingMetaLine(record: MeetingRecord) -> String {
    let formatter: DateFormatter = DateFormatter()
    formatter.locale = Locale(identifier: "tr_TR")
    formatter.dateStyle = .long
    formatter.timeStyle = .short
    let duration: [String] = record.endedAt.map { (endedAt: Date) -> [String] in
        ["\(max(1, Int((endedAt.timeIntervalSince(record.startedAt) / 60).rounded()))) dk"]
    } ?? []
    let language: [String] = record.language.map { [meetingLanguageName(language: $0)] } ?? []
    return ([formatter.string(from: record.startedAt)] + duration + language).joined(separator: " · ")
}
