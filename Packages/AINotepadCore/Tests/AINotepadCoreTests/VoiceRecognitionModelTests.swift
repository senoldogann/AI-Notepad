import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

/// macOS'un Fince seslerinden ilk ikisi (`say -v '?'`).
private func finnishVoices() throws -> [String] {
    let process: Process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-v", "?"]
    let output: Pipe = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    let text: String = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return text.split(separator: "\n").compactMap { (line: Substring) -> String? in
        guard let range = line.range(of: #" +fi_FI "#, options: .regularExpression) else {
            return nil
        }
        return String(line[..<range.lowerBound])
    }
}

/// Metni verilen sesle okutur, 16 kHz mono örnekler döndürür.
private func spoken(voice: String, text: String, directory: URL) throws -> [Float] {
    let aiff: URL = directory.appending(path: "\(UUID().uuidString).aiff")
    let wav: URL = aiff.deletingPathExtension().appendingPathExtension("wav")
    for (tool, arguments) in [("/usr/bin/say", ["-v", voice, "-o", aiff.path, text]), ("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@16000", "-c", "1", aiff.path, wav.path])] {
        let process: Process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
    let file: AVAudioFile = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer: AVAudioPCMBuffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
}

/// Sırayla konuşan kişilerden toplantı sesi ve kişili bölümler.
private func meeting(turns: [(person: Int, voice: String, text: String)], directory: URL) throws -> (samples: [Float], segments: [StoredSegment]) {
    var samples: [Float] = []
    var segments: [StoredSegment] = []
    for (index, turn) in turns.enumerated() {
        let start: Double = Double(samples.count) / 16000
        samples += try spoken(voice: turn.voice, text: turn.text, directory: directory)
        segments.append(StoredSegment(key: "final-\(index)", speaker: .others, person: turn.person, startSec: start, endSec: Double(samples.count) / 16000, text: turn.text, words: nil))
        samples += [Float](repeating: 0, count: 8000)
    }
    return (samples, segments)
}

@Suite(.enabled(if: modelTestsEnabled)) struct VoiceRecognitionModelTests {
    // Gerçek SpeakerKit: ilk toplantıda adı verilen kişi, ikinci toplantıda (başka cümleler, başka sıra) sesinden
    // tanınır; adı verilmemiş kişiye ad verilmez.
    @Test func namedVoiceIsRecognizedInNextMeeting() async throws {
        let voices: [String] = try finnishVoices()
        try #require(voices.count >= 2, "En az iki Fince ses gerekli")
        let directory: URL = try temporaryDirectory()
        let lines: [String] = [
            "Hyvää huomenta kaikille. Käydään ensin läpi viime viikon raportti ja sen jälkeen budjetti.",
            "Kiitos. Raportti on lähes valmis, mutta tarvitsen vielä luvut myyntitiimiltä ennen perjantaita.",
            "Selvä. Sovitaan, että luvut toimitetaan keskiviikkoon mennessä ja esitys pidetään maanantaina.",
            "Hyvä, minä varaan kokoushuoneen ja lähetän kutsun koko tiimille vielä tänään iltapäivällä.",
        ]
        let first = try meeting(turns: (0..<10).map { (index: Int) in (person: index % 2 + 1, voice: voices[index % 2], text: lines[index % 4]) }, directory: directory)
        let embedder: SpeakerKitVoiceEmbedder = SpeakerKitVoiceEmbedder(modelsDirectory: try AppPaths.modelsDirectory())
        let firstVoices: [Int: Voiceprint] = try await meetingVoiceprints(samples: first.samples, segments: first.segments, embedder: embedder, windowSec: 120)
        #expect(Set(firstVoices.keys) == [1, 2])
        let registry: [RegisteredVoice] = registering(voices: [], name: "Aino", voiceprint: try #require(firstVoices[1]), now: Date())

        // İkinci toplantı: sıra ters, kişi numaraları farklı.
        let second = try meeting(turns: (0..<10).map { (index: Int) in (person: index % 2 == 0 ? 1 : 2, voice: voices[index % 2 == 0 ? 1 : 0], text: lines[(index + 1) % 4]) }, directory: directory)
        let secondVoices: [Int: Voiceprint] = try await meetingVoiceprints(samples: second.samples, segments: second.segments, embedder: embedder, windowSec: 120)
        #expect(recognizedNames(voiceprints: secondVoices, registry: registry) == [2: "Aino"])
    }
}
