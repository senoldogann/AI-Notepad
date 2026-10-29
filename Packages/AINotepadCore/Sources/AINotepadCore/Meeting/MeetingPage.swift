import Foundation

/// Metni HTML'e güvenle yazar (`& < > " '`). Saf fonksiyondur.
func htmlEscaped(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

/// Paylaşılabilir tek dosyalık web sayfası: notun başlığı, tarihi, özeti, kararları, görevleri (sahibi ve tarihiyle),
/// konu akışı ve sözlüğü (asıl notta). Bağlantı ya da betik içermez; tarayıcıda açılır, e-postaya eklenir, açık ve
/// koyu temaya uyar. `language` paylaşım dili (başlıklar o dilde); nil ise asıl not (başlıklar arayüz dilinde).
/// `appName`: sayfanın altındaki ürün adı (uygulamanın görünen adı). Saf fonksiyondur.
public func meetingHTML(record: MeetingRecord, note: MeetingNote, language: ShareLanguage?, appName: String) -> String {
    let headings: (summary: String, decisions: String, tasks: String) = language.map { (language: ShareLanguage) -> (summary: String, decisions: String, tasks: String) in
        (summary: language.headings.summary, decisions: language.headings.decisions, tasks: language.headings.tasks)
    } ?? (summary: String(localized: "Özet"), decisions: String(localized: "Kararlar"), tasks: String(localized: "Görevler"))
    let date: String = record.startedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(language.map { Locale(identifier: $0.rawValue) } ?? interfaceLocale()))
    // Asıl notta "dk" (arayüz dilinde), paylaşım dillerinde evrensel "min".
    let minutes: String = meetingDurationMinutes(record: record).map { (value: Int) -> String in
        language == nil ? " · " + String(localized: "\(value) dk") : " · \(value) min"
    } ?? ""
    var sections: [String] = ["<h2>\(htmlEscaped(headings.summary))</h2>", "<p>\(htmlEscaped(note.summary))</p>"]
    if language == nil, let outline = note.outline, !outline.isEmpty {
        sections += ["<h2>\(htmlEscaped(String(localized: "Konu akışı")))</h2>", "<ol class=\"outline\">"]
            + outline.map { "<li><span class=\"time\">\(timestamp(seconds: $0.startSec))</span> <b>\(htmlEscaped($0.title))</b> — \(htmlEscaped($0.summary))</li>" }
            + ["</ol>"]
    }
    if !note.decisions.isEmpty {
        sections += ["<h2>\(htmlEscaped(headings.decisions))</h2>", "<ul>"] + note.decisions.map { "<li>\(htmlEscaped($0))</li>" } + ["</ul>"]
    }
    if !note.tasks.isEmpty {
        sections += ["<h2>\(htmlEscaped(headings.tasks))</h2>", "<ul class=\"tasks\">"]
            + note.tasks.map { (task: NoteTask) -> String in
                let due: String = task.dueDate.map { " <span class=\"due\">\(htmlEscaped($0))</span>" } ?? ""
                return "<li><span class=\"box\"></span><b>\(htmlEscaped(task.owner))</b> — \(htmlEscaped(task.description))\(due)</li>"
            }
            + ["</ul>"]
    }
    if language == nil, !note.glossary.isEmpty {
        sections += ["<h2>\(htmlEscaped(String(localized: "Sözlük")))</h2>", "<dl>"]
            + note.glossary.map { "<dt>\(htmlEscaped($0.term))</dt><dd>\(htmlEscaped($0.meaning))</dd>" }
            + ["</dl>"]
    }
    return """
    <!doctype html>
    <html lang="\(language?.rawValue ?? "tr")"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>\(htmlEscaped(note.title))</title>
    <style>
    :root{color-scheme:light dark;--bg:#fdfcfc;--fg:#171717;--muted:#737373;--line:#e7e5e4;--soft:#f5f5f4}
    @media(prefers-color-scheme:dark){:root{--bg:#0a0a0a;--fg:#fafafa;--muted:#a3a3a3;--line:#262626;--soft:#171717}}
    body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,"Inter",system-ui,sans-serif}
    main{max-width:720px;margin:0 auto;padding:56px 24px 80px}
    h1{font-size:32px;font-weight:500;letter-spacing:-.5px;margin:0 0 6px}
    .meta{color:var(--muted);font-size:14px;margin-bottom:36px}
    h2{font-size:12px;font-weight:600;letter-spacing:.6px;text-transform:uppercase;color:var(--muted);margin:36px 0 10px}
    ul,ol{padding-left:20px}li{margin:6px 0}
    ul.tasks{list-style:none;padding:0}ul.tasks li{display:flex;gap:10px;align-items:baseline;padding:10px 12px;background:var(--soft);border-radius:10px}
    .box{flex:none;width:12px;height:12px;border:1.5px solid var(--muted);border-radius:4px;transform:translateY(1px)}
    .due{color:var(--muted);font-size:13px;margin-left:auto;white-space:nowrap}
    ol.outline{list-style:none;padding:0}.time{color:var(--muted);font-variant-numeric:tabular-nums;font-size:13px;margin-right:6px}
    dt{font-weight:600;margin-top:8px}dd{margin:0 0 4px;color:var(--muted)}
    footer{margin-top:56px;color:var(--muted);font-size:12px;border-top:1px solid var(--line);padding-top:16px}
    </style></head>
    <body><main>
    <h1>\(htmlEscaped(note.title))</h1>
    <div class="meta">\(htmlEscaped(date + minutes))</div>
    \(sections.joined(separator: "\n"))
    <footer>\(htmlEscaped(appName))</footer>
    </main></body></html>
    """
}
