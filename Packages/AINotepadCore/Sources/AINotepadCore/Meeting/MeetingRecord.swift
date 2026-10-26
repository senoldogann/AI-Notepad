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

/// Zamanı belli bir kelime (son geçişten); zamanlar kaydın başından itibaren saniye.
public struct StoredWord: Sendable, Equatable, Codable {
    public let text: String
    public let startSec: Double
    public let endSec: Double

    public init(text: String, startSec: Double, endSec: Double) {
        self.text = text
        self.startSec = startSec
        self.endSec = endSec
    }
}

/// Diskte saklanan bölüm. `key` canlı bölüm kimliğidir ("others-3"); son geçişte "final-12".
public struct StoredSegment: Sendable, Equatable, Codable {
    public let key: String
    public let speaker: Speaker
    public let person: Int?
    public let startSec: Double
    public let endSec: Double
    public let text: String
    /// Son geçişin kelime zamanları (çalarken kelime vurgusu); canlı bölümlerde ve eski kayıtlarda nil.
    public let words: [StoredWord]?

    public init(key: String, speaker: Speaker, person: Int?, startSec: Double, endSec: Double, text: String, words: [StoredWord]?) {
        self.key = key
        self.speaker = speaker
        self.person = person
        self.startSec = startSec
        self.endSec = endSec
        self.text = text
        self.words = words
    }

    /// Konuşmacısı "Sen" ve kişisiz kopya (son geçiş "Sen" kaydından üretildiğinde).
    public func asMe() -> StoredSegment {
        StoredSegment(key: "me-\(key)", speaker: .me, person: nil, startSec: startSec, endSec: endSec, text: text, words: words)
    }

    /// Kişisi değişmiş kopya (konuşmacı birleştirme/düzeltme).
    public func with(person newPerson: Int?) -> StoredSegment {
        StoredSegment(key: key, speaker: speaker, person: newPerson, startSec: startSec, endSec: endSec, text: text, words: words)
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

/// Toplantının kaydedildiği canlı motor; son geçiş de buna göre yapılır (yerel toplantı buluta gönderilmez).
public enum RecordingEngine: String, Sendable, Codable {
    /// Deepgram + ElevenLabs.
    case cloud
    /// WhisperKit (+ SpeakerKit), internetsiz.
    case local
}

/// `meeting.json`'un içeriği. `id` oturum klasörünün adıdır. Yeni alanlar isteğe bağlıdır ki eski dosyalar okunabilsin.
public struct MeetingRecord: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public private(set) var title: String
    public let startedAt: Date
    public private(set) var endedAt: Date?
    public private(set) var language: MeetingLanguage?
    public private(set) var status: MeetingStatus
    public private(set) var failureMessage: String?
    public private(set) var liveSegments: [StoredSegment]
    public private(set) var finalSegments: [StoredSegment]
    /// Bölüm anahtarı → Türkçe.
    public private(set) var translations: [String: String]
    /// Kişi numarası → kullanıcının verdiği ad.
    public private(set) var speakerNames: [Int: String]
    public private(set) var note: MeetingNote?
    public private(set) var audioDeleted: Bool
    /// Kaydın motoru; eski toplantılarda nil (bulut sayılır).
    public private(set) var engine: RecordingEngine?
    /// Hata olmayan ama kullanıcının bilmesi gereken durum (ör. son geçiş atlandı).
    public private(set) var notice: String?
    /// "Sen"in canlı metin akışı kayıt sırasında koptu (ör. ağ gitti): canlı metin eksik, son geçiş "Sen" kaydını da
    /// yazıya döker. Eski toplantılarda nil.
    public private(set) var meNeedsFinalPass: Bool?
    /// Son geçiş kişilerinin ses izleri (sesinden tanıma); eski toplantılarda ve izi çıkarılamayanlarda nil.
    public private(set) var voiceprints: [Int: Voiceprint]?
    /// Tamamlanan görevlerin kimlikleri (bkz. `taskKey`); eski toplantılarda nil.
    public private(set) var completedTasks: [String]?
    /// Anımsatıcılar'a eklenen görevlerin kimlikleri.
    public private(set) var remindedTasks: [String]?
    /// Notun şablonu; eski toplantılarda ve genel şablonda nil.
    public private(set) var template: NoteTemplate?
    /// Notun paylaşım dillerindeki sürümleri (dil kodu → not); not yeniden yazılınca silinir.
    public private(set) var sharedNotes: [String: MeetingNote]?

    public init(
        id: String, title: String, startedAt: Date, endedAt: Date?, language: MeetingLanguage?, status: MeetingStatus,
        failureMessage: String?, liveSegments: [StoredSegment], finalSegments: [StoredSegment],
        translations: [String: String], speakerNames: [Int: String], note: MeetingNote?, audioDeleted: Bool,
        engine: RecordingEngine?, notice: String?, meNeedsFinalPass: Bool?
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
        self.engine = engine
        self.notice = notice
        self.meNeedsFinalPass = meNeedsFinalPass
    }

    /// Tamamlanan görevleri değişmiş kopya.
    public func with(completedTasks newCompleted: [String]) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.completedTasks = newCompleted
        return copy
    }

    /// Anımsatıcılar'a eklenen görevleri değişmiş kopya.
    public func with(remindedTasks newReminded: [String]) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.remindedTasks = newReminded
        return copy
    }

    /// Ses izleri değişmiş kopya.
    public func with(voiceprints newVoiceprints: [Int: Voiceprint]?) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.voiceprints = newVoiceprints
        return copy
    }

    /// Konuşmacı adları değişmiş kopya.
    public func with(speakerNames newNames: [Int: String]) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.speakerNames = newNames
        return copy
    }

    /// Ses dosyaları silinmiş olarak işaretli kopya.
    public func withAudioDeleted() -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.audioDeleted = true
        return copy
    }

    /// Yalnızca durumu (ve hata mesajını) değişmiş kopya.
    public func with(status newStatus: MeetingStatus, failureMessage newFailure: String?) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.status = newStatus
        copy.failureMessage = newFailure
        return copy
    }

    /// Türkçeleri değişmiş kopya.
    public func with(translations newTranslations: [String: String]) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.translations = newTranslations
        return copy
    }

    /// Son geçiş bölümleri ve dili değişmiş kopya.
    public func with(finalSegments newSegments: [StoredSegment], language newLanguage: MeetingLanguage?) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.finalSegments = newSegments
        copy.language = newLanguage
        return copy
    }

    /// Canlı bölümleri değişmiş kopya.
    public func with(liveSegments newSegments: [StoredSegment]) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.liveSegments = newSegments
        return copy
    }

    /// Şablonu değişmiş kopya.
    public func with(template newTemplate: NoteTemplate) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.template = newTemplate
        return copy
    }

    /// Paylaşım sürümleri değişmiş kopya.
    public func with(sharedNotes newShared: [String: MeetingNote]) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.sharedNotes = newShared
        return copy
    }

    /// Notu değişmiş kopya; başlık nottan gelir, eski paylaşım sürümleri (artık farklı not) silinir.
    public func with(note newNote: MeetingNote) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.note = newNote
        copy.sharedNotes = nil
        copy.title = newNote.title
        return copy
    }

    /// Uyarısı değişmiş kopya.
    public func with(notice newNotice: String?) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.notice = newNotice
        return copy
    }
}

/// Canlı bölümün saklama anahtarı: "me-0", "others-3".
public func segmentKey(id: SegmentID) -> String {
    "\(id.speaker.rawValue)-\(id.index)"
}

/// Canlı transkriptten saklanacak bölümler: metinli kesin bölümler. Saf fonksiyondur.
public func storedSegments(transcript: [LiveSegment]) -> [StoredSegment] {
    transcript
        .filter { (segment: LiveSegment) -> Bool in segment.isFinal && !segment.text.isEmpty && segment.failureMessage == nil }
        .map { (segment: LiveSegment) -> StoredSegment in
            StoredSegment(
                key: segmentKey(id: segment.id), speaker: segment.id.speaker, person: segment.person,
                startSec: segment.startSec, endSec: segment.endSec, text: segment.text, words: nil
            )
        }
}
