import Foundation

/// Görevin toplantı içindeki kimliği: sahibi ve işi (küçük harf, boşluklar sadeleşmiş). Not yeniden yazılınca sözcükler
/// değişebilir; işaretler `withCarriedTaskMarks` ile benzer yeni göreve taşınır. Saf fonksiyondur.
public func taskKey(task: NoteTask) -> String {
    let simplify: (String) -> String = { (text: String) -> String in
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    return simplify(task.owner) + "|" + simplify(task.description)
}

public extension NoteTask {
    /// Görevin toplantı içindeki kimliği (`taskKey`); listelerde satır kimliği olarak kullanılır.
    var trackingKey: String { taskKey(task: self) }
}

/// Toplantılardan kullanıcıya düşen görevler (verilen sırada). Saf fonksiyondur.
public func myTasks(meetings: [MeetingRecord]) -> [(record: MeetingRecord, task: NoteTask)] {
    meetings.flatMap { (record: MeetingRecord) -> [(record: MeetingRecord, task: NoteTask)] in
        (record.note?.tasks ?? []).filter(\.isMine).map { (record: record, task: $0) }
    }
}

/// Görev tamamlandı mı. Saf fonksiyondur.
public func isTaskDone(record: MeetingRecord, task: NoteTask) -> Bool {
    (record.completedTasks ?? []).contains(taskKey(task: task))
}

/// Görev Anımsatıcılar'a eklendi mi. Saf fonksiyondur.
public func isTaskReminded(record: MeetingRecord, task: NoteTask) -> Bool {
    (record.remindedTasks ?? []).contains(taskKey(task: task))
}

/// Görevin tamamlandı işaretini değiştirir. Saf fonksiyondur.
public func togglingTask(record: MeetingRecord, task: NoteTask) -> MeetingRecord {
    let key: String = taskKey(task: task)
    let done: [String] = record.completedTasks ?? []
    return record.with(completedTasks: done.contains(key) ? done.filter { $0 != key } : done + [key])
}

/// Görevi Anımsatıcılar'a eklenmiş olarak işaretler. Saf fonksiyondur.
public func markingReminded(record: MeetingRecord, task: NoteTask) -> MeetingRecord {
    let key: String = taskKey(task: task)
    let reminded: [String] = record.remindedTasks ?? []
    return reminded.contains(key) ? record : record.with(remindedTasks: reminded + [key])
}

/// Notun serbest metin tarihinden takvim günü: "2026-11-03", "3.11.2026", "3.11.", Türkçe "5 Kasım" ve "5 Kasım 2026"
/// (not tarihleri Türkçe yazar; yılsızda yıl toplantınınki, toplantıdan önceye düşerse ertesi yıl). "Perjantai", "sonraki dönem" gibi göreli ifadeler tarih vermez (nil). Saf fonksiyondur.
public func parseDueDate(text: String, meetingDate: Date, calendar: Calendar) -> DateComponents? {
    let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let meeting: DateComponents = calendar.dateComponents([.year, .month, .day], from: meetingDate)
    let parts: (year: Int?, month: Int, day: Int)?
    if let match = trimmed.firstMatch(of: /(\d{4})-(\d{1,2})-(\d{1,2})/) {
        parts = (Int(match.1), Int(match.2) ?? 0, Int(match.3) ?? 0)
    } else if let match = trimmed.firstMatch(of: /(\d{1,2})\.(\d{1,2})\.(\d{4})/) {
        parts = (Int(match.3), Int(match.2) ?? 0, Int(match.1) ?? 0)
    } else if let match = trimmed.firstMatch(of: /(\d{1,2})\.(\d{1,2})\./) {
        parts = (nil, Int(match.2) ?? 0, Int(match.1) ?? 0)
    } else if let match = trimmed.lowercased(with: Locale(identifier: "tr")).firstMatch(of: /(\d{1,2})\s+(ocak|şubat|mart|nisan|mayıs|haziran|temmuz|ağustos|eylül|ekim|kasım|aralık)\w*(?:\s+(\d{4}))?/) {
        let months: [String] = ["ocak", "şubat", "mart", "nisan", "mayıs", "haziran", "temmuz", "ağustos", "eylül", "ekim", "kasım", "aralık"]
        parts = (match.3.flatMap { Int($0) }, (months.firstIndex(of: String(match.2)) ?? -1) + 1, Int(match.1) ?? 0)
    } else {
        parts = nil
    }
    guard let parts, (1...12).contains(parts.month), (1...31).contains(parts.day), let meetingYear = meeting.year else {
        return nil
    }
    let year: Int = parts.year ?? {
        // Yılsız tarih toplantıdan önceye düşüyorsa gelecek yıldır.
        let sameYear: DateComponents = DateComponents(year: meetingYear, month: parts.month, day: parts.day)
        guard let date = calendar.date(from: sameYear), let start = calendar.date(from: meeting) else {
            return meetingYear
        }
        return date < start ? meetingYear + 1 : meetingYear
    }()
    let components: DateComponents = DateComponents(year: year, month: parts.month, day: parts.day)
    // 31.2. gibi geçersiz günler atılır.
    guard let date = calendar.date(from: components), calendar.component(.day, from: date) == parts.day else {
        return nil
    }
    return components
}

/// Anımsatıcılar'a eklenecek görev: başlık iş, notta toplantı ve sahibi; tarih çözülebiliyorsa son gün.
public struct ReminderDraft: Sendable, Equatable {
    public let title: String
    public let notes: String
    public let due: DateComponents?
}

/// Görevden anımsatıcı taslağı. Saf fonksiyondur.
public func reminderDraft(record: MeetingRecord, task: NoteTask, calendar: Calendar) -> ReminderDraft {
    let meetingTitle: String = record.note?.title ?? record.title
    let dueText: [String] = task.dueDate.map { [String(localized: "Tarih: \($0)")] } ?? []
    let notes: [String] = [String(localized: "Toplantı: \(meetingTitle)"), String(localized: "Sahibi: \(task.owner)")] + dueText
    return ReminderDraft(
        title: task.description,
        notes: notes.joined(separator: "\n"),
        due: task.dueDate.flatMap { parseDueDate(text: $0, meetingDate: record.startedAt, calendar: calendar) }
    )
}

/// Not yeniden yazılınca (ad verildi, şablon değişti) görevler başka sözcüklerle yazılır ve kimlikleri değişir.
/// İşaretli eski görevler yeni görevlere açıklamalarının sözcük benzerliğiyle (Jaccard ≥ 0,5, en benzeri) eşlenir;
/// eşleşenlerin yeni kimlikleri döner. Saf fonksiyondur.
public func carriedTaskKeys(oldTasks: [NoteTask], newTasks: [NoteTask], keys: [String]) -> [String] {
    let words: (NoteTask) -> Set<String> = { (task: NoteTask) -> Set<String> in Set(searchTokens(text: task.description).map { String($0.prefix(5)) }) }
    let marked: [NoteTask] = oldTasks.filter { keys.contains(taskKey(task: $0)) }
    return marked.reduce(into: [String]()) { (result: inout [String], old: NoteTask) -> Void in
        let oldWords: Set<String> = words(old)
        let best: (task: NoteTask, score: Double)? = newTasks
            .map { (new: NoteTask) -> (task: NoteTask, score: Double) in
                let newWords: Set<String> = words(new)
                let union: Int = oldWords.union(newWords).count
                return (task: new, score: union == 0 ? 0 : Double(oldWords.intersection(newWords).count) / Double(union))
            }
            .max { $0.score < $1.score }
        if let best, best.score >= 0.5, !result.contains(taskKey(task: best.task)) {
            result.append(taskKey(task: best.task))
        }
    }
}

/// Yeni not yazılmış kayıtta tamamlandı ve Anımsatıcılar işaretlerini eski nottan taşır. Saf fonksiyondur.
public func withCarriedTaskMarks(old: MeetingRecord, new: MeetingRecord) -> MeetingRecord {
    let oldTasks: [NoteTask] = old.note?.tasks ?? []
    let newTasks: [NoteTask] = new.note?.tasks ?? []
    let completed: MeetingRecord = old.completedTasks.map { new.with(completedTasks: carriedTaskKeys(oldTasks: oldTasks, newTasks: newTasks, keys: $0)) } ?? new
    return old.remindedTasks.map { completed.with(remindedTasks: carriedTaskKeys(oldTasks: oldTasks, newTasks: newTasks, keys: $0)) } ?? completed
}
