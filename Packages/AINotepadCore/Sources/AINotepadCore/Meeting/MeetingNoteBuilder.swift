import Foundation

/// Saklanan bölümün etiketi: kullanıcının verdiği ad, yoksa "Konuşmacı N", "Sen" ya da "Diğerleri".
public func storedLabel(segment: StoredSegment, speakerNames: [Int: String]) -> String {
    if let person = segment.person, let name = speakerNames[person], !name.isEmpty {
        return name
    }
    return speakerLabel(speaker: segment.speaker, person: segment.person)
}

/// Bölümleri `[mm:ss] Etiket: metin` satırlarına çevirir (zamana göre sıralı). Saf fonksiyondur.
public func storedLines(segments: [StoredSegment], speakerNames: [Int: String]) -> String {
    segments
        .filter { (segment: StoredSegment) -> Bool in !segment.text.isEmpty }
        .sorted { (left: StoredSegment, right: StoredSegment) -> Bool in left.startSec < right.startSec }
        .map { (segment: StoredSegment) -> String in
            "[\(timestamp(seconds: segment.startSec))] \(storedLabel(segment: segment, speakerNames: speakerNames)): \(segment.text)"
        }
        .joined(separator: "\n")
}

/// Toplantı notu isteği (Claude Opus, yapılandırılmış çıktı); metin yoksa nil. Saf fonksiyondur.
public func meetingNoteRequest(segments: [StoredSegment], speakerNames: [Int: String], userName: String) -> ClaudeRequest? {
    let transcript: String = storedLines(segments: segments, speakerNames: speakerNames)
    guard !transcript.isEmpty else {
        return nil
    }
    let user: String = userName.isEmpty ? "kullanıcı" : userName
    return ClaudeRequest(
        model: .opus,
        system: """
        Fince ya da İngilizce bir toplantının transkriptinden Türkçe toplantı notu çıkarıyorsun. Kullanıcının adı \(user);
        transkriptte "Sen" odur. Kısa bir başlık, birkaç cümlelik özet, alınan kararlar, görevler (kim, ne, varsa ne zaman;
        kullanıcıya düşenlerde benimMi true) ve toplantıda geçen önemli Fince/İngilizce terimlerin Türkçe anlamlarını yaz.
        Transkriptte olmayan bir şey uydurma; tarih yoksa boş metin ver.
        """,
        userText: "<transkript>\n\(transcript)\n</transkript>",
        maxTokens: 16000,
        effort: "medium",
        jsonSchema: """
        {"type":"object","properties":{"baslik":{"type":"string"},"ozet":{"type":"string"},\
        "kararlar":{"type":"array","items":{"type":"string"}},\
        "gorevler":{"type":"array","items":{"type":"object","properties":{"sahip":{"type":"string"},"aciklama":{"type":"string"},\
        "tarih":{"type":"string"},"benimMi":{"type":"boolean"}},"required":["sahip","aciklama","tarih","benimMi"],"additionalProperties":false}},\
        "sozluk":{"type":"array","items":{"type":"object","properties":{"terim":{"type":"string"},"anlam":{"type":"string"}},\
        "required":["terim","anlam"],"additionalProperties":false}}},\
        "required":["baslik","ozet","kararlar","gorevler","sozluk"],"additionalProperties":false}
        """,
        timeoutSec: 300
    )
}

/// Not yanıtını ayrıştırır; boş tarih "yok" demektir.
public func parseMeetingNote(text: String) throws -> MeetingNote {
    guard let raw = try? JSONDecoder().decode(RawMeetingNote.self, from: Data(text.utf8)) else {
        throw LLMError.malformed(body: text)
    }
    return MeetingNote(
        title: raw.baslik,
        summary: raw.ozet,
        decisions: raw.kararlar,
        tasks: raw.gorevler.map { (task: RawTask) -> NoteTask in
            NoteTask(owner: task.sahip, description: task.aciklama, dueDate: task.tarih.isEmpty ? nil : task.tarih, isMine: task.benimMi)
        },
        glossary: raw.sozluk.map { (entry: RawGlossary) -> GlossaryEntry in GlossaryEntry(term: entry.terim, meaning: entry.anlam) }
    )
}

/// Toplantıyı Markdown'a çevirir (Notion, Apple Notes, Obsidian'a yapıştırılabilir). Saf fonksiyondur.
public func meetingMarkdown(record: MeetingRecord) -> String {
    let formatter: DateFormatter = DateFormatter()
    formatter.locale = Locale(identifier: "tr_TR")
    formatter.dateStyle = .long
    formatter.timeStyle = .short
    var lines: [String] = ["# \(record.note?.title ?? record.title)", "", "_\(formatter.string(from: record.startedAt))_", ""]
    if let note = record.note {
        lines += ["## Özet", "", note.summary, ""]
        if !note.decisions.isEmpty {
            lines += ["## Kararlar", ""] + note.decisions.map { "- \($0)" } + [""]
        }
        if !note.tasks.isEmpty {
            lines += ["## Görevler", ""] + note.tasks.map { (task: NoteTask) -> String in
                let due: String = task.dueDate.map { " (\($0))" } ?? ""
                return "- [ ] **\(task.owner)** — \(task.description)\(due)\(task.isMine ? " ⭐" : "")"
            } + [""]
        }
        if !note.glossary.isEmpty {
            lines += ["## Sözlük", ""] + note.glossary.map { "- **\($0.term)** — \($0.meaning)" } + [""]
        }
    }
    let segments: [StoredSegment] = record.finalSegments.isEmpty
        ? record.liveSegments
        : record.finalSegments + record.liveSegments.filter { $0.speaker == .me }
    lines += ["## Transkript", ""]
    for segment in segments.sorted(by: { $0.startSec < $1.startSec }) where !segment.text.isEmpty {
        lines.append("**[\(timestamp(seconds: segment.startSec))] \(storedLabel(segment: segment, speakerNames: record.speakerNames)):** \(segment.text)")
        if let turkish = record.translations[segment.key] {
            lines.append("  _\(turkish)_")
        }
    }
    return lines.joined(separator: "\n")
}

// Şemadaki Türkçe alan adları.
private struct RawMeetingNote: Decodable {
    let baslik: String
    let ozet: String
    let kararlar: [String]
    let gorevler: [RawTask]
    let sozluk: [RawGlossary]
}

private struct RawTask: Decodable {
    let sahip: String
    let aciklama: String
    let tarih: String
    let benimMi: Bool
}

private struct RawGlossary: Decodable {
    let terim: String
    let anlam: String
}
