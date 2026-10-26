import Foundation
import Synchronization

/// Bir devamı yalnızca bir kez sürdürür (yarışan iki görevden ilki kazanır).
private final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Bool, Never>?> = Mutex(nil)

    func store(_ value: CheckedContinuation<Bool, Never>) {
        continuation.withLock { $0 = value }
    }

    func resume(returning value: Bool) {
        let pending: CheckedContinuation<Bool, Never>? = continuation.withLock { (stored: inout CheckedContinuation<Bool, Never>?) -> CheckedContinuation<Bool, Never>? in
            defer { stored = nil }
            return stored
        }
        pending?.resume(returning: value)
    }
}

/// İşi en fazla `seconds` bekler: iş önce biterse true, süre önce dolarsa false. İptale yanıt vermeyen işler
/// (ör. `Task.value`) için: süre dolunca beklemeyi bırakır, iş arka planda sürebilir.
public func finishesWithin(seconds: Double, work: @escaping @Sendable () async -> Void) async -> Bool {
    let once: ResumeOnce = ResumeOnce()
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) -> Void in
        once.store(continuation)
        Task {
            await work()
            once.resume(returning: true)
        }
        Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                // Bu zamanlayıcı iptal edilmez; iptal gelirse süre dolmuş sayılır.
            }
            once.resume(returning: false)
        }
    }
}
