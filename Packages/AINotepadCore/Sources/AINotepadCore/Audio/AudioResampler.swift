import AVFoundation
import Foundation

/// Herhangi bir PCM formatını 16 kHz mono Float32'ye dönüştürür.
///
/// Parçalı gelen bir akış için tek bir örnek kullanılmalıdır: dönüştürücü filtre durumunu
/// çağrılar arasında korur. Thread-safe değildir; yalnızca tek bir ses geri çağrısından kullanılır.
public final class AudioResampler {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    public init(inputFormat: AVAudioFormat) throws {
        guard
            let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: output)
        else {
            throw AudioCaptureError.converterCreationFailed(inputDescription: inputFormat.description)
        }
        // Çok kanallı girişte kanalların ortalaması alınır (yalnızca ilk kanal değil).
        converter.downmix = true
        // Canlı akışta başlangıç gecikmesi istenmez: dönüştürücü filtre için örnek biriktirmez.
        converter.primeMethod = .none
        self.converter = converter
        self.outputFormat = output
    }

    /// Tamponu dönüştürür ve 16 kHz mono örnekleri döndürür.
    public func convert(buffer: AVAudioPCMBuffer) throws -> [Float] {
        let ratio: Double = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity: AVAudioFrameCount = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioCaptureError.conversionFailed(reason: "çıkış tamponu oluşturulamadı (kapasite \(capacity))")
        }

        var supplied: Bool = false
        var conversionError: NSError?
        let status: AVAudioConverterOutputStatus = converter.convert(to: output, error: &conversionError) { (_: AVAudioPacketCount, inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? in
            // Tampon bir kez verilir; sonra "şimdilik veri yok" denir ki dönüştürücü akışı kapatmasın.
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw AudioCaptureError.conversionFailed(reason: conversionError.map { String(describing: $0) } ?? "bilinmeyen hata")
        }
        guard let channel = output.floatChannelData?[0] else {
            throw AudioCaptureError.conversionFailed(reason: "çıkış tamponunda kanal verisi yok")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
