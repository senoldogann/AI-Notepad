import Foundation

/// Otomatik dil algılamada biriken oylar (olasılık toplamları).
public struct LanguageVotes: Sendable, Equatable {
    public let finnish: Double
    public let english: Double

    public init(finnish: Double, english: Double) {
        self.finnish = finnish
        self.english = english
    }

    public static let empty: LanguageVotes = LanguageVotes(finnish: 0, english: 0)
}

/// Whisper'ın dil log olasılıklarından Fince ile İngilizce arasında seçim yapar.
/// Diğer diller yok sayılır; ikisi de yoksa nil (bu bölüm dil oyu vermez).
/// WhisperKit yalnızca en olası dili döndürdüğü için kısa ya da gürültülü bölümlerde
/// sonuç "et" gibi başka bir dil olabilir. Eşitlikte Fince seçilir.
public func pickLanguage(logProbs: [String: Float]) -> MeetingLanguage? {
    let finnish: Float? = logProbs[MeetingLanguage.finnish.rawValue]
    let english: Float? = logProbs[MeetingLanguage.english.rawValue]
    switch (finnish, english) {
    case (nil, nil):
        return nil
    case (.some, nil):
        return .finnish
    case (nil, .some):
        return .english
    case (.some(let fi), .some(let en)):
        return en > fi ? .english : .finnish
    }
}

/// Bir bölümün Fince/İngilizce olasılıklarını (log → olasılık) oylara ekler; ikisi de yoksa oylar değişmez.
public func addVote(votes: LanguageVotes, logProbs: [String: Float]) -> LanguageVotes {
    let finnish: Double = logProbs[MeetingLanguage.finnish.rawValue].map { (value: Float) -> Double in exp(Double(value)) } ?? 0
    let english: Double = logProbs[MeetingLanguage.english.rawValue].map { (value: Float) -> Double in exp(Double(value)) } ?? 0
    return LanguageVotes(finnish: votes.finnish + finnish, english: votes.english + english)
}

/// Dil kilitlenmeden önce bir bölümün hangi dilde yazıya döküleceği:
/// bölümün kendi algılaması, yoksa öndeki dil, o da yoksa Fince (kullanıcının ana toplantı dili).
public func resolveSegmentLanguage(detected: MeetingLanguage?, votes: LanguageVotes) -> MeetingLanguage {
    detected ?? leadingLanguage(votes: votes) ?? .finnish
}

/// Kilit süresi dolduysa ve oy varsa çoğunluk dilini döndürür; aksi halde nil.
public func lockedLanguage(votes: LanguageVotes, elapsedSec: Double, lockAfterSec: Double) -> MeetingLanguage? {
    guard elapsedSec >= lockAfterSec else {
        return nil
    }
    return leadingLanguage(votes: votes)
}

/// Şu an önde olan dil; hiç oy yoksa nil. Eşitlikte Fince.
public func leadingLanguage(votes: LanguageVotes) -> MeetingLanguage? {
    guard votes.finnish > 0 || votes.english > 0 else {
        return nil
    }
    return votes.english > votes.finnish ? .english : .finnish
}
