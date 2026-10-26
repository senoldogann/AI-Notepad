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
