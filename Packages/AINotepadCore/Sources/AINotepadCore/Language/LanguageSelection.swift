import Foundation

/// Otomatik dil algılamada (Mac'te, Whisper) biriken oylar: aday dil başına olasılık toplamı.
public struct LanguageVotes: Sendable, Equatable {
    public let scores: [MeetingLanguage: Double]

    public init(scores: [MeetingLanguage: Double]) {
        self.scores = scores
    }

    public static let empty: LanguageVotes = LanguageVotes(scores: [:])
}

/// Whisper'ın dil log olasılıklarından aday diller arasında en olasıyı seçer. Adaylar dışındaki diller yok sayılır
/// (kısa ya da gürültülü bölümde Fince "et" Estonca çıkabilir; yalnızca kullanıcının toplantı dilleri arasında
/// seçilir). Adaylardan hiçbiri yoksa nil (bu bölüm dil oyu vermez). Eşitlikte aday sırasında önce gelen. Saf
/// fonksiyondur.
public func pickLanguage(logProbs: [String: Float], candidates: [MeetingLanguage]) -> MeetingLanguage? {
    candidates
        .compactMap { (language: MeetingLanguage) -> (language: MeetingLanguage, score: Float)? in
            logProbs[language.rawValue].map { (language: language, score: $0) }
        }
        .reduce(nil) { (best: (language: MeetingLanguage, score: Float)?, item: (language: MeetingLanguage, score: Float)) -> (language: MeetingLanguage, score: Float)? in
            guard let best, best.score >= item.score else {
                return item
            }
            return best
        }?
        .language
}

/// Bir bölümün aday dillerdeki olasılıklarını (log → olasılık) oylara ekler; adaylardan hiçbiri yoksa oylar değişmez.
/// Saf fonksiyondur.
public func addVote(votes: LanguageVotes, logProbs: [String: Float], candidates: [MeetingLanguage]) -> LanguageVotes {
    LanguageVotes(scores: candidates.reduce(into: votes.scores) { (scores: inout [MeetingLanguage: Double], language: MeetingLanguage) -> Void in
        if let logProb = logProbs[language.rawValue] {
            scores[language, default: 0] += exp(Double(logProb))
        }
    })
}

/// Dil kilitlenmeden önce bir bölümün hangi dilde yazıya döküleceği: bölümün kendi algılaması, yoksa öndeki dil, o da
/// yoksa ilk aday (kullanıcının ana toplantı dili). Saf fonksiyondur.
public func resolveSegmentLanguage(detected: MeetingLanguage?, votes: LanguageVotes, candidates: [MeetingLanguage]) -> MeetingLanguage {
    detected ?? leadingLanguage(votes: votes, candidates: candidates) ?? candidates.first ?? .finnish
}

/// Kilit süresi dolduysa ve oy varsa çoğunluk dilini döndürür; aksi halde nil. Saf fonksiyondur.
public func lockedLanguage(votes: LanguageVotes, elapsedSec: Double, lockAfterSec: Double, candidates: [MeetingLanguage]) -> MeetingLanguage? {
    guard elapsedSec >= lockAfterSec else {
        return nil
    }
    return leadingLanguage(votes: votes, candidates: candidates)
}

/// Şu an önde olan dil; hiç oy yoksa nil. Eşitlikte aday sırasında önce gelen. Saf fonksiyondur.
public func leadingLanguage(votes: LanguageVotes, candidates: [MeetingLanguage]) -> MeetingLanguage? {
    candidates
        .filter { (votes.scores[$0] ?? 0) > 0 }
        .reduce(nil) { (best: MeetingLanguage?, language: MeetingLanguage) -> MeetingLanguage? in
            guard let best, (votes.scores[best] ?? 0) >= (votes.scores[language] ?? 0) else {
                return language
            }
            return best
        }
}

/// Otomatik algılamanın aday dilleri: ana toplantı dili önce, sonra İngilizce (en sık ikinci dil); ana dil İngilizceyse
/// ikinci aday Fince (uygulamanın asıl kullanım yeri). Saf fonksiyondur.
public func automaticCandidates(primary: MeetingLanguage) -> [MeetingLanguage] {
    primary == .english ? [.english, .finnish] : [primary, .english]
}
