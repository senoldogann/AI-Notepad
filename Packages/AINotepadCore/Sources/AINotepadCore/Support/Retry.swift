import Foundation

/// İşlemi en fazla `attempts` kez dener; denemeler arasında bekleme her seferinde iki katına çıkar
/// (`delaySec`, `2×delaySec`, …). Her başarısız denemede `onFailure` çağrılır; son deneme de
/// başarısızsa son hata fırlatılır. Bekleme sırasında görev iptal edilirse `CancellationError` fırlar.
@MainActor
public func retryWithBackoff(
    attempts: Int,
    delaySec: Double,
    operation: () throws -> Void,
    onFailure: (Int, any Error) -> Void
) async throws {
    for attempt in 1...attempts {
        do {
            try operation()
            return
        } catch {
            onFailure(attempt, error)
            if attempt == attempts {
                throw error
            }
            try await Task.sleep(for: .seconds(delaySec * pow(2, Double(attempt - 1))))
        }
    }
}
