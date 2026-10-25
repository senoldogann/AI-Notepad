import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

/// Testler için geçici, boş bir klasör.
func temporaryDirectory() throws -> URL {
    let url: URL = FileManager.default.temporaryDirectory.appending(path: "ainotepad-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct AudioFileTests {
    @Test func resamples48kStereoTo16kMono() throws {
        // Canlı akış gibi: 1 sn'lik ses 20 adet 50 ms'lik ardışık tampon halinde verilir.
        let format: AVAudioFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let resampler: AudioResampler = try AudioResampler(inputFormat: format)
        var counts: [Int] = []
        for chunk in 0..<20 {
            let buffer: AVAudioPCMBuffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400))
            buffer.frameLength = 2400
            for channel in 0..<2 {
                let data: UnsafeMutablePointer<Float> = try #require(buffer.floatChannelData?[channel])
                for index in 0..<2400 {
                    let position: Int = chunk * 2400 + index
                    data[index] = Float(0.3 * sin(2.0 * Double.pi * 440.0 * Double(position) / 48000.0))
                }
            }
            counts.append(try resampler.convert(buffer: buffer).count)
        }
        let total: Int = counts.reduce(0, +)
        // Dönüştürücü son bloğun bir kısmını bir sonraki çağrıya saklayabilir (en fazla ~80 ms).
        #expect(total <= 16000 && total >= 16000 - 1280, "toplam: \(total), parçalar: \(counts)")
    }

    @Test func recorderWritesReadableCaf() throws {
        let url: URL = try temporaryDirectory().appending(path: "me.caf")
        let recorder: CafRecorder = try CafRecorder(fileURL: url)
        try recorder.append(samples: tone(seconds: 1))
        recorder.close()

        let file: AVAudioFile = try AVAudioFile(forReading: url)
        #expect(file.length == 16000)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
    }

    @Test func cafReadableBeforeClose() throws {
        let url: URL = try temporaryDirectory().appending(path: "others.caf")
        let recorder: CafRecorder = try CafRecorder(fileURL: url)
        try recorder.append(samples: tone(seconds: 1))

        // Uygulama çökmüş gibi: yazıcı kapatılmadan dosya okunur.
        let file: AVAudioFile = try AVAudioFile(forReading: url)
        #expect(file.length >= 16000, "uzunluk: \(file.length)")
        recorder.close()
    }
}
