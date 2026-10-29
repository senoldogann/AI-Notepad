import Foundation
import SpeakerKit
import WhisperKit

/// SpeakerKit (Pyannote) ile ses izi: model ilk kullanımda yüklenir (yoksa ~40 MB indirilir) ve örnek yaşadıkça
/// bellekte kalır; kayıt boyunca her dakika aynı model kullanılır.
public actor SpeakerKitVoiceEmbedder: VoiceEmbedder {
    private let modelsDirectory: URL
    private var kit: SpeakerKit?

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    public func clusters(samples: [Float]) async throws -> [VoiceCluster] {
        do {
            let loaded: SpeakerKit = try await loadedKit()
            // Çekirdekte de `DiarizationResult` olduğu için sonuç tipi adıyla yazılamaz.
            let result = try await loaded.diarize(audioArray: samples)
            let turns: [Int: [ClosedRange<Double>]] = result.segments.reduce(into: [Int: [ClosedRange<Double>]]()) { (turns: inout [Int: [ClosedRange<Double>]], segment: SpeakerSegment) -> Void in
                if let id = segment.speaker.speakerId, segment.endTime > segment.startTime {
                    turns[id, default: []].append(Double(segment.startTime)...Double(segment.endTime))
                }
            }
            return result.speakerCentroidEmbeddings.keys.sorted().compactMap { (id: Int) -> VoiceCluster? in
                guard let centroid = result.speakerCentroidEmbeddings[id], let spoken = turns[id] else {
                    return nil
                }
                return VoiceCluster(turns: spoken, centroid: centroid)
            }
        } catch {
            throw TranscriptionError.diarizationFailed(reason: String(describing: error))
        }
    }

    private func loadedKit() async throws -> SpeakerKit {
        if let kit {
            return kit
        }
        let loaded: SpeakerKit = try await SpeakerKit(PyannoteConfig(
            downloadBase: modelsDirectory.path, download: true, load: true, verbose: false, logLevel: .error
        ))
        kit = loaded
        return loaded
    }
}

/// Kayıt dosyasını 16 kHz mono örneklere çevirir.
public func loadMonoSamples(url: URL) throws -> [Float] {
    do {
        return try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
    } catch {
        throw StorageError.readFailed(path: url.path, reason: String(describing: error))
    }
}

/// Kayıtlı seslerin dosyası: kullanıcı verisinin altında `Voices.json` (yalnızca sayılar; ses saklanmaz; bkz.
/// `AppPaths.userDataDirectory`).
public func voicesFileURL() throws -> URL {
    try AppPaths.userDataDirectory().appending(path: "Voices.json")
}

/// Kayıtlı sesleri okur; dosya henüz yoksa boş.
public func loadRegisteredVoices(url: URL) throws -> [RegisteredVoice] {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return []
    }
    do {
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RegisteredVoice].self, from: Data(contentsOf: url))
    } catch {
        throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
    }
}

/// Kayıtlı sesleri atomik olarak yazar.
public func saveRegisteredVoices(voices: [RegisteredVoice], url: URL) throws {
    do {
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(voices).write(to: url, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: url.path, reason: error.localizedDescription)
    }
}
