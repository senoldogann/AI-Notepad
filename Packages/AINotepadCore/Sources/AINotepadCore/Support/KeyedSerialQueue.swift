import Foundation
import os

private let serialQueueLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "KeyedSerialQueue")

/// Aynı anahtarlı işlemleri sırayla yürütür (farklı anahtarlar paralel kalır): ör. aynı MCP bağlantısına iki gönderim
/// aynı yenileme jetonunu iki kez kullanmasın. Bir işlemin hatası sıradakini durdurmaz; çağırana iletilir.
actor KeyedSerialQueue {
    private var tails: [String: Task<Void, Never>] = [:]

    func run<Value: Sendable>(key: String, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let previous: Task<Void, Never>? = tails[key]
        let task: Task<Value, any Error> = Task {
            await previous?.value
            return try await operation()
        }
        // Sıra yalnızca bitişi bekler; hata çağırana aşağıda iletilir.
        tails[key] = Task {
            do {
                _ = try await task.value
            } catch {
                serialQueueLogger.debug("Sıradaki işlem hatayla bitti, anahtar: \(key, privacy: .private)")
            }
        }
        return try await task.value
    }
}
