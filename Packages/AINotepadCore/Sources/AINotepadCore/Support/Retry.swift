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

/// Mesaj gönderiminde (POST) yeniden denemenin güvenli olduğu ağ hataları: istek sunucuya hiç ulaşmadı. Zaman aşımı ya
/// da bağlantının yarıda kopması sayılmaz: sunucu mesajı almış olabilir, yeniden deneme aynı notu iki kez gönderir.
/// Saf fonksiyondur.
public func isSafeToRetryPost(code: URLError.Code) -> Bool {
    [.cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed].contains(code)
}

/// Gönderimin sonucu bilinmiyor: istek sunucuya ulaşmış olabilir (zaman aşımı, bağlantı yarıda koptu, 5xx). Yeniden
/// göndermek aynı içeriği iki kez oluşturabilir: kendiliğinden yeniden denenmez, kullanıcıya gösterilir.
public struct DeliveryUncertainError: Error, Equatable {
    public let host: String
    public let reason: String

    public init(host: String, reason: String) {
        self.host = host
        self.reason = reason
    }
}

/// HTTP yanıtı kalıcı ret mi (yeniden denemenin anlamı yok: geçersiz anahtar, bozuk istek). 408 (zaman aşımı) ve 429
/// (hız sınırı) geçicidir; beklenip yeniden denenir. Saf fonksiyondur.
public func isPermanentHTTPRejection(status: Int) -> Bool {
    (400..<500).contains(status) && status != 408 && status != 429
}
