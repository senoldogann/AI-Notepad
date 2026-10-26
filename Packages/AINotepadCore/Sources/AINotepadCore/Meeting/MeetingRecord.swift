import Foundation

/// Toplantının yaşam döngüsü.
public enum MeetingStatus: String, Sendable, Codable {
    case recording
    case processing
    case done
    case failed
    /// Uygulama kayıt ya da işleme sırasında kapandı; ses varsa yeniden işlenebilir.
    case interrupted
}

/// Diskte saklanan bölüm. `key` canlı bölüm kimliğidir ("others-3"); son geçişte "final-12".
public struct StoredSegment: Sendable, Equatable, Codable {
    public let key: String
    public let speaker: Speaker
    public let person: Int?
    public let startSec: Double
    public let endSec: Double
    public let text: String

    public init(key: String, speaker: Speaker, person: Int?, startSec: Double, endSec: Double, text: String) {
        self.key = key
        self.speaker = speaker
        self.person = person
        self.startSec = startSec
        self.endSec = endSec
        self.text = text
    }
}

/// Toplantı notunda bir görev.
public struct NoteTask: Sendable, Equatable, Codable {
    public let owner: String
    public let description: String
    public let dueDate: String?
    /// Kullanıcıya ("Sen") düşen görev.
    public let isMine: Bool

    public init(owner: String, description: String, dueDate: String?, isMine: Bool) {
        self.owner = owner
        self.description = description
        self.dueDate = dueDate
        self.isMine = isMine
    }
}

/// Sözlükte bir terim.
public struct GlossaryEntry: Sendable, Equatable, Codable {
    public let term: String
    public let meaning: String

    public init(term: String, meaning: String) {
        self.term = term
        self.meaning = meaning
    }
}

/// Toplantı sonrası Türkçe not.
public struct MeetingNote: Sendable, Equatable, Codable {
    public let title: String
    public let summary: String
    public let decisions: [String]
    public let tasks: [NoteTask]
    public let glossary: [GlossaryEntry]

    public init(title: String, summary: String, decisions: [String], tasks: [NoteTask], glossary: [GlossaryEntry]) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.tasks = tasks
        self.glossary = glossary
    }
}

/// `meeting.json`'un içeriği. `id` oturum klasörünün adıdır.
public struct MeetingRecord: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let startedAt: Date
    public let endedAt: Date?
    public let language: MeetingLanguage?
    public let status: MeetingStatus
    public let failureMessage: String?
    public let liveSegments: [StoredSegment]
    public let finalSegments: [StoredSegment]
    /// Bölüm anahtarı → Türkçe.
    public let translations: [String: String]
    /// Kişi numarası → kullanıcının verdiği ad.
    public let speakerNames: [Int: String]
    public let note: MeetingNote?
    public let audioDeleted: Bool

    public init(
        id: String, title: String, startedAt: Date, endedAt: Date?, language: MeetingLanguage?, status: MeetingStatus,
        failureMessage: String?, liveSegments: [StoredSegment], finalSegments: [StoredSegment],
        translations: [String: String], speakerNames: [Int: String], note: MeetingNote?, audioDeleted: Bool
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.language = language
        self.status = status
        self.failureMessage = failureMessage
        self.liveSegments = liveSegments
        self.finalSegments = finalSegments
        self.translations = translations
        self.speakerNames = speakerNames
        self.note = note
        self.audioDeleted = audioDeleted
    }

    /// Yalnızca durumu (ve hata mesajını) değişmiş kopya.
    public func with(status newStatus: MeetingStatus, failureMessage newFailure: String?) -> MeetingRecord {
        MeetingRecord(
            id: id, title: title, startedAt: startedAt, endedAt: endedAt, language: language, status: newStatus,
            failureMessage: newFailure, liveSegments: liveSegments, finalSegments: finalSegments,
            translations: translations, speakerNames: speakerNames, note: note, audioDeleted: audioDeleted
        )
    }
}

/// Canlı bölümün saklama anahtarı: "me-0", "others-3".
public func segmentKey(id: SegmentID) -> String {
    "\(id.speaker.rawValue)-\(id.index)"
}
