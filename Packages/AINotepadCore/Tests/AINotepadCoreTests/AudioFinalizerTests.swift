import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

@Suite struct AudioFinalizerTests {
    @Test func convertsCafToM4A() throws {
        let directory: URL = try temporaryDirectory()
        let caf: URL = directory.appending(path: "others.caf")
        let m4a: URL = directory.appending(path: "others.m4a")
        let recorder: CafRecorder = try CafRecorder(fileURL: caf)
        let samples: [Float] = try loadFixture(name: "fi-dialog")
        try recorder.append(samples: samples)
        recorder.close()

        try convertToM4A(source: caf, destination: m4a)

        let file: AVAudioFile = try AVAudioFile(forReading: m4a)
        let seconds: Double = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(seconds - Double(samples.count) / 16000) < 0.1, "süre: \(seconds)")
        #expect(file.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
        #expect(FileManager.default.fileExists(atPath: caf.path))
    }
}
