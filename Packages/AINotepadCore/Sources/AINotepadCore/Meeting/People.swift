import Foundation

/// Bir kişinin bir toplantıdaki yeri: konuşma süresi ve payı.
public struct PersonMeeting: Sendable, Equatable {
    public let meetingID: String
    public let title: String
    public let date: Date
    public let seconds: Double
    public let fraction: Double
}

/// Bir kişinin görevi ve toplantısı.
public struct PersonTask: Sendable, Equatable {
    public let meetingID: String
    public let meetingTitle: String
    public let task: NoteTask
}

/// Adı verilmiş bir konuşmacının toplantılar boyunca özeti (Kişiler sayfası).
public struct PersonSummary: Sendable, Equatable, Identifiable {
    public let name: String
    /// Yeniden eskiye.
    public let meetings: [PersonMeeting]
    public let tasks: [PersonTask]
    /// Sesinden tanınabiliyor (kayıtlı ses izi var).
    public let hasVoiceprint: Bool

    public var id: String { name.lowercased() }
    public var totalSeconds: Double { meetings.map(\.seconds).reduce(0, +) }
}

/// Kişiler: toplantılarda konuşmacıya verilen adlar (büyük/küçük harf duyarsız tek kişi), her toplantıdaki konuşma
/// süreleri, adına yazılmış görevler ve kayıtlı sesi. Son görüldüğü toplantıya göre sıralı. Kullanıcının kendisi
/// (görevleri Görevlerim'de) dahil değildir. Saf fonksiyondur.
public func peopleDirectory(records: [MeetingRecord], voices: [RegisteredVoice], userName: String) -> [PersonSummary] {
    let entries: [(name: String, meeting: PersonMeeting)] = records.flatMap { (record: MeetingRecord) -> [(name: String, meeting: PersonMeeting)] in
        let shares: [SpeakerShare] = speakerShares(paragraphs: transcriptParagraphs(record: record))
        return record.speakerNames.compactMap { (entry: (key: Int, value: String)) -> (name: String, meeting: PersonMeeting)? in
            let name: String = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.caseInsensitiveCompare(userName) != .orderedSame else {
                return nil
            }
            let share: SpeakerShare? = shares.first { $0.key.person == entry.key }
            return (name: name, meeting: PersonMeeting(
                meetingID: record.id, title: record.note?.title ?? record.title, date: record.startedAt,
                seconds: share?.seconds ?? 0, fraction: share?.fraction ?? 0
            ))
        }
    }
    let grouped: [String: [(name: String, meeting: PersonMeeting)]] = Dictionary(grouping: entries) { $0.name.lowercased() }
    return grouped.values.compactMap { (group: [(name: String, meeting: PersonMeeting)]) -> PersonSummary? in
        // Aynı ad bir toplantıda iki numaraya verildiyse (ayırma kişiyi bölmüş) toplantı bir kez, süreler toplanır.
        let meetings: [PersonMeeting] = Dictionary(grouping: group.map(\.meeting)) { $0.meetingID }.values
            .compactMap { (rows: [PersonMeeting]) -> PersonMeeting? in
                rows.first.map { PersonMeeting(meetingID: $0.meetingID, title: $0.title, date: $0.date, seconds: rows.map(\.seconds).reduce(0, +), fraction: rows.map(\.fraction).reduce(0, +)) }
            }
            .sorted { $0.date > $1.date }
        guard let latest = group.max(by: { $0.meeting.date < $1.meeting.date }) else {
            return nil
        }
        let name: String = latest.name
        let tasks: [PersonTask] = records.flatMap { (record: MeetingRecord) -> [PersonTask] in
            (record.note?.tasks ?? [])
                .filter { $0.owner.caseInsensitiveCompare(name) == .orderedSame }
                .map { PersonTask(meetingID: record.id, meetingTitle: record.note?.title ?? record.title, task: $0) }
        }
        return PersonSummary(
            name: name, meetings: meetings, tasks: tasks,
            hasVoiceprint: voices.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        )
    }
    .sorted { ($0.meetings.first?.date ?? .distantPast) > ($1.meetings.first?.date ?? .distantPast) }
}
