import AVFoundation
import Foundation
import os

/// Mikrofonu 16 kHz mono Float parçalar halinde yakalar ("Sen" akışı).
///
/// Giriş cihazı değişirse (ör. AirPods bağlanınca) motor yeni formatla yeniden kurulur;
/// kurulamazsa akış bitirilir ve hata loglanır.
@MainActor
public final class MicrophoneCapture {
    private nonisolated static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "MicrophoneCapture")

    private let engine: AVAudioEngine = AVAudioEngine()
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var configurationObserver: (any NSObjectProtocol)?

    public init() {}

    /// İzni ister, yakalamayı başlatır ve ses parçalarının akışını döndürür.
    public func start() async throws -> AsyncStream<[Float]> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw AudioCaptureError.microphonePermissionDenied
        }
        let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        do {
            try startEngine(continuation: continuation)
        } catch {
            continuation.finish()
            self.continuation = nil
            throw error
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.restartAfterConfigurationChange()
            }
        }
        return stream
    }

    /// Yakalamayı durdurur ve akışı bitirir.
    public func stop() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        configurationObserver = nil
        stopEngine()
        continuation?.finish()
        continuation = nil
    }

    /// Giriş formatına göre tap kurar ve motoru başlatır.
    private func startEngine(continuation: AsyncStream<[Float]>.Continuation) throws {
        let input: AVAudioInputNode = engine.inputNode
        let format: AVAudioFormat = input.outputFormat(forBus: 0)
        let resampler: AudioResampler = try AudioResampler(inputFormat: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.makeTapBlock(resampler: resampler, continuation: continuation))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.coreAudio(operation: "AVAudioEngine.start", status: Int32((error as NSError).code))
        }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Cihaz değişince motoru yeni formatla yeniden kurar.
    private func restartAfterConfigurationChange() {
        guard let continuation else {
            return
        }
        stopEngine()
        do {
            try startEngine(continuation: continuation)
            Self.logger.info("Mikrofon yeni giriş cihazıyla yeniden başlatıldı")
        } catch {
            Self.logger.error("Mikrofon yeniden başlatılamadı: \(String(describing: error), privacy: .public)")
            stop()
        }
    }

    /// Ses thread'inde çalışan tap bloğu. Ana aktöre bağlı olmaması için `nonisolated` üretilir.
    private nonisolated static func makeTapBlock(
        resampler: AudioResampler,
        continuation: AsyncStream<[Float]>.Continuation
    ) -> AVAudioNodeTapBlock {
        { (buffer: AVAudioPCMBuffer, _: AVAudioTime) -> Void in
            do {
                let samples: [Float] = try resampler.convert(buffer: buffer)
                if !samples.isEmpty {
                    continuation.yield(samples)
                }
            } catch {
                logger.error("Mikrofon sesi dönüştürülemedi: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
