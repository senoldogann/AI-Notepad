import Foundation

/// İşlemi en fazla `attempts` kez dener; denemeler arasında bekleme her seferinde iki katına çıkar
/// (`delaySec`, `2×delaySec`, …). Her başarısız denemede `onFailure` çağrılır; son deneme de
/// başarısızsa son hata fırlatılır. Bekleme sırasında görev iptal edilirse `CancellationError` fırlar.
///
/// Çağıran kendi izolasyonunu açıkça verir (`#isolation`, `MainActor.shared` ya da `nil`); böylece
/// kapanışlar çağıranın durumuna güvenle erişir.
public func retryWithBackoff(
    attempts: Int,
    delaySec: Double,
    isolation: isolated (any Actor)?,
    operation: () async throws -> Void,
    onFailure: (Int, any Error) -> Void
) async throws {
    for attempt in 1...attempts {
        do {
            try await operation()
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
