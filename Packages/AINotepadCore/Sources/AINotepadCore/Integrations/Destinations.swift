import Foundation

/// Slack'te AI-Notepad uygulamasını önceden doldurulmuş olarak oluşturan bağlantı: ad, açıklama ve "incoming-webhook"
/// izni hazır gelir; kullanıcı çalışma alanını ve kanalı seçer, Slack webhook adresini verir. Saf fonksiyondur.
public func slackSetupURL() -> URL {
    let manifest: String = """
    {"display_information":{"name":"AI-Notepad","description":"Toplantı notları: görevler, kararlar ve özet.","background_color":"#d9552c"},\
    "oauth_config":{"scopes":{"bot":["incoming-webhook"]}},\
    "settings":{"org_deploy_enabled":false,"socket_mode_enabled":false,"token_rotation_enabled":false}}
    """
    var components: URLComponents = URLComponents()
    components.scheme = "https"
    components.host = "api.slack.com"
    components.path = "/apps"
    components.queryItems = [URLQueryItem(name: "new_app", value: "1"), URLQueryItem(name: "manifest_json", value: manifest)]
    // Sabit, geçerli bileşenlerden kurulur; nil olamaz.
    return components.url!
}

/// Panodaki metin bilinen bir kanalın (Slack, Discord, Teams) webhook adresiyse adres; değilse nil (genel adreslerde
/// kullanıcı açıkça yapıştırır, pano yanlışlıkla başka bir bağlantıyı almasın). Saf fonksiyondur.
public func channelWebhookFromClipboard(text: String) -> URL? {
    let url: URL
    do {
        url = try webhookURL(text: text)
    } catch {
        // Panoda başka bir metin var: kanal adresi değil (hata değil).
        return nil
    }
    guard url.scheme == "https", webhookKind(url: url) != .generic else {
        return nil
    }
    return url
}

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

/// Klasöre yazılacak Markdown dosyasının adı: "2026-10-27 Bütçe toplantısı.md"; dosya sisteminde sorunlu karakterler
/// temizlenir, ad 80 karakterle sınırlı. Aynı toplantı her zaman aynı ada yazılır (yeniden işlenince güncellenir).
/// Saf fonksiyondur.
public func markdownFileName(record: MeetingRecord) -> String {
    let formatter: DateFormatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
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
