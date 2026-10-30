import Foundation

/// Sesin kaynağı: kullanıcının mikrofonu ya da toplantıdaki diğer katılımcılar (sistem sesi).
public enum Speaker: String, Sendable, Hashable, Codable {
    case me
    case others
}

/// Bir toplantının dili (konuşulan dil). Ham değer Whisper ve Deepgram dil kodudur (ikisinde de aynı); listede yalnızca
/// Deepgram Nova-3 canlı tanıma, ElevenLabs Scribe ve Whisper'ın üçünün de desteklediği diller vardır. Fince ve İngilizce
/// öne, diğerleri bölgelere göre.
public enum MeetingLanguage: String, Sendable, Hashable, Codable, CaseIterable {
    case finnish = "fi"
    case english = "en"
    case swedish = "sv"
    case norwegian = "no"
    case danish = "da"
    case estonian = "et"
    case german = "de"
    case dutch = "nl"
    case french = "fr"
    case spanish = "es"
    case portuguese = "pt"
    case italian = "it"
    case polish = "pl"
    case czech = "cs"
    case slovak = "sk"
    case hungarian = "hu"
    case romanian = "ro"
    case bulgarian = "bg"
    case croatian = "hr"
    case greek = "el"
    case latvian = "lv"
    case lithuanian = "lt"
    case russian = "ru"
    case ukrainian = "uk"
    case turkish = "tr"
    case arabic = "ar"
    case hebrew = "he"
    case persian = "fa"
    case hindi = "hi"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"
    case indonesian = "id"
    case vietnamese = "vi"
    case thai = "th"

    /// ElevenLabs Scribe'ın ISO 639-3 kodu (istekte ve yanıtta).
    public var elevenLabsCode: String {
        switch self {
        case .finnish: "fin"
        case .english: "eng"
        case .swedish: "swe"
        case .norwegian: "nor"
        case .danish: "dan"
        case .estonian: "est"
        case .german: "deu"
        case .dutch: "nld"
        case .french: "fra"
        case .spanish: "spa"
        case .portuguese: "por"
        case .italian: "ita"
        case .polish: "pol"
        case .czech: "ces"
        case .slovak: "slk"
        case .hungarian: "hun"
        case .romanian: "ron"
        case .bulgarian: "bul"
        case .croatian: "hrv"
        case .greek: "ell"
        case .latvian: "lav"
        case .lithuanian: "lit"
        case .russian: "rus"
        case .ukrainian: "ukr"
        case .turkish: "tur"
        case .arabic: "ara"
        case .hebrew: "heb"
        case .persian: "fas"
        case .hindi: "hin"
        case .chinese: "cmn"
        case .japanese: "jpn"
        case .korean: "kor"
        case .indonesian: "ind"
        case .vietnamese: "vie"
        case .thai: "tha"
        }
    }

    /// Bayrak (seçicilerde adın önünde).
    public var flag: String {
        switch self {
        case .finnish: "🇫🇮"
        case .english: "🇬🇧"
        case .swedish: "🇸🇪"
        case .norwegian: "🇳🇴"
        case .danish: "🇩🇰"
        case .estonian: "🇪🇪"
        case .german: "🇩🇪"
        case .dutch: "🇳🇱"
        case .french: "🇫🇷"
        case .spanish: "🇪🇸"
        case .portuguese: "🇵🇹"
        case .italian: "🇮🇹"
        case .polish: "🇵🇱"
        case .czech: "🇨🇿"
        case .slovak: "🇸🇰"
        case .hungarian: "🇭🇺"
        case .romanian: "🇷🇴"
        case .bulgarian: "🇧🇬"
        case .croatian: "🇭🇷"
        case .greek: "🇬🇷"
        case .latvian: "🇱🇻"
        case .lithuanian: "🇱🇹"
        case .russian: "🇷🇺"
        case .ukrainian: "🇺🇦"
        case .turkish: "🇹🇷"
        case .arabic: "🇸🇦"
        case .hebrew: "🇮🇱"
        case .persian: "🇮🇷"
        case .hindi: "🇮🇳"
        case .chinese: "🇨🇳"
        case .japanese: "🇯🇵"
        case .korean: "🇰🇷"
        case .indonesian: "🇮🇩"
        case .vietnamese: "🇻🇳"
        case .thai: "🇹🇭"
        }
    }
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

/// Akış durunca ekrandaki geçici metni silen boş kesin bölüm: akış o bölümün kesin sonucunu artık göndermeyecek
/// (reducer boş, hatasız kesin bölümü listeden çıkarır; geçici metin yoksa etkisizdir). O sesin metni son geçişte
/// yazılır. Saf fonksiyondur.
func clearingPartial(id: SegmentID) -> LiveSegment {
    LiveSegment(id: id, startSec: 0, endSec: 0, text: "", isFinal: true, failureMessage: nil, person: nil)
}
