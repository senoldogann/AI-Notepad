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
    let visible: [LiveSegment] = suppressEchoes(transcript: transcript)
    let latest: String? = visible
        .last { (segment: LiveSegment) -> Bool in segment.id.speaker == .others && !segment.text.isEmpty }
        .map { (segment: LiveSegment) -> String in truncateFromStart(text: segment.text, maxCharacters: islandSentenceLimit) }
    return LiveViewState(
        isRecording: isRecording,
        startedAt: startedAt,
        statusText: statusText,
        languageText: languageText,
        blocks: groupBySpeaker(transcript: visible),
        errors: Array(errors.suffix(3)),
        latestOthersSentence: latest,
        isIslandVisible: isRecording
    )
}

/// Metin uzunsa başını atıp "…" ile son `maxCharacters` karakteri bırakır. Saf fonksiyondur.
public func truncateFromStart(text: String, maxCharacters: Int) -> String {
    text.count <= maxCharacters ? text : "…" + String(text.suffix(maxCharacters))
}
