import Foundation

/// Görevin toplantı içindeki kalıcı kimliği: sahibi ve işi (küçük harf, boşluklar sadeleşmiş). Not yeniden yazılınca
/// aynı görev aynı kimliği alır; tamamlandı işareti korunur. Saf fonksiyondur.
public func taskKey(task: NoteTask) -> String {
    let simplify: (String) -> String = { (text: String) -> String in
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    return simplify(task.owner) + "|" + simplify(task.description)
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

/// Notun serbest metin tarihinden takvim günü: "2026-11-03", "3.11.2026", "3.11." (yıl toplantınınki; toplantıdan
/// önceye düşerse ertesi yıl). "Perjantai", "sonraki dönem" gibi göreli ifadeler tarih vermez (nil). Saf fonksiyondur.
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
