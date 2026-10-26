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

/// Ada ve panelin gösterdiği her şey; uygulama modelinden bağımsız değer tipi.
public struct LiveViewState: Equatable, Sendable {
    public let isRecording: Bool
    public let startedAt: Date?
    /// Kayıt yokken gösterilen durum ("Hazır · Deepgram" gibi).
    public let statusText: String
    public let languageText: String
    /// Yankısı süzülmüş, konuşmacıya göre gruplanmış transkript.
    public let blocks: [SpeakerBlock]
    /// "Diğerleri" bölümlerinin Türkçesi.
    public let translations: [SegmentID: String]
    public let displayMode: DisplayMode
    public let assistantCard: AssistantCard?
    /// En son en fazla 3 hata.
    public let errors: [String]
    /// Adada gösterilen son "Diğerleri" cümlesi (başından kısaltılmış).
    public let latestOthersSentence: String?
    public let isIslandVisible: Bool
}

/// Adada gösterilecek en fazla karakter.
let islandSentenceLimit: Int = 140

/// Uygulama durumundan görünüm durumunu üretir. Saf fonksiyondur.
public func makeLiveViewState(
    transcript: [LiveSegment],
    translations: [SegmentID: String],
    displayMode: DisplayMode,
    assistantCard: AssistantCard?,
    isRecording: Bool,
    startedAt: Date?,
    statusText: String,
    languageText: String,
    errors: [String]
) -> LiveViewState {
    let blocks: [SpeakerBlock] = groupBySpeaker(transcript: suppressEchoes(transcript: transcript))
    // Son "Diğerleri" bloğunun tüm metni: tek parça cümlenin yalnızca sonunu gösterebilir.
    let latest: String? = blocks
        .last { (block: SpeakerBlock) -> Bool in block.speaker == .others }
        .map { (block: SpeakerBlock) -> String in
            // Türkçesi varsa o gösterilir: adada kullanıcıya en hızlı anlam lazım.
            blockTurkishText(block: block, translations: translations)
                ?? block.segments.map(\.text).filter { (text: String) -> Bool in !text.isEmpty }.joined(separator: " ")
        }
        .flatMap { (text: String) -> String? in text.isEmpty ? nil : truncateFromStart(text: text, maxCharacters: islandSentenceLimit) }
    return LiveViewState(
        isRecording: isRecording,
        startedAt: startedAt,
        statusText: statusText,
        languageText: languageText,
        blocks: blocks,
        translations: translations,
        displayMode: displayMode,
        assistantCard: assistantCard,
        errors: Array(errors.suffix(3)),
        latestOthersSentence: latest,
        isIslandVisible: isRecording
    )
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
