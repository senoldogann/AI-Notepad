import Foundation

/// Toplantı listesini yeniden okur ve art arda gelen istekleri birleştirir: okuma sürerken gelen istekler tek bir ek
/// okumaya dönüşür (iCloud bir eşitleme turunda çok sayıda değişiklik bildirir). Okuma sürerken uygulama bir toplantıyı
/// yazdıysa ya da sildiyse (`invalidate`) o okumanın sonucu eskimiş sayılır, uygulanmaz ve liste yeniden okunur. Okuma
/// diske ve iCloud'a bağlandığı için sınıftır; okumanın kendisi `load` ile verilir (uygulamada
/// `loadMeetingsInBackground`).
@MainActor
public final class MeetingReloader {
    /// Süren okuma döngüsü; yoksa nil.
    private var running: Task<Void, Never>?
    /// Döngü bittiğinde bir okuma daha gerekiyor.
    private var needsLoad: Bool = false
    /// Süren okumanın sonucu, okuma başladıktan sonraki yerel bir yazma yüzünden eskidi.
    private var isStale: Bool = false

    public init() {}

    /// Listeyi yeniden okur; sonuç `apply`'a, okuma hatası `fail`'e verilir. Okuma sürüyorsa bir ek okuma sıraya girer
    /// ve çağıran o okuma da bitince döner (ilk çağıranın `load`/`apply`/`fail`'i kullanılır; uygulamada hepsi aynıdır).
    public func reload(
        load: @escaping @MainActor () async throws -> MeetingLoadResult,
        apply: @escaping @MainActor (MeetingLoadResult) -> Void,
        fail: @escaping @MainActor (any Error) -> Void
    ) async {
        needsLoad = true
        if let running {
            await running.value
            return
        }
        let loop: Task<Void, Never> = Task { () async -> Void in
            await self.runLoads(load: load, apply: apply, fail: fail)
        }
        running = loop
        await loop.value
    }

    /// Bellekteki liste diske yazılarak değişti: süren okuma bu değişikliği görmemiş olabilir, sonucu uygulanmaz ve
    /// liste bir kez daha okunur. Okuma yoksa bir şey yapmaz.
    public func invalidate() {
        guard running != nil else {
            return
        }
        isStale = true
        needsLoad = true
    }

    private func runLoads(
        load: @escaping @MainActor () async throws -> MeetingLoadResult,
        apply: @escaping @MainActor (MeetingLoadResult) -> Void,
        fail: @escaping @MainActor (any Error) -> Void
    ) async {
        while needsLoad {
            needsLoad = false
            isStale = false
            do {
                let result: MeetingLoadResult = try await load()
                if !isStale {
                    apply(result)
                }
            } catch {
                fail(error)
            }
        }
        running = nil
    }
}
