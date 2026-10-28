import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

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

/// Gerçek modelle çalışan tüm test grupları bunun altında ve sırayla çalışır:
/// model bellekte bir kez tutulur ve motora aynı anda iki çağrı gitmez.
@Suite(.enabled(if: modelTestsEnabled), .serialized)
struct ModelTests {}

/// Model testlerinin paylaştığı motor; ilk kullanımda bir kez yüklenir.
let sharedTestEngine: Task<WhisperKitEngine, any Error> = Task {
    try await WhisperKitEngine.load(modelName: liveWhisperModel, modelsDirectory: testModelsDirectory())
}

/// Model testlerinin modelleri: geliştirici sürümünün model klasörü (`~/Library/Application Support/AINotepad/Models`;
/// test paketinin Info.plist'inde veri klasörü adı olmadığı için `AppPaths` kullanılmaz). Klasör yoksa oluşturulur.
func testModelsDirectory() throws -> URL {
    let base: URL = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let models: URL = base.appending(path: "AINotepad", directoryHint: .isDirectory).appending(path: "Models", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    return models
}
