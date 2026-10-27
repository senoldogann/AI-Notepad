import Foundation
import os
import SpeakerKit
import WhisperKit

/// Zamanı belli bir kelime (konuşmacısı henüz yok); zamanlar sesin başından itibaren saniye.
public struct TimedWord: Sendable, Equatable {
    public let text: String
    public let startSec: Double
    public let endSec: Double

    public init(text: String, startSec: Double, endSec: Double) {
        self.text = text
        self.startSec = startSec
        self.endSec = endSec
    }
}

/// Konuşmacı ayırmanın bir konuşma dönemi.
public struct SpeakerTurn: Sendable, Equatable {
    public let speaker: Int
    public let startSec: Double
    public let endSec: Double

    public init(speaker: Int, startSec: Double, endSec: Double) {
        self.speaker = speaker
        self.startSec = startSec
        self.endSec = endSec
    }
}

/// Her kelimeye en çok örtüştüğü dönemin konuşmacısını verir; hiçbir dönemle örtüşmüyorsa ortası en yakın
/// dönemin konuşmacısını. Dönem yoksa (tek ses, ayrılamadı) tüm kelimeler tek konuşmacıdır. Saf fonksiyondur.
public func attributeSpeakers(words: [TimedWord], turns: [SpeakerTurn]) -> [DiarizedWord] {
    words.map { (word: TimedWord) -> DiarizedWord in
        let middle: Double = (word.startSec + word.endSec) / 2
        let best: SpeakerTurn? = turns.max { (left: SpeakerTurn, right: SpeakerTurn) -> Bool in
            let leftOverlap: Double = max(0, min(word.endSec, left.endSec) - max(word.startSec, left.startSec))
            let rightOverlap: Double = max(0, min(word.endSec, right.endSec) - max(word.startSec, right.startSec))
            if leftOverlap != rightOverlap {
                return leftOverlap < rightOverlap
            }
            // Örtüşme yoksa (ya da eşitse) ortaya uzaklık belirler: uzak olan "küçük".
            return distance(point: middle, turn: left) > distance(point: middle, turn: right)
        }
        return DiarizedWord(text: word.text, startSec: word.startSec, endSec: word.endSec, speaker: "speaker_\(best?.speaker ?? 0)")
    }
}

private func distance(point: Double, turn: SpeakerTurn) -> Double {
    point < turn.startSec ? turn.startSec - point : (point > turn.endSec ? point - turn.endSec : 0)
}

/// Konuşmacı ayırma modelini (Pyannote, ~40 MB) önceden indirir: ilk yerel toplantının son geçişi internetsiz
/// de çalışsın. Model zaten varsa ağ kullanılmaz.
public func prepareLocalDiarization(modelsDirectory: URL) async throws {
    do {
        _ = try await SpeakerKit(PyannoteConfig(downloadBase: modelsDirectory.path, download: true, load: false, verbose: false, logLevel: .error))
    } catch {
        throw TranscriptionError.diarizationFailed(reason: String(describing: error))
    }
}

private let localPassLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "LocalFinalPass")

/// İnternetsiz son geçiş: kaydın tamamı WhisperKit (canlıdaki model) ile kelime zamanlı yazıya dökülür,
/// SpeakerKit (Pyannote) ile konuşmacılara ayrılır. Canlı motoru meşgul etmemek için kendi model örneğini
/// yükler ve iş bitince bırakır. SpeakerKit modeli ilk seferde indirilir (~40 MB).
public struct LocalFinalTranscriber: FinalTranscriber {
    private let modelsDirectory: URL
    private let modelName: String
    /// Otomatik modda aday diller (ilki ana toplantı dili).
    private let candidateLanguages: [MeetingLanguage]

    public init(modelsDirectory: URL, modelName: String, candidateLanguages: [MeetingLanguage]) {
        self.modelsDirectory = modelsDirectory
        self.modelName = modelName
        self.candidateLanguages = candidateLanguages
    }

    public func transcribeFinal(audioURL: URL, languageMode: LanguageMode) async throws -> FinalPassResult {
        let samples: [Float]
        do {
            samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
        } catch {
            throw StorageError.readFailed(path: audioURL.path, reason: String(describing: error))
        }
        let engine: WhisperKitEngine = try await WhisperKitEngine.load(modelName: modelName, modelsDirectory: modelsDirectory)
        let language: MeetingLanguage = try await meetingLanguage(languageMode: languageMode, samples: samples, engine: engine)
        let words: [TimedWord] = try await engine.transcribeWords(samples: samples, language: language)
        // Konuşmacı ayırma başarısızsa (ör. model indirilemedi) yazıya dökülen metin atılmaz: tek konuşmacı olarak
        // saklanır ve toplantıda açık uyarı gösterilir.
        let turns: [SpeakerTurn]
        let notice: String?
        do {
            turns = try await diarize(samples: samples)
            notice = nil
        } catch {
            localPassLogger.error("Yerel konuşmacı ayırma başarısız, hata: \(String(describing: error), privacy: .public)")
            turns = []
            notice = String(localized: "Konuşmacılar ayrılamadı (\(userFacingMessage(error: error))); metin tek konuşmacı olarak kaydedildi. İnternete bağlanıp \"Tekrar işle\"yi dene.")
        }
        localPassLogger.info("Yerel son geçiş bitti, kelime: \(words.count, privacy: .public), dönem: \(turns.count, privacy: .public)")
        return FinalPassResult(segments: finalSegments(words: attributeSpeakers(words: words, turns: turns), gapSec: 1.5), language: language, notice: notice)
    }

    /// Sabit dil ya da otomatikte konuşmanın ortasından alınan 30 sn'lik örnekle aday diller arasında algılanan dil
    /// (adaylardan hiçbiri değilse ana toplantı dili).
    private func meetingLanguage(languageMode: LanguageMode, samples: [Float], engine: WhisperKitEngine) async throws -> MeetingLanguage {
        if case .fixed(let language) = languageMode {
            return language
        }
        let window: Int = 16000 * 30
        let start: Int = max(0, samples.count / 2 - window / 2)
        let probe: [Float] = Array(samples[start..<min(samples.count, start + window)])
        return pickLanguage(logProbs: try await engine.detectLanguage(samples: probe), candidates: candidateLanguages)
            ?? candidateLanguages.first ?? .finnish
    }

    private func diarize(samples: [Float]) async throws -> [SpeakerTurn] {
        do {
            let speakerKit: SpeakerKit = try await SpeakerKit(PyannoteConfig(
                downloadBase: modelsDirectory.path, download: true, load: true, verbose: false, logLevel: .error
            ))
            // Modül ve sınıf adı aynı ("SpeakerKit") ve çekirdekte de `DiarizationResult` olduğu için sonuç tipi
            // adıyla yazılamaz; doğrudan bölümler alınır.
            let segments: [SpeakerSegment] = try await speakerKit.diarize(audioArray: samples).segments
            await speakerKit.unloadModels()
            return segments.compactMap { (segment: SpeakerSegment) -> SpeakerTurn? in
                segment.speaker.speakerId.map { (id: Int) -> SpeakerTurn in
                    SpeakerTurn(speaker: id, startSec: Double(segment.startTime), endSec: Double(segment.endTime))
                }
            }
        } catch {
            throw TranscriptionError.diarizationFailed(reason: String(describing: error))
        }
    }
}
