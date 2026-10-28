import AINotepadCore
import Foundation

/// Çevirinin panelde gösterilişi.
public enum DisplayMode: String, Sendable, CaseIterable {
    /// Orijinal (soluk) + not dilindeki çeviri.
    case bilingual
    /// Yalnızca çeviri (ham değer eski sürümlerle uyumlu kalsın diye "turkishOnly"); çevirisi olmayan metin orijinal haliyle soluk.
    case turkishOnly
    /// Yalnızca orijinal (Fince/İngilizce); canlı çeviri yapılmaz, toplantı sonu not yine üretilir.
    case originalOnly

    /// Bu görünümde canlı çeviri gerekir mi.
    public var needsLiveTranslation: Bool {
        self != .originalOnly
    }
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
    /// Kayıt duraklatıldı: ses sessizlikle değiştiriliyor.
    public let isPaused: Bool
    /// "Sen" (mikrofon) kapalı: hoparlörle dinlerken yankı olmasın.
    public let isMicMuted: Bool
    /// Mikrofon düğmesi kullanılabilir: kayıt yokken her zaman; kayıtta yalnızca mikrofon kayıt başında açıldıysa
    /// (mikrofonsuz başlayan kayıtta mikrofon hiç açılmaz).
    public let canToggleMic: Bool
    /// Yüz yüze kayıt: mikrofon odadaki herkesi "Diğerleri" olarak kaydediyor (mikrofon düğmesi yerine gösterge).
    public let isInPerson: Bool
    /// Kayıt başlatılabilir (model hazır, önceki kayıt bitti).
    public let canStart: Bool
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
    /// Adada gösterilen son konuşma (konuşmacı, Türkçesi ve canlı orijinali); konuşma yoksa nil.
    public let islandLine: IslandLine?
    /// Transkriptteki kişi numaraları (konuşmacı düzeltme menüsü için).
    public let persons: [Int]
    /// "Yeni konuşmacı" seçilince verilecek, hiç kullanılmamış numara.
    public let newPersonNumber: Int
    public let isIslandVisible: Bool

    public var isRecording: Bool {
        phase == .recording
    }

    /// Adadaki ana metin (erişilebilirlik ve testler için); konuşma yoksa nil.
    public var latestOthersSentence: String? {
        islandLine?.primary
    }
}

/// Adanın açık hâlindeki satırlar: kim konuşuyor, ne dedi (Türkçesi), şu an ne diyor (orijinal, canlı).
public struct IslandLine: Sendable, Equatable {
    public let speaker: Speaker
    public let person: Int?
    /// Ana satır: son cümlelerin Türkçesi; çeviri yoksa (ya da "Sadece orijinal"de) orijinali.
    public let primary: String
    /// Ana satır henüz çeviri değil (çeviri bekleniyor): biraz soluk gösterilir.
    public let primaryIsOriginal: Bool
    /// Alt satır: çevirisi gelmemiş en yeni orijinal metin (canlı); "İki dil"de çevrilenlerin orijinali.
    public let secondary: String?
}

/// Adada en fazla bu kadar son bölüm birleştirilir (cümle bağlamı yetsin, ada dolmasın).
let islandSegmentCount: Int = 2

/// Son "Diğerleri" bloğundan ada satırlarını üretir. Saf fonksiyondur.
public func makeIslandLine(block: SpeakerBlock, translations: [SegmentID: String], displayMode: DisplayMode) -> IslandLine? {
    let spoken: [LiveSegment] = block.segments.filter { $0.failureMessage == nil && !$0.text.isEmpty }
    guard !spoken.isEmpty else {
        return nil
    }
    let recentOriginal: String = spoken.suffix(islandSegmentCount).map(\.text).joined(separator: " ")
    guard displayMode.needsLiveTranslation, let lastTranslated = spoken.lastIndex(where: { translations[$0.id] != nil }) else {
        return IslandLine(speaker: block.speaker, person: block.person, primary: recentOriginal, primaryIsOriginal: displayMode.needsLiveTranslation, secondary: nil)
    }
    let translated: [LiveSegment] = Array(spoken[...lastTranslated].filter { translations[$0.id] != nil }.suffix(islandSegmentCount))
    let pending: [LiveSegment] = Array(spoken[(lastTranslated + 1)...])
    let secondary: String? = pending.isEmpty
        ? (displayMode == .bilingual ? translated.map(\.text).joined(separator: " ") : nil)
        : pending.map(\.text).joined(separator: " ")
    return IslandLine(
        speaker: block.speaker, person: block.person,
        primary: translated.compactMap { translations[$0.id] }.joined(separator: " "),
        primaryIsOriginal: false, secondary: secondary
    )
}

/// Uygulama durumundan görünüm durumunu üretir. Saf fonksiyondur.
public func makeLiveViewState(
    transcript: [LiveSegment],
    translations: [SegmentID: String],
    displayMode: DisplayMode,
    failedTranslations: Set<SegmentID>,
    assistantCard: AssistantCard?,
    phase: RecordingPhase,
    newPersonNumber: Int,
    isPaused: Bool,
    isMicMuted: Bool,
    canToggleMic: Bool,
    isInPerson: Bool,
    canStart: Bool,
    startedAt: Date?,
    statusText: String,
    languageText: String,
    errors: [String]
) -> LiveViewState {
    let blocks: [SpeakerBlock] = groupBySpeaker(transcript: suppressEchoes(transcript: transcript))
    let island: IslandLine? = blocks
        .last { (block: SpeakerBlock) -> Bool in block.speaker == .others }
        .flatMap { (block: SpeakerBlock) -> IslandLine? in makeIslandLine(block: block, translations: translations, displayMode: displayMode) }
    return LiveViewState(
        phase: phase,
        isPaused: isPaused,
        isMicMuted: isMicMuted,
        canToggleMic: canToggleMic,
        isInPerson: isInPerson,
        canStart: canStart,
        startedAt: startedAt,
        statusText: statusText,
        languageText: languageText,
        blocks: blocks,
        translations: translations,
        failedTranslations: failedTranslations,
        displayMode: displayMode,
        assistantCard: assistantCard,
        errors: Array(errors.suffix(3)),
        islandLine: island,
        persons: knownPersons(transcript: transcript),
        newPersonNumber: newPersonNumber,
        isIslandVisible: phase != .idle
    )
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
