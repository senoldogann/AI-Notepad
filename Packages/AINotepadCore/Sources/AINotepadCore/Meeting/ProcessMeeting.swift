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

    public init(segments: [StoredSegment], language: MeetingLanguage?, notice: String?) {
        self.segments = segments
        self.language = language
        self.notice = notice
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
    /// Türkçe not.
    case writingNote
}

/// Son geçiş yapılacak mı: hangi servisle ya da neden atlandığı (toplantıda uyarı olarak görünür).
public enum FinalPassPlan: Sendable {
    case run(any FinalTranscriber)
    case skip(reason: String)
}

/// Bulut son geçişi: ElevenLabs Scribe v2, konuşmacı ayırma açık.
public struct ElevenLabsFinalTranscriber: FinalTranscriber {
    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func transcribeFinal(audioURL: URL, languageMode: LanguageMode) async throws -> FinalPassResult {
        let result: DiarizationResult = try await diarizeFile(
            apiKey: apiKey, fileURL: audioURL, mimeType: "audio/mp4", languageMode: languageMode,
            timeoutSec: finalPassTimeoutSec(durationSec: try audioDurationSec(url: audioURL))
        )
        return FinalPassResult(
            segments: finalSegments(words: result.words, gapSec: 1.5),
            language: result.languageCode.flatMap { meetingLanguage(elevenLabsCode: $0) },
            notice: nil
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
/// başarısız olursa toplantıda uyarı, canlı metin kullanılır), (3) Türkçe not. Bir adım başarısız olursa o ana kadarki ilerleme korunur, durum `failed` olur;
/// ses dosyaları kaldığı için yeniden işlenebilir.
public func processMeeting(
    record: MeetingRecord,
    directory: URL,
    finalPass: FinalPassPlan,
    llm: LLMProvider?,
    languageMode: LanguageMode,
    userName: String,
    onStep: @escaping @MainActor @Sendable (ProcessingStep) async -> Void
) async -> MeetingRecord {
    var current: MeetingRecord = record.with(status: .processing, failureMessage: nil).with(notice: nil)
    await onStep(.convertingAudio)

    for name in ["me", "others"] {
        let caf: URL = directory.appending(path: "\(name).caf")
        guard FileManager.default.fileExists(atPath: caf.path) else {
            continue
        }
        do {
            try convertToM4A(source: caf, destination: directory.appending(path: "\(name).m4a"))
            try FileManager.default.removeItem(at: caf)
        } catch {
            return failed(record: current, step: String(localized: "Ses dönüştürülemedi"), error: error)
        }
    }

    await onStep(.finalPass)
    switch finalPass {
    case .skip(let reason):
        current = current.with(notice: String(localized: "Son geçiş yapılmadı: \(reason) Canlı metin kullanıldı."))
    case .run(let transcriber):
        current = await transcribeOthers(record: current, directory: directory, transcriber: transcriber, languageMode: languageMode)
        if current.meNeedsFinalPass == true {
            current = await transcribeMe(record: current, directory: directory, transcriber: transcriber, languageMode: languageMode)
        }
    }

    await onStep(.writingNote)
    return await regenerateNote(record: current, llm: llm, userName: userName)
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
        return record
            .with(translations: record.translations.merging(
                alignTranslations(final: result.segments, live: record.liveSegments, translations: record.translations)
            ) { (existing: String, _: String) -> String in existing })
            .with(finalSegments: result.segments, language: record.language ?? result.language)
            // Yeni son geçiş konuşmacıları baştan numaralar: eski adlar ("Konuşmacı 2 = Aino") başka kişiye düşerdi ve
            // not yanlış kişilere görev yazardı. Adlar yeniden verilir ("Gözden geçir" önerir).
            .with(speakerNames: [:])
            .with(notice: result.notice)
    } catch {
        processLogger.error("Son geçiş başarısız, canlı metinle devam ediliyor, hata: \(String(describing: error), privacy: .private)")
        return record.with(notice: String(localized: "Son geçiş başarısız: \(userFacingMessage(error: error)) Not canlı metinden yazıldı; \"Tekrar işle\" ile yeniden deneyebilirsin."))
    }
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

/// Yalnızca notu (yeniden) üretir: saklı bölümler ve güncel konuşmacı adlarıyla. Ses gerekmez; ad verdikten
/// sonra notta da adlar görünsün diye kullanılır.
public func regenerateNote(record: MeetingRecord, llm: LLMProvider?, userName: String) async -> MeetingRecord {
    // Son geçiş "Diğerleri"ni kapsar; "Sen" için canlı bölümler; hoparlör yankısı nota girmez.
    let segments: [StoredSegment] = meetingSegments(record: record)
    guard segments.contains(where: { !$0.text.isEmpty }) else {
        return record.with(status: .done, failureMessage: nil)
    }
    guard let llm else {
        return record.with(status: .failed, failureMessage: String(localized: "Not oluşturulamadı: LLM anahtarı ya da ayarı yok. Ayarlar'dan ekleyip \"Notu yenile\"ye bas."))
    }
    do {
        guard let note = try await writeMeetingNote(segments: segments, speakerNames: record.speakerNames, userName: userName, llm: llm) else {
            return record.with(status: .done, failureMessage: nil)
        }
        return record.with(note: note).with(status: .done, failureMessage: nil)
    } catch {
        return failed(record: record, step: String(localized: "Not oluşturulamadı"), error: error)
    }
}

private func failed(record: MeetingRecord, step: String, error: any Error) -> MeetingRecord {
    // Hata gövdesi toplantı metni içerebilir: yalnızca özel (private) loglanır.
    processLogger.error("Toplantı işleme adımı başarısız, adım: \(step, privacy: .public), hata: \(String(describing: error), privacy: .private)")
    return record.with(status: .failed, failureMessage: "\(step): \(userFacingMessage(error: error))")
}
