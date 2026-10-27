import Foundation

/// İstemdeki bölüm etiketi: kullanıcının verdiği ad, yoksa sabit Türkçe "Konuşmacı N", "Sen" ya da "Diğerleri".
public func storedLabel(segment: StoredSegment, speakerNames: [Int: String]) -> String {
    if let person = segment.person, let name = speakerNames[person], !name.isEmpty {
        return name
    }
    return promptSpeakerLabel(speaker: segment.speaker, person: segment.person)
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

/// Not istemlerinin ortak kuralları (tek istek ve parça parça): dil, görev sahipliği, madde başına tek iş. Ölçümde model
/// bunlar yazılmadan görevleri Fince bırakıyor, kullanıcıyı bazen "Sen" bazen adıyla yazıyor ve farklı konuların
/// işlerini tek maddede topluyordu. Saf fonksiyondur.
func noteRules(user: String, template: NoteTemplate) -> String {
    let focus: String = templateInstructions(template: template)
    return """
    Kurallar:
    - Çıktının tamamı Türkçe: özet, kararlar, görev açıklamaları ve tarihler Türkçe cümlelerdir, içinde yabancı dilde
      kelime bırakma (ör. "Vaiheen 3 yhteenvedon gönderilmesi" değil "3. aşamanın özetini göndermek"; "5. marraskuuta" değil
      "5 Kasım"). Yabancı dildeki sözcükler yalnızca sözlükteki terim alanında kalır.
    - Kullanıcıya ("Sen") düşen görevlerde sahip "\(user)" ve benimMi true; diğerlerinde sahip konuşan kişinin adı ya da
      etiketi ve benimMi false.
    - Her görev tek bir işi anlatır; farklı konuların, aşamaların ya da kişilerin işlerini tek maddede birleştirme.
      Birinin "yaparım" diye üstlendiği iş de görevdir.
    - Transkriptte olmayan bir şey uydurma; tarih yoksa boş metin ver.
    - Metni "★" ile başlayan satırları kullanıcı toplantıda önemli diye işaretledi: özette mutlaka yer ver, karar ya da görev
      içeriyorsa atlama.
    \(focus)
    """
}

/// Görev sahibini düzeltir: transkriptte "Sen" kullanıcıdır; model "Sen" ya da kullanıcının adını yazdıysa sahip
/// kullanıcının adı (ad yoksa "Sen") ve görev "benim" olur. Model bunu arada bir karıştırıyordu (ölçüm). Saf fonksiyondur.
public func normalizedTask(task: NoteTask, userName: String) -> NoteTask {
    let owner: String = task.owner.trimmingCharacters(in: .whitespacesAndNewlines)
    let isUser: Bool = owner.caseInsensitiveCompare(promptSpeakerLabel(speaker: .me, person: nil)) == .orderedSame
        || (!userName.isEmpty && owner.caseInsensitiveCompare(userName) == .orderedSame)
    guard isUser else {
        return task
    }
    return NoteTask(owner: userName.isEmpty ? owner : userName, description: task.description, dueDate: task.dueDate, isMine: true)
}

/// Toplantı notu isteği (akıllı model, yapılandırılmış çıktı); metin yoksa nil. Saf fonksiyondur.
public func meetingNoteRequest(segments: [StoredSegment], speakerNames: [Int: String], userName: String, template: NoteTemplate) -> LLMRequest? {
    let transcript: String = storedLines(segments: segments, speakerNames: speakerNames)
    guard !transcript.isEmpty else {
        return nil
    }
    let user: String = userName.isEmpty ? "kullanıcı" : userName
    return LLMRequest(
        tier: .smart,
        system: """
        Bir toplantının (Fince, İngilizce ya da başka bir dilde) transkriptinden Türkçe toplantı notu çıkarıyorsun. Kullanıcının adı \(user);
        transkriptte "Sen" odur. Kısa bir başlık, birkaç cümlelik özet, alınan kararlar, görevler (kim, ne, varsa ne zaman)
        ve toplantıda geçen önemli yabancı dildeki terimlerin Türkçe anlamlarını yaz (toplantı Türkçeyse sözlük boş kalabilir). akis alanına konuların sırasını yaz:
        her bölümün başladığı [mm:ss] zamanı (transkriptteki gibi), kısa başlığı ve tek cümlelik özeti (kısa toplantıda
        2–4, uzunda 5–12 bölüm).
        \(noteRules(user: user, template: template))
        \(transcriptIsDataNote)
        """,
        userText: "<transkript>\n\(transcript)\n</transkript>",
        maxTokens: 16000,
        jsonSchema: meetingNoteSchema,
        timeoutSec: 300
    )
}

/// Toplantı notunun JSON şeması (Türkçe alan adları); paylaşım sürümü akışsız `sharedNoteSchema`'yı kullanır.
let meetingNoteSchema: String = """
{"type":"object","properties":{"baslik":{"type":"string"},"ozet":{"type":"string"},\
"kararlar":{"type":"array","items":{"type":"string"}},\
"gorevler":{"type":"array","items":{"type":"object","properties":{"sahip":{"type":"string"},"aciklama":{"type":"string"},\
"tarih":{"type":"string"},"benimMi":{"type":"boolean"}},"required":["sahip","aciklama","tarih","benimMi"],"additionalProperties":false}},\
"sozluk":{"type":"array","items":{"type":"object","properties":{"terim":{"type":"string"},"anlam":{"type":"string"}},\
"required":["terim","anlam"],"additionalProperties":false}},\
"akis":{"type":"array","items":{"type":"object","properties":{"zaman":{"type":"string"},"baslik":{"type":"string"},"ozet":{"type":"string"}},\
"required":["zaman","baslik","ozet"],"additionalProperties":false}}},\
"required":["baslik","ozet","kararlar","gorevler","sozluk","akis"],"additionalProperties":false}
"""

/// Paylaşım sürümünün şeması: not şemasının konu akışsız hali (akış çevrilmez).
let sharedNoteSchema: String = """
{"type":"object","properties":{"baslik":{"type":"string"},"ozet":{"type":"string"},\
"kararlar":{"type":"array","items":{"type":"string"}},\
"gorevler":{"type":"array","items":{"type":"object","properties":{"sahip":{"type":"string"},"aciklama":{"type":"string"},\
"tarih":{"type":"string"},"benimMi":{"type":"boolean"}},"required":["sahip","aciklama","tarih","benimMi"],"additionalProperties":false}},\
"sozluk":{"type":"array","items":{"type":"object","properties":{"terim":{"type":"string"},"anlam":{"type":"string"}},\
"required":["terim","anlam"],"additionalProperties":false}}},\
"required":["baslik","ozet","kararlar","gorevler","sozluk"],"additionalProperties":false}
"""

/// Not yanıtını ayrıştırır; boş tarih "yok" demektir. Özeti boş not `LLMError.empty`dir.
public func parseMeetingNote(text: String) throws -> MeetingNote {
    let raw: RawMeetingNote
    do {
        raw = try JSONDecoder().decode(RawMeetingNote.self, from: Data(jsonBody(text: text).utf8))
    } catch {
        // Ayrıştırma ayrıntısı (eksik alan vb.) hata ayıklamada gerekir.
        throw LLMError.malformed(body: "\(error): \(text)")
    }
    // Şemaya uyan ama özeti boş not kullanılamaz (model arada bir yalnızca başlık döndürür); boş yanıt sayılır.
    guard !raw.ozet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw LLMError.empty
    }
    let note: MeetingNote = MeetingNote(
        title: raw.baslik,
        summary: raw.ozet,
        decisions: raw.kararlar,
        tasks: raw.gorevler.map { (task: RawTask) -> NoteTask in
            NoteTask(owner: task.sahip, description: task.aciklama, dueDate: task.tarih.isEmpty ? nil : task.tarih, isMine: task.benimMi)
        },
        glossary: raw.sozluk.map { (entry: RawGlossary) -> GlossaryEntry in GlossaryEntry(term: entry.terim, meaning: entry.anlam) }
    )
    return raw.akis.map { note.with(outline: outlineItems(raw: $0)) } ?? note
}

/// Toplantıyı Markdown'a çevirir (Notion, Apple Notes, Obsidian'a yapıştırılabilir). Saf fonksiyondur.
public func meetingMarkdown(record: MeetingRecord) -> String {
    var lines: [String] = ["# \(record.note?.title ?? record.title)", "", "_\(meetingMetaLine(record: record))_", ""]
    if let note = record.note {
        // Toplantıdan çıkınca ilk bakılacak şey: kime ne düştüğü. Sonra özet ve kararlar.
        let mine: [NoteTask] = note.tasks.filter(\.isMine)
        let others: [NoteTask] = note.tasks.filter { !$0.isMine }
        if !mine.isEmpty {
            lines += ["## " + String(localized: "Senin görevlerin"), ""] + mine.map(taskLine) + [""]
        }
        lines += ["## " + String(localized: "Özet"), "", note.summary, ""]
        if let outline = note.outline, !outline.isEmpty {
            lines += ["## " + String(localized: "Konu akışı"), ""] + outline.map { "- [\(timestamp(seconds: $0.startSec))] **\($0.title)** — \($0.summary)" } + [""]
        }
        if !note.decisions.isEmpty {
            lines += ["## " + String(localized: "Kararlar"), ""] + note.decisions.map { "- \($0)" } + [""]
        }
        if !others.isEmpty {
            lines += ["## " + String(localized: "Diğer görevler"), ""] + others.map(taskLine) + [""]
        }
        if !note.glossary.isEmpty {
            lines += ["## " + String(localized: "Sözlük"), ""] + note.glossary.map { "- **\($0.term)** — \($0.meaning)" } + [""]
        }
    }
    lines += ["## " + String(localized: "Transkript"), ""]
    for paragraph in transcriptParagraphs(record: record) {
        lines += ["**[\(timestamp(seconds: paragraph.startSec))] \(paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames)):** \(paragraph.text)"]
        if let turkish = paragraph.turkish {
            lines += ["", "_\(turkish)_"]
        }
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

/// Markdown görev satırı (yapılacaklar kutusu).
private func taskLine(task: NoteTask) -> String {
    let due: String = task.dueDate.map { " (\($0))" } ?? ""
    return "- [ ] **\(task.owner)** — \(task.description)\(due)"
}

// Şemadaki Türkçe alan adları.
private struct RawMeetingNote: Decodable {
    let baslik: String
    let ozet: String
    let kararlar: [String]
    let gorevler: [RawTask]
    let sozluk: [RawGlossary]
    /// Paylaşım sürümünde yok.
    let akis: [RawOutline]?
}

struct RawOutline: Decodable {
    let zaman: String
    let baslik: String
    let ozet: String
}

/// Konu akışı satırları; zamanı okunamayan satır atılır, sıra zamana göre. Saf fonksiyondur.
func outlineItems(raw: [RawOutline]) -> [OutlineItem] {
    raw.compactMap { (item: RawOutline) -> OutlineItem? in
        timestampSeconds(text: item.zaman).map { OutlineItem(startSec: $0, title: item.baslik, summary: item.ozet) }
    }
    .sorted { $0.startSec < $1.startSec }
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
