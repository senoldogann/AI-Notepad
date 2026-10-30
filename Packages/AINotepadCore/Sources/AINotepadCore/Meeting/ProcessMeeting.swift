import AVFoundation
import Foundation
import os

private let processLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "ProcessMeeting")

/// Son geçiş sonucu: konuşmacılı "Diğerleri" bölümleri, (algılandıysa) dil ve kullanıcının bilmesi gereken
/// kısıt (ör. konuşmacılar ayrılamadı).
public struct FinalPassResult: Sendable, Equatable {
    public let segments: [StoredSegment]
    public let language: MeetingLanguage?
    public let notice: String?
    /// Geçiş yarıda kaldıysa yazıya dökülen kaydın sonu (sn); kaydın tamamı yazıldıysa nil. Bu andan sonraki canlı
    /// metin korunur (bkz. `finalSegmentsWithLiveTail`).
    public let coveredUntilSec: Double?

    public init(segments: [StoredSegment], language: MeetingLanguage?, notice: String?, coveredUntilSec: Double?) {
        self.segments = segments
        self.language = language
        self.notice = notice
        self.coveredUntilSec = coveredUntilSec
    }
}

/// Kaydın tamamından (`others.m4a`) konuşmacılı son geçiş bölümleri üreten servis.
public protocol FinalTranscriber: Sendable {
    func transcribeFinal(audioURL: URL, languageMode: LanguageMode) async throws -> FinalPassResult
}

/// Toplantı sonrası işlemenin adımı (arayüzde ilerleme olarak gösterilir).
public enum ProcessingStep: Int, Sendable, Equatable, CaseIterable {
    /// `.caf` → `.m4a`.
    case convertingAudio
    /// Kaydın tamamından son geçiş (konuşmacılar).
    case finalPass
    /// Not (not ve çeviri dilinde).
    case writingNote
}

/// Son geçiş yapılacak mı: hangi servisle ya da neden atlandığı (toplantıda uyarı olarak görünür).
public enum FinalPassPlan: Sendable {
    case run(any FinalTranscriber)
    case skip(reason: String)
    /// Son geçiş şimdi yapılamaz ve atlanmamalı (ör. sunucu güncel değil): işleme durur, toplantı "başarısız" olur ve
    /// "Tekrar işle" ile yeniden denenebilir (not canlı metinden yazılmaz).
    case stop(any Error)
}

/// Bulut son geçişi: ElevenLabs Scribe v2, konuşmacı ayırma açık.
public struct ElevenLabsFinalTranscriber: FinalTranscriber {
    private let apiKey: String
    /// Adlar ve terimler (bkz. `meetingKeyterms`).
    private let keyterms: [String]

    public init(apiKey: String, keyterms: [String]) {
        self.apiKey = apiKey
        self.keyterms = keyterms
    }

    public func transcribeFinal(audioURL: URL, languageMode: LanguageMode) async throws -> FinalPassResult {
        let result: DiarizationResult = try await diarizeFile(
            apiKey: apiKey, fileURL: audioURL, mimeType: "audio/mp4", languageMode: languageMode, keyterms: keyterms,
            timeoutSec: finalPassTimeoutSec(durationSec: try audioDurationSec(url: audioURL))
        )
        return FinalPassResult(
            segments: finalSegments(words: result.words, gapSec: 1.5),
            language: result.languageCode.flatMap { meetingLanguage(elevenLabsCode: $0) },
            notice: nil,
            coveredUntilSec: nil
        )
    }
}

/// Son geçiş isteğinin zaman aşımı: en az 300 sn, kaydın her dakikası için +10 sn. Saf fonksiyondur.
public func finalPassTimeoutSec(durationSec: Double) -> Double {
    300 + (durationSec / 60).rounded(.up) * 10
}

/// Ses dosyasının süresi (saniye).
public func audioDurationSec(url: URL) throws -> Double {
    do {
        let file: AVAudioFile = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    } catch {
        throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
    }
}

/// Toplantı sonrası işleme: (1) `.caf` → `.m4a`, (2) kaydın tamamından son geçiş (bulut ya da yerel; atlanır ya da
/// başarısız olursa toplantıda uyarı, canlı metin kullanılır), (3) not dilinde (`noteLanguage`) not. Bir adım başarısız olursa o ana kadarki ilerleme korunur, durum `failed` olur;
/// ses dosyaları kaldığı için yeniden işlenebilir.
public func processMeeting(
    record: MeetingRecord,
    directory: URL,
    finalPass: FinalPassPlan,
    llm: LLMProvider?,
    languageMode: LanguageMode,
    userName: String,
    noteLanguage: ShareLanguage,
    voiceEmbedder: (any VoiceEmbedder)?,
    registry: [RegisteredVoice],
    onStep: @escaping @MainActor @Sendable (ProcessingStep) async -> Void
) async -> MeetingRecord {
    var current: MeetingRecord = record.with(status: .processing, failureMessage: nil).with(notice: nil)
    await onStep(.convertingAudio)

    // İki kayıt aynı anda dönüştürülür (uzun toplantıda bekleme yarıya iner).
    do {
        try await convertRecordings(directory: directory)
    } catch {
        return failed(record: current, step: String(localized: "Ses dönüştürülemedi"), error: error)
    }

    await onStep(.finalPass)
    switch finalPass {
    case .skip(let reason):
        current = current.with(notice: skippedFinalPassNotice(reason: reason, hasFinalTranscript: hasOthersFinalTranscript(record: current)))
    case .stop(let error):
        return failed(record: current, step: String(localized: "Son geçiş başlatılamadı"), error: error)
    case .run(let transcriber):
        current = await transcribeOthers(record: current, directory: directory, transcriber: transcriber, languageMode: languageMode)
        if current.meNeedsFinalPass == true {
            current = await transcribeMe(record: current, directory: directory, transcriber: transcriber, languageMode: languageMode)
        }
    }

    if let voiceEmbedder {
        current = await recognizeVoices(record: current, directory: directory, embedder: voiceEmbedder, registry: registry)
    }

    // Canlı metni olmayan toplantı (içe aktarılan dosya) son geçiş metin üretmediyse "bitti" görünmesin.
    if current.liveSegments.isEmpty, !meetingSegments(record: current).contains(where: { !$0.text.isEmpty }) {
        return current.with(status: .failed, failureMessage: String(localized: "Ses yazıya dökülemedi: son geçiş metin üretmedi. \"Tekrar işle\" ile yeniden deneyebilirsin."))
    }

    await onStep(.writingNote)
    return await regenerateNote(record: current, directory: directory, llm: llm, userName: userName, language: noteLanguage)
}

/// Sesinden tanıma: kişilerin ses izleri "Diğerleri" kaydından çıkarılır, adı olmayan kişilere kayıtlı seslerden emin
/// olunan adlar verilir ve hangi adların sesinden verildiği uyarıda yazılır. İz çıkarılamazsa (ör. model indirilemedi)
/// toplantı adsız kalır, uyarı eklenir; not engellenmez.
private func recognizeVoices(record: MeetingRecord, directory: URL, embedder: any VoiceEmbedder, registry: [RegisteredVoice]) async -> MeetingRecord {
    let othersAudio: URL = directory.appending(path: "others.m4a")
    let segments: [StoredSegment] = meetingSegments(record: record)
    guard FileManager.default.fileExists(atPath: othersAudio.path), segments.contains(where: { $0.person != nil }) else {
        return record
    }
    do {
        let voiceprints: [Int: Voiceprint] = try await meetingVoiceprints(
            samples: try loadMonoSamples(url: othersAudio), segments: segments, embedder: embedder, windowSec: voiceWindowSec
        )
        let recognized: [Int: String] = recognizedNames(voiceprints: voiceprints, registry: registry)
            .filter { (entry: (key: Int, value: String)) -> Bool in
                // Kullanıcının verdiği ad ezilmez; aynı ad iki kişide olmaz.
                record.speakerNames[entry.key] == nil && !record.speakerNames.values.contains(entry.value)
            }
        let names: [Int: String] = record.speakerNames.merging(recognized) { (given: String, _: String) -> String in given }
        processLogger.info("Ses izleri çıkarıldı, kişi: \(voiceprints.count, privacy: .public), tanınan: \(recognized.count, privacy: .public)")
        let updated: MeetingRecord = record.with(voiceprints: voiceprints).with(speakerNames: names)
        guard !recognized.isEmpty else {
            return updated
        }
        let list: String = recognized.sorted { $0.key < $1.key }.map(\.value).joined(separator: ", ")
        return updated.with(notice: joinedNotice(record.notice, String(localized: "Sesinden tanındı: \(list).")))
    } catch {
        processLogger.error("Ses izleri çıkarılamadı, hata: \(String(describing: error), privacy: .private)")
        return record.with(notice: joinedNotice(record.notice, String(localized: "Konuşmacılar sesinden tanınamadı: \(userFacingMessage(error: error))")))
    }
}

/// Ses izi için kaydın bölündüğü parça (SpeakerKit'in en iyi çalıştığı uzunluk; 37 dk'lık kayıt ~20 sn).
private let voiceWindowSec: Double = 120

/// Kayıttaki `.caf` dosyalarını (`me`, `others`) aynı anda `.m4a`'ya dönüştürür ve `.caf`'ları siler; ilk hata fırlatılır.
private func convertRecordings(directory: URL) async throws {
    let sources: [URL] = ["me", "others"]
        .map { (name: String) -> URL in directory.appending(path: "\(name).caf") }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    try await withThrowingTaskGroup(of: Void.self) { (group: inout ThrowingTaskGroup<Void, any Error>) -> Void in
        for caf in sources {
            group.addTask {
                try convertToM4A(source: caf, destination: caf.deletingPathExtension().appendingPathExtension("m4a"))
                try FileManager.default.removeItem(at: caf)
            }
        }
        try await group.waitForAll()
    }
}

/// "Diğerleri" kaydının tamamından konuşmacılı son geçiş. Ses yoksa ya da geçiş başarısızsa canlı metin kalır, uyarı
/// eklenir: son geçiş yalnızca metni ve konuşmacıları iyileştirir; başarısızlığı (kota, ağ, uzun yükleme) notu
/// engellemez, "Tekrar işle" yeniden dener.
private func transcribeOthers(record: MeetingRecord, directory: URL, transcriber: any FinalTranscriber, languageMode: LanguageMode) async -> MeetingRecord {
    let othersAudio: URL = directory.appending(path: "others.m4a")
    guard FileManager.default.fileExists(atPath: othersAudio.path) else {
        return record.with(notice: String(localized: "Son geçiş yapılmadı: \"Diğerleri\" sesi kaydedilmemiş. Canlı metin kullanıldı."))
    }
    do {
        let result: FinalPassResult = try await transcriber.transcribeFinal(audioURL: othersAudio, languageMode: languageMode)
        // Canlıdaki Türkçeler son geçiş bölümlerine taşınır; geçmişte de Türkçe görünsün.
        // Önceki son geçişin Türkçeleri ("final-N") yeni bölümlere yazılmaz: yeniden işlemede numaralar başka cümlelere
        // düşer. Canlı bölümlerin Türkçeleri kalır, yeni bölümlere canlıdan hizalananlar eklenir.
        let liveTranslations: [String: String] = record.translations.filter { !$0.key.hasPrefix("final-") }
        return record
            .with(translations: liveTranslations.merging(
                alignTranslations(final: result.segments, live: record.liveSegments, translations: liveTranslations)
            ) { (_: String, aligned: String) -> String in aligned })
            // Önceki "Sen" son geçişi korunur: bu tekrar işlemede "Sen" geçişi başarısız olursa iyi metin kaybolmasın.
            .with(
                finalSegments: finalSegmentsWithLiveTail(final: result.segments, live: record.liveSegments, coveredUntilSec: result.coveredUntilSec)
                    + record.finalSegments.filter { $0.speaker == .me },
                language: record.language ?? result.language
            )
            // Yeni son geçiş konuşmacıları baştan numaralar: eski adlar ("Konuşmacı 2 = Aino") başka kişiye düşerdi ve
            // not yanlış kişilere görev yazardı. Adlar yeniden verilir ("Gözden geçir" önerir).
            .with(speakerNames: [:])
            // Eski ses izleri eski numaralara aittir; yeni numaralarla karışıp yanlış kişiye ad verdirmesin.
            .with(voiceprints: nil)
            .with(notice: result.notice)
    } catch {
        processLogger.error("Son geçiş başarısız, eldeki metinle devam ediliyor, hata: \(String(describing: error), privacy: .private)")
        return record.with(notice: failedFinalPassNotice(error: error, hasFinalTranscript: hasOthersFinalTranscript(record: record)))
    }
}

/// "Diğerleri"nin son geçiş bölümleri; geçiş yarıda kaldıysa (`coveredUntilSec`) o andan sonra başlayan canlı
/// "Diğerleri" bölümleri eklenir: son geçiş varken canlı metin gösterilmediği için (`meetingSegments`) kalan kısım
/// transkriptten ve nottan düşerdi. Saf fonksiyondur.
func finalSegmentsWithLiveTail(final: [StoredSegment], live: [StoredSegment], coveredUntilSec: Double?) -> [StoredSegment] {
    guard let coveredUntilSec else {
        return final
    }
    return final + live.filter { $0.speaker == .others && $0.startSec >= coveredUntilSec }
}

/// Kayıtta önceki son geçişin "Diğerleri" metni var mı (yeniden işlemede yeni geçiş olmazsa o metin kalır). Saf fonksiyondur.
func hasOthersFinalTranscript(record: MeetingRecord) -> Bool {
    record.finalSegments.contains { $0.speaker == .others }
}

/// Son geçiş atlandığında toplantıdaki uyarı: hangi metnin kaldığını doğru söyler. Saf fonksiyondur.
func skippedFinalPassNotice(reason: String, hasFinalTranscript: Bool) -> String {
    hasFinalTranscript
        ? String(localized: "Ses yeniden yazıya dökülmedi: \(reason) Önceki son geçiş metni korundu.")
        : String(localized: "Son geçiş yapılmadı: \(reason) Canlı metin kullanıldı.")
}

/// Son geçiş başarısız olduğunda toplantıdaki uyarı: hangi metnin kaldığını doğru söyler. Saf fonksiyondur.
func failedFinalPassNotice(error: any Error, hasFinalTranscript: Bool) -> String {
    hasFinalTranscript
        ? String(localized: "Ses yeniden yazıya dökülemedi: \(userFacingMessage(error: error)) Önceki son geçiş metni korundu, not ondan yazıldı.")
        : String(localized: "Son geçiş başarısız: \(userFacingMessage(error: error)) Not canlı metinden yazıldı; \"Tekrar işle\" ile yeniden deneyebilirsin.")
}

/// "Sen"in canlı akışı koptuysa "Sen" kaydını da yazıya döker; bölümler "Sen" olarak son geçişe eklenir ve canlı
/// "Sen" metninin yerini alır. Başarısızsa canlı metin kalır, uyarı eklenir.
private func transcribeMe(record: MeetingRecord, directory: URL, transcriber: any FinalTranscriber, languageMode: LanguageMode) async -> MeetingRecord {
    let meAudio: URL = directory.appending(path: "me.m4a")
    guard FileManager.default.fileExists(atPath: meAudio.path) else {
        return record.with(notice: joinedNotice(record.notice, String(localized: "\"Sen\" metni eksik: kayıt sırasında akış koptu ve \"Sen\" sesi kaydedilmemiş.")))
    }
    do {
        let result: FinalPassResult = try await transcriber.transcribeFinal(audioURL: meAudio, languageMode: languageMode)
        let meSegments: [StoredSegment] = result.segments.map { $0.asMe() }
        return record.with(
            finalSegments: record.finalSegments.filter { $0.speaker != .me } + meSegments,
            language: record.language ?? result.language
        )
    } catch {
        processLogger.error("\"Sen\" son geçişi başarısız, hata: \(String(describing: error), privacy: .private)")
        return record.with(notice: joinedNotice(record.notice, String(localized: "\"Sen\" kaydı yazıya dökülemedi: \(userFacingMessage(error: error)) Canlı metin eksik olabilir; \"Tekrar işle\" ile yeniden deneyebilirsin.")))
    }
}

/// İki uyarıyı birleştirir. Saf fonksiyondur.
private func joinedNotice(_ first: String?, _ second: String) -> String {
    first.map { "\($0) \(second)" } ?? second
}

/// Uzun notun parça ilerlemesinin toplantı klasöründeki dosyası (not bitince silinir).
let noteProgressFileName: String = "note-progress.json"

/// Yalnızca notu (yeniden) üretir: saklı bölümler ve güncel konuşmacı adlarıyla. Ses gerekmez; ad verdikten
/// sonra notta da adlar görünsün diye kullanılır. Not `language` dilinde yazılır. Uzun notun ilerlemesi toplantı
/// klasörüne yazılır (bkz. `writeMeetingNote`).
public func regenerateNote(record: MeetingRecord, directory: URL, llm: LLMProvider?, userName: String, language: ShareLanguage) async -> MeetingRecord {
    // Son geçiş "Diğerleri"ni kapsar; "Sen" için canlı bölümler; hoparlör yankısı nota girmez.
    // İşaretli anlar istemde "★" ile öne çıkar.
    let segments: [StoredSegment] = markingHighlights(segments: meetingSegments(record: record), highlights: record.highlights ?? [])
    guard segments.contains(where: { !$0.text.isEmpty }) else {
        // Metni olmayan başarısız toplantı (ör. son geçişi başarısız içe aktarma) "bitti" olmaz: "Tekrar işle" için sesi
        // saklama süresinde silinmesin.
        return record.status == .failed ? record : record.with(status: .done, failureMessage: nil)
    }
    guard let llm else {
        // Notu olan toplantı (yenileme) "Hata"ya dönmez: eski not kalır (hata yolundaki kuralla aynı).
        if record.note != nil {
            return record.with(status: .done, failureMessage: String(localized: "Not yenilenemedi: LLM anahtarı ya da ayarı yok. Önceki not gösteriliyor."))
        }
        return record.with(status: .failed, failureMessage: String(localized: "Not oluşturulamadı: LLM anahtarı ya da ayarı yok. Ayarlar'dan ekleyip \"Notu yenile\"ye bas."))
    }
    do {
        // Cihaz içi modelde toplantının ya da notun dili desteklenmiyorsa not yazılmaz (bozuk not yerine açık hata).
        try requireOnDeviceLanguages(provider: llm, meetingLanguages: record.language.map { [$0] } ?? [], outputLanguage: language)
        guard let note = try await writeMeetingNote(
            segments: segments, speakerNames: record.speakerNames, userName: userName, template: record.template ?? .general,
            myNotes: record.myNotes ?? "", language: language, llm: llm,
            progressFile: directory.appending(path: noteProgressFileName)
        ) else {
            return record.with(status: .done, failureMessage: nil)
        }
        // Görevler yeniden yazıldı: tamamlandı ve Anımsatıcılar işaretleri benzer yeni görevlere taşınır.
        return withCarriedTaskMarks(old: record, new: record.with(note: note)).with(status: .done, failureMessage: nil)
    } catch {
        // Notu olan toplantıda (yenileme) geçici hata toplantıyı "Hata"ya çevirmez: eski not kalır, hata mesajı sayfada
        // görünür ve sonraki başarılı yenilemede silinir.
        if record.note != nil {
            processLogger.error("Not yenilenemedi, eski not korunuyor, hata: \(String(describing: error), privacy: .private)")
            return record.with(
                status: .done,
                failureMessage: String(localized: "Not yenilenemedi: \(userFacingMessage(error: error)) Önceki not gösteriliyor.")
            )
        }
        return failed(record: record, step: String(localized: "Not oluşturulamadı"), error: error)
    }
}

private func failed(record: MeetingRecord, step: String, error: any Error) -> MeetingRecord {
    // Hata gövdesi toplantı metni içerebilir: yalnızca özel (private) loglanır.
    processLogger.error("Toplantı işleme adımı başarısız, adım: \(step, privacy: .public), hata: \(String(describing: error), privacy: .private)")
    return record.with(status: .failed, failureMessage: "\(step): \(userFacingMessage(error: error))")
}
