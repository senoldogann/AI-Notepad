import Foundation
import os
import WhisperKit

/// Canlı transkripsiyonda kullanılan WhisperKit modeli (large-v3 turbo, ~630 MB).
public let liveWhisperModel: String = "large-v3-v20240930_turbo_632MB"

/// WhisperKit üzerinden Mac'te çalışan yazıya dökme motoru.
///
/// Actor yeniden girişlidir: `await` noktalarında başka bir çağrı araya girebilir. Çağıran taraf
/// motor çağrılarını tek bir seri işçiden yapmalıdır (bkz. `runLiveSession`).
public actor WhisperKitEngine: TranscriptionEngine {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "WhisperKitEngine")

    private let whisperKit: WhisperKit
    private let modelName: String

    private init(whisperKit: WhisperKit, modelName: String) {
        self.whisperKit = whisperKit
        self.modelName = modelName
    }

    /// Modeli (gerekirse indirip) yükler ve hazır bir motor döndürür.
    public static func load(modelName: String, modelsDirectory: URL) async throws -> WhisperKitEngine {
        let config: WhisperKitConfig = WhisperKitConfig(
            model: modelName,
            downloadBase: modelsDirectory,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        do {
            let whisperKit: WhisperKit = try await WhisperKit(config)
            logger.info("Model yüklendi: \(modelName, privacy: .public)")
            return WhisperKitEngine(whisperKit: whisperKit, modelName: modelName)
        } catch {
            throw TranscriptionError.modelLoadFailed(model: modelName, reason: String(describing: error))
        }
    }

    public func detectLanguage(samples: [Float]) async throws -> [String: Float] {
        do {
            // Not: "detectLangauge" WhisperKit'teki gerçek (yazım hatalı) API adıdır.
            return try await whisperKit.detectLangauge(audioArray: samples).langProbs
        } catch {
            throw TranscriptionError.transcriptionFailed(
                sampleCount: samples.count,
                language: "detect",
                reason: String(describing: error)
            )
        }
    }

    public func transcribe(samples: [Float], language: MeetingLanguage) async throws -> String {
        let options: DecodingOptions = DecodingOptions(
            task: .transcribe,
            language: language.rawValue,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results: [TranscriptionResult]
        do {
            results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        } catch {
            throw TranscriptionError.transcriptionFailed(
                sampleCount: samples.count,
                language: language.rawValue,
                reason: String(describing: error)
            )
        }
        return speechText(segments: results.flatMap { (result: TranscriptionResult) -> [TranscriptionSegment] in result.segments })
    }
}

extension WhisperKitEngine {
    /// Uzun sesi (ör. kaydın tamamı) ses etkinliğine göre parçalayarak kelime zamanlarıyla yazıya döker.
    /// Uydurma ifade içeren bölümlerin kelimeleri atılır.
    func transcribeWords(samples: [Float], language: MeetingLanguage) async throws -> [TimedWord] {
        let options: DecodingOptions = DecodingOptions(
            task: .transcribe,
            language: language.rawValue,
            detectLanguage: false,
            skipSpecialTokens: true,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        let results: [TranscriptionResult]
        do {
            results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        } catch {
            throw TranscriptionError.transcriptionFailed(sampleCount: samples.count, language: language.rawValue, reason: String(describing: error))
        }
        return results
            .flatMap { (result: TranscriptionResult) -> [TranscriptionSegment] in result.segments }
            .filter { (segment: TranscriptionSegment) -> Bool in
                !dropHallucination(text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty
            }
            .flatMap { (segment: TranscriptionSegment) -> [WordTiming] in segment.words ?? [] }
            .compactMap { (word: WordTiming) -> TimedWord? in
                let text: String = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : TimedWord(text: text, startSec: Double(word.start), endSec: Double(word.end))
            }
    }
}

/// Bölümlerin metnini birleştirir; bilinen uydurma ifadeleri atar.
/// Not: WhisperKit `noSpeechProb` değerini hesaplamaz (her zaman 0), bu yüzden ona göre süzülmez.
func speechText(segments: [TranscriptionSegment]) -> String {
    segments
        .map { (segment: TranscriptionSegment) -> String in
            dropHallucination(text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .filter { (text: String) -> Bool in !text.isEmpty }
        .joined(separator: " ")
}
