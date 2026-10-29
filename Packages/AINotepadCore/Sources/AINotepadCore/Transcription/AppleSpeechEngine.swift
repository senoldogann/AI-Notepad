import AVFoundation
import Foundation
import os
import Speech

/// Apple'ın cihaz içi konuşma tanıma modülü (`SpeechAnalyzer`).
public enum AppleSpeechModuleKind: String, Sendable, Equatable {
    /// `SpeechTranscriber`: uzun, çok konuşmacılı konuşma için yeni model (daha az dil).
    case speech
    /// `DictationTranscriber`: dikte modeli; `SpeechTranscriber`'ın desteklemediği diller (ör. Fince, Türkçe) için.
    case dictation
}

/// Bir toplantı dili için seçilen modül ve yerel ayar (ör. `fi_FI`).
public struct AppleSpeechChoice: Sendable, Equatable {
    public let kind: AppleSpeechModuleKind
    public let localeIdentifier: String

    public init(kind: AppleSpeechModuleKind, localeIdentifier: String) {
        self.kind = kind
        self.localeIdentifier = localeIdentifier
    }
}

/// Cihaz içi konuşma tanıma hataları.
public enum AppleSpeechError: Error, Equatable {
    /// Bu cihazda iki modül de bu dili desteklemiyor.
    case unsupportedLanguage(language: String)
    /// Dil modeli indirilemedi ya da kurulamadı.
    case assetInstallFailed(locale: String, reason: String)
    /// Modül için uygun ses biçimi yok.
    case noAudioFormat(locale: String)
    case audioConversionFailed(reason: String)
    case analysisFailed(locale: String, reason: String)
    /// Bu motor dil algılamaz: oturum sabit dille çalıştırılmalı (programlama hatası).
    case languageDetectionUnsupported
    /// Sistem `SpeechAnalyzer`'ı içermiyor (macOS 26'dan eski).
    case requiresNewerSystem
}

/// Cihaz içi konuşma tanıma (`SpeechAnalyzer`) bu sistemde var mı: macOS 26 ve sonrası, iPhone'da (iOS 26+) her zaman.
/// Arayüz seçeneği bununla kapatır; motorun girişleri aynı koşulda `AppleSpeechError.requiresNewerSystem` atar.
public func appleSpeechSupportedBySystem() -> Bool {
    if #available(macOS 26.0, *) {
        return true
    }
    return false
}

/// Yerel ayar kimliğinin dil kısmı ("fi_FI" → "fi", "zh-Hant-TW" → "zh"). Saf fonksiyondur.
func localeLanguagePart(identifier: String) -> String {
    String(identifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).first ?? "").lowercased()
}

/// Dil kodu için en uygun yerel ayar: kullanıcının bölgesi (ör. en_GB), sonra dilin kendi ülkesi (fi_FI, de_DE),
/// sonra alfabetik ilk. Yoksa nil. Saf fonksiyondur.
func preferredLocaleIdentifier(languageCode: String, identifiers: [String], regionCode: String?) -> String? {
    let candidates: [String] = identifiers.filter { localeLanguagePart(identifier: $0) == languageCode }.sorted()
    let regional: String? = regionCode.flatMap { (region: String) -> String? in
        candidates.first { $0.uppercased().hasSuffix("_" + region.uppercased()) }
    }
    return regional ?? candidates.first { $0.uppercased().hasSuffix("_" + languageCode.uppercased()) } ?? candidates.first
}

/// Toplantı dili için modül: `SpeechTranscriber` destekliyorsa o (uzun konuşmada daha iyi), değilse dikte modeli;
/// ikisi de desteklemiyorsa nil. Norveççe yerel ayarlarda Bokmål ("nb"). Saf fonksiyondur.
public func appleSpeechChoice(language: MeetingLanguage, speechLocales: [String], dictationLocales: [String], regionCode: String?) -> AppleSpeechChoice? {
    let code: String = language == .norwegian ? "nb" : language.rawValue
    if let identifier = preferredLocaleIdentifier(languageCode: code, identifiers: speechLocales, regionCode: regionCode) {
        return AppleSpeechChoice(kind: .speech, localeIdentifier: identifier)
    }
    return preferredLocaleIdentifier(languageCode: code, identifiers: dictationLocales, regionCode: regionCode)
        .map { AppleSpeechChoice(kind: .dictation, localeIdentifier: $0) }
}

/// Cihazın desteklediği yerel ayarlarla toplantı dili için modül seçer.
@available(macOS 26.0, *)
public func appleSpeechChoice(language: MeetingLanguage) async -> AppleSpeechChoice? {
    let speech: [String] = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales.map(\.identifier) : []
    let dictation: [String] = await DictationTranscriber.supportedLocales.map(\.identifier)
    return appleSpeechChoice(language: language, speechLocales: speech, dictationLocales: dictation, regionCode: Locale.current.region?.identifier)
}

/// Cihaz içi konuşma tanımanın desteklediği toplantı dilleri.
@available(macOS 26.0, *)
public func appleSpeechLanguages() async -> [MeetingLanguage] {
    let speech: [String] = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales.map(\.identifier) : []
    let dictation: [String] = await DictationTranscriber.supportedLocales.map(\.identifier)
    return MeetingLanguage.allCases.filter { (language: MeetingLanguage) -> Bool in
        appleSpeechChoice(language: language, speechLocales: speech, dictationLocales: dictation, regionCode: nil) != nil
    }
}

/// Seçime göre yeni modül (her çözümleyici kendi modülünü ister).
@available(macOS 26.0, *)
private func makeModule(choice: AppleSpeechChoice) -> any SpeechModule {
    let locale: Locale = Locale(identifier: choice.localeIdentifier)
    return switch choice.kind {
    case .speech: SpeechTranscriber(locale: locale, preset: .transcription)
    case .dictation: DictationTranscriber(locale: locale, preset: .longDictation)
    }
}

private let speechLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AppleSpeech")

/// Toplantı dilinin cihaz içi konuşma modelini hazırlar: dil desteklenmiyorsa `unsupportedLanguage`; model yüklü
/// değilse indirilir, ilerleme (0…1) `onProgress`'e yarım saniyede bir verilir. Sistem eskiyse `requiresNewerSystem`.
public func prepareAppleSpeech(language: MeetingLanguage, onProgress: @escaping @Sendable (Double) -> Void) async throws -> AppleSpeechChoice {
    guard #available(macOS 26.0, *) else {
        throw AppleSpeechError.requiresNewerSystem
    }
    return try await installedAppleSpeech(language: language, onProgress: onProgress)
}

/// `prepareAppleSpeech`'in gövdesi: modül seçilir, model yüklü değilse indirilip kurulur.
@available(macOS 26.0, *)
private func installedAppleSpeech(language: MeetingLanguage, onProgress: @escaping @Sendable (Double) -> Void) async throws -> AppleSpeechChoice {
    guard let choice = await appleSpeechChoice(language: language) else {
        throw AppleSpeechError.unsupportedLanguage(language: language.rawValue)
    }
    let module: any SpeechModule = makeModule(choice: choice)
    let request: AssetInstallationRequest?
    do {
        request = try await AssetInventory.assetInstallationRequest(supporting: [module])
    } catch {
        throw AppleSpeechError.assetInstallFailed(locale: choice.localeIdentifier, reason: String(describing: error))
    }
    guard let request else {
        onProgress(1)
        return choice
    }
    speechLogger.info("Konuşma modeli indiriliyor, yerel ayar: \(choice.localeIdentifier, privacy: .public), modül: \(choice.kind.rawValue, privacy: .public)")
    let progress: Progress = request.progress
    let reporter: Task<Void, Never> = Task {
        while !Task.isCancelled {
            onProgress(progress.fractionCompleted)
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                // İptal: indirme bitti.
                return
            }
        }
    }
    defer { reporter.cancel() }
    do {
        try await request.downloadAndInstall()
    } catch {
        throw AppleSpeechError.assetInstallFailed(locale: choice.localeIdentifier, reason: String(describing: error))
    }
    onProgress(1)
    speechLogger.info("Konuşma modeli kuruldu, yerel ayar: \(choice.localeIdentifier, privacy: .public)")
    return choice
}

/// Apple'ın cihaz içi konuşma tanımasıyla (`SpeechAnalyzer`) çalışan motor: internetsiz, anahtarsız, ücretsiz.
/// Dil algılamaz; oturum sabit dille çalıştırılır (kullanıcı kayıt sırasında dili değiştirebilir). Her bölüm ayrı bir
/// çözümleyiciyle yazıya dökülür; model bölümler arasında bellekte kalır (`lingering`).
///
/// Actor yeniden girişlidir: çağıran taraf motor çağrılarını tek bir seri işçiden yapmalıdır (bkz. `runLiveSession`).
public actor AppleSpeechEngine: TranscriptionEngine {
    /// Hazırlanmış diller (model kurulu).
    private var prepared: [MeetingLanguage: AppleSpeechChoice] = [:]

    public init() {}

    public func detectLanguage(samples: [Float]) async throws -> [String: Float] {
        throw AppleSpeechError.languageDetectionUnsupported
    }

    /// Sistem eskiyse `requiresNewerSystem`.
    public func transcribe(samples: [Float], language: MeetingLanguage) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw AppleSpeechError.requiresNewerSystem
        }
        let choice: AppleSpeechChoice = try await preparedChoice(language: language)
        return try await choiceText(samples: samples, choice: choice)
    }

    /// Dilin modülü; ilk kullanımda model gerekirse indirilir (kayıt sırasında dil değiştiyse).
    private func preparedChoice(language: MeetingLanguage) async throws -> AppleSpeechChoice {
        if let choice = prepared[language] {
            return choice
        }
        let choice: AppleSpeechChoice = try await prepareAppleSpeech(language: language) { (_: Double) -> Void in }
        prepared[language] = choice
        return choice
    }
}

/// Cihaz içi konuşma tanımanın dili: motor dil algılamadığı için otomatik modda ana toplantı dili. Saf fonksiyondur.
public func appleSpeechLanguage(mode: LanguageMode, primary: MeetingLanguage) -> MeetingLanguage {
    switch mode {
    case .fixed(let language): language
    case .automatic: primary
    }
}

/// Zamanlı kesin sonuç (son geçişte bölüm olur).
private struct TimedText: Sendable {
    let text: String
    let startSec: Double
    let endSec: Double
}

/// Örnekleri seçilen modülle yazıya döker.
@available(macOS 26.0, *)
private func choiceText(samples: [Float], choice: AppleSpeechChoice) async throws -> String {
    let locale: Locale = Locale(identifier: choice.localeIdentifier)
    switch choice.kind {
    case .speech:
        let module: SpeechTranscriber = SpeechTranscriber(locale: locale, preset: .transcription)
        return try await analyzedText(samples: samples, module: module, localeIdentifier: choice.localeIdentifier) { (result: SpeechTranscriber.Result) -> String in
            String(result.text.characters)
        }
    case .dictation:
        let module: DictationTranscriber = DictationTranscriber(locale: locale, preset: .longDictation)
        return try await analyzedText(samples: samples, module: module, localeIdentifier: choice.localeIdentifier) { (result: DictationTranscriber.Result) -> String in
            String(result.text.characters)
        }
    }
}

/// Cihaz içi son geçiş: kaydın tamamı Apple'ın konuşma tanımasıyla yazıya dökülür (internetsiz, model indirmesi
/// gerekmez). Konuşmacılar ayrılmaz: her sonuç zamanlı bir "Diğerleri" bölümüdür ve toplantıda bu açıkça belirtilir.
/// İçe aktarılan dosyalar da bununla yazıya dökülür. Sistem eskiyse `AppleSpeechError.requiresNewerSystem`.
public struct AppleSpeechFinalTranscriber: FinalTranscriber {
    /// Otomatik modda kullanılan dil (ana toplantı dili).
    private let primaryLanguage: MeetingLanguage

    public init(primaryLanguage: MeetingLanguage) {
        self.primaryLanguage = primaryLanguage
    }

    public func transcribeFinal(audioURL: URL, languageMode: LanguageMode) async throws -> FinalPassResult {
        guard #available(macOS 26.0, *) else {
            throw AppleSpeechError.requiresNewerSystem
        }
        let language: MeetingLanguage = appleSpeechLanguage(mode: languageMode, primary: primaryLanguage)
        let choice: AppleSpeechChoice = try await prepareAppleSpeech(language: language) { (_: Double) -> Void in }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioURL)
        } catch {
            throw StorageError.readFailed(path: audioURL.path, reason: String(describing: error))
        }
        let locale: Locale = Locale(identifier: choice.localeIdentifier)
        let parts: [TimedText] = switch choice.kind {
        case .speech:
            try await analyzedFile(file: file, module: SpeechTranscriber(locale: locale, preset: .transcription), localeIdentifier: choice.localeIdentifier) { (result: SpeechTranscriber.Result) -> TimedText in
                TimedText(text: String(result.text.characters), startSec: result.range.start.seconds, endSec: result.range.end.seconds)
            }
        case .dictation:
            try await analyzedFile(file: file, module: DictationTranscriber(locale: locale, preset: .longDictation), localeIdentifier: choice.localeIdentifier) { (result: DictationTranscriber.Result) -> TimedText in
                TimedText(text: String(result.text.characters), startSec: result.range.start.seconds, endSec: result.range.end.seconds)
            }
        }
        let segments: [StoredSegment] = parts
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .enumerated()
            .map { (item: (offset: Int, element: TimedText)) -> StoredSegment in
                StoredSegment(
                    key: "final-\(item.offset)", speaker: .others, person: nil, startSec: item.element.startSec, endSec: item.element.endSec,
                    text: item.element.text.trimmingCharacters(in: .whitespacesAndNewlines), words: nil
                )
            }
        speechLogger.info("Cihaz içi son geçiş bitti, bölüm: \(segments.count, privacy: .public), yerel ayar: \(choice.localeIdentifier, privacy: .public)")
        return FinalPassResult(
            segments: segments, language: language,
            notice: String(localized: "Cihaz içi konuşma tanıma konuşmacıları ayırmaz; konuşmacılar ayrılsın istersen Ayarlar'dan bulut motorunu seç.")
        )
    }
}

/// Ses dosyasını tek bir çözümleyiciyle yazıya döker; kesin sonuçlar zamanlarıyla döner.
@available(macOS 26.0, *)
private func analyzedFile<Module: SpeechModule>(
    file: AVAudioFile, module: Module, localeIdentifier: String, timed: @escaping @Sendable (Module.Result) -> TimedText
) async throws -> [TimedText] {
    let analyzer: SpeechAnalyzer = SpeechAnalyzer(modules: [module], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse))
    let collector: Task<[TimedText], any Error> = Task {
        var parts: [TimedText] = []
        for try await result in module.results where result.isFinal {
            parts.append(timed(result))
        }
        return parts
    }
    do {
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await collector.value
    } catch {
        collector.cancel()
        throw AppleSpeechError.analysisFailed(locale: localeIdentifier, reason: String(describing: error))
    }
}

/// Örnekleri tek bir çözümleyiciyle yazıya döker ve kesin sonuçların metnini birleştirir; konuşma yoksa boş metin.
@available(macOS 26.0, *)
private func analyzedText<Module: SpeechModule>(
    samples: [Float], module: Module, localeIdentifier: String, text: @escaping @Sendable (Module.Result) -> String
) async throws -> String {
    guard !samples.isEmpty else {
        return ""
    }
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
        throw AppleSpeechError.noAudioFormat(locale: localeIdentifier)
    }
    let buffer: AVAudioPCMBuffer = try convertedBuffer(samples: samples, format: format)
    let analyzer: SpeechAnalyzer = SpeechAnalyzer(modules: [module], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
    let collector: Task<[String], any Error> = Task {
        var parts: [String] = []
        for try await result in module.results where result.isFinal {
            parts.append(text(result))
        }
        return parts
    }
    let (input, continuation): (AsyncStream<AnalyzerInput>, AsyncStream<AnalyzerInput>.Continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    continuation.yield(AnalyzerInput(buffer: buffer))
    continuation.finish()
    do {
        try await analyzer.start(inputSequence: input)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let parts: [String] = try await collector.value
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    } catch {
        collector.cancel()
        throw AppleSpeechError.analysisFailed(locale: localeIdentifier, reason: String(describing: error))
    }
}

/// 16 kHz mono Float32 örnekleri modülün istediği biçimde tampona çevirir.
private func convertedBuffer(samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
          let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
          let channel = source.floatChannelData?[0] else {
        throw AppleSpeechError.audioConversionFailed(reason: "kaynak tampon oluşturulamadı (\(samples.count) örnek)")
    }
    samples.withUnsafeBufferPointer { (pointer: UnsafeBufferPointer<Float>) -> Void in
        guard let base = pointer.baseAddress else {
            return
        }
        channel.update(from: base, count: samples.count)
    }
    source.frameLength = AVAudioFrameCount(samples.count)
    guard format != sourceFormat else {
        return source
    }
    guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
        throw AppleSpeechError.audioConversionFailed(reason: "dönüştürücü yok: \(format)")
    }
    let capacity: AVAudioFrameCount = AVAudioFrameCount((Double(samples.count) * format.sampleRate / 16000).rounded(.up)) + 64
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
        throw AppleSpeechError.audioConversionFailed(reason: "çıkış tamponu oluşturulamadı (kapasite \(capacity))")
    }
    var supplied: Bool = false
    var conversionError: NSError?
    let status: AVAudioConverterOutputStatus = converter.convert(to: output, error: &conversionError) { (_: AVAudioPacketCount, inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? in
        // Tek tampon: verildikten sonra akış biter (dönüştürücü kalan örnekleri boşaltır).
        if supplied {
            inputStatus.pointee = .endOfStream
            return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return source
    }
    guard status != .error else {
        throw AppleSpeechError.audioConversionFailed(reason: conversionError.map { String(describing: $0) } ?? "bilinmeyen hata")
    }
    return output
}

/// Hatanın kullanıcıya gösterilen açıklaması. Saf fonksiyondur.
func appleSpeechMessage(error: AppleSpeechError) -> String {
    switch error {
    case .unsupportedLanguage(let code):
        String(localized: "Cihaz içi konuşma tanıma bu dili desteklemiyor (\(code)). Başka bir toplantı dili seç ya da Ayarlar'dan bulut motorunu (Deepgram) seç.")
    case .assetInstallFailed:
        String(localized: "Cihaz içi konuşma modeli indirilemedi. İnternete bağlanıp yeniden dene; disk alanını kontrol et.")
    case .noAudioFormat, .audioConversionFailed:
        String(localized: "Ses cihaz içi konuşma tanımaya uygun biçime çevrilemedi.")
    case .analysisFailed:
        String(localized: "Bu bölüm cihaz içi konuşma tanımayla yazıya dökülemedi.")
    case .languageDetectionUnsupported:
        String(localized: "Cihaz içi konuşma tanıma dili kendisi algılamaz; toplantı dilini seç.")
    case .requiresNewerSystem:
        String(localized: "Cihaz içi konuşma tanıma macOS 26 gerektirir. Ayarlar'dan Mac'te (WhisperKit) ya da bulut (Deepgram) motorunu seç.")
    }
}
