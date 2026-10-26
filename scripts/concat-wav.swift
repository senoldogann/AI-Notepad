// WAV dosyalarını sırayla okuyup tek bir WAV'a yazar (hepsi aynı formatta olmalı).
// Kullanım: swift scripts/concat-wav.swift <çıkış.wav> <giriş1.wav> <giriş2.wav> ...
import AVFoundation

let arguments: [String] = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    FileHandle.standardError.write("Kullanım: concat-wav.swift <çıkış> <girişler...>\n".data(using: .utf8)!)
    exit(1)
}
let inputs: [AVAudioFile] = try arguments.dropFirst().map { (path: String) -> AVAudioFile in
    try AVAudioFile(forReading: URL(fileURLWithPath: path))
}
let output: AVAudioFile = try AVAudioFile(
    forWriting: URL(fileURLWithPath: arguments[0]),
    settings: inputs[0].fileFormat.settings,
    commonFormat: .pcmFormatFloat32,
    interleaved: false
)
for input in inputs {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)) else {
        FileHandle.standardError.write("Tampon oluşturulamadı: \(input.url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    try input.read(into: buffer)
    try output.write(from: buffer)
}
// Kapatınca WAV başlığındaki veri boyutu yazılır.
output.close()
