import Foundation
import Observation
import os
import Sparkle

private let updateLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Update")

/// Info.plist'teki Sparkle açık anahtarı (`SUPublicEDKey`, Config/Signing.xcconfig'teki `SPARKLE_PUBLIC_KEY`); boşsa
/// ya da yoksa nil.
func sparklePublicKey(bundle: Bundle) -> String? {
    guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
        return nil
    }
    let trimmed: String = key.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Sparkle güncelleyicisine bağlantı: GitHub'daki appcast.xml'den yeni sürümü denetler, indirir ve kurar (uygulama
/// sandbox'sız; Sparkle'ın XPC servisleri gerekmez). İmza anahtarı yoksa Sparkle hiç başlatılmaz (başlatılsa açılışta
/// hata penceresi gösterirdi), uyarı loglanır ve güncelleme menüsü ile ayarı gizlenir. Dış sisteme (Sparkle) bağlandığı
/// için sınıftır.
@MainActor
@Observable
final class AppUpdater {
    /// Güncelleme açık: imza anahtarı tanımlı ve Sparkle başlatıldı.
    let isEnabled: Bool
    /// "Güncellemeleri denetle…" şu an kullanılabilir (bir denetim sürerken değil).
    private(set) var canCheckForUpdates: Bool = false
    /// Güncellemeler arka planda indirilip çıkışta kurulur.
    private(set) var automaticallyUpdates: Bool = false
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(publicKey: String?) {
        guard publicKey != nil else {
            updateLogger.warning("Sparkle açık anahtarı (SUPublicEDKey) boş; otomatik güncelleme kapalı. Config/Signing.xcconfig'te SPARKLE_PUBLIC_KEY doldurulmalı")
            isEnabled = false
            controller = nil
            return
        }
        let controller: SPUStandardUpdaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        isEnabled = true
        automaticallyUpdates = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] (updater: SPUUpdater, _: NSKeyValueObservedChange<Bool>) -> Void in
            // Sparkle bu özelliği ana iş parçacığında değiştirir.
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        updateLogger.info("Sparkle başlatıldı, akış: \(controller.updater.feedURL?.absoluteString ?? "-", privacy: .public)")
    }

    /// Kullanıcının başlattığı denetim (Sparkle kendi penceresinde sonucu gösterir).
    func checkForUpdates() {
        guard let controller else {
            updateLogger.error("Güncelleme denetlenemedi: Sparkle başlatılmadı (açık anahtar yok)")
            return
        }
        controller.checkForUpdates(nil)
    }

    /// Otomatik güncellemeyi açar ya da kapatır. Açıkken günlük denetim de açılır; kapalıyken denetim sürer, yeni sürüm
    /// yalnızca haber verilir (kendiliğinden indirilmez).
    func setAutomaticallyUpdates(enabled: Bool) {
        guard let controller else {
            updateLogger.error("Otomatik güncelleme ayarlanamadı: Sparkle başlatılmadı (açık anahtar yok)")
            return
        }
        if enabled {
            controller.updater.automaticallyChecksForUpdates = true
        }
        controller.updater.automaticallyDownloadsUpdates = enabled
        automaticallyUpdates = controller.updater.automaticallyDownloadsUpdates
        updateLogger.info("Otomatik güncelleme değişti, açık: \(self.automaticallyUpdates, privacy: .public)")
    }
}
