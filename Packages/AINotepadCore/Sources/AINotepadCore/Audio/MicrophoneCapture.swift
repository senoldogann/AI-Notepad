import AVFoundation
import Foundation
import os
#if os(iOS)
import UIKit
#endif

/// Mikrofonu 16 kHz mono Float parçalar halinde yakalar ("Sen" akışı).
///
/// Giriş cihazı değişirse (ör. AirPods bağlanınca) motor yeni formatla, geri çekilmeli denemelerle
/// yeniden kurulur; kurulamazsa akış bitirilir ve hata loglanır. iOS'ta önce kayıt için ses oturumu açılır; telefon
/// çağrısı gibi bir kesinti bitince motor aynı yolla yeniden kurulur.
@MainActor
public final class MicrophoneCapture {
    private nonisolated static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "MicrophoneCapture")

    private let engine: AVAudioEngine = AVAudioEngine()
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var configurationObserver: (any NSObjectProtocol)?
    /// iOS: ses oturumu kesintisi (telefon çağrısı, alarm) bitince yeniden kurma.
    private var interruptionObserver: (any NSObjectProtocol)?
    /// iOS: uygulama öne gelince kesinti sürüyorsa yeniden kurma (VoIP uygulamaları kesinti bitişini her zaman bildirmez).
    private var activationObserver: (any NSObjectProtocol)?
    /// Her yeniden kurma isteğinde artar; eski denemeler yenisi gelince vazgeçer.
    private var restartGeneration: Int = 0
    /// Ses oturumu kesildi (telefon çağrısı, alarm): mikrofon ses vermiyor, arayüz bunu gösterir.
    public private(set) var isInterrupted: Bool = false
    /// Kesinti başlayınca ve bitince çağrılır (iPhone kayıt ekranı "Mikrofon kesildi" gösterir).
    public var onInterruptionChange: (@MainActor (Bool) -> Void)?

    public init() {}

    /// İzni ister, yakalamayı başlatır ve ses parçalarının akışını döndürür.
    public func start() async throws -> AsyncStream<[Float]> {
        guard continuation == nil else {
            throw AudioCaptureError.alreadyRunning(source: "MicrophoneCapture")
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw AudioCaptureError.microphonePermissionDenied
        }
        let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        #if os(iOS)
        var sessionActivated: Bool = false
        #endif
        do {
            #if os(iOS)
            try activateRecordingSession()
            sessionActivated = true
            #endif
            try startEngine(continuation: continuation)
        } catch {
            continuation.finish()
            self.continuation = nil
            #if os(iOS)
            // Açılan oturum bırakılır: yoksa diğer uygulamaların sesi (müzik) kesik kalırdı.
            if sessionActivated {
                deactivateRecordingSession()
            }
            #endif
            throw error
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] (_: Notification) -> Void in
            Task { @MainActor in
                await self?.handleConfigurationChange()
            }
        }
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] (notification: Notification) -> Void in
            let rawType: UInt? = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type: AVAudioSession.InterruptionType? = rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in
                switch type {
                case .began:
                    self?.setInterrupted(true)
                case .ended:
                    await self?.resumeAfterInterruption()
                default:
                    return
                }
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] (_: Notification) -> Void in
            Task { @MainActor in
                guard self?.isInterrupted == true else {
                    return
                }
                await self?.resumeAfterInterruption()
            }
        }
        #endif
        return stream
    }

    /// Yakalamayı durdurur ve akışı bitirir.
    public func stop() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        configurationObserver = nil
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        interruptionObserver = nil
        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        activationObserver = nil
        #if os(iOS)
        // Kesinti sürerken durdurulduysa dinleyen de öğrenir: yoksa "Mikrofon kesildi" sonraki kayıtta da kalırdı.
        setInterrupted(false)
        let wasRunning: Bool = continuation != nil
        #else
        isInterrupted = false
        #endif
        stopEngine()
        continuation?.finish()
        continuation = nil
        #if os(iOS)
        if wasRunning {
            deactivateRecordingSession()
        }
        #endif
    }

    #if os(iOS)
    private func setInterrupted(_ interrupted: Bool) {
        guard isInterrupted != interrupted else {
            return
        }
        isInterrupted = interrupted
        Self.logger.info("Ses oturumu kesintisi, sürüyor: \(interrupted, privacy: .public)")
        onInterruptionChange?(interrupted)
    }

    /// Kesinti bitti: ses oturumu yeniden etkinleştirilir (kesinti onu kapatır) ve motor yeniden kurulur.
    private func resumeAfterInterruption() async {
        guard continuation != nil else {
            return
        }
        do {
            try activateRecordingSession()
        } catch {
            Self.logger.error("Kesinti sonrası ses oturumu açılamadı, hata: \(String(describing: error), privacy: .private)")
            return
        }
        await restartAfterConfigurationChange()
        setInterrupted(false)
    }

    /// Kayıt için ses oturumu: odadaki konuşmayı yerleşik mikrofonla alır; kayıt arka planda ve ekran kilitliyken sürer
    /// (Info.plist'te `audio` arka plan modu). Bluetooth kulaklık yalnızca çalma için (A2DP) kullanılır; kulaklık
    /// mikrofonu (HFP) sesi 16 kHz dar banda düşürdüğü için seçilmez.
    private func activateRecordingSession() throws {
        let session: AVAudioSession = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            throw AudioCaptureError.microphoneStartFailed(code: Int32((error as NSError).code))
        }
    }

    /// Kayıt bitince oturum bırakılır; diğer uygulamaların sesi (müzik) kaldığı yerden sürer.
    private func deactivateRecordingSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.logger.error("Ses oturumu kapatılamadı, hata: \(String(describing: error), privacy: .private)")
        }
    }
    #endif

    /// Giriş formatına göre tap kurar ve motoru başlatır.
    private func startEngine(continuation: AsyncStream<[Float]>.Continuation) throws {
        let input: AVAudioInputNode = engine.inputNode
        let format: AVAudioFormat = input.outputFormat(forBus: 0)
        let resampler: AudioResampler = try AudioResampler(inputFormat: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.makeTapBlock(resampler: resampler, continuation: continuation, throttle: LogThrottle(intervalSec: 60)))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.microphoneStartFailed(code: Int32((error as NSError).code))
        }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Cihaz değişti: kesinti sürerken (telefon çağrısı) yeniden kurulmaz, denemeler tükenip akış bitmesin; kesinti
    /// bitince `resumeAfterInterruption` motoru yeniden kurar.
    private func handleConfigurationChange() async {
        guard !isInterrupted else {
            Self.logger.info("Kesinti sürerken cihaz değişti; yeniden kurma kesinti bitince yapılacak")
            return
        }
        await restartAfterConfigurationChange()
    }

    /// Cihaz değişince motoru yeni formatla yeniden kurar; yeni cihaz henüz hazır olmayabileceği
    /// için birkaç kez dener. Daha yeni bir istek gelirse ya da yakalama durdurulursa çekilir.
    private func restartAfterConfigurationChange() async {
        guard continuation != nil else {
            return
        }
        restartGeneration += 1
        let generation: Int = restartGeneration
        do {
            try await retryWithBackoff(
                attempts: 4,
                delaySec: 0.25,
                isolation: #isolation,
                operation: {
                    guard generation == self.restartGeneration, let continuation = self.continuation else {
                        return
                    }
                    self.stopEngine()
                    try self.startEngine(continuation: continuation)
                },
                onFailure: { (attempt: Int, error: any Error) -> Void in
                    Self.logger.warning("Mikrofon yeniden başlatılamadı, deneme \(attempt, privacy: .public): \(String(describing: error), privacy: .private)")
                }
            )
            Self.logger.info("Mikrofon yeni giriş cihazıyla yeniden başlatıldı")
        } catch {
            guard generation == restartGeneration else {
                return
            }
            Self.logger.error("Mikrofon yeniden başlatılamadı, akış bitiriliyor: \(String(describing: error), privacy: .private)")
            stop()
        }
    }

    /// Ses thread'inde çalışan tap bloğu. Ana aktöre bağlı olmaması için `nonisolated` üretilir.
    private nonisolated static func makeTapBlock(
        resampler: AudioResampler,
        continuation: AsyncStream<[Float]>.Continuation,
        throttle: LogThrottle
    ) -> AVAudioNodeTapBlock {
        { (buffer: AVAudioPCMBuffer, _: AVAudioTime) -> Void in
            do {
                let samples: [Float] = try resampler.convert(buffer: buffer)
                if !samples.isEmpty {
                    continuation.yield(samples)
                }
            } catch {
                // Her tamponda tekrarlanır: dakikada bir loglanır.
                if throttle.allow() {
                    logger.error("Mikrofon sesi dönüştürülemedi, hata: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }
}
