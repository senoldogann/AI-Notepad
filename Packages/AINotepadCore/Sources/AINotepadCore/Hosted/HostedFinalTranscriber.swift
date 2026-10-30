import Foundation
import os
import Security

private let finalLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedFinal")

/// Abonelik sürümünün son geçişi: kayıt 16 kHz mono WAV parçalarına (≤95 MB, ~49 dk) çevrilir, her parça sunucunun
/// `/v1/transcribe` ucuna (ElevenLabs Scribe vekili, konuşmacı ayırma açık) sırayla gönderilir, sonuçlar parça
/// konumlarıyla kaydırılıp birleştirilir; ardışık parçalar bir dakika örtüşür ve konuşmacılar ortak bölgedeki
/// kelimelerle eşlenir (bkz. `mergeChunkTranscriptions`). Sınır: ortak dakikada konuşmayan kişi sonraki parçada yeni
/// kişi olarak görünür (adlandırırken aynı ad verilebilir). Parçalar geçici klasörde tutulur ve iş bitince silinir.
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
        let chunks: [WavChunkFile] = try writeHostedWavChunks(
            source: audioURL, directory: directory, maxBytes: hostedTranscribeMaxBytes,
            overlapSamples: Int(hostedChunkOverlapSec * Double(hostedTranscribeSampleRate))
        )
        let terms: [String] = hostedKeyterms(terms: keyterms, limit: 30)
        var results: [ChunkTranscription] = []
        var stoppedNotice: String?
        var coveredUntilSec: Double?
        for (index, chunk) in chunks.enumerated() {
            let overlapSec: Double = index == 0 ? 0 : Double(chunks[index - 1].span.startSample + chunks[index - 1].span.sampleCount - chunk.span.startSample) / Double(hostedTranscribeSampleRate)
            let durationSec: Double = Double(chunk.span.sampleCount) / Double(hostedTranscribeSampleRate)
            do {
                let data: Data = try await transcribeChunk(
                    url: chunk.url, languageCode: elevenLabsLanguageCode(languageMode: languageMode), keyterms: terms,
                    uploadKey: try makeUploadKey(), timeoutSec: hostedTranscribeTimeoutSec(durationSec: durationSec)
                )
                results.append(ChunkTranscription(
                    offsetSec: chunk.span.offsetSec(sampleRate: hostedTranscribeSampleRate), overlapSec: overlapSec, result: try parseElevenLabsResponse(data: data)
                ))
                finalLogger.info("Son geçiş parçası yazıya döküldü, parça: \(results.count, privacy: .public)/\(chunks.count, privacy: .public), saniye: \(durationSec, privacy: .public)")
            } catch let error where !results.isEmpty && !(error is CancellationError) {
                // Sonraki parça reddedildi (ör. toplantının ses hakkı ya da aylık süre doldu) ya da bağlantı koptu:
                // yazıya dökülmüş (ve faturalanmış) parçalar atılmaz; kalan kısmın canlı metni korunur
                // (`coveredUntilSec`), neden bildirilir.
                let previous: WavChunkFile = chunks[index - 1]
                let covered: Double = previous.span.offsetSec(sampleRate: hostedTranscribeSampleRate) + Double(previous.span.sampleCount) / Double(hostedTranscribeSampleRate)
                let doneMinutes: Int = Int((covered / 60).rounded())
                let reason: String = (error as? HostedAPIError).map { hostedErrorMessage(error: $0) } ?? userFacingMessage(error: error)
                finalLogger.warning("Son geçiş yarıda kaldı, yazıya dökülen dakika: \(doneMinutes, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                stoppedNotice = String(localized: "Kaydın ilk \(doneMinutes) dakikası yeniden yazıya döküldü; kalanında canlı metin kullanıldı: \(reason)")
                coveredUntilSec = covered
                break
            }
        }
        let merged: DiarizationResult = mergeChunkTranscriptions(chunks: results)
        return FinalPassResult(
            segments: finalSegments(words: merged.words, gapSec: 1.5),
            language: merged.languageCode.flatMap { meetingLanguage(elevenLabsCode: $0) },
            notice: stoppedNotice,
            coveredUntilSec: coveredUntilSec
        )
    }
}

extension HostedFinalTranscriber {
    /// Parçayı gönderir. Sunucu aynı toplantının önceki yüklemesini hâlâ işliyorsa (`transcription_in_progress`, ör.
    /// bağlantı kopup istek yinelendiyse) beklenir ve en çok `hostedTranscribeBusyAttempts` kez yeniden denenir; her
    /// bekleme uyarı loglanır, sonra son hata fırlar.
    private func transcribeChunk(url: URL, languageCode: String?, keyterms: [String], uploadKey: String, timeoutSec: Double) async throws -> Data {
        var attempt: Int = 1
        while true {
            do {
                // Aynı parçanın her denemesi aynı anahtarla: önceki yanıt kaybolduysa sunucu saklı sonucu döndürür.
                return try await client.transcribe(meetingID: meetingID, wavFile: url, languageCode: languageCode, keyterms: keyterms, uploadKey: uploadKey, timeoutSec: timeoutSec)
            } catch let error as HostedAPIError where error.code == .transcriptionInProgress && attempt < hostedTranscribeBusyAttempts {
                finalLogger.warning("Toplantının önceki yüklemesi sürüyor, bekleniyor, deneme: \(attempt, privacy: .public)")
                try await Task.sleep(for: .seconds(hostedTranscribeBusyDelaySec))
                attempt += 1
            }
        }
    }
}

/// Parçanın yükleme anahtarı: 32 rastgele bayt, dolgusuz base64url (sunucu yalnızca özetini saklar).
func makeUploadKey() throws -> String {
    var bytes: [UInt8] = [UInt8](repeating: 0, count: 32)
    let status: OSStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
        throw KeychainError.unexpectedStatus(operation: "SecRandomCopyBytes(uploadKey)", status: status)
    }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Geçici parça klasörünü siler; silinemezse uyarı loglanır (son geçişin sonucu etkilenmez, sistem geçici klasörü
/// kendisi temizler).
private func removeChunkDirectory(directory: URL) {
    do {
        try FileManager.default.removeItem(at: directory)
    } catch {
        finalLogger.warning("Geçici WAV parçaları silinemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
    }
}
