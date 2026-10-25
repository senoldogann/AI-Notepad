import AVFoundation
import CoreAudio
import Foundation
import os

/// Sistemde çalan tüm sesi (Zoom, Teams vb.) Core Audio process tap ile yakalar ("Diğerleri" akışı).
///
/// Akış: global tap → tap'i ve varsayılan çıkış cihazını içeren özel toplu (aggregate) cihaz → IO bloğu.
/// Ekran kaydı izni gerekmez; ilk kullanımda macOS "sistem sesi kaydı" izni sorar.
/// Varsayılan çıkış cihazı değişirse (ör. AirPods) toplu cihaz yeni çıkışla yeniden kurulur.
@MainActor
public final class SystemAudioCapture {
    private nonisolated static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "SystemAudioCapture")

    private let ioQueue: DispatchQueue = DispatchQueue(label: "com.senoldogan.AINotepad.system-audio", qos: .userInteractive)
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var tapUID: String = ""
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var outputListener: AudioObjectPropertyListenerBlock?

    public init() {}

    /// Tap'i oluşturur, yakalamayı başlatır ve ses parçalarının akışını döndürür.
    public func start() async throws -> AsyncStream<[Float]> {
        let description: CATapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var newTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        try check(status: AudioHardwareCreateProcessTap(description, &newTapID), operation: "AudioHardwareCreateProcessTap")
        tapID = newTapID
        tapUID = description.uuid.uuidString

        let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        do {
            try startDevice(continuation: continuation)
            try addOutputListener()
        } catch {
            stop()
            throw error
        }
        return stream
    }

    /// Yakalamayı durdurur, Core Audio nesnelerini siler ve akışı bitirir.
    public func stop() {
        removeOutputListener()
        stopDevice()
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            let status: OSStatus = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr {
                Self.logger.error("Tap silinemedi, durum: \(status, privacy: .public)")
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        continuation?.finish()
        continuation = nil
    }

    /// Toplu cihazı varsayılan çıkışla kurar ve IO bloğunu başlatır.
    private func startDevice(continuation: AsyncStream<[Float]>.Continuation) throws {
        let outputUID: String = try deviceUID(deviceID: defaultOutputDeviceID())
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AI-Notepad Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        var newAggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        try check(
            status: AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregateID),
            operation: "AudioHardwareCreateAggregateDevice"
        )
        aggregateID = newAggregateID

        var streamDescription: AudioStreamBasicDescription = try tapFormat(tapID: tapID)
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw AudioCaptureError.converterCreationFailed(inputDescription: String(describing: streamDescription))
        }
        let resampler: AudioResampler = try AudioResampler(inputFormat: format)
        var newProcID: AudioDeviceIOProcID?
        try check(
            status: AudioDeviceCreateIOProcIDWithBlock(
                &newProcID,
                aggregateID,
                ioQueue,
                Self.makeIOBlock(format: format, resampler: resampler, continuation: continuation)
            ),
            operation: "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = newProcID
        try check(status: AudioDeviceStart(aggregateID, ioProcID), operation: "AudioDeviceStart")
        Self.logger.info("Sistem sesi yakalama başladı, çıkış: \(outputUID, privacy: .public)")
    }

    /// IO bloğunu ve toplu cihazı siler (tap kalır).
    private func stopDevice() {
        guard aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            return
        }
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        let status: OSStatus = AudioHardwareDestroyAggregateDevice(aggregateID)
        if status != noErr {
            Self.logger.error("Toplu cihaz silinemedi, durum: \(status, privacy: .public)")
        }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Varsayılan çıkış cihazı değişince toplu cihazı yeniden kurar.
    private func addOutputListener() throws {
        var address: AudioObjectPropertyAddress = defaultOutputAddress()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] (_: UInt32, _: UnsafePointer<AudioObjectPropertyAddress>) -> Void in
            Task { @MainActor in
                self?.restartAfterOutputChange()
            }
        }
        try check(
            status: AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, ioQueue, listener),
            operation: "AudioObjectAddPropertyListenerBlock"
        )
        outputListener = listener
    }

    private func removeOutputListener() {
        guard let listener = outputListener else {
            return
        }
        var address: AudioObjectPropertyAddress = defaultOutputAddress()
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, ioQueue, listener)
        outputListener = nil
    }

    private func restartAfterOutputChange() {
        guard let continuation else {
            return
        }
        stopDevice()
        do {
            try startDevice(continuation: continuation)
        } catch {
            Self.logger.error("Çıkış cihazı değişince sistem sesi yeniden başlatılamadı: \(String(describing: error), privacy: .public)")
            stop()
        }
    }

    /// IO thread'inde çalışan blok. Ana aktöre bağlı olmaması için `nonisolated` üretilir.
    private nonisolated static func makeIOBlock(
        format: AVAudioFormat,
        resampler: AudioResampler,
        continuation: AsyncStream<[Float]>.Continuation
    ) -> AudioDeviceIOBlock {
        { (_: UnsafePointer<AudioTimeStamp>, inputData: UnsafePointer<AudioBufferList>, _: UnsafePointer<AudioTimeStamp>, _: UnsafeMutablePointer<AudioBufferList>, _: UnsafePointer<AudioTimeStamp>) -> Void in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else {
                logger.error("Sistem sesi tamponu oluşturulamadı")
                return
            }
            do {
                let samples: [Float] = try resampler.convert(buffer: buffer)
                if !samples.isEmpty {
                    continuation.yield(samples)
                }
            } catch {
                logger.error("Sistem sesi dönüştürülemedi: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// `noErr` dışındaki Core Audio durumunu hataya çevirir.
private func check(status: OSStatus, operation: String) throws {
    guard status == noErr else {
        throw AudioCaptureError.coreAudio(operation: operation, status: status)
    }
}

private func defaultOutputAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

/// Sistemin varsayılan çıkış cihazı.
private func defaultOutputDeviceID() throws -> AudioObjectID {
    var address: AudioObjectPropertyAddress = defaultOutputAddress()
    var deviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    var size: UInt32 = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(
        status: AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
        operation: "DefaultOutputDevice"
    )
    return deviceID
}

/// Bir ses cihazının kalıcı UID'si.
private func deviceUID(deviceID: AudioObjectID) throws -> String {
    var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>?
    var size: UInt32 = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(status: AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid), operation: "DeviceUID")
    guard let value = uid?.takeRetainedValue() else {
        throw AudioCaptureError.coreAudio(operation: "DeviceUID boş", status: 0)
    }
    return value as String
}

/// Tap'in ürettiği sesin formatı.
private func tapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
    var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var description: AudioStreamBasicDescription = AudioStreamBasicDescription()
    var size: UInt32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(status: AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description), operation: "TapFormat")
    return description
}
