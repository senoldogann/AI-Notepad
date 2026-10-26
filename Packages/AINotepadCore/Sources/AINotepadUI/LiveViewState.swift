import AINotepadCore
import Foundation

/// Çevirinin panelde gösterilişi.
public enum DisplayMode: String, Sendable, CaseIterable {
    /// Orijinal (soluk) + Türkçe.
    case bilingual
    /// Yalnızca Türkçe; çevirisi olmayan metin orijinal haliyle soluk.
    case turkishOnly
}

/// Paneldeki asistan kartı: "Ne kaçırdım?" özeti ya da soru cevabı.
public enum AssistantCard: Sendable, Equatable {
    case loading(title: String)
    case summary(MissedSummary)
    case answer(question: String, text: String)
    case failed(message: String)
}

/// Kaydın aşaması.
public enum RecordingPhase: Sendable, Equatable {
    case idle
    case recording
    /// Durduruldu; kalan metin, çeviriler ve son konuşmacı ayırma bitiyor.
    case finishing
}

/// Ada ve panelin gösterdiği her şey; uygulama modelinden bağımsız değer tipi.
public struct LiveViewState: Equatable, Sendable {
    public let phase: RecordingPhase
    public let startedAt: Date?
    /// Kayıt yokken gösterilen durum ("Hazır · Deepgram" gibi).
    public let statusText: String
    public let languageText: String
    /// Yankısı süzülmüş, konuşmacıya göre gruplanmış transkript.
    public let blocks: [SpeakerBlock]
    /// "Diğerleri" bölümlerinin Türkçesi.
    public let translations: [SegmentID: String]
    /// Çevirisi başarısız olan bölümler; panelde "Tekrar dene" gösterilir.
    public let failedTranslations: Set<SegmentID>
    public let displayMode: DisplayMode
    public let assistantCard: AssistantCard?
    /// En son en fazla 3 hata.
    public let errors: [String]
    /// Adada gösterilen son "Diğerleri" bloğu: Türkçesi gelenler Türkçe, bekleyenler orijinal (soluk);
    /// en yeni kelimeler görünsün diye başından kısaltılmış.
    public let latestOthersParts: [DisplayPart]
    public let isIslandVisible: Bool

    public var isRecording: Bool {
        phase == .recording
    }

    /// Adadaki metnin düz hali (erişilebilirlik ve testler için); konuşma yoksa nil.
    public var latestOthersSentence: String? {
        latestOthersParts.isEmpty ? nil : latestOthersParts.map(\.text).joined(separator: " ")
    }
}

/// Adada gösterilecek en fazla karakter.
let islandSentenceLimit: Int = 140

/// Uygulama durumundan görünüm durumunu üretir. Saf fonksiyondur.
public func makeLiveViewState(
    transcript: [LiveSegment],
    translations: [SegmentID: String],
    displayMode: DisplayMode,
    failedTranslations: Set<SegmentID>,
    assistantCard: AssistantCard?,
    phase: RecordingPhase,
    startedAt: Date?,
    statusText: String,
    languageText: String,
    errors: [String]
) -> LiveViewState {
    let blocks: [SpeakerBlock] = groupBySpeaker(transcript: suppressEchoes(transcript: transcript))
    // Son "Diğerleri" bloğunun tamamı: Türkçesi gelenler Türkçe (adada en hızlı anlam lazım), çevirisi
    // beklenen en yeni metin orijinal haliyle; böylece yeni konuşma çeviri gelene kadar da görünür.
    let latest: [DisplayPart] = blocks
        .last { (block: SpeakerBlock) -> Bool in block.speaker == .others }
        .map { (block: SpeakerBlock) -> [DisplayPart] in
            truncatePartsFromStart(parts: turkishOnlyParts(block: block, translations: translations), maxCharacters: islandSentenceLimit)
        } ?? []
    return LiveViewState(
        phase: phase,
        startedAt: startedAt,
        statusText: statusText,
        languageText: languageText,
        blocks: blocks,
        translations: translations,
        failedTranslations: failedTranslations,
        displayMode: displayMode,
        assistantCard: assistantCard,
        errors: Array(errors.suffix(3)),
        latestOthersParts: latest,
        isIslandVisible: phase != .idle
    )
}

/// Parçaları sondan başa toplam `maxCharacters` karaktere sığdırır; sığmayan ilk parça başından kısaltılır,
/// daha eskiler atılır. Saf fonksiyondur.
public func truncatePartsFromStart(parts: [DisplayPart], maxCharacters: Int) -> [DisplayPart] {
    var remaining: Int = maxCharacters
    var kept: [DisplayPart] = []
    for part in parts.reversed() where remaining > 0 {
        if part.text.count <= remaining {
            kept.insert(part, at: 0)
            // Parçalar arasındaki boşluk da sayılır.
            remaining -= part.text.count + 1
        } else {
            kept.insert(DisplayPart(text: truncateFromStart(text: part.text, maxCharacters: remaining), isTranslated: part.isTranslated, isFinal: part.isFinal), at: 0)
            remaining = 0
        }
    }
    return kept
}

/// Bloktaki çevirisi başarısız bölümler (sırayla). Saf fonksiyondur.
public func failedTranslationIDs(block: SpeakerBlock, failed: Set<SegmentID>) -> [SegmentID] {
    block.segments.map(\.id).filter { (id: SegmentID) -> Bool in failed.contains(id) }
}

/// Metin uzunsa başını atıp "…" ile son `maxCharacters` karakteri bırakır. Saf fonksiyondur.
public func truncateFromStart(text: String, maxCharacters: Int) -> String {
    text.count <= maxCharacters ? text : "…" + String(text.suffix(maxCharacters))
}

/// Bloktaki bölümlerin Türkçelerini sırayla birleştirir; hiç çeviri yoksa nil. Saf fonksiyondur.
public func blockTurkishText(block: SpeakerBlock, translations: [SegmentID: String]) -> String? {
    let parts: [String] = block.segments.compactMap { (segment: LiveSegment) -> String? in translations[segment.id] }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

/// "Sadece Türkçe" görünümünde bir bloğun parçası.
public struct DisplayPart: Sendable, Equatable {
    public let text: String
    public let isTranslated: Bool
    public let isFinal: Bool

    public init(text: String, isTranslated: Bool, isFinal: Bool) {
        self.text = text
        self.isTranslated = isTranslated
        self.isFinal = isFinal
    }
}

/// "Sadece Türkçe": çevirisi olan bölüm Türkçe, olmayan (yeni ya da kesinleşmemiş) bölüm orijinal haliyle;
/// böylece canlı konuşma çeviri gelene kadar da görünür. Saf fonksiyondur.
public func turkishOnlyParts(block: SpeakerBlock, translations: [SegmentID: String]) -> [DisplayPart] {
    block.segments
        .filter { (segment: LiveSegment) -> Bool in segment.failureMessage == nil && !segment.text.isEmpty }
        .map { (segment: LiveSegment) -> DisplayPart in
            translations[segment.id].map { (turkish: String) -> DisplayPart in DisplayPart(text: turkish, isTranslated: true, isFinal: true) }
                ?? DisplayPart(text: segment.text, isTranslated: false, isFinal: segment.isFinal)
        }
}
