import AINotepadCore
import Foundation

/// Ada ve panelin gösterdiği her şey; uygulama modelinden bağımsız değer tipi.
public struct LiveViewState: Equatable, Sendable {
    public let isRecording: Bool
    public let startedAt: Date?
    /// Kayıt yokken gösterilen durum ("Hazır · Deepgram" gibi).
    public let statusText: String
    public let languageText: String
    /// Yankısı süzülmüş, konuşmacıya göre gruplanmış transkript.
    public let blocks: [SpeakerBlock]
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
            block.segments.map(\.text).filter { (text: String) -> Bool in !text.isEmpty }.joined(separator: " ")
        }
        .flatMap { (text: String) -> String? in text.isEmpty ? nil : truncateFromStart(text: text, maxCharacters: islandSentenceLimit) }
    return LiveViewState(
        isRecording: isRecording,
        startedAt: startedAt,
        statusText: statusText,
        languageText: languageText,
        blocks: blocks,
        errors: Array(errors.suffix(3)),
        latestOthersSentence: latest,
        isIslandVisible: isRecording
    )
}

/// Metin uzunsa başını atıp "…" ile son `maxCharacters` karakteri bırakır. Saf fonksiyondur.
public func truncateFromStart(text: String, maxCharacters: Int) -> String {
    text.count <= maxCharacters ? text : "…" + String(text.suffix(maxCharacters))
}
