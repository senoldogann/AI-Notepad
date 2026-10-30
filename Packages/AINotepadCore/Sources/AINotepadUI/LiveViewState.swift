import AINotepadCore
import Foundation

/// Çevirinin panelde gösterilişi.
public enum DisplayMode: String, Sendable, CaseIterable {
    /// Orijinal (soluk) + not dilindeki çeviri.
    case bilingual
    /// Yalnızca çeviri (ham değer eski sürümlerle uyumlu kalsın diye "turkishOnly"); çevirisi olmayan metin orijinal haliyle soluk.
    case turkishOnly
    /// Yalnızca orijinal (toplantı dili); canlı çeviri yapılmaz, toplantı sonu not yine üretilir.
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
    /// Kayıt yokken gösterilen durum; yalnızca bir sorun ya da bekleme varsa dolu (ör. "Model hazırlanıyor…").
    public let statusText: String
    public let languageText: String
    /// Not ve çeviri dilinin arayüz dilindeki adı ("Ne kaçırdım?" ipucunda).
    public let noteLanguageText: String
    /// Yankısı süzülmüş, konuşmacıya göre gruplanmış transkript.
    public let blocks: [SpeakerBlock]
    /// "Diğerleri" bölümlerinin not dilindeki çevirisi.
    public let translations: [SegmentID: String]
    /// Çevirisi başarısız olan bölümler; panelde "Tekrar dene" gösterilir.
    public let failedTranslations: Set<SegmentID>
    /// Sabit toplantı dilinden başka dilde konuşulan bölümler: panelde soluk ve eğik görünür, çevrilmez; toplantıdan
    /// (transkript, not, Sor) okunurken atlanır (bkz. `isSkippedForLanguage`).
    public let otherLanguageSegments: Set<SegmentID>
    public let displayMode: DisplayMode
    public let assistantCard: AssistantCard?
    /// En son en fazla 3 hata.
    public let errors: [String]
    /// Adada gösterilen son konuşma (konuşmacı, çevirisi ve canlı orijinali); konuşma yoksa nil.
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

/// Adanın açık hâlindeki satırlar: kim konuşuyor, ne dedi (çevirisi), şu an ne diyor (orijinal, canlı).
public struct IslandLine: Sendable, Equatable {
    public let speaker: Speaker
    public let person: Int?
    /// Ana satır: son cümlelerin çevirisi; çeviri yoksa (ya da "Sadece orijinal"de) orijinali.
    public let primary: String
    /// Ana satır henüz çeviri değil (çeviri bekleniyor): biraz soluk gösterilir.
    public let primaryIsOriginal: Bool
    /// Alt satır: çevirisi gelmemiş en yeni orijinal metin (canlı); "İki dil"de çevrilenlerin orijinali.
    public let secondary: String?
}

/// Adada en fazla bu kadar son çeviri (çeviri birimi) birleştirilir (cümle bağlamı yetsin, ada dolmasın).
let islandSegmentCount: Int = 2

/// Son "Diğerleri" bloğundan ada satırlarını üretir. Kapanan bölüm (boş çeviri; çevirisi birimin son bölümünde, bkz.
/// `TranslationUnit`) çevrilmiş sayılır ama satıra çeviri eklemez. Saf fonksiyondur.
public func makeIslandLine(block: SpeakerBlock, translations: [SegmentID: String], displayMode: DisplayMode) -> IslandLine? {
    let spoken: [LiveSegment] = block.segments.filter { $0.failureMessage == nil && !$0.text.isEmpty }
    guard !spoken.isEmpty else {
        return nil
    }
    let recentOriginal: String = spoken.suffix(islandSegmentCount).map(\.text).joined(separator: " ")
    let carriers: [Int] = Array(spoken.indices.filter { shownTranslation(translations: translations, id: spoken[$0].id) != nil }.suffix(islandSegmentCount))
    guard displayMode.needsLiveTranslation, !carriers.isEmpty, let lastDone = spoken.lastIndex(where: { translations[$0.id] != nil }) else {
        return IslandLine(speaker: block.speaker, person: block.person, primary: recentOriginal, primaryIsOriginal: displayMode.needsLiveTranslation, secondary: nil)
    }
    // Bir çevirinin orijinali, önündeki kapsanan bölümlerle (aynı birim) birlikte kendi metnidir.
    let translatedOriginal: String = carriers
        .map { (carrier: Int) -> String in
            let unitStart: Int = spoken[..<carrier].lastIndex { translations[$0.id] != "" }.map { $0 + 1 } ?? 0
            return spoken[unitStart...carrier].map(\.text).joined(separator: " ")
        }
        .joined(separator: " ")
    let pending: [LiveSegment] = Array(spoken[(lastDone + 1)...])
    let secondary: String? = pending.isEmpty
        ? (displayMode == .bilingual ? translatedOriginal : nil)
        : pending.map(\.text).joined(separator: " ")
    return IslandLine(
        speaker: block.speaker, person: block.person,
        primary: carriers.compactMap { shownTranslation(translations: translations, id: spoken[$0].id) }.joined(separator: " "),
        primaryIsOriginal: false, secondary: secondary
    )
}

/// Bölümün gösterilecek çevirisi: yoksa ya da bölüm kapsandıysa (boş çeviri, bkz. `TranslationUnit`) nil. Saf fonksiyondur.
public func shownTranslation(translations: [SegmentID: String], id: SegmentID) -> String? {
    translations[id].flatMap { (text: String) -> String? in text.isEmpty ? nil : text }
}

/// Uygulama durumundan görünüm durumunu üretir. Saf fonksiyondur.
public func makeLiveViewState(
    transcript: [LiveSegment],
    translations: [SegmentID: String],
    displayMode: DisplayMode,
    failedTranslations: Set<SegmentID>,
    otherLanguageSegments: Set<SegmentID>,
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
    noteLanguageText: String,
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
        noteLanguageText: noteLanguageText,
        blocks: blocks,
        translations: translations,
        failedTranslations: failedTranslations,
        otherLanguageSegments: otherLanguageSegments,
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

/// Bloktaki bölümlerin çevirilerini sırayla birleştirir (kapsanan bölümlerin boş çevirisi atlanır); hiç çeviri yoksa
/// nil. Saf fonksiyondur.
public func blockTurkishText(block: SpeakerBlock, translations: [SegmentID: String]) -> String? {
    let parts: [String] = block.segments.compactMap { (segment: LiveSegment) -> String? in shownTranslation(translations: translations, id: segment.id) }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

/// "Sadece çeviri" görünümünde bir bloğun parçası.
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

/// Panelde görünen metnin düz hali ("Kopyala", "Tümünü kopyala"): blok başına `[mm:ss] Etiket: metin`; "Sadece
/// orijinal"de orijinal, "Sadece çeviri"de çeviri (çevirisi olmayan bölüm orijinal haliyle, panelde olduğu gibi), iki
/// dilde orijinalin altında çevirisi. Saf fonksiyondur.
public func displayedPlainText(blocks: [SpeakerBlock], translations: [SegmentID: String], displayMode: DisplayMode) -> String {
    switch displayMode {
    case .originalOnly:
        return plainText(blocks: blocks)
    case .turkishOnly:
        return blocks
            .compactMap { (block: SpeakerBlock) -> String? in
                let text: String = turkishOnlyParts(block: block, translations: translations).map(\.text).joined(separator: " ")
                return text.isEmpty ? nil : "[\(timestamp(seconds: block.startSec))] \(speakerLabel(speaker: block.speaker, person: block.person)): \(text)"
            }
            .joined(separator: "\n\n")
    case .bilingual:
        return blocks
            .compactMap { (block: SpeakerBlock) -> String? in
                let original: String = plainText(blocks: [block])
                guard !original.isEmpty else {
                    return nil
                }
                return blockTurkishText(block: block, translations: translations).map { "\(original)\n\($0)" } ?? original
            }
            .joined(separator: "\n\n")
    }
}

/// "Sadece çeviri": çevirisi olan bölüm çevirisiyle, olmayan (yeni ya da kesinleşmemiş) bölüm orijinal haliyle;
/// böylece canlı konuşma çeviri gelene kadar da görünür. Kapsanan bölüm (birimi çevrildi, çevirisi birimin son
/// bölümünde; bkz. `TranslationUnit`) hiç görünmez; birimi çevrilene dek orijinaliyle görünür. Saf fonksiyondur.
public func turkishOnlyParts(block: SpeakerBlock, translations: [SegmentID: String]) -> [DisplayPart] {
    block.segments
        .filter { (segment: LiveSegment) -> Bool in segment.failureMessage == nil && !segment.text.isEmpty && translations[segment.id] != "" }
        .map { (segment: LiveSegment) -> DisplayPart in
            translations[segment.id].map { (turkish: String) -> DisplayPart in DisplayPart(text: turkish, isTranslated: true, isFinal: true) }
                ?? DisplayPart(text: segment.text, isTranslated: false, isFinal: segment.isFinal)
        }
}

/// Bloğun bütün bölümleri kapsanmış mı (çevirileri sonraki bloktaki birim sonunda): "Sadece çeviri"de blok gösterilmez,
/// çevirisi o blokta görünür. Hatalı ya da boş bölümü olan blok kapsanmış sayılmaz. Saf fonksiyondur.
public func isFullyCoveredBlock(block: SpeakerBlock, translations: [SegmentID: String]) -> Bool {
    !block.segments.isEmpty && block.segments.allSatisfy { (segment: LiveSegment) -> Bool in translations[segment.id] == "" }
}

/// Blokta çeviri ya da kapsanan bölüm var mı: "Sadece çeviri"de blok çeviri parçalarıyla (`turkishOnlyParts`) gösterilir.
/// Saf fonksiyondur.
public func hasTranslationEntries(block: SpeakerBlock, translations: [SegmentID: String]) -> Bool {
    block.segments.contains { (segment: LiveSegment) -> Bool in translations[segment.id] != nil }
}
