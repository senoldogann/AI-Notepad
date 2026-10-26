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
    /// Çalarken vurgulanacak kelimeler: son geçişin gerçek zamanları, yoksa bölüm süresine göre tahmin.
    public let words: [StoredWord]
}

/// Kelime zamanı olmayan bölüm için tahmini zamanlar: süre kelimelere harf sayısıyla orantılı bölünür. Saf fonksiyondur.
public func estimatedWords(text: String, startSec: Double, endSec: Double) -> [StoredWord] {
    let tokens: [String] = text.split(separator: " ").map(String.init)
    let totalLetters: Double = Double(tokens.reduce(0) { $0 + max(1, $1.count) })
    guard !tokens.isEmpty, endSec > startSec else {
        return []
    }
    var cursor: Double = startSec
    return tokens.map { (token: String) -> StoredWord in
        let duration: Double = (endSec - startSec) * Double(max(1, token.count)) / totalLetters
        defer { cursor += duration }
        return StoredWord(text: token, startSec: cursor, endSec: cursor + duration)
    }
}

/// Çalma anında vurgulanacak kelime: başlangıcı geçilmiş son kelime; ilk kelimeden önceyse nil. Saf fonksiyondur.
public func activeWordIndex(words: [StoredWord], timeSec: Double) -> Int? {
    words.lastIndex { (word: StoredWord) -> Bool in word.startSec <= timeSec }
}

/// Bir paragraf bu süreyi geçince sonraki bölüm yeni paragraf başlatır (uzun konuşma tek duvar olmasın).
let paragraphMaxSec: Double = 60

/// Toplantının gösterilecek bölümleri: her taraf için son geçiş varsa ondan, yoksa canlıdan ("Sen" yalnızca canlı akış
/// koptuysa son geçişten gelir); zamana göre sıralı, boşlar ve hoparlör yankısı süzülmüş. Toplantılar penceresi, not ve
/// dışa aktarma bunu kullanır. Saf fonksiyondur.
public func meetingSegments(record: MeetingRecord) -> [StoredSegment] {
    let side: (Speaker) -> [StoredSegment] = { (speaker: Speaker) -> [StoredSegment] in
        let final: [StoredSegment] = record.finalSegments.filter { $0.speaker == speaker }
        return final.isEmpty ? record.liveSegments.filter { $0.speaker == speaker } : final
    }
    let segments: [StoredSegment] = side(.others) + side(.me)
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
            turkish: turkish.isEmpty ? nil : turkish.joined(separator: " "),
            words: group.flatMap { (segment: StoredSegment) -> [StoredWord] in
                segment.words ?? estimatedWords(text: segment.text, startSec: segment.startSec, endSec: segment.endSec)
            }
        )
    }
}

/// Toplantıda bir sesin kimliği: taraf ve (ayrıldıysa) kişi numarası. Renk, konuşma payı ve zaman çizgisi bununla eşlenir.
public struct SpeakerKey: Sendable, Hashable {
    public let speaker: Speaker
    public let person: Int?

    public init(speaker: Speaker, person: Int?) {
        self.speaker = speaker
        self.person = person
    }
}

/// Bir konuşmacının toplam konuşma süresi ve toplamdaki payı (0...1).
public struct SpeakerShare: Sendable, Equatable {
    public let key: SpeakerKey
    public let seconds: Double
    public let fraction: Double
}

/// Zaman çizgisinde bir konuşmacının kesintisiz konuştuğu aralık.
public struct SpeakerSpan: Sendable, Equatable {
    public let key: SpeakerKey
    public let startSec: Double
    public let endSec: Double
}

/// Aynı konuşmacının iki paragrafı arasındaki boşluk bundan kısaysa zaman çizgisinde tek aralık olur.
let spanJoinGapSec: Double = 3

/// Konuşma payları, çok konuşandan aza; eşitlikte kişi numarasına göre. Konuşma yoksa boş. Saf fonksiyondur.
public func speakerShares(paragraphs: [TranscriptParagraph]) -> [SpeakerShare] {
    let seconds: [SpeakerKey: Double] = paragraphs.reduce(into: [SpeakerKey: Double]()) { (totals: inout [SpeakerKey: Double], paragraph: TranscriptParagraph) -> Void in
        totals[SpeakerKey(speaker: paragraph.speaker, person: paragraph.person), default: 0] += max(0, paragraph.endSec - paragraph.startSec)
    }
    let total: Double = seconds.values.reduce(0, +)
    guard total > 0 else {
        return []
    }
    return seconds
        .map { (key: SpeakerKey, value: Double) -> SpeakerShare in SpeakerShare(key: key, seconds: value, fraction: value / total) }
        .sorted { (left: SpeakerShare, right: SpeakerShare) -> Bool in
            if left.seconds != right.seconds {
                return left.seconds > right.seconds
            }
            return (left.key.person ?? 0, left.key.speaker.rawValue) < (right.key.person ?? 0, right.key.speaker.rawValue)
        }
}

/// Zaman çizgisi: art arda gelen ve arası `spanJoinGapSec`'ten kısa aynı konuşmacı paragrafları tek aralık. Saf fonksiyondur.
public func speakerSpans(paragraphs: [TranscriptParagraph]) -> [SpeakerSpan] {
    paragraphs.reduce(into: [SpeakerSpan]()) { (spans: inout [SpeakerSpan], paragraph: TranscriptParagraph) -> Void in
        let key: SpeakerKey = SpeakerKey(speaker: paragraph.speaker, person: paragraph.person)
        if let last = spans.last, last.key == key, paragraph.startSec - last.endSec < spanJoinGapSec {
            spans[spans.count - 1] = SpeakerSpan(key: key, startSec: last.startSec, endSec: max(last.endSec, paragraph.endSec))
        } else {
            spans.append(SpeakerSpan(key: key, startSec: paragraph.startSec, endSec: paragraph.endSec))
        }
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
    case .finnish: String(localized: "Fince")
    case .english: String(localized: "İngilizce")
    }
}

/// Arayüz dilinin yerel ayarı (tarih biçimleri için): uygulamanın seçili dili, bölge sistemden (Finlandiya'da İngilizce
/// arayüz 24 saatlik saat ve gün.ay.yıl kullanır). Paketin yerelleştirmesi yoksa (testler) geliştirme dili Türkçe.
public func interfaceLocale() -> Locale {
    var components: Locale.Components = Locale.Components(identifier: Bundle.main.preferredLocalizations.first ?? "tr")
    components.region = Locale.current.region
    return Locale(components: components)
}

/// Toplantının süresi (dakika, en az 1); henüz bitmediyse nil. Saf fonksiyondur.
public func meetingDurationMinutes(record: MeetingRecord) -> Int? {
    record.endedAt.map { (endedAt: Date) -> Int in max(1, Int((endedAt.timeIntervalSince(record.startedAt) / 60).rounded())) }
}

/// "26 Ekim 2026 10:00 · 42 dk · Fince": sayfa, Markdown ve PDF'in alt başlığı. Saf fonksiyondur.
public func meetingMetaLine(record: MeetingRecord) -> String {
    let formatter: DateFormatter = DateFormatter()
    formatter.locale = interfaceLocale()
    formatter.dateStyle = .long
    formatter.timeStyle = .short
    let duration: [String] = meetingDurationMinutes(record: record).map { (minutes: Int) -> [String] in
        [String(localized: "\(minutes) dk")]
    } ?? []
    let language: [String] = record.language.map { [meetingLanguageName(language: $0)] } ?? []
    return ([formatter.string(from: record.startedAt)] + duration + language).joined(separator: " · ")
}
