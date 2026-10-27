import Foundation

/// Notun önceki bir sürümü: yerine yenisi yazıldığı an, neden değiştiği ("Not yenilendi", "Düzenlendi: özeti kısalt")
/// ve o anki not.
public struct NoteVersion: Sendable, Equatable, Codable {
    public let savedAt: Date
    public let reason: String
    public let note: MeetingNote

    public init(savedAt: Date, reason: String, note: MeetingNote) {
        self.savedAt = savedAt
        self.reason = reason
        self.note = note
    }
}

/// Bir toplantıda saklanan en fazla önceki not sürümü.
public let noteHistoryLimit: Int = 10

/// Not geçmişi hataları.
public enum NoteHistoryError: Error, Equatable {
    /// İstenen sürüm geçmişte yok (geçmiş bu arada değişmiş olabilir).
    case versionNotFound(index: Int, count: Int)
}

/// `updated` kaydına `previous` kaydın notunu en yeni sürüm olarak ekler (yeniden eskiye, en fazla `noteHistoryLimit`).
/// Önceki not yoksa ya da not değişmediyse `updated` olduğu gibi döner. Saf fonksiyondur.
public func withNoteVersion(updated: MeetingRecord, previous: MeetingRecord, reason: String, savedAt: Date) -> MeetingRecord {
    guard let old = previous.note, old != updated.note else {
        return updated
    }
    let versions: [NoteVersion] = [NoteVersion(savedAt: savedAt, reason: reason, note: old)] + (updated.noteHistory ?? [])
    return updated.with(noteHistory: Array(versions.prefix(noteHistoryLimit)))
}

/// Geçmişteki `index`. sürümü geri yükler: o sürüm geçmişten çıkar, şimdiki not geçmişe eklenir (geri yükleme de geri
/// alınabilir). Görev işaretleri benzer görevlere taşınır. Sürüm yoksa `versionNotFound`. Saf fonksiyondur.
public func restoringNoteVersion(record: MeetingRecord, index: Int, reason: String, savedAt: Date) throws -> MeetingRecord {
    let versions: [NoteVersion] = record.noteHistory ?? []
    guard versions.indices.contains(index) else {
        throw NoteHistoryError.versionNotFound(index: index, count: versions.count)
    }
    let remaining: [NoteVersion] = versions.enumerated()
        .filter { (item: (offset: Int, element: NoteVersion)) -> Bool in item.offset != index }
        .map { (item: (offset: Int, element: NoteVersion)) -> NoteVersion in item.element }
    let restored: MeetingRecord = withCarriedTaskMarks(old: record, new: record.with(note: versions[index].note)).with(noteHistory: remaining)
    return withNoteVersion(updated: restored, previous: record, reason: reason, savedAt: savedAt)
}

/// Menüde sürümün satırı: değiştirildiği an ve neden ("27 Eki 14:05 · Düzenlendi: özeti kısalt"). Saf fonksiyondur.
public func noteVersionTitle(version: NoteVersion, locale: Locale) -> String {
    let date: String = version.savedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    return "\(date) · \(version.reason)"
}
