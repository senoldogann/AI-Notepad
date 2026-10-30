import AINotepadCore
import AppKit
import Foundation
import os

private let telemetryLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedTelemetry")

/// Bekleyen olayların UserDefaults anahtarı (uygulama kapanınca da kalsın; sonraki açılışta gönderilir).
private let pendingEventsKey: String = "telemetry.pendingEvents"
/// Özellik kullanımı durumunun anahtarı (bugün ve gönderilmeyi bekleyen gün).
private let featureStateKey: String = "telemetry.featureState"
/// Düzenli gönderim aralığı.
private let flushIntervalSec: Double = 15 * 60

/// Abonelik sürümünün istemci telemetrisi: güvenilirlik ve süre olayları ile günlük özellik kullanımı UserDefaults'ta
/// birikir, açılışta, uygulama arka plana geçince ve 15 dakikada bir sunucuya gönderilir. Kayıt ve arayüzü hiç
/// beklemez; gönderim başarısız olursa (istemci üç kez dener) yapılandırılmış uyarı loglanır ve veri düşer (telemetri
/// kritik değildir). "Anonim kullanım istatistiklerini paylaş" kapalıyken hiçbir şey kaydedilmez ve gönderilmez;
/// kapatılınca bekleyenler silinir. Sürüm ve yapay zekâ amacı başlıkları bundan bağımsızdır (hizmetin işleyişi).
@MainActor
final class HostedTelemetryCenter {
    static let shared: HostedTelemetryCenter = HostedTelemetryCenter()

    private var isFlushing: Bool = false
    private var timer: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []

    private init() {}

    /// Kayıt ve gönderim izni: abonelik sürümü ve kullanıcının paylaşım seçimi.
    private var isAllowed: Bool {
        telemetrySendingAllowed(edition: .hosted, sharingEnabled: UserDefaults.standard.bool(forKey: SettingsKey.shareUsageStatistics))
    }

    /// Düzenli gönderimi ve arka plana geçişte gönderimi başlatır; bekleyenleri hemen gönderir (önceki oturumdan kalanlar).
    func start() {
        guard timer == nil else {
            return
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { (_: Notification) -> Void in
            MainActor.assumeIsolated {
                HostedTelemetryCenter.shared.flushInBackground()
            }
        })
        timer = Task { @MainActor in
            while !Task.isCancelled {
                self.flushInBackground()
                do {
                    try await Task.sleep(for: .seconds(flushIntervalSec))
                } catch {
                    // İptal: uygulama kapanıyor.
                    return
                }
            }
        }
    }

    // MARK: Kayıt

    /// Güvenilirlik olayını sayar.
    func record(count kind: TelemetryCountKind) {
        guard isAllowed else {
            return
        }
        storePendingEvents(addingTelemetryCount(pending: loadPendingEvents(), kind: kind))
    }

    /// Süre ölçümünü ekler.
    func record(duration kind: TelemetryDurationKind, seconds: Double) {
        guard isAllowed else {
            return
        }
        storePendingEvents(addingTelemetryDuration(pending: loadPendingEvents(), kind: kind, seconds: seconds))
    }

    /// Özellik kullanımını bugünün (UTC) kaydına işler.
    func record(feature: TelemetryFeature) {
        guard isAllowed else {
            return
        }
        storeFeatureState(recordingFeature(state: loadFeatureState(), feature: feature, today: telemetryDayKey(date: Date())))
    }

    /// Paylaşım kapatıldı: bekleyen olaylar ve özellik kaydı silinir (sonradan gönderilmez).
    func sharingDisabled() {
        UserDefaults.standard.removeObject(forKey: pendingEventsKey)
        UserDefaults.standard.removeObject(forKey: featureStateKey)
        telemetryLogger.info("Kullanım istatistikleri kapatıldı, bekleyenler silindi")
    }

    // MARK: Gönderim

    /// Bekleyenleri arka planda gönderir; süren gönderim varsa bir şey yapmaz.
    private func flushInBackground() {
        guard !isFlushing else {
            return
        }
        isFlushing = true
        Task { @MainActor in
            await self.flush()
            self.isFlushing = false
        }
    }

    /// Bekleyen olayları ve tamamlanmış günün özellik raporunu gönderir. Giriş yoksa bekler (veri kalır); izin yoksa
    /// bekleyenler silinir.
    private func flush() async {
        guard isAllowed else {
            sharingDisabled()
            return
        }
        let client: HostedClient
        do {
            client = try HostedServices.requireClient()
            guard try await client.isSignedIn() else {
                return
            }
        } catch {
            telemetryLogger.warning("Telemetri gönderilmedi, sunucu bağlantısı yok, hata: \(String(describing: error), privacy: .public)")
            return
        }
        await flushEvents(client: client)
        await flushFeatureReport(client: client)
    }

    /// Bekleyen olayları gönderir; gönderilen (ya da gönderilemeyip düşen) olaylar silinir. Gönderim sürerken gelen yeni
    /// olaylar silinmesin diye yalnızca gönderilen anlık görüntü çıkarılır.
    private func flushEvents(client: HostedClient) async {
        let pending: TelemetryPendingEvents = loadPendingEvents()
        let body: Data?
        do {
            body = try hostedTelemetryEventsBody(pending: pending)
        } catch {
            telemetryLogger.error("Telemetri gövdesi üretilemedi, olaylar düştü, hata: \(String(describing: error), privacy: .public)")
            storePendingEvents(subtracting(sent: pending, from: loadPendingEvents()))
            return
        }
        guard let body else {
            return
        }
        do {
            try await client.sendTelemetryEvents(body: body)
            telemetryLogger.info("Telemetri olayları gönderildi, sayım türü: \(pending.counts.count, privacy: .public), süre: \(pending.durations.count, privacy: .public)")
        } catch {
            telemetryLogger.warning("Telemetri olayları gönderilemedi, düştü, sayım türü: \(pending.counts.count, privacy: .public), süre: \(pending.durations.count, privacy: .public), hata: \(String(describing: error), privacy: .public)")
        }
        storePendingEvents(subtracting(sent: pending, from: loadPendingEvents()))
    }

    /// Tamamlanmış günün (dünden ya da daha önceki) özellik raporunu gönderir; gönderilen ya da düşen gün silinir.
    private func flushFeatureReport(client: HostedClient) async {
        let state: TelemetryFeatureState = rollingFeatureState(state: loadFeatureState(), today: telemetryDayKey(date: Date()))
        storeFeatureState(state)
        guard let completed = state.completed else {
            return
        }
        do {
            let counted: Bool = try await client.sendFeatureUsage(body: try hostedFeatureUsageBody(usage: completed))
            telemetryLogger.info("Günlük özellik kullanımı gönderildi, gün: \(completed.day, privacy: .public), sayıldı: \(counted, privacy: .public)")
        } catch {
            telemetryLogger.warning("Günlük özellik kullanımı gönderilemedi, düştü, gün: \(completed.day, privacy: .public), hata: \(String(describing: error), privacy: .public)")
        }
        let latest: TelemetryFeatureState = loadFeatureState()
        storeFeatureState(TelemetryFeatureState(current: latest.current, completed: latest.completed == completed ? nil : latest.completed))
    }

    // MARK: Saklama

    private func loadPendingEvents() -> TelemetryPendingEvents {
        let empty: TelemetryPendingEvents = TelemetryPendingEvents(counts: [], durations: [])
        guard let data = UserDefaults.standard.data(forKey: pendingEventsKey) else {
            return empty
        }
        do {
            return try JSONDecoder().decode(TelemetryPendingEvents.self, from: data)
        } catch {
            telemetryLogger.error("Bekleyen telemetri okunamadı, silindi, hata: \(String(describing: error), privacy: .public)")
            UserDefaults.standard.removeObject(forKey: pendingEventsKey)
            return empty
        }
    }

    private func storePendingEvents(_ pending: TelemetryPendingEvents) {
        guard !pending.isEmpty else {
            UserDefaults.standard.removeObject(forKey: pendingEventsKey)
            return
        }
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(pending), forKey: pendingEventsKey)
        } catch {
            telemetryLogger.error("Bekleyen telemetri yazılamadı, hata: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadFeatureState() -> TelemetryFeatureState {
        let empty: TelemetryFeatureState = TelemetryFeatureState(current: nil, completed: nil)
        guard let data = UserDefaults.standard.data(forKey: featureStateKey) else {
            return empty
        }
        do {
            return try JSONDecoder().decode(TelemetryFeatureState.self, from: data)
        } catch {
            telemetryLogger.error("Özellik kullanımı okunamadı, silindi, hata: \(String(describing: error), privacy: .public)")
            UserDefaults.standard.removeObject(forKey: featureStateKey)
            return empty
        }
    }

    private func storeFeatureState(_ state: TelemetryFeatureState) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: featureStateKey)
        } catch {
            telemetryLogger.error("Özellik kullanımı yazılamadı, hata: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Gönderilen anlık görüntüyü güncel bekleyenlerden çıkarır: sayımlardan gönderilen kadar düşülür, gönderilen süre
/// ölçümleri (baştan, sırayla) atılır. Saf fonksiyondur.
private func subtracting(sent: TelemetryPendingEvents, from current: TelemetryPendingEvents) -> TelemetryPendingEvents {
    let counts: [TelemetryCount] = current.counts.compactMap { (count: TelemetryCount) -> TelemetryCount? in
        let remaining: Int = count.count - (sent.counts.first { $0.kind == count.kind }?.count ?? 0)
        return remaining > 0 ? TelemetryCount(kind: count.kind, count: remaining) : nil
    }
    let durations: [TelemetryDurationSample] = Array(current.durations.dropFirst(min(sent.durations.count, current.durations.count)))
    return TelemetryPendingEvents(counts: counts, durations: durations)
}

/// Son geçişi ölçen sarmalayıcı: süresini (başarılıysa) ve yarıda bırakılmasını (kısmi sonuç ya da hata) telemetriye
/// yazar; sonucu ve hatayı değiştirmez.
struct TelemetryFinalTranscriber: FinalTranscriber {
    let inner: any FinalTranscriber

    func transcribeFinal(audioURL: URL, languageMode: LanguageMode) async throws -> FinalPassResult {
        let started: ContinuousClock.Instant = .now
        do {
            let result: FinalPassResult = try await inner.transcribeFinal(audioURL: audioURL, languageMode: languageMode)
            let seconds: Double = Double((ContinuousClock.now - started).components.seconds)
            await MainActor.run {
                // Kısmi sonuç (`coveredUntilSec`): kalan parçalar yazıya dökülemedi, son geçiş yarıda bırakıldı.
                if result.coveredUntilSec != nil {
                    HostedTelemetryCenter.shared.record(count: .finalPassGiveUp)
                } else {
                    HostedTelemetryCenter.shared.record(duration: .finalPassDuration, seconds: seconds)
                }
            }
            return result
        } catch {
            if !(error is CancellationError) {
                await MainActor.run {
                    HostedTelemetryCenter.shared.record(count: .finalPassGiveUp)
                }
            }
            throw error
        }
    }
}
