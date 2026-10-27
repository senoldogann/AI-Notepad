import Foundation

/// Notun Apple Notlar'a yazılacak HTML gövdesi: başlık, tarih, senin görevlerin, özet, kararlar, diğer görevler;
/// metin kaçışlı. Saf fonksiyondur.
public func notesHTML(record: MeetingRecord, note: MeetingNote) -> String {
    let escape: (String) -> String = { (text: String) -> String in
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
    }
    let taskItem: (NoteTask) -> String = { (task: NoteTask) -> String in
        "<li><b>\(escape(task.owner))</b> — \(escape(task.description))\(task.dueDate.map { " (\(escape($0)))" } ?? "")</li>"
    }
    let mine: [NoteTask] = note.tasks.filter(\.isMine)
    let others: [NoteTask] = note.tasks.filter { !$0.isMine }
    var parts: [String] = ["<h1>\(escape(note.title))</h1>", "<p><i>\(escape(meetingMetaLine(record: record)))</i></p>"]
    if !mine.isEmpty {
        parts += ["<h2>\(escape(String(localized: "Senin görevlerin")))</h2>", "<ul>" + mine.map(taskItem).joined() + "</ul>"]
    }
    parts += ["<h2>\(escape(String(localized: "Özet")))</h2>", "<p>\(escape(note.summary))</p>"]
    if !note.decisions.isEmpty {
        parts += ["<h2>\(escape(String(localized: "Kararlar")))</h2>", "<ul>" + note.decisions.map { "<li>\(escape($0))</li>" }.joined() + "</ul>"]
    }
    if !others.isEmpty {
        parts += ["<h2>\(escape(String(localized: "Diğer görevler")))</h2>", "<ul>" + others.map(taskItem).joined() + "</ul>"]
    }
    return parts.joined(separator: "\n")
}

/// Apple Notlar'da "AI-Notepad" klasörüne not oluşturan AppleScript (klasör yoksa oluşturur). Gövde AppleScript
/// dizgesi olarak kaçışlanır. Saf fonksiyondur.
public func appleNotesScript(html: String) -> String {
    let quoted: String = "\"" + html.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    return """
    tell application "Notes"
        if not (exists folder "AI-Notepad") then make new folder with properties {name:"AI-Notepad"}
        make new note at folder "AI-Notepad" with properties {body:\(quoted)}
    end tell
    """
}

/// Klasöre yazılacak Markdown dosyasının adı: "2026-10-27 0930 Bütçe toplantısı.md"; dosya sisteminde sorunlu
/// karakterler temizlenir, ad 80 karakterle sınırlı. Saat aynı gün aynı adlı iki toplantının (iki "Daily") birbirinin
/// üstüne yazılmasını önler; aynı toplantı her zaman aynı ada yazılır (yeniden işlenince güncellenir).
/// Saf fonksiyondur.
public func markdownFileName(record: MeetingRecord) -> String {
    let formatter: DateFormatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HHmm"
    let title: String = (record.note?.title ?? record.title)
        .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t"))
        .joined(separator: " ")
        .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
    return "\(formatter.string(from: record.startedAt)) \(String(title.prefix(80)))".trimmingCharacters(in: .whitespaces) + ".md"
}

/// Toplantının Markdown'ını klasöre yazar (aynı ad varsa üzerine: yeniden işlenen not güncellenir); yazılan dosya.
public func exportMarkdown(record: MeetingRecord, folder: URL) throws -> URL {
    let file: URL = folder.appending(path: markdownFileName(record: record))
    do {
        try Data(meetingMarkdown(record: record).utf8).write(to: file, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
    return file
}
