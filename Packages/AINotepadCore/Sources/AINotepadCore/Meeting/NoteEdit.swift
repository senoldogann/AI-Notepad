import Foundation

/// Notu sorarak düzenleme isteği ("daha kısa yaz", "görevlere tarih ekle", "kararları maddele"): mevcut not ve
/// transkript verilir, model notun yeni halini aynı şemayla yazar. Saf fonksiyondur.
public func noteEditRequest(note: MeetingNote, instruction: String, segments: [StoredSegment], speakerNames: [Int: String], userName: String) -> LLMRequest {
    let user: String = userName.isEmpty ? "kullanıcı" : userName
    let outline: String = (note.outline ?? []).map { "- [\(timestamp(seconds: $0.startSec))] \($0.title): \($0.summary)" }.joined(separator: "\n")
    let tasks: String = note.tasks.map { "- \($0.owner) | \($0.description) | \($0.dueDate ?? "") | \($0.isMine ? "benim" : "başkası")" }.joined(separator: "\n")
    return LLMRequest(
        tier: .smart,
        system: """
        Bir toplantının Türkçe notunu kullanıcının isteğine göre düzenliyorsun. Kullanıcının adı \(user). Yalnızca
        istenen değişikliği yap; istenmeyen bölümleri (başlık, özet, kararlar, görevler, sözlük, konu akışı) aynen koru.
        Yeni bilgi gerekirse yalnızca transkriptten al, uydurma. Çıktı Türkçe ve notun tam yeni hali (değişmeyenler dahil).
        Görevlerde kullanıcınınkiler benimMi true. \(transcriptIsDataNote)
        """,
        userText: """
        <istek>
        \(instruction)
        </istek>

        <mevcut_not>
        Başlık: \(note.title)
        Özet: \(note.summary)
        Kararlar:
        \(note.decisions.map { "- \($0)" }.joined(separator: "\n"))
        Görevler (sahip | iş | tarih | kimin):
        \(tasks)
        Sözlük:
        \(note.glossary.map { "- \($0.term): \($0.meaning)" }.joined(separator: "\n"))
        Konu akışı:
        \(outline)
        </mevcut_not>

        <transkript>
        \(storedLines(segments: segments, speakerNames: speakerNames))
        </transkript>
        """,
        maxTokens: 16000,
        jsonSchema: meetingNoteSchema,
        timeoutSec: 300
    )
}

/// Notu kullanıcının isteğine göre düzenler; tamamlanan/hatırlatılan görev işaretleri benzer görevlere taşınır.
public func editMeetingNote(record: MeetingRecord, instruction: String, llm: LLMProvider, userName: String) async throws -> MeetingRecord {
    guard let note = record.note else {
        throw LLMError.empty
    }
    try requireOnDeviceLanguages(provider: llm, meetingLanguages: record.language.map { [$0] } ?? [])
    let request: LLMRequest = noteEditRequest(
        note: note, instruction: instruction, segments: meetingSegments(record: record), speakerNames: record.speakerNames, userName: userName
    )
    let edited: MeetingNote = try await requestStructured(provider: llm, request: request) { (text: String) throws -> MeetingNote in
        try parseMeetingNote(text: text)
    }
    // Yazılan notla aynı kural: sahip düzeltilir, aynı görev iki kez yazıldıysa tek kalır (aynı kimliği paylaşıp
    // birlikte işaretlenmesinler).
    return withCarriedTaskMarks(old: record, new: record.with(note: withNormalizedTasks(note: edited, userName: userName)))
}
