import Foundation
import os

private let finalLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedFinal")

/// Abonelik sürümünün son geçişi: kayıt 16 kHz mono WAV parçalarına (≤95 MB, ~49 dk) çevrilir, her parça sunucunun
/// `/v1/transcribe` ucuna (ElevenLabs Scribe vekili, konuşmacı ayırma açık) sırayla gönderilir, sonuçlar parça
/// konumlarıyla kaydırılıp birleştirilir. Parçalar geçici klasörde tutulur ve iş bitince silinir.
public struct HostedFinalTranscriber: FinalTranscriber {
    private let client: HostedClient
    /// Sesin sayıldığı toplantı oturumu (kayıt bitince ek süre boyunca açıktır).
    private let meetingID: String
    /// Adlar ve terimler; sunucunun kabul ettiği biçime süzülür (bkz. `hostedKeyterms`).
    private let keyterms: [String]

    public init(client: HostedClient, meetingID: String, keyterms: [String]) {
        self.client = client
        self.meetingID = meetingID
        self.keyterms = keyterms
    }

    public func transcribeFinal(audioURL: URL, languageMode: LanguageMode) async throws -> FinalPassResult {
        let directory: URL = FileManager.default.temporaryDirectory.appending(path: "ainotepad-hosted-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StorageError.writeFailed(path: directory.path, reason: error.localizedDescription)
        }
        defer { removeChunkDirectory(directory: directory) }
        let chunks: [WavChunkFile] = try writeHostedWavChunks(source: audioURL, directory: directory, maxBytes: hostedTranscribeMaxBytes)
        let terms: [String] = hostedKeyterms(terms: keyterms, limit: 30)
        var results: [ChunkTranscription] = []
        for chunk in chunks {
            let durationSec: Double = Double(chunk.span.sampleCount) / Double(hostedTranscribeSampleRate)
            let data: Data = try await client.transcribe(
                meetingID: meetingID, wavFile: chunk.url, languageCode: elevenLabsLanguageCode(languageMode: languageMode),
                keyterms: terms, timeoutSec: finalPassTimeoutSec(durationSec: durationSec)
            )
            results.append(ChunkTranscription(offsetSec: chunk.span.offsetSec(sampleRate: hostedTranscribeSampleRate), result: try parseElevenLabsResponse(data: data)))
            finalLogger.info("Son geçiş parçası yazıya döküldü, parça: \(results.count, privacy: .public)/\(chunks.count, privacy: .public), saniye: \(durationSec, privacy: .public)")
        }
        let merged: DiarizationResult = mergeChunkTranscriptions(chunks: results)
        return FinalPassResult(
            segments: finalSegments(words: merged.words, gapSec: 1.5),
            language: merged.languageCode.flatMap { meetingLanguage(elevenLabsCode: $0) },
            notice: nil
        )
    }
}

/// Geçici parça klasörünü siler; silinemezse uyarı loglanır (son geçişin sonucu etkilenmez, sistem geçici klasörü
/// kendisi temizler).
private func removeChunkDirectory(directory: URL) {
    do {
        try FileManager.default.removeItem(at: directory)
    } catch {
        finalLogger.warning("Geçici WAV parçaları silinemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .public)")
    }
}
