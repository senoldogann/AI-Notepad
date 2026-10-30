import Foundation
import NaturalLanguage

// Bölüm dilinin algılanması ve sabit toplantı dilinde olmayan konuşmanın ayıklanması.
//
// Kullanıcı toplantı dilini sabitlediyse (Otomatik değil), dili güvenle başka bir dil olan bölümler (haber yayınında
// yabancı dilde klip, araya giren başka dilde konuşma) transkriptten, nottan, Sor/MCP arşivinden, dışa aktarmalardan ve
// konuşmacı sayısından çıkarılır. Kayıttaki bölümler silinmez: dil bölümle birlikte saklanır (`StoredSegment.spokenLanguage`)
// ve süzme okuma anında `meetingSegments` içinde yapılır (bkz. `isSkippedForLanguage`).
//
// Algılama Apple'ın NaturalLanguage çerçevesiyle cihazda yapılır (ücretsiz, ağsız); çerçeve paketin desteklediği bütün
// sürümlerde (macOS 15, iOS 26) vardır. Bir algılama ~0,5 ms sürdüğü için okuma anında değil, bölüm oluşurken bir kez
// yapılır (canlı bölüm kesinleşince, son geçiş bölümleri gelince).
//
// Eşikler muhafazakârdır: yanlışlıkla toplantı dilindeki konuşmayı atlamak, başka dildeki bir cümleyi bırakmaktan
// kötüdür. Yalnızca en az `spokenLanguageMinWords` harfli sözcüğü olan ve baskın dil olasılığı en az
// `spokenLanguageMinProbability` olan bölümün dili kaydedilir; kısa sözler ("okei, joo"), adlar, sayılar ve karışık
// cümleler hiç algılanmaz ve toplantı dilinde sayılır.

/// Dili algılanacak bölümde en az bu kadar harfli sözcük olmalı (sayılar ve işaretler sayılmaz): kısa sözlerde
/// NaturalLanguage kararsızdır ("Okei, joo." Fince %82).
let spokenLanguageMinWords: Int = 6
/// Baskın dilin olasılığı en az bu kadar olmalı: "Microsoft Teams Q3 OKR KPI" gibi ad ve kısaltma dizileri %60 civarında
/// kalır, gerçek cümleler %99'un üstündedir.
let spokenLanguageMinProbability: Double = 0.85

/// Yazılı biçimleri çok yakın olduğu için birbirinden ayrılmayan dil kümeleri (NaturalLanguage kodlarıyla): toplantı dili
/// bunlardan biriyse kümedeki diğerleri başka dil sayılmaz (Norveççe toplantıda Danca sanılan cümle atlanmasın).
private let closeLanguageGroups: [Set<String>] = [
    ["no", "da"],
    ["hr", "sr", "bs"],
    ["id", "ms"],
    ["cs", "sk"],
]

/// Metnin güvenle algılanan dili: NaturalLanguage kodu, toplantı dili kodlarına uyarlanmış ("nb"/"nn" → "no",
/// "zh-Hans"/"zh-Hant" → "zh"). Metin kısaysa (`spokenLanguageMinWords`) ya da baskın dil belirsizse
/// (`spokenLanguageMinProbability`) nil. Aynı metin için hep aynı sonucu verir.
public func confidentSpokenLanguage(text: String) -> String? {
    guard letterWordCount(text: text) >= spokenLanguageMinWords else {
        return nil
    }
    let recognizer: NLLanguageRecognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    let best: (key: NLLanguage, value: Double)? = recognizer.languageHypotheses(withMaximum: 1)
        .max { (left: (key: NLLanguage, value: Double), right: (key: NLLanguage, value: Double)) -> Bool in left.value < right.value }
    guard let best, best.value >= spokenLanguageMinProbability, best.key != .undetermined else {
        return nil
    }
    return meetingLanguageCode(naturalLanguage: best.key)
}

/// NaturalLanguage dil kodunu toplantı dili kodlarına uyarlar (Whisper/Deepgram "no" ve "zh" kullanır). Saf fonksiyondur.
func meetingLanguageCode(naturalLanguage: NLLanguage) -> String {
    switch naturalLanguage {
    case .norwegian: "no"
    case .simplifiedChinese, .traditionalChinese: "zh"
    default: naturalLanguage.rawValue
    }
}

/// Metindeki harf içeren sözcükler (NaturalLanguage sözcük ayırıcısıyla; boşluksuz yazılan dillerde de doğru sayar).
/// Sayılar ve yalnız işaretten oluşan parçalar sayılmaz.
func letterWordCount(text: String) -> Int {
    let tokenizer: NLTokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    return tokenizer.tokens(for: text.startIndex..<text.endIndex)
        .filter { (range: Range<String.Index>) -> Bool in text[range].unicodeScalars.contains { CharacterSet.letters.contains($0) } }
        .count
}

/// Algılanan dil toplantı dilinden başka mı: algılanmadıysa (kısa, belirsiz, eski kayıt) hayır; toplantı diliyle ya da
/// yakın akrabasıyla (`closeLanguageGroups`) aynıysa hayır. Saf fonksiyondur.
public func isOtherLanguage(spokenLanguage: String?, meetingLanguage: MeetingLanguage) -> Bool {
    guard let spokenLanguage, spokenLanguage != meetingLanguage.rawValue else {
        return false
    }
    return !closeLanguageGroups.contains { (group: Set<String>) -> Bool in
        group.contains(spokenLanguage) && group.contains(meetingLanguage.rawValue)
    }
}

/// Bölümler, güvenle algılanan dilleriyle (bkz. `confidentSpokenLanguage`); son geçiş bölümleri saklanmadan önce bir kez.
public func labelingSpokenLanguages(segments: [StoredSegment]) -> [StoredSegment] {
    segments.map { (segment: StoredSegment) -> StoredSegment in
        segment.with(spokenLanguage: confidentSpokenLanguage(text: segment.text))
    }
}

/// Bölüm, toplantının sabit dilinden başka dilde olduğu için atlanıyor mu: dil sabit değilse (Otomatik ya da eski kayıt)
/// hiçbir bölüm atlanmaz. Saf fonksiyondur.
public func isSkippedForLanguage(segment: StoredSegment, fixedLanguage: MeetingLanguage?) -> Bool {
    guard let fixedLanguage else {
        return false
    }
    return isOtherLanguage(spokenLanguage: segment.spokenLanguage, meetingLanguage: fixedLanguage)
}

/// Canlı kayıtta sabit toplantı dilinden başka dilde algılanan kesin bölümler (panelde soluk gösterilir); dil sabit
/// değilse boş. Saf fonksiyondur.
public func otherLanguageSegmentIDs(spokenLanguages: [SegmentID: String], fixedLanguage: MeetingLanguage?) -> Set<SegmentID> {
    guard let fixedLanguage else {
        return []
    }
    return Set(spokenLanguages.compactMap { (entry: (key: SegmentID, value: String)) -> SegmentID? in
        isOtherLanguage(spokenLanguage: entry.value, meetingLanguage: fixedLanguage) ? entry.key : nil
    })
}

/// Canlı çeviri birimi sabit toplantı dilinden başka dilde mi: birimin birleşik metni (tek bölümden uzun, algılama daha
/// güvenilir) algılanır; dil sabit değilse hayır. Öyleyse çeviri istenmez (maliyet; toplantıdan zaten atlanır).
public func isOtherLanguageUnit(unit: TranslationUnit, fixedLanguage: MeetingLanguage?) -> Bool {
    guard let fixedLanguage else {
        return false
    }
    return isOtherLanguage(spokenLanguage: confidentSpokenLanguage(text: unit.text), meetingLanguage: fixedLanguage)
}
