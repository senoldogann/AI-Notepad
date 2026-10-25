import AVFoundation
import Foundation

/// Test seslerini yüklerken oluşan hatalar.
enum FixtureError: Error {
    case notFound(name: String)
    case bufferCreationFailed(name: String)
    case unexpectedFormat(name: String, sampleRate: Double, channels: AVAudioChannelCount)
}

/// Model gerektiren testler yalnızca bu ortam değişkeni "1" ise çalışır.
let modelTestsEnabled: Bool = ProcessInfo.processInfo.environment["AINOTEPAD_MODEL_TESTS"] == "1"

/// `Fixtures/<name>.wav` dosyasını 16 kHz mono Float örnekler olarak yükler.
func loadFixture(name: String) throws -> [Float] {
    guard let url = Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures") else {
        throw FixtureError.notFound(name: name)
    }
    let file: AVAudioFile = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format: AVAudioFormat = file.processingFormat
    guard format.sampleRate == 16000, format.channelCount == 1 else {
        throw FixtureError.unexpectedFormat(name: name, sampleRate: format.sampleRate, channels: format.channelCount)
    }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw FixtureError.bufferCreationFailed(name: name)
    }
    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?[0] else {
        throw FixtureError.bufferCreationFailed(name: name)
    }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

/// Sabit tohumlu, belirli genlikte beyaz gürültü (16 kHz).
func whiteNoise(seconds: Double, amplitude: Float, seed: UInt64) -> [Float] {
    var state: UInt64 = seed
    return (0..<Int(seconds * 16000)).map { (_: Int) -> Float in
        // xorshift64: tekrarlanabilir sözde rastgele sayı
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        let unit: Float = Float(state % 1_000_000) / 1_000_000
        return (unit * 2 - 1) * amplitude
    }
}
