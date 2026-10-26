import AVFoundation
import Foundation

/// Kaydı (ör. `.caf`) 16 kHz mono AAC `.m4a`'ya dönüştürür (32 kbps; saatte ~15 MB). Kaynağı silmez.
public func convertToM4A(source: URL, destination: URL) throws {
    let input: AVAudioFile
    do {
        input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
    } catch {
        throw AudioCaptureError.recorderFailed(path: source.path, reason: "okunamadı: \(error)")
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32000,
    ]
    let output: AVAudioFile
    do {
        output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    } catch {
        throw AudioCaptureError.recorderFailed(path: destination.path, reason: "yazılamadı: \(error)")
    }
    let chunk: AVAudioFrameCount = 16000 * 10
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else {
        throw AudioCaptureError.recorderFailed(path: source.path, reason: "tampon oluşturulamadı")
    }
    do {
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunk)
            try output.write(from: buffer)
        }
    } catch {
        throw AudioCaptureError.recorderFailed(path: destination.path, reason: "dönüştürülemedi: \(error)")
    }
    // Kapatınca AAC paket tablosu ve süre yazılır.
    output.close()
}
