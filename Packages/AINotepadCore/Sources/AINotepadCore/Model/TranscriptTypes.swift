import Foundation

/// Sesin kaynağı: kullanıcının mikrofonu ya da toplantıdaki diğer katılımcılar (sistem sesi).
public enum Speaker: String, Sendable, Hashable, Codable {
    case me
    case others
}

/// Bir toplantının dili. Ham değer Whisper dil kodudur.
public enum MeetingLanguage: String, Sendable, Hashable, Codable {
    case finnish = "fi"
    case english = "en"
}

/// Dilin nasıl belirleneceği: otomatik algılama ya da kullanıcının seçtiği sabit dil.
public enum LanguageMode: Sendable, Hashable {
    case automatic
    case fixed(MeetingLanguage)
}

/// Bir konuşma bölümünün kimliği: konuşmacı + o konuşmacının akışındaki sıra numarası.
public struct SegmentID: Sendable, Hashable {
    public let speaker: Speaker
    public let index: Int

    public init(speaker: Speaker, index: Int) {
        self.speaker = speaker
        self.index = index
    }
}

/// Canlı transkriptte gösterilen bir bölüm. `isFinal == false` ise metin geçicidir.
public struct LiveSegment: Sendable, Equatable, Identifiable {
    public let id: SegmentID
    public let startSec: Double
    public let endSec: Double
    public let text: String
    public let isFinal: Bool
    /// Yazıya dökme başarısız olduysa kullanıcıya gösterilecek açıklama.
    public let failureMessage: String?
    /// Konuşmacı ayırmanın atadığı "Konuşmacı N" numarası; atanmadıysa nil.
    public let person: Int?

    public init(id: SegmentID, startSec: Double, endSec: Double, text: String, isFinal: Bool, failureMessage: String?, person: Int?) {
        self.id = id
        self.startSec = startSec
        self.endSec = endSec
        self.text = text
        self.isFinal = isFinal
        self.failureMessage = failureMessage
        self.person = person
    }
}
