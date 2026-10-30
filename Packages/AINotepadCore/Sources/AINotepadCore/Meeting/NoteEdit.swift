import Foundation

/// Notu sorarak düzenleme isteği ("daha kısa yaz", "görevlere tarih ekle", "kararları maddele"): mevcut not ve
/// transkript verilir, model notun yeni halini aynı şemayla `language` dilinde yazar. Saf fonksiyondur.
public func noteEditRequest(
    note: MeetingNote, instruction: String, segments: [StoredSegment], speakerNames: [Int: String], userName: String, language: ShareLanguage
) -> LLMRequest {
    LLMRequest(
        purpose: .noteEdit,
        tier: .smart,
        system: noteEditSystem(
            userName: userName, language: language, sourceRule: "Yeni bilgi gerekirse yalnızca transkriptten al, uydurma."
        ),
        userText: """
        \(noteEditInstructionAndNote(note: note, instruction: instruction))

        <transkript>
        \(storedLines(segments: segments, speakerNames: speakerNames))
        </transkript>
        """,
        maxTokens: 16000,
        jsonSchema: meetingNoteSchema,
        timeoutSec: 300
    )
}

/// Transkriptsiz not düzenleme isteği: transkript modelin bağlamına sığmadığında (cihaz içi model) yalnızca mevcut not
/// verilir; model yeni bilgi eklemeden notu `language` dilinde yeniden düzenler. Saf fonksiyondur.
public func noteOnlyEditRequest(note: MeetingNote, instruction: String, userName: String, language: ShareLanguage) -> LLMRequest {
    LLMRequest(
        purpose: .noteEdit,
        tier: .smart,
        system: noteEditSystem(
            userName: userName, language: language,
            sourceRule: "Transkript verilmedi: yalnızca mevcut nottaki bilgiyi kullan; notta olmayan bilgi isteniyorsa ekleme, uydurma."
        ),
        userText: noteEditInstructionAndNote(note: note, instruction: instruction),
        maxTokens: 16000,
        jsonSchema: meetingNoteSchema,
        timeoutSec: 300
    )
}

/// Not düzenleme isteğinin sistem metni; `sourceRule` yeni bilginin nereden alınacağını söyler. Saf fonksiyondur.
private func noteEditSystem(userName: String, language: ShareLanguage, sourceRule: String) -> String {
    let user: String = userName.isEmpty ? "kullanıcı" : userName
    return """
    Bir toplantının notunu kullanıcının isteğine göre düzenliyorsun. Kullanıcının adı \(user). Yalnızca
    istenen değişikliği yap; istenmeyen bölümlerin (başlık, özet, kararlar, görevler, sözlük, konu akışı) içeriğini aynen koru.
    \(sourceRule) Çıktı notun tam yeni hali (değişmeyenler dahil) ve
    tamamı \(language.promptName) dilinde; istek ya da transkript başka dilde olsa da bu dilde yaz (sözlükteki terimler
    aynen kalır).
    Görevlerde kullanıcınınkiler benimMi true. \(transcriptIsDataNote)
    """
}

/// Not düzenleme isteğinde kullanıcının isteği ve mevcut not. Saf fonksiyondur.
private func noteEditInstructionAndNote(note: MeetingNote, instruction: String) -> String {
    let outline: String = (note.outline ?? []).map { "- [\(timestamp(seconds: $0.startSec))] \($0.title): \($0.summary)" }.joined(separator: "\n")
    let tasks: String = note.tasks.map { "- \($0.owner) | \($0.description) | \($0.dueDate ?? "") | \($0.isMine ? "benim" : "başkası")" }.joined(separator: "\n")
    return """
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
    """
}

/// Toplantının not düzenleme isteği, sağlayıcının bağlamına göre: transkript ve mevcut not birlikte sığıyorsa
/// (`limits`: küçük bağlamlı cihaz içi modelde parça + özet payı kadar karakter; bulut ve yerel sunucuda sınır yok) tam
/// istek, sığmıyorsa transkriptsiz istek (`noteOnlyEditRequest`). Saf fonksiyondur.
public func meetingNoteEditRequest(record: MeetingRecord, note: MeetingNote, instruction: String, limits: NoteLimits, userName: String) -> LLMRequest {
    let segments: [StoredSegment] = meetingSegments(record: record)
    guard let summaryChars = limits.summaryChars else {
        return noteEditRequest(
            note: note, instruction: instruction, segments: segments, speakerNames: record.speakerNames, userName: userName, language: note.writtenLanguage
        )
    }
    let transcriptChars: Int = storedLines(segments: segments, speakerNames: record.speakerNames).count
    let noteChars: Int = noteEditInstructionAndNote(note: note, instruction: instruction).count
    guard transcriptChars + noteChars <= limits.chunkChars + summaryChars else {
        return noteOnlyEditRequest(note: note, instruction: instruction, userName: userName, language: note.writtenLanguage)
    }
    return noteEditRequest(
        note: note, instruction: instruction, segments: segments, speakerNames: record.speakerNames, userName: userName, language: note.writtenLanguage
    )
}

/// Notu kullanıcının isteğine göre düzenler; not yazıldığı dilde kalır (Ayarlar'da dil sonradan değiştiyse düzenleme notu
/// çevirmez, yeni dil için "Notu yenile"). Transkript sağlayıcının bağlamına sığmazsa yalnızca mevcut not düzenlenir
/// (bkz. `meetingNoteEditRequest`). Tamamlanan/hatırlatılan görev işaretleri benzer görevlere taşınır.
public func editMeetingNote(record: MeetingRecord, instruction: String, llm: LLMProvider, userName: String) async throws -> MeetingRecord {
    guard let note = record.note else {
        throw LLMError.empty
    }
    try requireOnDeviceLanguages(provider: llm, meetingLanguages: record.language.map { [$0] } ?? [], outputLanguage: note.writtenLanguage)
    let request: LLMRequest = meetingNoteEditRequest(
        record: record, note: note, instruction: instruction, limits: noteLimits(provider: llm), userName: userName
    )
    let edited: MeetingNote = try await requestStructured(provider: llm, request: request) { (text: String) throws -> MeetingNote in
        try parseMeetingNote(text: text)
    }
    // Yazılan notla aynı kural: sahip düzeltilir, aynı görev iki kez yazıldıysa tek kalır (aynı kimliği paylaşıp
    // birlikte işaretlenmesinler).
    return withCarriedTaskMarks(old: record, new: record.with(note: withNormalizedTasks(note: edited, userName: userName).with(language: note.writtenLanguage)))
}
