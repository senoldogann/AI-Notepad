import Foundation

/// Toplantının yaşam döngüsü.
public enum MeetingStatus: String, Sendable, Codable {
    case recording
    case processing
    case done
    case failed
    /// Uygulama kayıt ya da işleme sırasında kapandı; ses varsa yeniden işlenebilir.
    case interrupted
    /// Sunucuya ulaşılamadan (çevrimdışı) kaydedildi; bağlantı gelince sunucuda işlenmeyi bekliyor (abonelik sürümü).
    /// Ses ve canlı metin bu Mac'te; kendiliğinden silinmez.
    case queued
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
    /// Bölümün güvenle algılanan dili (bkz. `confidentSpokenLanguage`); kısa ya da belirsiz bölümde ve eski kayıtlarda nil.
    /// Sabit dilli toplantıda başka dildeki bölüm okunurken atlanır (bkz. `isSkippedForLanguage`).
    public private(set) var spokenLanguage: String?

    public init(key: String, speaker: Speaker, person: Int?, startSec: Double, endSec: Double, text: String, words: [StoredWord]?) {
        self.key = key
        self.speaker = speaker
        self.person = person
        self.startSec = startSec
        self.endSec = endSec
        self.text = text
        self.words = words
    }

    /// Konuşmacısı "Sen" ve kişisiz kopya (son geçiş "Sen" kaydından üretildiğinde); dili korunur.
    public func asMe() -> StoredSegment {
        StoredSegment(key: "me-\(key)", speaker: .me, person: nil, startSec: startSec, endSec: endSec, text: text, words: words)
            .with(spokenLanguage: spokenLanguage)
    }

    /// Kişisi değişmiş kopya (konuşmacı birleştirme/düzeltme); dili korunur.
    public func with(person newPerson: Int?) -> StoredSegment {
        StoredSegment(key: key, speaker: speaker, person: newPerson, startSec: startSec, endSec: endSec, text: text, words: words)
            .with(spokenLanguage: spokenLanguage)
    }

    /// Algılanan dili değişmiş kopya.
    public func with(spokenLanguage newLanguage: String?) -> StoredSegment {
        var copy: StoredSegment = self
        copy.spokenLanguage = newLanguage
        return copy
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

/// Toplantı sonrası not (not ve çeviri dilinde; bkz. `language`).
public struct MeetingNote: Sendable, Equatable, Codable {
    public let title: String
    public let summary: String
    public let decisions: [String]
    public let tasks: [NoteTask]
    public let glossary: [GlossaryEntry]
    /// Konu akışı: toplantının bölümleri, başladıkları anla (eski notlarda nil).
    public private(set) var outline: [OutlineItem]?
    /// Notun yazıldığı dil (Ayarlar › "Not ve çeviri dili"); dil seçimi gelmeden yazılan eski notlarda nil (bkz.
    /// `writtenLanguage`).
    public private(set) var language: ShareLanguage?

    public init(title: String, summary: String, decisions: [String], tasks: [NoteTask], glossary: [GlossaryEntry]) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.tasks = tasks
        self.glossary = glossary
    }

    /// Konu akışı değişmiş kopya.
    public func with(outline newOutline: [OutlineItem]) -> MeetingNote {
        var copy: MeetingNote = self
        copy.outline = newOutline
        return copy
    }

    /// Başlığı değişmiş kopya (konu akışı ve dil korunur).
    public func with(title newTitle: String) -> MeetingNote {
        var copy: MeetingNote = MeetingNote(title: newTitle, summary: summary, decisions: decisions, tasks: tasks, glossary: glossary)
        copy.outline = outline
        copy.language = language
        return copy
    }

    /// Yazıldığı dil işaretli kopya.
    public func with(language newLanguage: ShareLanguage) -> MeetingNote {
        var copy: MeetingNote = self
        copy.language = newLanguage
        return copy
    }

    /// Notun yazıldığı dil: dil kaydı olmayan notlar Türkçedir (dil seçimi gelmeden önceki sürümler notu hep Türkçe
    /// yazardı).
    public var writtenLanguage: ShareLanguage {
        language ?? .turkish
    }
}

/// Konu akışında bir bölüm: başladığı an (saniye), başlık ve tek cümlelik özet.
public struct OutlineItem: Sendable, Equatable, Codable {
    public let startSec: Double
    public let title: String
    public let summary: String

    public init(startSec: Double, title: String, summary: String) {
        self.startSec = startSec
        self.title = title
        self.summary = summary
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
    /// Bölüm anahtarı → not dilindeki canlı çevirisi.
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
    /// Toplantının klasörü (proje, ekip, ders…); klasörsüzde nil.
    public private(set) var folder: String?
    /// İşaretlenen anlar (kayıt sırasında ya da sonradan).
    public private(set) var highlights: [Highlight]?
    /// Takvimdeki katılımcıların adları (kayıt bir etkinliğe bağlandıysa).
    public private(set) var attendees: [String]?
    /// Not webhook'a kendiliğinden gönderildi (tekrar işlemede yeniden gönderilmesin).
    public private(set) var webhookSentAt: Date?
    /// Bağlı takvim etkinliğinin kimliği (`CalendarMeeting.id`); takvimden notu açmak için.
    public private(set) var calendarEventID: String?
    /// Notun şablonu; eski toplantılarda ve genel şablonda nil.
    public private(set) var template: NoteTemplate?
    /// Notun paylaşım dillerindeki sürümleri (dil kodu → not); not yeniden yazılınca silinir.
    public private(set) var sharedNotes: [String: MeetingNote]?
    /// Not Apple Notlar'a kendiliğinden gönderildi (tekrar işlemede yinelenmesin).
    public private(set) var notesSentAt: Date?
    /// Kullanıcının toplantıda (ya da sonradan) kendi yazdığı notlar; not bunları öncelik sayar. Eski toplantılarda nil.
    public private(set) var myNotes: String?
    /// Notun gönderildiği hedeflerin kimlikleri (`NoteDestination.id`); kendiliğinden gönderim aynı hedefe yinelenmez.
    public private(set) var sentDestinationIDs: [String]?
    /// Görev aracına (Linear, Jira) gönderilen görevler: araç kimliği → görev kimlikleri (`taskKey`).
    public private(set) var sentTaskKeys: [String: [String]]?
    /// Notun önceki sürümleri (yeniden eskiye, en fazla `noteHistoryLimit`); geri almak için. Eski toplantılarda nil.
    public private(set) var noteHistory: [NoteVersion]?
    /// Kullanıcının kayıtta sabitlediği toplantı dili (kayıt başında seçili dil ya da kayıtta "Dili değiştir" ile
    /// seçilen); Otomatik dilde, içe aktarmada ve eski toplantılarda nil. Doluysa başka dildeki bölümler okunurken atlanır
    /// (bkz. `isSkippedForLanguage`).
    public private(set) var fixedLanguage: MeetingLanguage?

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

    /// Hedefe gönderildi işaretli kopya (yinelenmez).
    public func markingSent(destinationID: String) -> MeetingRecord {
        var copy: MeetingRecord = self
        let current: [String] = sentDestinationIDs ?? []
        copy.sentDestinationIDs = current.contains(destinationID) ? current : current + [destinationID]
        return copy
    }

    /// Görev araca gönderildi işaretli kopya.
    public func markingTaskSent(trackerID: String, task: NoteTask) -> MeetingRecord {
        var copy: MeetingRecord = self
        var all: [String: [String]] = sentTaskKeys ?? [:]
        let key: String = taskKey(task: task)
        let keys: [String] = all[trackerID] ?? []
        all[trackerID] = keys.contains(key) ? keys : keys + [key]
        copy.sentTaskKeys = all
        return copy
    }

    /// Apple Notlar'a gönderildi işaretli kopya.
    public func with(notesSentAt newDate: Date) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.notesSentAt = newDate
        return copy
    }

    /// Notun gönderim işaretleri (hedefler, Apple Notlar ve webhook anları) değişmiş kopya; iki kaydın işaretlerini
    /// birleştirirken kullanılır (nil: işaret yok).
    public func with(sentDestinationIDs newIDs: [String]?, notesSentAt newNotesDate: Date?, webhookSentAt newWebhookDate: Date?) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.sentDestinationIDs = newIDs
        copy.notesSentAt = newNotesDate
        copy.webhookSentAt = newWebhookDate
        return copy
    }

    /// Araca gönderilen görevleri değişmiş kopya.
    public func with(sentTaskKeys newTaskKeys: [String: [String]]) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.sentTaskKeys = newTaskKeys
        return copy
    }

    /// Kendi notları değişmiş kopya (boş metin nil olur).
    public func with(myNotes newNotes: String) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.myNotes = newNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newNotes
        return copy
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

    /// Bitiş zamanı değişmiş kopya.
    public func with(endedAt newEndedAt: Date) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.endedAt = newEndedAt
        return copy
    }

    /// Yalnızca durumu (ve hata mesajını) değişmiş kopya.
    public func with(status newStatus: MeetingStatus, failureMessage newFailure: String?) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.status = newStatus
        copy.failureMessage = newFailure
        return copy
    }

    /// Çevirileri değişmiş kopya.
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

    /// Adı değişmiş kopya: listede not başlığı görünür, ikisi birlikte değişir.
    public func with(title newTitle: String) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.title = newTitle
        copy.note = note?.with(title: newTitle)
        return copy
    }

    /// Klasörü değişmiş kopya (nil klasörden çıkarır).
    public func with(folder newFolder: String?) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.folder = newFolder
        return copy
    }

    /// İşaretleri değişmiş kopya.
    public func with(highlights newHighlights: [Highlight]) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.highlights = newHighlights
        return copy
    }

    /// Katılımcıları değişmiş kopya.
    public func with(attendees newAttendees: [String]) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.attendees = newAttendees
        return copy
    }

    /// Webhook'a gönderildiği işaretlenmiş kopya.
    public func with(webhookSentAt newDate: Date) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.webhookSentAt = newDate
        return copy
    }

    /// Takvim etkinliği bağlanmış kopya.
    public func with(calendarEventID newID: String) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.calendarEventID = newID
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

    /// Not geçmişi değişmiş kopya.
    public func with(noteHistory newHistory: [NoteVersion]) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.noteHistory = newHistory
        return copy
    }

    /// Uyarısı değişmiş kopya.
    public func with(notice newNotice: String?) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.notice = newNotice
        return copy
    }

    /// Sabit toplantı dili değişmiş kopya (nil: Otomatik).
    public func with(fixedLanguage newLanguage: MeetingLanguage?) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.fixedLanguage = newLanguage
        return copy
    }

    /// "Sen" son geçiş işareti değişmiş kopya.
    public func with(meNeedsFinalPass newValue: Bool?) -> MeetingRecord {
        var copy: MeetingRecord = self
        copy.meNeedsFinalPass = newValue
        return copy
    }
}

/// Canlı bölümün saklama anahtarı: "me-0", "others-3".
public func segmentKey(id: SegmentID) -> String {
    "\(id.speaker.rawValue)-\(id.index)"
}

/// Canlı transkriptten saklanacak bölümler: metinli kesin bölümler, kesinleşince algılanan dilleriyle
/// (`spokenLanguages`; bkz. `confidentSpokenLanguage`, dili algılanmayan bölüm listede yoktur). Saf fonksiyondur.
public func storedSegments(transcript: [LiveSegment], spokenLanguages: [SegmentID: String]) -> [StoredSegment] {
    transcript
        .filter { (segment: LiveSegment) -> Bool in segment.isFinal && !segment.text.isEmpty && segment.failureMessage == nil }
        .map { (segment: LiveSegment) -> StoredSegment in
            StoredSegment(
                key: segmentKey(id: segment.id), speaker: segment.id.speaker, person: segment.person,
                startSec: segment.startSec, endSec: segment.endSec, text: segment.text, words: nil
            )
            .with(spokenLanguage: spokenLanguages[segment.id])
        }
}
