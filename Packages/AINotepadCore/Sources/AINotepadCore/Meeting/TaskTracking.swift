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
/// İşaretli eski görev yeni notta aynı kimlikle varsa o alınır; yoksa açıklamalarının sözcük benzerliğiyle (Jaccard
/// ≥ 0,5, en benzeri) eşlenir; eşleşenlerin yeni kimlikleri döner. Saf fonksiyondur.
public func carriedTaskKeys(oldTasks: [NoteTask], newTasks: [NoteTask], keys: [String]) -> [String] {
    let words: (NoteTask) -> Set<String> = { (task: NoteTask) -> Set<String> in Set(searchTokens(text: task.description).map { String($0.prefix(5)) }) }
    let marked: [NoteTask] = oldTasks.filter { keys.contains(taskKey(task: $0)) }
    let newKeys: [String] = newTasks.map { taskKey(task: $0) }
    return marked.reduce(into: [String]()) { (result: inout [String], old: NoteTask) -> Void in
        // Değişmeyen görev kendisiyle eşlenir (benzerlik, aynı açıklamalı iki görevi ya da sözcüksüz görevi şaşırabilir).
        let oldKey: String = taskKey(task: old)
        if newKeys.contains(oldKey) {
            if !result.contains(oldKey) {
                result.append(oldKey)
            }
            return
        }
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

/// Yeni not yazılmış kayıtta tamamlandı, Anımsatıcılar ve araca (Linear, Jira) gönderildi işaretlerini eski nottan
/// taşır. Gönderildi işareti taşınmazsa yeniden yazılan not görevleri araçta ikinci kez açardı. Saf fonksiyondur.
public func withCarriedTaskMarks(old: MeetingRecord, new: MeetingRecord) -> MeetingRecord {
    let oldTasks: [NoteTask] = old.note?.tasks ?? []
    let newTasks: [NoteTask] = new.note?.tasks ?? []
    let carry: ([String]) -> [String] = { (keys: [String]) -> [String] in carriedTaskKeys(oldTasks: oldTasks, newTasks: newTasks, keys: keys) }
    let completed: MeetingRecord = old.completedTasks.map { new.with(completedTasks: carry($0)) } ?? new
    let reminded: MeetingRecord = old.remindedTasks.map { completed.with(remindedTasks: carry($0)) } ?? completed
    return old.sentTaskKeys.map { (sent: [String: [String]]) -> MeetingRecord in
        reminded.with(sentTaskKeys: sent.mapValues(carry))
    } ?? reminded
}

/// Listelerin sırayı koruyan, tekrarsız birleşimi; hepsi nil ise nil. Saf fonksiyondur.
private func unitedKeys(lists: [[String]?]) -> [String]? {
    let present: [[String]] = lists.compactMap { $0 }
    guard !present.isEmpty else {
        return nil
    }
    return present.joined().reduce(into: [String]()) { (result: inout [String], key: String) -> Void in
        if !result.contains(key) {
            result.append(key)
        }
    }
}

/// Notun gönderim işaretlerini birleştirir: gönderildiği hedefler (tekrarsız), Apple Notlar ve webhook anlarının en
/// eskisi. Bu işaretler görevlere değil nota bağlıdır; not değişse de olduğu gibi geçer. Saf fonksiyondur.
private func unitingNoteSendMarks(current: MeetingRecord, others: [MeetingRecord]) -> MeetingRecord {
    let records: [MeetingRecord] = [current] + others
    return current.with(
        sentDestinationIDs: unitedKeys(lists: records.map(\.sentDestinationIDs)),
        notesSentAt: records.compactMap(\.notesSentAt).min(),
        webhookSentAt: records.compactMap(\.webhookSentAt).min()
    )
}

/// Aynı toplantının iki ya da daha çok sürümündeki kullanıcı işaretlerini `current`'a birleştirir: tamamlanan,
/// Anımsatıcılar'a eklenen ve araca gönderilen (araç başına) görevler ile notun gönderildiği hedefler tekrarsız
/// birleşir; Apple Notlar ve webhook gönderim anlarının en eskisi kalır. Diğer alanlar `current`'tan gelir. Görev
/// işaretleri olduğu gibi birleşir: sürümlerin notları farklıysa önce `withCarriedTaskMarks` ile taşınmalıdır
/// (bkz. `mergingConflictVersions`). Saf fonksiyondur.
public func mergingUserMarks(current: MeetingRecord, others: [MeetingRecord]) -> MeetingRecord {
    let records: [MeetingRecord] = [current] + others
    let completed: MeetingRecord = unitedKeys(lists: records.map(\.completedTasks)).map { current.with(completedTasks: $0) } ?? current
    let reminded: MeetingRecord = unitedKeys(lists: records.map(\.remindedTasks)).map { completed.with(remindedTasks: $0) } ?? completed
    let trackers: [String] = unitedKeys(lists: records.map { $0.sentTaskKeys.map { Array($0.keys).sorted() } }) ?? []
    let sentTasks: MeetingRecord = records.allSatisfy { $0.sentTaskKeys == nil }
        ? reminded
        : reminded.with(sentTaskKeys: Dictionary(uniqueKeysWithValues: trackers.map { (tracker: String) -> (String, [String]) in
            (tracker, unitedKeys(lists: records.map { $0.sentTaskKeys?[tracker] }) ?? [])
        }))
    return unitingNoteSendMarks(current: sentTasks, others: others)
}

/// iCloud çakışmasındaki sürümlerin işaretlerini son yazılan sürüme birleştirir. Sürümlerin notları farklı olabilir
/// (ör. iPhone'da görev işaretlenirken Mac notu yeniden yazdı): her sürümün görev işaretleri önce `current`'ın
/// görevlerine taşınır (`withCarriedTaskMarks`), notun gönderim işaretleri olduğu gibi kalır; sonra hepsi
/// `mergingUserMarks` ile birleşir. Saf fonksiyondur.
public func mergingConflictVersions(current: MeetingRecord, others: [MeetingRecord]) -> MeetingRecord {
    let carried: [MeetingRecord] = others.map { (other: MeetingRecord) -> MeetingRecord in
        withCarriedTaskMarks(old: other, new: current)
            .with(sentDestinationIDs: other.sentDestinationIDs, notesSentAt: other.notesSentAt, webhookSentAt: other.webhookSentAt)
    }
    return mergingUserMarks(current: current, others: carried)
}

/// Uzun not işinin (işleme, düzenleme, yeniden yazma; 30–300 sn) sonucuna eski kaydın işaretlerini uygular: görev
/// işaretleri benzer yeni görevlere taşınır (`withCarriedTaskMarks`), notun gönderim işaretleri eklenir. `old`: eski
/// notlu kaydın en güncel işaretli hali (iş bitince diskten okunan kayıt, bekleyen
/// işaretleri uygulanmış). Böylece iş sürerken diğer cihazda ya da kendiliğinden gönderimde konan işaretler işin
/// sonucuyla ezilmez. Saf fonksiyondur.
public func withJobMarks(old: MeetingRecord, result: MeetingRecord) -> MeetingRecord {
    unitingNoteSendMarks(current: withCarriedTaskMarks(old: old, new: result), others: [old])
}
