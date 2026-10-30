import Foundation

/// Canlı çevirinin birimi: aynı konuşmacının art arda kesin bölümleri; birleşik metin bir ya da birkaç tam cümledir.
///
/// Deepgram birkaç saniyede bir, çoğu zaman cümle ortasında kesinleştirir ("…tarjouksen hinta-" | "laatusuhde on
/// hyvä."). Bölüm bölüm çevrilince model yarım cümleyi tamamlıyor, sonraki parça aynı ifadeyi tekrarlıyor, cümle başı ve
/// sonu çevrilmeden kalıyordu. Bu yüzden bölümler cümle sonuna dek birikir ve birlikte çevrilir (bkz. `addingFinal`).
///
/// Saklama: birimin çevirisi son bölümüne (`carrierID`) yazılır; önceki bölümlerine (`coveredIDs`) boş çeviri ("")
/// yazılır: "çevrildi, çevirisi birimin son bölümünde" (bkz. `applyingUnitTranslation`). Çevirileri birleştiren her yer
/// boş çeviriyi atlar; "Sadece çeviri" görünümü kapsanan bölümün orijinalini göstermez, birim çevrilene dek gösterir.
/// Birim iki bloğa yayılırsa (konuşmacı ayırma sonradan iki kişi dedi ya da blok süresi doldu) çeviri son bölümün
/// bloğunda görünür.
public struct TranslationUnit: Sendable, Equatable {
    /// Çevirisi son bölümde görünen önceki bölümler (sırayla); tek bölümlük birimde boş.
    public let coveredIDs: [SegmentID]
    /// Çeviriyi taşıyan son bölüm.
    public let carrierID: SegmentID
    /// Bölümlerin birleşik metni (çeviriye giden).
    public let text: String
    public let startSec: Double
    public let endSec: Double

    public init(coveredIDs: [SegmentID], carrierID: SegmentID, text: String, startSec: Double, endSec: Double) {
        self.coveredIDs = coveredIDs
        self.carrierID = carrierID
        self.text = text
        self.startSec = startSec
        self.endSec = endSec
    }

    /// Birimin bütün bölümleri (sırayla, son bölüm en sonda).
    public var segmentIDs: [SegmentID] {
        coveredIDs + [carrierID]
    }

    public var speaker: Speaker {
        carrierID.speaker
    }
}

/// Birimin cümle sonu beklemeden kapandığı sınırlar.
public struct TranslationUnitLimits: Sendable, Equatable {
    /// Birim bu kadar ses süresine ulaşınca kapanır (noktalama gelmeyen uzun konuşma da çevrilsin).
    public let maxDurationSec: Double
    /// Birleşik metin bu kadar karaktere ulaşınca kapanır.
    public let maxCharacters: Int
    /// Konuşmacıdan bu kadar süre yeni kesin bölüm gelmezse bekleyen yarım birim çevrilir (duraklama, konuşma bitti).
    public let idleSec: Double

    public init(maxDurationSec: Double, maxCharacters: Int, idleSec: Double) {
        self.maxDurationSec = maxDurationSec
        self.maxCharacters = maxCharacters
        self.idleSec = idleSec
    }
}

/// Canlı çevirinin sınırları (Mac ve iPhone): ~15 sn ya da 400 karakterde, 2,5 sn sessizlikte kapanır.
public let liveTranslationUnitLimits: TranslationUnitLimits = TranslationUnitLimits(maxDurationSec: 15, maxCharacters: 400, idleSec: 2.5)

/// Birim kurucunun durumu (değer tipi; yalnızca bu dosyadaki saf fonksiyonlar yeni durum üretir).
public struct TranslationUnitBuilder: Sendable, Equatable {
    /// Konuşmacı başına henüz birime girmemiş kesin bölümler (başlangıca göre sıralı).
    public let pending: [Speaker: [LiveSegment]]
    /// Konuşmacının son kesin bölümünün geldiği an (çağıranın monoton saati, saniye).
    public let lastFinalAt: [Speaker: Double]
    /// Konuşmacı başına kapanmış birimlerin en geç bitişi: tamamı bundan önce biten geç bölüm (doldurulan boşluk) kendi
    /// başına birim olur; kapanmış birime eklenemez.
    public let closedUntilSec: [Speaker: Double]
    /// Birime girmiş bölümler: ikinci kez birime girmez (aynı bölüm iki kez çevrilmez).
    public let assigned: Set<SegmentID>

    public init(pending: [Speaker: [LiveSegment]], lastFinalAt: [Speaker: Double], closedUntilSec: [Speaker: Double], assigned: Set<SegmentID>) {
        self.pending = pending
        self.lastFinalAt = lastFinalAt
        self.closedUntilSec = closedUntilSec
        self.assigned = assigned
    }

    /// Kayıt başındaki boş durum.
    public static let empty: TranslationUnitBuilder = TranslationUnitBuilder(pending: [:], lastFinalAt: [:], closedUntilSec: [:], assigned: [])

    /// Konuşmacının bekleyen bölümleri.
    public func pendingSegments(speaker: Speaker) -> [LiveSegment] {
        pending[speaker] ?? []
    }
}

/// Kurucunun bir adımı: yeni durum ve çevrilmeye hazır birimler (sırayla).
public struct TranslationUnitStep: Sendable, Equatable {
    public let builder: TranslationUnitBuilder
    public let ready: [TranslationUnit]

    public init(builder: TranslationUnitBuilder, ready: [TranslationUnit]) {
        self.builder = builder
        self.ready = ready
    }
}

/// Cümle sonu işaretleri (Latin, CJK, Arapça/Farsça, Devanagari).
private let sentenceTerminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？", "؟", "।"]
/// Cümle sonundan sonra gelebilen kapanış işaretleri ("Tule tänne!", (näin.) gibi).
private let closingMarks: Set<Character> = ["\"", "'", "”", "’", "»", "›", ")", "]", "}"]

/// Metin cümle sonuyla bitiyor mu: sondaki boşluk ve kapanış tırnağı/parantezi atlanır. Saf fonksiyondur.
public func endsSentence(text: String) -> Bool {
    let lastMeaningful: Character? = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .reversed()
        .first { (character: Character) -> Bool in !closingMarks.contains(character) }
    return lastMeaningful.map { (character: Character) -> Bool in sentenceTerminators.contains(character) } ?? false
}

/// Bölüm metinlerini birleştirir. Kelime ortasında kesilen bileşik kelime ("hinta-" | "laatusuhde") boşluksuz
/// birleşir ("hinta-laatusuhde"); diğerleri boşlukla. Saf fonksiyondur.
public func joinedUnitText(texts: [String]) -> String {
    texts
        .map { (text: String) -> String in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { (text: String) -> Bool in !text.isEmpty }
        .reduce("") { (joined: String, text: String) -> String in
            guard !joined.isEmpty else {
                return text
            }
            return endsWithWordHyphen(text: joined) ? joined + text : joined + " " + text
        }
}

/// Metin harften hemen sonra gelen kısa çizgiyle bitiyor mu ("hinta-"; "sana -" değil). Saf fonksiyondur.
private func endsWithWordHyphen(text: String) -> Bool {
    guard text.last == "-", text.count >= 2 else {
        return false
    }
    return text.dropLast().last.map(\.isLetter) ?? false
}

/// Kesin bölümü kurucuya ekler; tamamlanan birimleri döndürür. Bölümler konuşmacı başına başlangıca göre birikir;
/// birleşik metin cümle sonuyla bitince ya da `limits` süresi/uzunluğu dolunca birim kapanır. Bilinen iki farklı kişi
/// (konuşmacı ayırma) arasında birim kendiliğinden kapanır. Kapanış her zaman bir bölümün sonundadır: cümle sonuyla
/// biten ama son bölümü cümle ortasında kalan birim oluşamaz. Boş, hatalı, kesinleşmemiş ya da zaten birime girmiş
/// bölüm yok sayılır; bekleyen bölüm aynı kimlikle yeniden gelirse yenisi geçerlidir. Saf fonksiyondur.
public func addingFinal(builder: TranslationUnitBuilder, segment: LiveSegment, nowSec: Double, limits: TranslationUnitLimits) -> TranslationUnitStep {
    let isTranslatable: Bool = segment.isFinal && segment.failureMessage == nil
        && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard isTranslatable, !builder.assigned.contains(segment.id) else {
        return TranslationUnitStep(builder: builder, ready: [])
    }
    let speaker: Speaker = segment.id.speaker
    // Kapanmış birimlerden önce biten geç bölüm (Deepgram'ın boş bıraktığı yerin doldurulması) tek başına çevrilir.
    if let closedUntil = builder.closedUntilSec[speaker], segment.endSec <= closedUntil {
        let unit: TranslationUnit = makeUnit(fragments: [segment])
        return TranslationUnitStep(builder: closing(builder: builder, speaker: speaker, units: [unit], open: builder.pendingSegments(speaker: speaker)), ready: [unit])
    }
    let fragments: [LiveSegment] = (builder.pendingSegments(speaker: speaker).filter { $0.id != segment.id } + [segment])
        .sorted { (left: LiveSegment, right: LiveSegment) -> Bool in left.startSec < right.startSec }
    let split: (units: [TranslationUnit], open: [LiveSegment]) = closingUnits(fragments: fragments, limits: limits)
    let touched: TranslationUnitBuilder = TranslationUnitBuilder(
        pending: builder.pending, lastFinalAt: builder.lastFinalAt.merging([speaker: nowSec]) { (_: Double, new: Double) -> Double in new },
        closedUntilSec: builder.closedUntilSec, assigned: builder.assigned
    )
    return TranslationUnitStep(builder: closing(builder: touched, speaker: speaker, units: split.units, open: split.open), ready: split.units)
}

/// Konuşmacısından `limits.idleSec` boyunca yeni kesin bölüm gelmeyen bekleyen bölümleri birim yapar (konuşma durdu ya
/// da noktalama gelmedi). Saf fonksiyondur.
public func flushingIdle(builder: TranslationUnitBuilder, nowSec: Double, limits: TranslationUnitLimits) -> TranslationUnitStep {
    let idleSpeakers: [Speaker] = builder.pending.keys
        .filter { (speaker: Speaker) -> Bool in
            nowSec - (builder.lastFinalAt[speaker] ?? nowSec) >= limits.idleSec
        }
        .sorted { $0.rawValue < $1.rawValue }
    return flushing(builder: builder, speakers: idleSpeakers)
}

/// Kayıt sonunda bütün bekleyen bölümleri birim yapar. Saf fonksiyondur.
public func flushingAll(builder: TranslationUnitBuilder) -> TranslationUnitStep {
    flushing(builder: builder, speakers: builder.pending.keys.sorted { $0.rawValue < $1.rawValue })
}

/// Verilen konuşmacıların bekleyen bölümlerini birer birim yapar. Saf fonksiyondur.
private func flushing(builder: TranslationUnitBuilder, speakers: [Speaker]) -> TranslationUnitStep {
    speakers.reduce(TranslationUnitStep(builder: builder, ready: [])) { (step: TranslationUnitStep, speaker: Speaker) -> TranslationUnitStep in
        let fragments: [LiveSegment] = step.builder.pendingSegments(speaker: speaker)
        guard !fragments.isEmpty else {
            return step
        }
        let unit: TranslationUnit = makeUnit(fragments: fragments)
        return TranslationUnitStep(builder: closing(builder: step.builder, speaker: speaker, units: [unit], open: []), ready: step.ready + [unit])
    }
}

/// Sıralı bölümlerden kapanan birimler ve açık kalan kuyruk. Saf fonksiyondur.
private func closingUnits(fragments: [LiveSegment], limits: TranslationUnitLimits) -> (units: [TranslationUnit], open: [LiveSegment]) {
    var units: [TranslationUnit] = []
    var current: [LiveSegment] = []
    for fragment in fragments {
        if let previous = current.last?.person, let next = fragment.person, previous != next {
            units.append(makeUnit(fragments: current))
            current = []
        }
        current.append(fragment)
        if isComplete(fragments: current, limits: limits) {
            units.append(makeUnit(fragments: current))
            current = []
        }
    }
    return (units, current)
}

/// Birim kapanmalı mı: cümle sonu, en uzun süre ya da en uzun metin. Saf fonksiyondur.
private func isComplete(fragments: [LiveSegment], limits: TranslationUnitLimits) -> Bool {
    guard let first = fragments.first, let last = fragments.last else {
        return false
    }
    let text: String = joinedUnitText(texts: fragments.map(\.text))
    return endsSentence(text: text) || last.endSec - first.startSec >= limits.maxDurationSec || text.count >= limits.maxCharacters
}

/// Kapanan birimleri duruma işler: bekleyenler `open` olur, birimin bölümleri "birime girdi" sayılır. Saf fonksiyondur.
private func closing(builder: TranslationUnitBuilder, speaker: Speaker, units: [TranslationUnit], open: [LiveSegment]) -> TranslationUnitBuilder {
    let closedUntil: Double? = (units.map(\.endSec) + [builder.closedUntilSec[speaker]].compactMap { $0 }).max()
    return TranslationUnitBuilder(
        pending: builder.pending.merging([speaker: open]) { (_: [LiveSegment], new: [LiveSegment]) -> [LiveSegment] in new }.filter { !$0.value.isEmpty },
        lastFinalAt: builder.lastFinalAt,
        closedUntilSec: closedUntil.map { (end: Double) -> [Speaker: Double] in
            builder.closedUntilSec.merging([speaker: end]) { (_: Double, new: Double) -> Double in new }
        } ?? builder.closedUntilSec,
        assigned: builder.assigned.union(units.flatMap(\.segmentIDs))
    )
}

/// Boş olmayan sıralı bölümlerden birim. Saf fonksiyondur.
private func makeUnit(fragments: [LiveSegment]) -> TranslationUnit {
    let ids: [SegmentID] = fragments.map(\.id)
    return TranslationUnit(
        coveredIDs: Array(ids.dropLast()),
        carrierID: ids[ids.count - 1],
        text: joinedUnitText(texts: fragments.map(\.text)),
        startSec: fragments.map(\.startSec).min() ?? 0,
        endSec: fragments.map(\.endSec).max() ?? 0
    )
}

/// Birimin çevirisini sözlüğe yazar: son bölüme çeviri, önceki bölümlere boş çeviri (kapsandı). Saf fonksiyondur.
public func applyingUnitTranslation(translations: [SegmentID: String], unit: TranslationUnit, translation: String) -> [SegmentID: String] {
    let covered: [SegmentID: String] = Dictionary(uniqueKeysWithValues: unit.coveredIDs.map { ($0, "") })
    return translations
        .merging(covered) { (_: String, new: String) -> String in new }
        .merging([unit.carrierID: translation]) { (_: String, new: String) -> String in new }
}

/// Verilen bölümlerden en az birini içeren birimler (sırayla, her biri bir kez): "Tekrar dene" bütün birimi yeniden
/// çevirir. Saf fonksiyondur.
public func unitsContaining(ids: [SegmentID], units: [TranslationUnit]) -> [TranslationUnit] {
    let wanted: Set<SegmentID> = Set(ids)
    return units.filter { (unit: TranslationUnit) -> Bool in !wanted.isDisjoint(with: unit.segmentIDs) }
}

/// Birimi çevirirken bağlam: ondan önce başlayan son `count` birimin orijinal metni (zaman sırasıyla). Saf fonksiyondur.
public func translationContext(units: [TranslationUnit], before unit: TranslationUnit, count: Int) -> [String] {
    units
        .filter { (other: TranslationUnit) -> Bool in other.startSec < unit.startSec && other.carrierID != unit.carrierID }
        .sorted { $0.startSec < $1.startSec }
        .suffix(count)
        .map(\.text)
}

/// Birim kurucunun saati (`nowSec`): monoton saniye. `Task.sleep` ile aynı saattir; sistem saati değişse de geri gitmez.
public func translationUnitClockSeconds() -> Double {
    (ContinuousClock.now - translationUnitClockOrigin) / .seconds(1)
}

private let translationUnitClockOrigin: ContinuousClock.Instant = .now
