import AVFoundation
import Foundation

/// Dosya içe aktarılamadı.
public enum MediaImportError: Error, Equatable {
    case noAudioTrack(path: String)
    case readFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
}

/// Ses ya da video dosyasının (mp3, m4a, wav, aiff, mp4, mov…) ses izini 16 kHz mono AAC olarak `destination`'a yazar
/// (toplantı kaydıyla aynı biçim: son geçiş ve oynatıcı aynen kullanır). Süreyi (saniye) döndürür.
public func importMediaAudio(source: URL, destination: URL) async throws -> Double {
    let asset: AVURLAsset = AVURLAsset(url: source)
    let tracks: [AVAssetTrack]
    do {
        tracks = try await asset.loadTracks(withMediaType: .audio)
    } catch {
        throw MediaImportError.readFailed(path: source.path, reason: error.localizedDescription)
    }
    guard let track = tracks.first else {
        throw MediaImportError.noAudioTrack(path: source.path)
    }
    let reader: AVAssetReader
    do {
        reader = try AVAssetReader(asset: asset)
    } catch {
        throw MediaImportError.readFailed(path: source.path, reason: error.localizedDescription)
    }
    let output: AVAssetReaderTrackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ])
    reader.add(output)
    guard reader.startReading() else {
        throw MediaImportError.readFailed(path: source.path, reason: reader.error?.localizedDescription ?? "okuma başlamadı")
    }
    let file: AVAudioFile
    do {
        file = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    } catch {
        throw MediaImportError.writeFailed(path: destination.path, reason: error.localizedDescription)
    }
    // Sabit, geçerli biçim: oluşturma başarısız olamaz.
    let format: AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    var frames: Int = 0
    while let sample = output.copyNextSampleBuffer() {
        // Uzun dosyada iptal edilebilsin (ör. uygulama kapanırken).
        try Task.checkCancellation()
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            throw MediaImportError.readFailed(path: source.path, reason: "ses parçasında veri yok (\(frames) örnekten sonra)")
        }
        let count: Int = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        guard count > 0 else {
            continue
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let channel = buffer.floatChannelData?[0] else {
            throw MediaImportError.readFailed(path: source.path, reason: "ses arabelleği ayrılamadı (\(count) örnek)")
        }
        let status: OSStatus = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: channel)
        guard status == kCMBlockBufferNoErr else {
            throw MediaImportError.readFailed(path: source.path, reason: "ses verisi kopyalanamadı (\(status))")
        }
        buffer.frameLength = AVAudioFrameCount(count)
        do {
            try file.write(from: buffer)
        } catch {
            throw MediaImportError.writeFailed(path: destination.path, reason: error.localizedDescription)
        }
        frames += count
    }
    if reader.status == .failed {
        throw MediaImportError.readFailed(path: source.path, reason: reader.error?.localizedDescription ?? "okuma yarıda kaldı")
    }
    guard frames > 0 else {
        throw MediaImportError.noAudioTrack(path: source.path)
    }
    return Double(frames) / 16000
}

/// İçe aktarılan dosyanın toplantı kaydı: başlık dosya adı, süre sesinki, durum işleniyor (son geçiş ve not yazılacak).
/// Saf fonksiyondur.
public func importedMeetingRecord(id: String, source: URL, startedAt: Date, durationSec: Double, engine: RecordingEngine, template: NoteTemplate) -> MeetingRecord {
    MeetingRecord(
        id: id, title: source.deletingPathExtension().lastPathComponent, startedAt: startedAt,
        endedAt: startedAt.addingTimeInterval(durationSec), language: nil, status: .processing, failureMessage: nil,
        liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false,
        engine: engine, notice: nil, meNeedsFinalPass: nil
    )
    .with(template: template)
}
