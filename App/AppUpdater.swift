import AppKit
import Foundation
import Observation
import os
import Sparkle

private let updateLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Update")

/// Açılıştaki ek denetimin en kısa aralığı: son denetim bundan yeniyse açılışta yeniden denetlenmez (art arda açılışlar
/// sunucuyu yormasın). Sparkle'ın kendi zamanlanmış denetimi Info.plist'te (`SUScheduledCheckInterval`, 6 saat; Sparkle
/// 1 saatten sıkına izin vermez).
private let launchCheckMinimumIntervalSec: TimeInterval = 3600

/// Uygulama açıkken yeni sürümün denetlendiği aralık (saniye): yeni sürüm birkaç dakikada kullanıcıya ulaşsın. Denetim
/// GitHub'daki küçük appcast.xml'in indirilmesidir (birkaç KB; işlemci ve pil etkisi yok sayılacak kadar az).
private let frequentCheckIntervalSec: TimeInterval = 300

/// Info.plist'teki Sparkle açık anahtarı (`SUPublicEDKey`, Config/Signing.xcconfig'teki `SPARKLE_PUBLIC_KEY`); boşsa
/// ya da yoksa nil.
func sparklePublicKey(bundle: Bundle) -> String? {
    guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
        return nil
    }
    let trimmed: String = key.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Açılışta ek denetim yapılmalı mı: hiç denetlenmemişse ya da son denetim `minimumIntervalSec`'ten eskiyse. Saf
/// fonksiyondur.
func shouldCheckForUpdatesAtLaunch(lastCheck: Date?, now: Date, minimumIntervalSec: TimeInterval) -> Bool {
    guard let lastCheck else {
        return true
    }
    return now.timeIntervalSince(lastCheck) >= minimumIntervalSec
}

/// Şeritte ve menüde gösterilen güncelleme: sürüm, sürüm notları ve indirilip kurulmaya hazır olup olmadığı.
struct AvailableAppUpdate: Equatable {
    /// Kullanıcıya görünen sürüm (ör. "0.1.6").
    let version: String
    /// Appcast'e gömülü sürüm notları (Markdown); yoksa nil.
    let releaseNotes: String?
    /// Sürüm notlarının sayfası (güncelleme kartındaki "Tüm notlar" bunu açar); yoksa nil.
    let releaseNotesURL: URL?
    /// İndirildi; uygulama yeniden başlatılınca (ya da çıkışta) kurulur.
    let isReadyToInstall: Bool
}

/// Sparkle öğesinden şerit bilgisi.
@MainActor
private func availableUpdate(item: SUAppcastItem, isReadyToInstall: Bool) -> AvailableAppUpdate {
    AvailableAppUpdate(
        version: item.displayVersionString,
        releaseNotes: item.itemDescription,
        releaseNotesURL: item.fullReleaseNotesURL ?? item.releaseNotesURL,
        isReadyToInstall: isReadyToInstall
    )
}

/// Sparkle'ın temsilcisi (dış sistem bağlantısı; Sparkle NSObject ister ve temsilciyi zayıf tutar, `AppUpdater` saklar).
/// Zamanlanmış denetimde bulunan güncelleme Sparkle'ın penceresiyle değil uygulamadaki sakin şeritle gösterilir ("nazik
/// hatırlatma"); arka planda indirilen güncelleme çıkışta kurulur, şeritteki "Yeniden başlat ve güncelle" hemen kurar.
/// Kayıt ya da işleme sürerken yeniden başlatma ertelenir. Kullanıcının başlattığı denetim Sparkle'ın kendi arayüzünde.
@MainActor
private final class SparkleDelegate: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    weak var owner: AppUpdater?

    // MARK: Kullanıcı arayüzü (SPUStandardUserDriverDelegate)

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    /// Zamanlanmış denetimde bulunan güncellemeyi Sparkle göstermez; uygulama şeritte gösterir.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else {
            return
        }
        let isReady: Bool = state.stage == .downloaded || state.stage == .installing
        updateLogger.info("Güncelleme bulundu, şeritte gösteriliyor, sürüm: \(update.displayVersionString, privacy: .public), hazır: \(isReady, privacy: .public)")
        owner?.showFound(update: availableUpdate(item: update, isReadyToInstall: isReady))
    }

    /// Kullanıcı güncellemeyle ilgilendi ya da oturum bitti: şeritteki "bulundu" bilgisi kalkar.
    func standardUserDriverWillFinishUpdateSession() {
        owner?.clearFound()
    }

    // MARK: Güncelleyici (SPUUpdaterDelegate)

    /// Arka planda indirilen güncelleme çıkışta sessizce kurulur; kurulumu uygulama üstlenir (şeritteki düğme
    /// `immediateInstallHandler`'ı çağırır). Sparkle kendi hatırlatmasını göstermez.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        updateLogger.info("Güncelleme indirildi, çıkışta kurulacak, sürüm: \(item.displayVersionString, privacy: .public)")
        owner?.showReady(update: availableUpdate(item: item, isReadyToInstall: true), install: immediateInstallHandler)
        return true
    }

    /// Kayıt ya da işleme sürerken yeniden başlatma ertelenir; iş bitince `AppUpdater.resumePostponedRelaunch` sürdürür.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let owner, owner.isBusy() else {
            return false
        }
        updateLogger.info("Kayıt ya da işleme sürüyor, güncellemenin yeniden başlatması ertelendi, sürüm: \(item.displayVersionString, privacy: .public)")
        owner.postpone(relaunch: installHandler)
        return true
    }

    /// Sparkle "güncelleme yok" ve kullanıcının vazgeçmesini de bu yoldan bildirir: bunlar hata değildir (Tanılama'nın
    /// son hatalarında görünmesin), yalnızca gerçek kesintiler uyarı olarak loglanır.
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError: NSError = error as NSError
        if nsError.domain == SUSparkleErrorDomain, [Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue)].contains(nsError.code) {
            updateLogger.info("Güncelleme denetimi bitti, yeni sürüm yok ya da kullanıcı vazgeçti, kod: \(nsError.code, privacy: .public)")
            return
        }
        updateLogger.warning("Güncelleme denetimi yarıda kaldı, hata: \(String(describing: error), privacy: .private)")
    }
}

/// Sparkle güncelleyicisine bağlantı: GitHub'daki appcast.xml'den yeni sürümü açılışta ve uygulama açıkken 5 dakikada bir denetler, arka
/// planda indirir (ayardan kapatılabilir) ve çıkışta kurar (uygulama sandbox'sız; Sparkle'ın XPC servisleri gerekmez).
/// Bulunan ya da indirilen güncelleme ana penceredeki şeritte ve menüde gösterilir; kayıt ya da işleme sürerken
/// yeniden başlatılmaz. İmza anahtarı yoksa Sparkle hiç başlatılmaz (başlatılsa açılışta hata penceresi gösterirdi),
/// uyarı loglanır ve güncelleme menüsü ile ayarı gizlenir. Dış sisteme (Sparkle) bağlandığı için sınıftır.
@MainActor
@Observable
final class AppUpdater {
    /// Güncelleme açık: imza anahtarı tanımlı ve Sparkle başlatıldı.
    let isEnabled: Bool
    /// "Güncellemeleri denetle…" şu an kullanılabilir (bir denetim sürerken değil).
    private(set) var canCheckForUpdates: Bool = false
    /// Güncellemeler arka planda indirilip çıkışta kurulur.
    private(set) var automaticallyUpdates: Bool = false
    /// İndirilmiş, yeniden başlatınca kurulacak güncelleme.
    private(set) var readyUpdate: AvailableAppUpdate?
    /// Bulunmuş ama indirilmemiş güncelleme (otomatik indirme kapalıyken).
    private(set) var foundUpdate: AvailableAppUpdate?
    /// Kullanıcı şeridi bu sürüm için kapattı (menüde görünmeye devam eder).
    private(set) var dismissedVersion: String?
    /// Yeniden başlatma, kayıt ya da işleme bitince yapılacak.
    private(set) var isRelaunchPostponed: Bool = false
    /// Kayıt ya da işleme sürüyor mu (uygulama bağlar; çıkış korumasıyla aynı koşul).
    @ObservationIgnored let isBusy: @MainActor () -> Bool
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let delegate: SparkleDelegate = SparkleDelegate()
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private var postponedRelaunch: (() -> Void)?
    /// Sık denetim döngüsü (bkz. `frequentCheckIntervalSec`).
    @ObservationIgnored private var frequentChecks: Task<Void, Never>?

    init(publicKey: String?, isBusy: @escaping @MainActor () -> Bool) {
        self.isBusy = isBusy
        guard publicKey != nil else {
            updateLogger.warning("Sparkle açık anahtarı (SUPublicEDKey) boş; otomatik güncelleme kapalı. Config/Signing.xcconfig'te SPARKLE_PUBLIC_KEY doldurulmalı")
            isEnabled = false
            controller = nil
            return
        }
        let controller: SPUStandardUpdaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: delegate)
        self.controller = controller
        isEnabled = true
        delegate.owner = self
        controller.startUpdater()
        let updater: SPUUpdater = controller.updater
        // Açılışta ek denetim (Sparkle'ın önerdiği gibi başlatmanın hemen ardından ve yalnızca otomatik denetim açıksa);
        // son denetim bir saatten yeniyse atlanır. Sonrası Sparkle'ın 6 saatlik zamanlayıcısıyla.
        if updater.automaticallyChecksForUpdates,
           shouldCheckForUpdatesAtLaunch(lastCheck: updater.lastUpdateCheckDate, now: Date(), minimumIntervalSec: launchCheckMinimumIntervalSec) {
            updater.checkForUpdatesInBackground()
            updateLogger.info("Açılışta güncelleme denetimi başlatıldı")
        }
        automaticallyUpdates = updater.automaticallyDownloadsUpdates
        frequentChecks = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(frequentCheckIntervalSec))
                } catch {
                    return
                }
                self?.checkInBackground()
            }
        }
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] (updater: SPUUpdater, _: NSKeyValueObservedChange<Bool>) -> Void in
            // Sparkle bu özelliği ana iş parçacığında değiştirir.
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        updateLogger.info("Sparkle başlatıldı, akış: \(updater.feedURL?.absoluteString ?? "-", privacy: .public), aralık: \(updater.updateCheckInterval, privacy: .public)")
    }

    /// Sık denetim: otomatik denetim açıksa, bir denetim sürmüyorsa ve bulunmuş bir güncelleme beklemiyorsa arka planda
    /// denetlenir (sonuç şeritte değil sağ alttaki kartta gösterilir; Sparkle penceresi açılmaz).
    private func checkInBackground() {
        guard let updater = controller?.updater, updater.automaticallyChecksForUpdates, updater.canCheckForUpdates, availableUpdate == nil else {
            return
        }
        updater.checkForUpdatesInBackground()
    }

    #if DEBUG
    /// Tanıtım modu (bkz. `DemoScene.update`): güncelleme kartı Sparkle'a sorulmadan gösterilir.
    func showUpdateForDemo(update: AvailableAppUpdate) {
        foundUpdate = update
    }
    #endif

    /// Son güncelleme denetiminin zamanı (Sparkle'ın kaydı); hiç denetlenmediyse ya da güncelleme kapalıysa nil.
    var lastCheckDate: Date? {
        controller?.updater.lastUpdateCheckDate
    }

    /// Şeritte ve menüde gösterilecek güncelleme: indirilmiş olan önce.
    var availableUpdate: AvailableAppUpdate? {
        readyUpdate ?? foundUpdate
    }

    /// Ana penceredeki şerit görünsün mü (kullanıcı bu sürüm için kapatmadıysa).
    var showsBanner: Bool {
        guard let update = availableUpdate else {
            return false
        }
        return update.version != dismissedVersion
    }

    /// Kullanıcının başlattığı denetim (Sparkle kendi penceresinde sonucu gösterir).
    func checkForUpdates() {
        guard let controller else {
            updateLogger.error("Güncelleme denetlenemedi: Sparkle başlatılmadı (açık anahtar yok)")
            return
        }
        controller.checkForUpdates(nil)
    }

    /// Şeritteki düğme: indirilmiş güncelleme hemen kurulur ve uygulama yeniden açılır; indirilmemişse Sparkle'ın
    /// güncelleme penceresi öne getirilir. Kayıt ya da işleme sürerken hiçbir şey yapılmaz (düğme de kapalıdır).
    func installUpdate() {
        guard !isBusy() else {
            updateLogger.warning("Güncelleme kurulmadı: kayıt ya da işleme sürüyor")
            return
        }
        if let installNow {
            updateLogger.info("Güncelleme kuruluyor, uygulama yeniden açılacak")
            installNow()
            return
        }
        checkForUpdates()
    }

    /// Şeridi bu sürüm için kapatır (menüde görünmeye devam eder; yeni sürüm gelince şerit yeniden çıkar).
    func dismissBanner() {
        dismissedVersion = availableUpdate?.version
    }

    /// Ertelenen yeniden başlatmayı sürdürür; kayıt ya da işleme bitince uygulama çağırır.
    func resumePostponedRelaunch() {
        guard let postponedRelaunch, !isBusy() else {
            return
        }
        self.postponedRelaunch = nil
        isRelaunchPostponed = false
        updateLogger.info("Kayıt bitti, ertelenen güncelleme kuruluyor")
        postponedRelaunch()
    }

    /// Otomatik güncellemeyi açar ya da kapatır. Açıkken denetim de açılır; kapalıyken denetim sürer, yeni sürüm
    /// yalnızca şeritte haber verilir (kendiliğinden indirilmez).
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

    // MARK: Sparkle temsilcisinden

    /// Zamanlanmış denetimde bulunan güncelleme. Önceki oturumda indirilmiş olsa da anında kurma bloğu yoksa
    /// şeritteki düğme Sparkle'ın penceresini öne getirir (bkz. `installUpdate`).
    fileprivate func showFound(update: AvailableAppUpdate) {
        foundUpdate = update
    }

    fileprivate func clearFound() {
        foundUpdate = nil
    }

    fileprivate func showReady(update: AvailableAppUpdate, install: @escaping () -> Void) {
        installNow = install
        readyUpdate = update
        foundUpdate = nil
    }

    fileprivate func postpone(relaunch: @escaping () -> Void) {
        postponedRelaunch = relaunch
        isRelaunchPostponed = true
    }
}
