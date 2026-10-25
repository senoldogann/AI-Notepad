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
/// Diğer diller yok sayılır; ikisi de yoksa hata fırlatılır. Eşitlikte Fince seçilir.
public func pickLanguage(logProbs: [String: Float]) throws -> MeetingLanguage {
    let pair: (finnish: Float, english: Float) = try finnishAndEnglish(logProbs: logProbs)
    return pair.english > pair.finnish ? .english : .finnish
}

/// Bir bölümün dil olasılıklarını (log → olasılık) oylara ekler.
public func addVote(votes: LanguageVotes, logProbs: [String: Float]) throws -> LanguageVotes {
    let pair: (finnish: Float, english: Float) = try finnishAndEnglish(logProbs: logProbs)
    return LanguageVotes(
        finnish: votes.finnish + exp(Double(pair.finnish)),
        english: votes.english + exp(Double(pair.english))
    )
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

/// Fince ve İngilizce log olasılıklarını çıkarır; ikisinden biri yoksa hata.
/// Tek dilin eksik olduğu durumda eksik olan çok düşük olasılık sayılır.
private func finnishAndEnglish(logProbs: [String: Float]) throws -> (finnish: Float, english: Float) {
    let finnish: Float? = logProbs[MeetingLanguage.finnish.rawValue]
    let english: Float? = logProbs[MeetingLanguage.english.rawValue]
    guard finnish != nil || english != nil else {
        throw TranscriptionError.languageProbabilitiesMissing(availableCodes: logProbs.keys.sorted())
    }
    return (finnish ?? -Float.infinity, english ?? -Float.infinity)
}
