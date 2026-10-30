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

/// Apple Notlar'da `folder` klasörüne (uygulamanın görünen adı: "AI-Notepad" ya da "Gistsmith") not oluşturan
/// AppleScript (klasör yoksa oluşturur). Klasör adı ve gövde AppleScript dizgesi olarak kaçışlanır. Saf fonksiyondur.
public func appleNotesScript(html: String, folder: String) -> String {
    let quote: (String) -> String = { (text: String) -> String in
        "\"" + text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }
    let folderName: String = quote(folder)
    return """
    tell application "Notes"
        if not (exists folder \(folderName)) then make new folder with properties {name:\(folderName)}
        make new note at folder \(folderName) with properties {body:\(quote(html))}
    end tell
    """
}

/// Klasöre yazılacak Markdown dosyasının adı: "2026-10-27 0930 Bütçe toplantısı.md"; dosya sisteminde sorunlu
/// karakterler temizlenir, ad 80 karakterle sınırlı. Saat aynı gün aynı adlı iki toplantının (iki "Daily") birbirinin
/// üstüne yazılmasını önler. Ad notun başlığını izler; başlık değişince (yeniden adlandırma, yeniden yazılan not) eski
/// adlı kopyayı `exportMarkdown` siler. Saf fonksiyondur.
public func markdownFileName(record: MeetingRecord) -> String {
    let title: String = (record.note?.title ?? record.title)
        .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t"))
        .joined(separator: " ")
        .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
    return "\(markdownFileNamePrefix(record: record)) \(String(title.prefix(80)))".trimmingCharacters(in: .whitespaces) + ".md"
}

/// Dosya adının başlıktan bağımsız başı: toplantının başladığı gün ve dakika ("2026-10-27 0930"). Saf fonksiyondur.
private func markdownFileNamePrefix(record: MeetingRecord) -> String {
    let formatter: DateFormatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HHmm"
    return formatter.string(from: record.startedAt)
}

/// Klasör kopyasının son satırı: dosyanın hangi toplantıya ait olduğunu söyleyen HTML yorumu (Markdown okuyucularında
/// görünmez). Başlık değişince aynı toplantının eski adlı kopyası bununla bulunur. Saf fonksiyondur.
func markdownExportMarker(meetingID: String) -> String {
    "<!-- meeting-id: \(meetingID) -->"
}

/// Klasördeki dosya adlarından aynı toplantının eski adlı kopyası olabilecekler: aynı gün ve dakikayla başlayan, yeni
/// addan farklı `.md` dosyaları. Kesin karar dosyadaki işarettir (`markdownExportMarker`). Saf fonksiyondur.
func staleMarkdownExportCandidates(record: MeetingRecord, fileNames: [String]) -> [String] {
    let current: String = markdownFileName(record: record)
    let prefix: String = markdownFileNamePrefix(record: record)
    return fileNames.filter { (name: String) -> Bool in
        name != current && name.hasSuffix(".md") && (name.hasPrefix(prefix + " ") || name == prefix + ".md")
    }
}

/// Toplantının Markdown'ını klasöre yazar (aynı ad varsa üzerine: yeniden işlenen not güncellenir) ve başlık değiştiği
/// için eski adla kalmış kopyasını siler: klasörde her toplantının tek dosyası olur. Yalnızca bu toplantının işaretini
/// (`markdownExportMarker`) taşıyan dosyalar silinir; kullanıcının dosyalarına ve işaretsiz eski kopyalara dokunulmaz.
/// Yazılan dosya döner; yazma, okuma ya da silme hatası `StorageError` olarak fırlatılır.
public func exportMarkdown(record: MeetingRecord, folder: URL) throws -> URL {
    let file: URL = folder.appending(path: markdownFileName(record: record))
    let marker: String = markdownExportMarker(meetingID: record.id)
    do {
        try Data((meetingMarkdown(record: record) + "\n\n" + marker + "\n").utf8).write(to: file, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
    let fileNames: [String]
    do {
        fileNames = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    } catch {
        throw StorageError.readFailed(path: folder.path, reason: error.localizedDescription)
    }
    for name in staleMarkdownExportCandidates(record: record, fileNames: fileNames) {
        let stale: URL = folder.appending(path: name)
        let text: String
        do {
            text = try String(contentsOf: stale, encoding: .utf8)
        } catch {
            throw StorageError.readFailed(path: stale.path, reason: error.localizedDescription)
        }
        guard text.contains(marker) else {
            continue
        }
        do {
            try FileManager.default.removeItem(at: stale)
        } catch {
            throw StorageError.deleteFailed(path: stale.path, reason: error.localizedDescription)
        }
    }
    return file
}
