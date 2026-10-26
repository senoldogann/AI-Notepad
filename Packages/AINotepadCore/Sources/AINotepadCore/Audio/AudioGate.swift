import Foundation
import Synchronization

/// Kayıt sırasında açılıp kapanan ses kapısı (duraklatma, mikrofonu kapatma). Thread-safe.
public final class AudioGate: Sendable {
    private let open: Mutex<Bool>

    public init(isOpen: Bool) {
        open = Mutex(isOpen)
    }

    public var isOpen: Bool {
        open.withLock { $0 }
    }

    public func set(isOpen value: Bool) {
        open.withLock { $0 = value }
    }
}

/// Kapı kapalıyken parçaları aynı uzunlukta sessizlikle değiştirir: kayıt ve yazıya dökme durur ama "Sen" ile
/// "Diğerleri"nin zaman çizgisi ve Deepgram bağlantısı bozulmaz.
public func gatedStream(audio: AsyncStream<[Float]>, gate: AudioGate) -> AsyncStream<[Float]> {
    let (gated, sink): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    let task: Task<Void, Never> = Task {
        for await chunk in audio {
            sink.yield(gate.isOpen ? chunk : [Float](repeating: 0, count: chunk.count))
        }
        sink.finish()
    }
    sink.onTermination = { (_: AsyncStream<[Float]>.Continuation.Termination) -> Void in
        task.cancel()
    }
    return gated
}

/// Parçanın ses seviyesi 0...1 (RMS, -60 dB sessizlik, 0 dB tam): panelde ses çubukları için. Saf fonksiyondur.
public func audioLevel(samples: [Float]) -> Float {
    guard !samples.isEmpty else {
        return 0
    }
    let rms: Float = (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    guard rms > 0 else {
        return 0
    }
    return min(1, max(0, (20 * log10(rms) + 60) / 60))
}

/// Akışı değiştirmeden geçirir, her parçanın seviyesini `onLevel`'a verir.
public func meteredStream(audio: AsyncStream<[Float]>, onLevel: @escaping @Sendable (Float) -> Void) -> AsyncStream<[Float]> {
    let (metered, sink): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    let task: Task<Void, Never> = Task {
        for await chunk in audio {
            onLevel(audioLevel(samples: chunk))
            sink.yield(chunk)
        }
        sink.finish()
    }
    sink.onTermination = { (_: AsyncStream<[Float]>.Continuation.Termination) -> Void in
        task.cancel()
    }
    return metered
}
