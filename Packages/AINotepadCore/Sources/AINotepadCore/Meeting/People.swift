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

/// Kullanıcının elle eklediği kişi (henüz toplantıda adı geçmese de Kişiler'de görünür; adı tanımaya verilir).
public struct SavedPerson: Sendable, Equatable, Codable {
    public let name: String
    /// Ünvan ya da kurum (ör. "Ürün müdürü, Acme").
    public let role: String
    public let email: String
    public let addedAt: Date

    public init(name: String, role: String, email: String, addedAt: Date) {
        self.name = name
        self.role = role
        self.email = email
        self.addedAt = addedAt
    }
}

/// Kaldırılan kişi: kaldırıldıktan sonraki bir toplantıda adı yeniden verilirse yeniden görünür.
public struct RemovedPerson: Sendable, Equatable, Codable {
    public let name: String
    public let removedAt: Date

    public init(name: String, removedAt: Date) {
        self.name = name
        self.removedAt = removedAt
    }
}

/// Kişiler defteri (`People.json`): elle eklenenler ve kaldırılanlar. Toplantılardan gelen kişiler ayrıca saklanmaz.
public struct PeopleBook: Sendable, Equatable, Codable {
    public let saved: [SavedPerson]
    public let removed: [RemovedPerson]

    public init(saved: [SavedPerson], removed: [RemovedPerson]) {
        self.saved = saved
        self.removed = removed
    }

    public static let empty: PeopleBook = PeopleBook(saved: [], removed: [])
}

/// Kişi ekler ya da (aynı ad, büyük/küçük harf duyarsız) bilgilerini günceller; kaldırılmışsa kaldırma kaydı silinir.
/// Ad boşsa defter aynen döner. Saf fonksiyondur.
public func addingPerson(book: PeopleBook, person: SavedPerson) -> PeopleBook {
    let name: String = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
        return book
    }
    let cleaned: SavedPerson = SavedPerson(
        name: name, role: person.role.trimmingCharacters(in: .whitespacesAndNewlines),
        email: person.email.trimmingCharacters(in: .whitespacesAndNewlines), addedAt: person.addedAt
    )
    return PeopleBook(
        saved: book.saved.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame } + [cleaned],
        removed: book.removed.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
    )
}

/// Elle eklenen kişinin adını ve bilgilerini değiştirir: eski kayıt yenisiyle yer değiştirir, kaldırma kaydı yazılmaz
/// (eski adın toplantıları gizlenmesin). Yeni ad boşsa defter aynen döner. Saf fonksiyondur.
public func renamingPerson(book: PeopleBook, oldName: String, person: SavedPerson) -> PeopleBook {
    let name: String = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
        return book
    }
    let original: Date = book.saved.first { $0.name.caseInsensitiveCompare(oldName) == .orderedSame }?.addedAt ?? person.addedAt
    let without: PeopleBook = PeopleBook(saved: book.saved.filter { $0.name.caseInsensitiveCompare(oldName) != .orderedSame }, removed: book.removed)
    return addingPerson(book: without, person: SavedPerson(name: name, role: person.role, email: person.email, addedAt: original))
}

/// Kişiyi kaldırır: elle eklenmişse silinir, toplantılardan geliyorsa `now`'dan önceki toplantılarla bir daha
/// görünmez. Saf fonksiyondur.
public func removingPerson(book: PeopleBook, name: String, now: Date) -> PeopleBook {
    PeopleBook(
        saved: book.saved.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame },
        removed: book.removed.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame } + [RemovedPerson(name: name, removedAt: now)]
    )
}

/// Adı verilmiş bir konuşmacının ya da elle eklenen kişinin toplantılar boyunca özeti (Kişiler sayfası).
public struct PersonSummary: Sendable, Equatable, Identifiable {
    public let name: String
    /// Elle eklenen bilgiler; yoksa boş.
    public let role: String
    public let email: String
    /// Elle eklendi (toplantıda adı geçmese de görünür).
    public let isSaved: Bool
    /// Yeniden eskiye.
    public let meetings: [PersonMeeting]
    public let tasks: [PersonTask]
    /// Sesinden tanınabiliyor (kayıtlı ses izi var).
    public let hasVoiceprint: Bool

    public var id: String { name.lowercased() }
    public var totalSeconds: Double { meetings.map(\.seconds).reduce(0, +) }
}

/// Kişiler: toplantılarda konuşmacıya verilen adlar (büyük/küçük harf duyarsız tek kişi) ve elle eklenenler; her
/// toplantıdaki konuşma süreleri, adına yazılmış görevler ve kayıtlı sesi. Kaldırılan kişi, kaldırıldıktan sonraki bir
/// toplantıda adı yeniden verilmedikçe görünmez. Toplantısı olanlar son görüldüğü toplantıya göre, toplantısı
/// olmayanlar en yeni eklenen önce sıralanır. Kullanıcının kendisi (görevleri Görevlerim'de) dahil değildir.
/// Saf fonksiyondur.
public func peopleDirectory(records: [MeetingRecord], voices: [RegisteredVoice], book: PeopleBook, userName: String) -> [PersonSummary] {
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
    let fromMeetings: [PersonSummary] = grouped.values.compactMap { (group: [(name: String, meeting: PersonMeeting)]) -> PersonSummary? in
        // Aynı ad bir toplantıda iki numaraya verildiyse (ayırma kişiyi bölmüş) toplantı bir kez, süreler toplanır.
        let meetings: [PersonMeeting] = Dictionary(grouping: group.map(\.meeting)) { $0.meetingID }.values
            .compactMap { (rows: [PersonMeeting]) -> PersonMeeting? in
                rows.first.map { PersonMeeting(meetingID: $0.meetingID, title: $0.title, date: $0.date, seconds: rows.map(\.seconds).reduce(0, +), fraction: rows.map(\.fraction).reduce(0, +)) }
            }
            .sorted { $0.date > $1.date }
        // Görünen ad: en yeni toplantıdaki yazılış; aynı toplantıda iki yazılışta sözlük sırasıyla ilki (her açılışta aynı).
        guard let latest = group.min(by: { $0.meeting.date != $1.meeting.date ? $0.meeting.date > $1.meeting.date : $0.name < $1.name }) else {
            return nil
        }
        let name: String = latest.name
        let saved: SavedPerson? = book.saved.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return personSummary(name: saved?.name ?? name, saved: saved, meetings: meetings, records: records, voices: voices)
    }
    .filter { (person: PersonSummary) -> Bool in
        // Kaldırılan kişi yalnızca kaldırıldıktan sonraki bir toplantıyla geri gelir.
        guard let removal = book.removed.first(where: { $0.name.caseInsensitiveCompare(person.name) == .orderedSame }) else {
            return true
        }
        return person.isSaved || (person.meetings.first?.date ?? .distantPast) > removal.removedAt
    }
    let withMeetings: [PersonSummary] = fromMeetings.sorted { ($0.meetings.first?.date ?? .distantPast) > ($1.meetings.first?.date ?? .distantPast) }
    let savedOnly: [PersonSummary] = book.saved
        .filter { (person: SavedPerson) -> Bool in
            person.name.caseInsensitiveCompare(userName) != .orderedSame
                && !fromMeetings.contains { $0.name.caseInsensitiveCompare(person.name) == .orderedSame }
        }
        .sorted { $0.addedAt > $1.addedAt }
        .map { personSummary(name: $0.name, saved: $0, meetings: [], records: records, voices: voices) }
    return savedOnly + withMeetings
}

/// Kişinin özeti: görevleri (notlarda sahibi bu ad olanlar) ve sesi. Saf fonksiyondur.
private func personSummary(name: String, saved: SavedPerson?, meetings: [PersonMeeting], records: [MeetingRecord], voices: [RegisteredVoice]) -> PersonSummary {
    let tasks: [PersonTask] = records.flatMap { (record: MeetingRecord) -> [PersonTask] in
        (record.note?.tasks ?? [])
            .filter { $0.owner.caseInsensitiveCompare(name) == .orderedSame }
            .map { PersonTask(meetingID: record.id, meetingTitle: record.note?.title ?? record.title, task: $0) }
    }
    return PersonSummary(
        name: name, role: saved?.role ?? "", email: saved?.email ?? "", isSaved: saved != nil, meetings: meetings, tasks: tasks,
        hasVoiceprint: voices.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    )
}

/// Kişiler defterinin dosyası (`Application Support/AINotepad/People.json`).
public func peopleFileURL() throws -> URL {
    try AppPaths.applicationSupport().appending(path: "People.json")
}

/// Kişiler defterini okur; dosya henüz yoksa boş.
public func loadPeopleBook(url: URL) throws -> PeopleBook {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return .empty
    }
    do {
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PeopleBook.self, from: Data(contentsOf: url))
    } catch {
        throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
    }
}

/// Kişiler defterini yazar (atomik).
public func savePeopleBook(book: PeopleBook, url: URL) throws {
    do {
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(book).write(to: url, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: url.path, reason: error.localizedDescription)
    }
}
