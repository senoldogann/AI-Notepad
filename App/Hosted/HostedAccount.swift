import AINotepadCore
import AppKit
import AuthenticationServices
import Foundation
import Network
import Observation
import os

private let accountLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedAccount")

extension Notification.Name {
    /// Sunucu oturumu kapattı (yenileme reddedildi; ör. yenileme jetonu yeniden kullanıldığı için tüm oturumlar düştü).
    static let hostedSessionEnded: Notification.Name = Notification.Name("com.senoldogan.AINotepad.hosted.sessionEnded")
}

/// Info.plist'teki adresi okur ve doğrular: Debug'da yerel http kabul edilir, yayında yalnızca https.
private func hostedURL(bundle: Bundle, key: String) throws -> URL {
    let value: String = bundle.object(forInfoDictionaryKey: key) as? String ?? ""
    let url: URL = try parseHostedBaseURL(value: value)
    #if !DEBUG
    try requireSecureHostedBaseURL(url: url)
    #endif
    return url
}

/// Uygulama boyunca tek sunucu bağlantısı; oturum Anahtar Zinciri'nde Info.plist'teki servis adıyla saklanır (Debug ve
/// Release ayrı: Debug derlemesi yayındaki oturumu okumaz, silmez).
private func makeHostedClient(bundle: Bundle) -> Result<HostedClient, HostedClientError> {
    do {
        let client: HostedClient = HostedClient(
            baseURL: try hostedURL(bundle: bundle, key: "HostedAPIBase"),
            storage: HostedKeychainTokenStorage(service: try hostedKeychainService(bundle: bundle))
        ) { () async -> Void in
            await MainActor.run {
                NotificationCenter.default.post(name: .hostedSessionEnded, object: nil)
            }
        }
        return .success(client)
    } catch let error as HostedClientError {
        accountLogger.error("Sunucu bağlantısı kurulamadı, hata: \(String(describing: error), privacy: .private)")
        return .failure(error)
    } catch {
        // `hostedURL` ve `hostedKeychainService` yalnızca `HostedClientError` fırlatır.
        return .failure(.invalidBaseURL(value: String(describing: error)))
    }
}

/// Paylaşılan sunucu bağlantısı ve site adresi.
enum HostedServices {
    static let client: Result<HostedClient, HostedClientError> = makeHostedClient(bundle: .main)

    /// Bağlantı; adres geçersizse hata.
    static func requireClient() throws -> HostedClient {
        try client.get()
    }

    /// Sitenin adresi (giriş sayfası orada).
    static func siteBase() throws -> URL {
        try hostedURL(bundle: .main, key: "HostedSiteBase")
    }
}

/// Davet kodunun ödeme öncesi doğrulaması.
enum HostedReferralCheck: Equatable {
    /// Geçerli; sunucunun sadeleştirdiği kod ödeme sayfasına gönderilir.
    case valid(code: String)
    /// Geçersiz; kullanıcıya gösterilecek neden.
    case invalid(message: String)
}

/// Hesap ekranının durumu.
enum HostedAccountState: Equatable {
    /// İlk okuma sürüyor.
    case loading
    case signedOut
    case signedIn(HostedEntitlements)
    /// Oturum var ama hak durumu okunamadı (ağ yok ya da sunucu yanıt vermiyor). Bağlantı gelince ve uygulama öne
    /// gelince yeniden okunur; kullanıcı çıkış yapmış sayılmaz.
    case signedInStatusUnknown(message: String)
    /// Sunucu adresi ayarlanmamış ya da güvensiz, ya da Anahtar Zinciri okunamıyor: hesap kullanılamaz.
    case unavailable(message: String)
}

/// Uygulama içi giriş penceresinin (ASWebAuthenticationSession) sonucu.
private enum HostedWebSignInOutcome {
    /// Site dönüş adresine yönlendirdi (henüz doğrulanmadı).
    case callback(URL)
    /// Kullanıcı pencereyi kapattı ya da "Vazgeç"e bastı.
    case canceled
}

/// Giriş penceresinin bağlandığı pencere (AuthenticationServices sunum sağlayıcısı; dış sistem bağlantısı, NSObject
/// gerekir). Giriş düğmesi ana penceredeyken anahtar pencere odur.
@MainActor
private final class HostedWebSignInPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Anahtar ya da ana pencere yoksa (ör. uygulama arka planda) sistem giriş penceresini kendi başına açar.
        NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
    }
}

/// Hesabın profil resmi adresinin anahtarı (hesap başına, yalnızca bu Mac'te). Saf fonksiyondur.
private func hostedAvatarKey(userId: String) -> String {
    "hosted.avatarURL.\(userId)"
}

/// Girişte jetondan gelen profil resmini hesaba yazar; resim yoksa (Apple) eskisi silinir.
private func saveHostedAvatar(picture: URL?, userId: String) {
    if let picture {
        UserDefaults.standard.set(picture, forKey: hostedAvatarKey(userId: userId))
    } else {
        UserDefaults.standard.removeObject(forKey: hostedAvatarKey(userId: userId))
    }
}

/// Ödeme ya da portaldan uygulamaya dönünce aboneliğin beklendiği aralıklar (sn): 5 sn arayla 2 dk. Abonelik bu sürede
/// görünmezse kullanıcı vazgeçmiş sayılır; sonraki her öne gelişte hak durumu zaten bir dakikadan eskiyse yenilenir.
private let hostedBillingReturnPollDelays: [Double] = Array(repeating: 5, count: 24)
/// Ödeme sayfası açıkken aboneliğin beklendiği aralıklar (sn): ilk 2 dk 5 sn'de bir (ödemelerin çoğu bu sürede biter),
/// 5. dakikaya dek 15 sn'de bir, 15. dakikaya dek 30 sn'de bir (kart bilgisi girmeye yeter). Her okuma sunucu isteği,
/// çevrimdışı kuyruk turu ve Anahtar Zinciri okumasıdır: sabit 5 sn'lik 180 okuma yerine 56.
private let hostedCheckoutWatchDelays: [Double] =
    Array(repeating: 5, count: 24) + Array(repeating: 15, count: 12) + Array(repeating: 30, count: 20)

/// Sunucunun bu hesabın denemesini bu Mac'te reddettiği anın kaydı (hesap başına; abone olunca etkisizdir, bir gün
/// sonra sunucuya yeniden sorulur: bkz. `hostedTrialRefusalMaxAgeSec`). Saf fonksiyondur.
private func hostedTrialRefusedKey(userId: String) -> String {
    "hosted.trialRefusedOnThisMac.\(userId)"
}

/// Yeni girişten önce bu Mac'teki eski oturum sunucuda kapatılır. Sunucuya ulaşılamazsa yerel oturum yine silinir
/// (bkz. `HostedClient.signOut`) ve uyarı loglanır; sunucudaki yenileme jetonu kullanılmadığı için en geç
/// `REFRESH_TOKEN_DAYS` (60) gün içinde kendiliğinden geçersizleşir.
private func endPreviousSession(client: HostedClient) async throws {
    guard try await client.isSignedIn() else {
        return
    }
    do {
        try await client.signOut()
        accountLogger.info("Yeni giriş öncesi eski oturum kapatıldı")
    } catch HostedClientError.network(let path, _) {
        accountLogger.warning("Eski oturum sunucuda kapatılamadı (ağ), yerelde silindi, yol: \(path, privacy: .public)")
    } catch let error as HostedAPIError {
        accountLogger.warning("Eski oturum sunucuda kapatılamadı, yerelde silindi, kod: \(error.rawCode, privacy: .public), durum: \(error.status, privacy: .public)")
    }
}

/// Abonelik hesabının arayüz bağlantısı: giriş (Apple, Google), hak durumu, ödeme sayfaları, hesap silme,
/// toplantı oturumu ve cihaz doğrulaması. Sunucuya `HostedClient` ile bağlanır (dış sistem bağlantısı olduğu için
/// sınıftır). Hata metinleri kullanıcıya gösterilir; jeton ve içerik loglanmaz.
@MainActor
@Observable
final class HostedAccount {
    static let shared: HostedAccount = HostedAccount()

    private(set) var state: HostedAccountState = .loading
    /// Son işlemin hatası (giriş, ödeme, silme); yeni işlem başlayınca temizlenir.
    var errorMessage: String?
    /// Bir işlem sürüyor (düğmeler kilitli).
    private(set) var isWorking: Bool = false
    /// Giriş penceresi açık, dönüşü beklenen deneme (ham nonce yalnızca burada, bellekte; tek kullanımlık).
    private(set) var pendingBrowserSignIn: HostedBrowserSignInAttempt?
    /// Açık giriş penceresinin sağlayıcısı (düğmede bekleme göstergesi için).
    private(set) var pendingSignInProvider: HostedSignInProvider?
    /// Ana pencerede açılacak abone olma teklifi (bkz. `meetingNoteReady`); kayıt ya da işleme sürerken açılmaz.
    private(set) var upsell: HostedUpsellMoment?
    /// Abonenin davet kodu ve sayıları (Ayarlar › Hesap açılınca okunur; bkz. `loadReferral`); yoksa nil.
    private(set) var referral: HostedReferral?
    /// Sunucu bu hesabın ücretsiz denemesini bu Mac'te reddetti (Mac denemesini başka bir hesapla kullandı); hak durumu
    /// kalan deneme 0 olarak gösterilir (bkz. `hostedEntitlementsOnThisMac`).
    private(set) var isTrialRefusedOnThisMac: Bool = false
    /// Son başlatılan toplantının sınırları (kayıt panelinde ve Ayarlar'da gösterilir).
    private(set) var currentMeeting: HostedStartedMeeting?
    /// Ana penceredeki kullanım bildirimi (%80, %100, son deneme toplantısı, deneme bitti). Her biri dönem başına bir
    /// kez gösterilir (UserDefaults'ta `hostedNoticeStorageKey` ile işaretlenir); kapatılınca ya da durum değişince kalkar.
    private(set) var visibleNotice: HostedUsageNotice?
    /// Bu Mac'te kayıtlı oturum var mı: açılışta Anahtar Zinciri'nden (ağsız) okunur, her yenilemede ve çıkışta
    /// güncellenir; okunamadıysa nil. Giriş kapısı buna bakar (bkz. `requiresSignIn`).
    private(set) var hasSession: Bool?
    /// Kayıt sunucuya ulaşılamadan (çevrimdışı) sürüyor: canlı metin Mac'te, toplantı sonra işlenecek.
    private(set) var isOfflineRecording: Bool = false
    /// Bekleyen (çevrimdışı) kayıtların işlenmesini tetikler: ağ gelince, hak durumu okununca ve uygulama öne gelince
    /// artar (uygulama izler; bkz. `AppModel.runOfflineQueue`).
    private(set) var queueTrigger: Int = 0
    /// Ödeme ya da müşteri portalı tarayıcıda açıldı: uygulama öne gelince hak durumu beklemeden yeniden okunur.
    @ObservationIgnored private var awaitingBillingReturn: Bool = false
    /// Ödeme sayfası açıkken aboneliği bekleyen izleme (bkz. `watchCheckout`); yoksa nil.
    @ObservationIgnored private var checkoutWatch: Task<Void, Never>?
    /// "Abonelik gerekli" teklifinin son açılışı (bkz. `subscriptionRequiredByServer`).
    @ObservationIgnored private var lastSubscriptionPromptAt: Date?
    /// Süren hak durumu okumaları (eşzamanlı okumalar birbirinin bayrağını indirmesin).
    @ObservationIgnored private var refreshesInFlight: Int = 0
    private var isRefreshing: Bool { refreshesInFlight > 0 }
    /// Hesap durumunun kuşağı: her okuma, çıkış ve hesap silme artırır; geç dönen eski okuma yeni durumu ezmez (çıkıştan
    /// sonra dönen okuma oturumu "giriş yapıldı" göstermez; bkz. `isCurrentSessionGeneration`).
    @ObservationIgnored private var stateGeneration: Int = 0
    /// Oturumdaki kullanıcı (Anahtar Zinciri'nden, her okumada); oturum yoksa nil. Çevrimdışı kayıt izni buna göre
    /// denetlenir (başka hesabın izni kullanılmaz).
    private(set) var signedInUserIDCache: String?
    /// Avatar resmi kaydedildikçe artar (aynı hesap yeniden girince de görünüm yenilensin; bkz. `avatarURL`).
    private(set) var avatarRevision: Int = 0

    /// Oturumdaki hesabın profil resmi (Google ile girişte jetondan alınır, yalnızca bu Mac'te saklanır); yoksa nil
    /// (Apple resim vermez): kenar çubuğunda hesaba özel küre görünür.
    var avatarURL: URL? {
        _ = avatarRevision
        return signedInUserIDCache.flatMap { (userID: String) -> URL? in UserDefaults.standard.url(forKey: hostedAvatarKey(userId: userID)) }
    }
    /// Son başarılı hak durumu okuması (uygulama öne gelince eskimişse yenilenir).
    @ObservationIgnored private var lastRefreshAt: Date?
    /// Yenilemenin gösterdiği hata: sonraki başarılı yenileme onu kaldırır (bağlantı gelince eski hata kalmasın).
    @ObservationIgnored private var refreshErrorMessage: String?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Ağ geri gelince hak durumu yeniden okunur (bkz. `retryUnknownStatus`).
    @ObservationIgnored private let pathMonitor: NWPathMonitor = NWPathMonitor()
    /// Açık giriş penceresi: oturum bitene dek tutulmalı (yoksa sistem pencereyi kapatır).
    @ObservationIgnored private var webSession: ASWebAuthenticationSession?
    @ObservationIgnored private let presenter: HostedWebSignInPresenter = HostedWebSignInPresenter()

    private init() {
        do {
            let userID: String? = try hostedStoredUserID(bundle: .main)
            hasSession = userID != nil
            signedInUserIDCache = userID
        } catch {
            // Kapı kapalı kalır; ilk yenileme hesabı "kullanılamıyor" yapar ve nedeni kapıda görünür.
            accountLogger.error("Kayıtlı oturum okunamadı, hata: \(String(describing: error), privacy: .private)")
            hasSession = nil
        }
        // Açılışta oturum varsa o hesabın verisi, toplantılar okunmadan önce yüklenir (bkz. `syncAccountData`).
        syncAccountData(userID: signedInUserIDCache)
        observers.append(NotificationCenter.default.addObserver(forName: .hostedSubscriptionRequired, object: nil, queue: .main) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.promptSubscriptionIfDue()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .hostedSessionEnded, object: nil, queue: .main) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.currentMeeting = nil
                self?.hasSession = false
                clearHostedOfflinePermit()
                self?.state = .signedOut
                self?.errorMessage = userFacingMessage(error: HostedClientError.sessionEnded)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                Task {
                    await self.retryUnknownStatus()
                    await self.refreshOnActivation()
                    await self.closeOrphanedMeeting()
                    self.queueTrigger += 1
                }
            }
        })
        pathMonitor.pathUpdateHandler = { [weak self] (path: NWPath) -> Void in
            guard path.status == .satisfied else {
                return
            }
            Task { @MainActor in
                await self?.networkBecameAvailable()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.senoldogan.AINotepad.hosted.path"))
        // Uygulama kapanırken açık kalan sunucu oturumu kapatılmaya çalışılır (en çok 3 sn); olmazsa sonraki açılışta.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                endOpenMeetingBeforeQuit(userID: self?.signedInUserIDCache)
            }
        })
    }

    /// Giriş kapısı kapalı mı: bu Mac'te oturum yoksa (ya da okunamadıysa) ana arayüz, kayıt, kısayollar ve menü
    /// eylemleri açılmaz. Oturum varken hak durumu bilinmese de (çevrimdışı) kapı açıktır. Tanıtım modu (yalnız Debug)
    /// sunucuya bağlanmadığı için kapıya takılmaz.
    var requiresSignIn: Bool {
        #if DEBUG
        if isDemoMode {
            return false
        }
        #endif
        return hasSession != true || !isAccountDataLoaded
    }

    // MARK: Hesap verisi

    /// Bu süreçte yüklü hesap verisinin durumu (bkz. `syncAccountData`). Giriş yapan hesabın verisi yüklü değilse giriş
    /// kapısı kapalı kalır ve nedeni kapıda görünür: hiçbir hesap başka bir hesabın toplantılarını görmez.
    private(set) var dataState: HostedDataState = .notLoaded
    /// Hesap verisi bu süreçte ilk kez yüklendiğinde artar (açılışta oturum yoktu, sonra giriş yapıldı): uygulama
    /// toplantıları, kişileri ve geçmişi o zaman okur (bkz. `AppModel.performStartupMaintenance`).
    private(set) var dataActivations: Int = 0

    /// Giriş yapan hesabın verisi yüklü mü.
    var isAccountDataLoaded: Bool {
        if case .loaded = dataState {
            return true
        }
        return false
    }

    /// Yüklü hesap verisini giriş yapan hesapla eşler (açılışta ve her hesap okumasında): giriş yoksa yüklü veri kalır
    /// (çıkış yerel veriyi silmez, kapı gizler); henüz hesap yüklenmediyse giriş yapanınki yüklenir (önceki veri
    /// sahiplenilmediyse ona taşınır); başka bir hesabınki yüklüyse uygulama yeniden başlamalıdır (`relaunchRequired`;
    /// uygulama kayıt ve işleme yokken yeniden başlatır).
    private func syncAccountData(userID: String?) {
        let loadedKey: String? = AppPaths.activeAccountKey()
        #if DEBUG
        // Tanıtım modu sunucuya bağlanmaz: açılışta yüklenen tanıtım hesabı kalır (bkz. App/DemoData.swift).
        if isDemoMode {
            if let loadedKey {
                dataState = .loaded(accountKey: loadedKey)
            }
            return
        }
        #endif
        switch accountDataTransition(loadedKey: loadedKey, signedInKey: userID.map { (id: String) -> String in accountDataKey(userId: id) }) {
        case .keep:
            if let loadedKey {
                dataState = .loaded(accountKey: loadedKey)
            }
        case .activate:
            guard let userID else {
                return
            }
            do {
                let key: String = try prepareHostedAccountData(userId: userID)
                dataState = .loaded(accountKey: key)
                dataActivations += 1
            } catch {
                accountLogger.error("Hesap verisi hazırlanamadı, hata: \(String(describing: error), privacy: .private)")
                dataState = .failed(message: userFacingMessage(error: error))
            }
        case .relaunch(let accountKey):
            if dataState != .relaunchRequired(accountKey: accountKey) {
                accountLogger.info("Başka bir hesapla giriş yapıldı, uygulama boşta olunca yeniden başlayacak")
            }
            dataState = .relaunchRequired(accountKey: accountKey)
        }
    }

    /// Hazırlanamayan hesap verisini yeniden dener (kapıdaki "Yeniden dene"); hesap değişiminde yeniden başlatma
    /// başarısız olduysa yeniden başlatmayı yeniden ister.
    func retryAccountData() {
        syncAccountData(userID: signedInUserIDCache)
    }

    /// Hesap değişiminde uygulama yeniden başlatılamadı: neden kapıda görünür, "Yeniden dene" yeniden ister.
    func reportRelaunchFailure(message: String) {
        dataState = .failed(message: message)
    }

    /// Bu Mac'te oturum var mı (hak durumu okunmuş olsun ya da olmasın).
    var isSignedIn: Bool {
        switch state {
        case .signedIn, .signedInStatusUnknown:
            true
        case .loading, .signedOut, .unavailable:
            false
        }
    }

    /// Son okunan hak durumu deneme mi. Bilinmiyorsa (okunamadı) false: DeviceCheck jetonu yalnızca deneme olduğu
    /// bilinen hesapta ya da sunucu isteyince gönderilir (abonelerin hiç gerekmez).
    private var isKnownTrial: Bool {
        if case .signedIn(let entitlements) = state {
            return entitlements.plan == .trial
        }
        return false
    }

    // MARK: Durum

    /// Oturumu ve hak durumunu sunucudan yeniden okur; App Attest destekleniyorsa cihaz önce doğrulanır (sessizce
    /// atlanır, bkz. `HostedDeviceAttestation`). Oturum varken hak durumu okunamazsa (ağ, sunucu) çıkış yapılmış
    /// sayılmaz: önceden okunmuş hak durumu kalır ve hata gösterilir; hiç okunmamışsa durum "bilinmiyor" olur.
    func refresh() async {
        #if DEBUG
        // Tanıtım modu sunucuya bağlanmaz ve Anahtar Zinciri'ni okumaz: sahnenin yazdığı durum kalır.
        if isDemoMode {
            return
        }
        #endif
        refreshesInFlight += 1
        defer { refreshesInFlight -= 1 }
        stateGeneration += 1
        let generation: Int = stateGeneration
        let client: HostedClient
        let hasSession: Bool
        let userID: String?
        do {
            client = try HostedServices.requireClient()
            hasSession = try await client.isSignedIn()
            userID = try await client.signedInUserID()
        } catch {
            accountLogger.error("Hesap okunamadı, hata: \(String(describing: error), privacy: .private)")
            guard isCurrentSessionGeneration(started: generation, current: stateGeneration) else {
                return
            }
            state = .unavailable(message: userFacingMessage(error: error))
            return
        }
        guard isCurrentSessionGeneration(started: generation, current: stateGeneration) else {
            return
        }
        self.hasSession = hasSession
        signedInUserIDCache = userID
        // Giriş yapan hesabın verisi, kapı açılmadan önce (aynı ana iş parçacığı adımında) yüklenir ya da yeniden
        // başlatma istenir: başka hesabın toplantıları bir an bile görünmez.
        syncAccountData(userID: userID)
        guard hasSession else {
            state = .signedOut
            return
        }
        do {
            await HostedDeviceAttestation.prepare(client: client)
            let received: HostedEntitlements = try await client.entitlements()
            // Bu arada çıkış yapıldıysa ya da daha yeni bir okuma başladıysa eski sonuç yazılmaz.
            guard isCurrentSessionGeneration(started: generation, current: stateGeneration) else {
                return
            }
            isTrialRefusedOnThisMac = isHostedTrialRefusalActive(
                refusedAt: UserDefaults.standard.object(forKey: hostedTrialRefusedKey(userId: received.userId)) as? Date,
                now: Date(),
                maxAgeSec: hostedTrialRefusalMaxAgeSec
            )
            let entitlements: HostedEntitlements = hostedEntitlementsOnThisMac(entitlements: received, trialRefusedOnThisMac: isTrialRefusedOnThisMac)
            state = .signedIn(entitlements)
            lastRefreshAt = Date()
            saveHostedOfflinePermit(permit: hostedOfflinePermit(entitlements: entitlements, now: Date()))
            queueTrigger += 1
            if let refreshErrorMessage, errorMessage == refreshErrorMessage {
                errorMessage = nil
            }
            refreshErrorMessage = nil
            updateNotice(entitlements: entitlements, now: Date())
        } catch HostedClientError.notSignedIn, HostedClientError.sessionEnded {
            guard isCurrentSessionGeneration(started: generation, current: stateGeneration) else {
                return
            }
            self.hasSession = false
            signedInUserIDCache = nil
            clearHostedOfflinePermit()
            state = .signedOut
        } catch {
            accountLogger.error("Hak durumu okunamadı, hata: \(String(describing: error), privacy: .private)")
            guard isCurrentSessionGeneration(started: generation, current: stateGeneration) else {
                return
            }
            let message: String = userFacingMessage(error: error)
            if case .signedIn = state {
                errorMessage = message
                refreshErrorMessage = message
            } else {
                state = .signedInStatusUnknown(message: message)
            }
        }
    }

    /// Bildirimi hak durumuna göre günceller: yeni eşik aşıldıysa ve bu dönemde gösterilmediyse gösterilir ve
    /// "gösterildi" diye işaretlenir; eşik artık geçerli değilse kalkar.
    private func updateNotice(entitlements: HostedEntitlements, now: Date) {
        guard let notice = hostedUsageNotice(entitlements: entitlements) else {
            visibleNotice = nil
            return
        }
        if visibleNotice == notice {
            return
        }
        // Son deneme toplantısı açılınca kalan hak 0'a iner; o toplantı sürerken "deneme bitti" gösterilmez (kayıt
        // duracak sanılmasın), toplantı kapanınca yapılan yenilemede gösterilir. Deneme bu Mac'te reddedildiyse de
        // gösterilmez: deneme hiç bitmedi, nedeni Başlat düğmesinin yanında yazar.
        if notice == .trialEnded && (currentMeeting != nil || isTrialRefusedOnThisMac) {
            visibleNotice = nil
            return
        }
        let key: String = hostedNoticeStorageKey(notice: notice, userId: entitlements.userId, now: now)
        guard !UserDefaults.standard.bool(forKey: key) else {
            visibleNotice = nil
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        visibleNotice = notice
        accountLogger.info("Kullanım bildirimi gösteriliyor, tür: \(notice.rawValue, privacy: .public)")
    }

    /// Bir toplantının notu hazır: hak durumu yenilenir; hesap denemedeyse ve zamanı geldiyse (günde en çok bir, deneme
    /// bitince bir kez; bkz. `hostedUpsellMoment`) abone olma teklifi açılır ve gösterim hesap başına kaydedilir.
    func meetingNoteReady() async {
        await refresh()
        guard case .signedIn(let entitlements) = state else {
            return
        }
        let lastShownKey: String = "hosted.upsell.lastShownAt.\(entitlements.userId)"
        let trialEndedKey: String = "hosted.upsell.trialEndedShown.\(entitlements.userId)"
        let trialEndingKey: String = "hosted.upsell.trialEndingShown.\(entitlements.userId)"
        guard let moment = hostedUpsellMoment(
            entitlements: entitlements,
            lastShownAt: UserDefaults.standard.object(forKey: lastShownKey) as? Date,
            trialEndedShown: UserDefaults.standard.bool(forKey: trialEndedKey),
            trialEndingShown: UserDefaults.standard.bool(forKey: trialEndingKey),
            now: Date(),
            intervalSec: hostedUpsellIntervalSec
        ) else {
            return
        }
        UserDefaults.standard.set(Date(), forKey: lastShownKey)
        if moment == .trialEnded {
            UserDefaults.standard.set(true, forKey: trialEndedKey)
        }
        if moment == .trialEnding {
            UserDefaults.standard.set(true, forKey: trialEndingKey)
        }
        upsell = moment
        accountLogger.info("Abone olma teklifi gösteriliyor, an: \(moment.rawValue, privacy: .public)")
    }

    #if DEBUG
    /// Tanıtım modu (bkz. `DemoScene.upsell`): teklif sunucuya sorulmadan açılır.
    func showUpsellForDemo(moment: HostedUpsellMoment) {
        upsell = moment
    }

    /// Tanıtım modu: hak durumu ve davet bilgisi sunucuya sorulmadan yazılır (bkz. `App/DemoData.swift`).
    func showAccountForDemo(entitlements: HostedEntitlements, referral: HostedReferral?) {
        state = .signedIn(entitlements)
        self.referral = referral
    }
    #endif

    /// "Abone ol"a basıldı (Ayarlar › Hesap, kullanım bildirimi): planlar ana pencerede açılır. Deneme bittiyse ya da
    /// abonelik sona erdiyse teklif nedenini de söyler (`subscriptionRequired`).
    func showPlans() {
        upsell = requiresSubscription ? .subscriptionRequired : .planChoice
    }

    /// Ücretli özellikler (kayıt, Sor, not) için abone olmak gerekiyor mu: deneme bitti ya da abonelik sona erdi (aylık
    /// sınırın dolması abonelikle çözülmez; hak durumu bilinmiyorsa sunucu karar verir).
    var requiresSubscription: Bool {
        guard case .signedIn(let entitlements) = state, let block = hostedStartBlock(entitlements: entitlements) else {
            return false
        }
        switch block {
        case .trialEnded, .subscriptionEnded:
            return true
        case .monthlyCapReached:
            return false
        }
    }

    /// Kullanıcı abonelik gerektiren bir şey denedi (Başlat'a bastı) ama hakkı yok: abone olma teklifi hemen açılır.
    func requestSubscription() {
        lastSubscriptionPromptAt = Date()
        upsell = .subscriptionRequired
    }

    /// Abonelik gerektiren bir istek durdu ya da sunucu reddetti (bkz. `hostedSubscriptionRequired`): teklif en çok
    /// `hostedSubscriptionPromptIntervalSec`'te bir açılır (arka plandaki işler art arda açmasın); hak durumu yenilenir.
    func promptSubscriptionIfDue() {
        if let last = lastSubscriptionPromptAt, Date().timeIntervalSince(last) < hostedSubscriptionPromptIntervalSec {
            return
        }
        lastSubscriptionPromptAt = Date()
        upsell = .subscriptionRequired
        Task { await refresh() }
    }

    /// Teklifi kapatır. Deneme bitti teklifi görüldüyse aynı şeyi söyleyen şerit de kalkar (iki kez söylenmesin).
    func dismissUpsell() {
        if upsell == .trialEnded && visibleNotice == .trialEnded {
            visibleNotice = nil
        }
        upsell = nil
    }

    /// Bildirimi kapatır (bu dönemde yeniden gösterilmez).
    func dismissNotice() {
        visibleNotice = nil
    }

    /// Uygulama öne gelince hak durumunu yeniler: ödeme ya da portal sayfasından dönüldüyse hemen, değilse son okuma
    /// `hostedStaleRefreshIntervalSec`'ten eskiyse (kullanım göstergeleri, bildirimler ve başlat engeli eskimesin).
    private func refreshOnActivation() async {
        guard case .signedIn = state, !isRefreshing else {
            return
        }
        guard awaitingBillingReturn || isHostedRefreshDue(lastRefresh: lastRefreshAt, now: Date(), intervalSec: hostedStaleRefreshIntervalSec) else {
            return
        }
        let returnedFromBilling: Bool = awaitingBillingReturn
        awaitingBillingReturn = false
        // Kullanıcı uygulamaya döndü: ödeme sayfasının izlemesi (bkz. `watchCheckout`) durur, yerini aşağıdaki kısa
        // bekleme alır (uygulama zaten önde; 15 dk boyunca arka planda okuma sürmesin).
        if returnedFromBilling {
            stopCheckoutWatch()
        }
        await refresh()
        if returnedFromBilling {
            _ = await pollForSubscription(delays: hostedBillingReturnPollDelays)
        }
    }

    /// Abonelik görünene dek `delays` aralıklarıyla (sn) hak durumunu yeniler (Stripe bildirimi birkaç saniye
    /// gecikebilir; Başlat düğmesi uygulamaya yeniden geçmeyi beklemeden açılsın). Abonelik zaten görünüyorsa (ör.
    /// portaldan dönüş) hemen biter; görev iptal edilirse durur. Döner: abonelik göründü mü.
    private func pollForSubscription(delays: [Double]) async -> Bool {
        for delay in delays {
            guard case .signedIn(let entitlements) = state else {
                return false
            }
            switch hostedPlanStatus(entitlements: entitlements) {
            case .subscribed, .complimentary, .ending, .grace:
                return true
            case .trial, .expired:
                break
            }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch is CancellationError {
                return false
            } catch {
                accountLogger.error("Abonelik beklemesi bozuldu, hata: \(String(describing: error), privacy: .private)")
                return false
            }
            await refresh()
        }
        accountLogger.warning("Abonelik beklendi ama görünmedi, deneme: \(delays.count, privacy: .public)")
        return false
    }

    /// Ödeme sayfası tarayıcıda açıldı: kullanıcı uygulamaya dönmeden abonelik beklenir (en çok 15 dk, giderek seyrelen
    /// aralıklarla; bkz. `hostedCheckoutWatchDelays`); görününce uygulama öne gelir, kullanıcı tarayıcıdan geri dönmek
    /// zorunda kalmaz. Önceki izleme varsa durdurulur; kullanıcı uygulamaya dönünce de durur (bkz. `refreshOnActivation`).
    private func watchCheckout() {
        stopCheckoutWatch()
        checkoutWatch = Task { [weak self] in
            guard let self else {
                return
            }
            let subscribed: Bool = await self.pollForSubscription(delays: hostedCheckoutWatchDelays)
            // İptal edilen (yerine yenisi açılan) izleme, yenisinin referansını silmesin.
            if !Task.isCancelled {
                self.checkoutWatch = nil
            }
            if subscribed, !NSApp.isActive {
                accountLogger.info("Abonelik göründü, uygulama öne getiriliyor")
                NSApp.activate()
            }
        }
    }

    /// İstemcinin jetonundaki (oturumdaki) hesabın açık sunucu oturumları alanı: oturumlar o hesabın jetonuyla açılır
    /// ve kapatılır. Oturum yoksa `notSignedIn`.
    private func signedInOpenMeetingsDefaults(client: HostedClient) async throws -> UserDefaults {
        guard let userID = try await client.signedInUserID() else {
            throw HostedClientError.notSignedIn
        }
        return try hostedOpenMeetingsDefaults(userID: userID)
    }

    /// Ödeme sayfasının izlemesini durdurur (yoksa bir şey yapmaz).
    private func stopCheckoutWatch() {
        checkoutWatch?.cancel()
        checkoutWatch = nil
    }

    /// Ağ geri geldi: hak durumu bilinmiyorsa yeniden okunur, kapatılamamış sunucu oturumu kapatılır ve bekleyen
    /// (çevrimdışı) kayıtlar işlenmeye başlar.
    private func networkBecameAvailable() async {
        await retryUnknownStatus()
        await closeOrphanedMeeting()
        queueTrigger += 1
    }

    /// Hak durumu bilinmiyorsa (çevrimdışı açılış) yeniden okur; ağ geri gelince ve uygulama öne gelince çağrılır.
    private func retryUnknownStatus() async {
        guard case .signedInStatusUnknown = state, !isRefreshing else {
            return
        }
        accountLogger.info("Hak durumu yeniden okunuyor (bağlantı ya da uygulama etkinleşti)")
        await refresh()
    }

    // MARK: Giriş ve çıkış

    /// Seçilen sağlayıcıyla (Apple ya da Google) uygulama içi giriş penceresinde (ASWebAuthenticationSession) girer:
    /// yeni ham nonce üretilir, sitedeki giriş sayfası nonce'un SHA-256'sı ve sağlayıcıyla açılır, site doğrudan
    /// sağlayıcıya yönlendirir; giriş bitince site `com.senoldogan.ainotepad.hosted://auth/<apple|google>#idToken=…`
    /// adresine yönlendirir ve dönüş Launch Services'e uğramadan doğrudan bu pencereye gelir (başka bir uygulama ya da
    /// eski bir kopya dönüşü alamaz). Dönüş bu denemenin nonce'uyla eşleşirse varsa eski oturum kapatılır ve kimlik
    /// jetonu ham nonce'la sağlayıcının giriş ucuna gider. Kullanıcı pencereyi kapatırsa hata gösterilmez. (Developer ID
    /// ile dağıtılan uygulama Apple ile girişi kendisi yapamaz; giriş sitede yapılır.)
    func signIn(provider: HostedSignInProvider) async {
        defer { avatarRevision += 1 }
        guard pendingBrowserSignIn == nil else {
            return
        }
        errorMessage = nil
        let attempt: HostedBrowserSignInAttempt
        let page: URL
        do {
            attempt = try makeHostedBrowserSignInAttempt(now: Date())
            page = hostedBrowserSignInPage(siteBase: try HostedServices.siteBase(), nonceHash: hostedNonceHash(nonce: attempt.rawNonce), provider: provider)
        } catch {
            accountLogger.error("Giriş başlatılamadı, hata: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
            return
        }
        pendingBrowserSignIn = attempt
        pendingSignInProvider = provider
        defer {
            pendingBrowserSignIn = nil
            pendingSignInProvider = nil
            webSession = nil
        }
        accountLogger.info("Giriş penceresi açılıyor, sağlayıcı: \(provider.rawValue, privacy: .public)")
        let callbackURL: URL
        do {
            switch try await runWebSignIn(page: page) {
            case .canceled:
                accountLogger.info("Giriş penceresi kapatıldı")
                return
            case .callback(let url):
                callbackURL = url
                // Giriş varsayılan tarayıcıda (ör. Chrome penceresinde) bittiyse odak orada kalmasın: kullanıcı
                // doğrudan uygulamaya döner.
                NSApp.activate()
            }
        } catch {
            accountLogger.error("Giriş penceresi açılamadı, hata: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
            return
        }
        let callback: HostedBrowserSignInCallback
        do {
            callback = try resolveHostedBrowserCallback(url: callbackURL, pending: attempt, now: Date(), lifetimeSec: hostedBrowserSignInLifetimeSec)
        } catch {
            accountLogger.error("Giriş dönüşü reddedildi, hata: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
            return
        }
        let picture: URL?
        do {
            picture = try hostedIDTokenPicture(identityToken: callback.identityToken)
        } catch {
            // Avatar girişe engel değil: resim yerine küre görünür.
            accountLogger.warning("Profil resmi jetondan okunamadı, hata: \(String(describing: error), privacy: .private)")
            picture = nil
        }
        await perform { (client: HostedClient) async throws -> Void in
            try await endPreviousSession(client: client)
            switch callback.provider {
            case .apple:
                try await client.signInWithApple(identityToken: callback.identityToken, nonce: callback.rawNonce)
            case .google:
                try await client.signInWithGoogle(identityToken: callback.identityToken, nonce: callback.rawNonce)
            }
            if let userID = try await client.signedInUserID() {
                saveHostedAvatar(picture: picture, userId: userID)
            }
        }
    }

    /// Giriş penceresini açar ve dönüşü bekler. Pencere açılamazsa `HostedBrowserSignInError.sessionNotStarted`.
    private func runWebSignIn(page: URL) async throws -> HostedWebSignInOutcome {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HostedWebSignInOutcome, any Error>) -> Void in
            // Tamamlanma bir kez sürdürülür: başlatılamayan oturum da tamamlanma bildirebilir.
            let pending: OSAllocatedUnfairLock<CheckedContinuation<HostedWebSignInOutcome, any Error>?> = OSAllocatedUnfairLock(initialState: continuation)
            let finish: @Sendable (Result<HostedWebSignInOutcome, any Error>) -> Void = { (result: Result<HostedWebSignInOutcome, any Error>) -> Void in
                pending.withLock { (waiting: inout CheckedContinuation<HostedWebSignInOutcome, any Error>?) -> Void in
                    waiting?.resume(with: result)
                    waiting = nil
                }
            }
            // Tamamlanma bloğu `@Sendable` (ana aktöre bağlı değil): sistem onu arka plandaki XPC kuyruğunda çağırır;
            // bu sınıfın ana aktör bağlamını devralsaydı Swift'in yalıtım denetimi uygulamayı çökertirdi.
            let completion: @Sendable (URL?, (any Error)?) -> Void = { (url: URL?, error: (any Error)?) -> Void in
                if let url {
                    finish(.success(.callback(url)))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    finish(.success(.canceled))
                } else {
                    finish(.failure(HostedBrowserSignInError.sessionNotStarted(reason: error.map { String(describing: $0) } ?? "dönüş adresi yok")))
                }
            }
            let session: ASWebAuthenticationSession = ASWebAuthenticationSession(url: page, callback: .customScheme(hostedURLScheme), completionHandler: completion)
            session.presentationContextProvider = presenter
            // Tarayıcıdaki Apple ve Google oturumları kullanılabilsin (her girişte parola sorulmasın).
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            guard session.start() else {
                finish(.failure(HostedBrowserSignInError.sessionNotStarted(reason: "start() false döndü")))
                return
            }
        }
    }

    /// Çıkış: sunucuda oturum kapatılır, yerel oturum her durumda silinir. Sunucuya ulaşılamazsa (çevrimdışı) bu Mac'te
    /// çıkış yine yapılır ve bu söylenir: sunucudaki yenileme jetonu kullanılmadığı için en geç `REFRESH_TOKEN_DAYS`
    /// (60) gün içinde kendiliğinden geçersizleşir.
    func signOut() async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        // Süren hak durumu okuması çıkıştan sonra dönerse oturumu "giriş yapıldı" göstermesin.
        stateGeneration += 1
        referral = nil
        do {
            try await HostedServices.requireClient().signOut()
        } catch HostedClientError.network(let path, _) {
            accountLogger.warning("Çıkış sunucuya iletilemedi (ağ), yerelde yapıldı, yol: \(path, privacy: .public)")
            errorMessage = String(localized: "Bu Mac'te çıkış yapıldı. Sunucuya ulaşılamadı; sunucudaki oturum en geç 60 gün içinde kendiliğinden kapanır.")
        } catch let error as HostedAPIError {
            accountLogger.warning("Çıkış sunucuda reddedildi, yerelde yapıldı, kod: \(error.rawCode, privacy: .public), durum: \(error.status, privacy: .public)")
            errorMessage = String(localized: "Bu Mac'te çıkış yapıldı. Sunucuya ulaşılamadı; sunucudaki oturum en geç 60 gün içinde kendiliğinden kapanır.")
        } catch {
            accountLogger.error("Çıkış yapılamadı, hata: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
        }
        currentMeeting = nil
        clearHostedOfflinePermit()
        await refresh()
    }

    /// Hesabı ve sunucudaki tüm verilerini siler (bitmemiş abonelik Stripe'ta iptal edilir).
    func deleteAccount() async {
        stateGeneration += 1
        // Silinen hesabın açık oturum listesi (silmeden sonra oturum yoktur, hesap ondan önce okunur).
        let userID: String? = signedInUserIDCache
        await perform { (client: HostedClient) async throws -> Void in
            try await client.deleteAccount()
        }
        currentMeeting = nil
        clearHostedOfflinePermit()
        guard let userID else {
            return
        }
        do {
            clearHostedOpenMeetingIDs(defaults: try hostedOpenMeetingsDefaults(userID: userID))
        } catch {
            accountLogger.error("Silinen hesabın açık oturum listesi temizlenemedi, hata: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: Ödeme

    /// Seçilen planın Stripe Checkout'unu tarayıcıda açar (`referralCode`: doğrulanmış davet kodu, yoksa nil) ve
    /// abonelik görününce uygulamayı öne getirir (bkz. `watchCheckout`); bitmemiş abonelik varsa Müşteri Portalı açılır.
    /// Hata yoksa true; açılamadıysa false ve neden `errorMessage`'da (teklif açık kalır, neden orada görünür).
    func subscribe(plan: HostedBillingPlan, referralCode: String?) async -> Bool {
        #if DEBUG
        // Tanıtım modu sunucuya bağlanmaz ve Anahtar Zinciri'ni okumaz.
        if isDemoMode {
            return true
        }
        #endif
        await perform { (client: HostedClient) async throws -> Void in
            do {
                NSWorkspace.shared.open(try await client.checkoutURL(plan: plan, referralCode: referralCode))
                await self.markAwaitingBillingReturn()
                await self.watchCheckout()
            } catch let error as HostedAPIError where error.code == .subscriptionExists {
                NSWorkspace.shared.open(try await client.portalURL())
                await self.markAwaitingBillingReturn()
            }
        }
        return errorMessage == nil
    }

    /// Davet kodunu ödemeden önce sunucuya doğrulatır: biçimsiz kod sunucuya sorulmaz; geçerliyse sadeleşmiş kod,
    /// değilse kullanıcıya gösterilecek neden.
    func validateReferral(input: String) async -> HostedReferralCheck {
        let code: String = normalizedHostedReferralCode(input: input)
        guard isWellFormedHostedReferralCode(code: code) else {
            return .invalid(message: String(localized: "Davet kodu 8 karakterdir, ör. K7M2QX9D."))
        }
        #if DEBUG
        // Tanıtım modu sunucuya bağlanmaz: biçimi doğru kod geçerli sayılır.
        if isDemoMode {
            return .valid(code: code)
        }
        #endif
        do {
            return .valid(code: try await HostedServices.requireClient().validateReferral(code: code).code)
        } catch {
            accountLogger.warning("Davet kodu doğrulanmadı, hata: \(String(describing: error), privacy: .private)")
            return .invalid(message: userFacingMessage(error: error))
        }
    }

    /// Abonenin davet kodunu ve sayılarını okur (Ayarlar › Hesap açılınca). Abonelik erişimi yoksa ya da okunamazsa
    /// davet bölümü görünmez (hata loglanır; davet isteğe bağlıdır, hesap ekranını bozmaz).
    func loadReferral() async {
        #if DEBUG
        if isDemoMode {
            return
        }
        #endif
        guard case .signedIn(let entitlements) = state, let subscription = entitlements.subscription, subscription.access != .none else {
            referral = nil
            return
        }
        do {
            referral = try await HostedServices.requireClient().referral()
        } catch {
            accountLogger.error("Davet bilgisi okunamadı, hata: \(String(describing: error), privacy: .private)")
            referral = nil
        }
    }

    /// Stripe Müşteri Portalı (kart, iptal; makbuzlar Link'ten e-postayla gelir).
    func manageSubscription() async {
        await perform { (client: HostedClient) async throws -> Void in
            NSWorkspace.shared.open(try await client.portalURL())
            await self.markAwaitingBillingReturn()
        }
    }

    /// Ödeme ya da portal sayfası gerçekten açıldı: uygulamaya dönünce hak durumu beklemeden okunur (sayfa açılamadıysa
    /// boşuna yoklama başlamasın).
    private func markAwaitingBillingReturn() {
        awaitingBillingReturn = true
    }

    // MARK: Toplantı

    /// Kayıt başında kaydın sunucu oturumunu açar (deneme hakkı ya da abonelik süresi buradan düşer; `recordID` aynı
    /// kayıt için yinelenen başlatmanın aynı oturumu döndürmesini sağlar). Oturum açık kalırken kimliği saklanır (uygulama
    /// çökse de sonra kapatılır) ve kayıt oturuma bağlanır (son geçiş ve not o oturumla). Sunucuya ulaşılamazsa
    /// (bkz. `isOfflineStartError`) ve son bilinen hak durumu son 7 günde kayda izin verdiyse kayıt çevrimdışı sürer;
    /// yoksa ya da sunucu reddederse hata fırlar ve kayıt başlamaz.
    func startMeeting(recordID: String) async throws -> HostedMeetingStart {
        let client: HostedClient = try HostedServices.requireClient()
        // Ödeme sonrası eski "deneme" durumu DeviceCheck istemesin: deneme görünen hesapta durum önce tazelenir.
        if isKnownTrial {
            await refresh()
        }
        do {
            let started: HostedStartedMeeting = try await openServerMeeting(client: client, clientRef: recordID, deferred: false)
            currentMeeting = started
            isOfflineRecording = false
            addHostedOpenMeetingID(meetingID: started.meetingId, defaults: try await signedInOpenMeetingsDefaults(client: client))
            try saveHostedMeetingLink(link: HostedMeetingLink(recordID: recordID, serverMeetingID: started.meetingId, createdAt: Date()))
            accountLogger.info("Toplantı oturumu açıldı, en çok dakika: \(started.maxDurationMinutes, privacy: .public)")
            Task { await refresh() }
            return .online(started)
        } catch where isOfflineStartError(error: error) {
            let userID: String? = try await client.signedInUserID()
            guard let minutes = hostedOfflineRecordingMinutes(permit: loadHostedOfflinePermit(), userId: userID, now: Date(), maxAgeSec: hostedOfflinePermitMaxAgeSec) else {
                accountLogger.warning("Sunucuya ulaşılamadı; son hak durumu eski ya da izin vermiyor, kayıt başlatılmadı")
                throw HostedClientError.offlineNotAllowed
            }
            if let userID {
                saveHostedRecordOwner(recordID: recordID, userId: userID)
            }
            // Canlı istekler önceki toplantının bütçesine yazılmasın.
            await client.clearCurrentMeeting()
            currentMeeting = nil
            isOfflineRecording = true
            accountLogger.info("Sunucuya ulaşılamadı, kayıt çevrimdışı başlıyor, en çok dakika: \(minutes, privacy: .public)")
            return .offline(maxMinutes: minutes)
        }
    }

    /// Sunucuda oturum açar. App Attest destekleniyorsa onay eklenir. Apple DeviceCheck jetonu yalnızca hesabın deneme
    /// olduğu biliniyorsa gönderilir; sunucu `device_check_required` derse bir kez jetonla yinelenir (aboneler
    /// DeviceCheck'e hiç takılmaz). Jeton üretilemezse hata fırlar.
    /// `deferred`: sonradan işlenen kayıt (bekleyen, içe aktarılan); sunucu süren canlı toplantıyı kapatmaz.
    /// Sunucu bu Mac'te denemeyi reddederse (`trial_device_used`) bu hesap için hatırlanır ve hak durumu yenilenir: kenar
    /// çubuğu, Hesap kartı ve Başlat düğmesi "denemen yok, abone ol" der; Başlat bir daha sunucuya gitmez.
    private func openServerMeeting(client: HostedClient, clientRef: String, deferred: Bool) async throws -> HostedStartedMeeting {
        do {
            return try await requestServerMeeting(client: client, clientRef: clientRef, deferred: deferred)
        } catch let error as HostedAPIError where error.code == .trialDeviceUsed {
            if let userID = try await client.signedInUserID() {
                UserDefaults.standard.set(Date(), forKey: hostedTrialRefusedKey(userId: userID))
                accountLogger.info("Deneme bu Mac'te reddedildi (Mac denemesini başka hesapla kullandı); hesap için hatırlandı")
                Task { await refresh() }
            }
            throw error
        }
    }

    /// Toplantı oturumu isteği; sunucu DeviceCheck isterse jetonla bir kez yinelenir.
    private func requestServerMeeting(client: HostedClient, clientRef: String, deferred: Bool) async throws -> HostedStartedMeeting {
        let device: HostedDeviceAssertion? = await HostedDeviceAttestation.assertion(client: client, action: "meetings.start")
        // Jeton yalnızca bilinen denemede ve üretilebilirse gönderilir: Apple'a ulaşılamazsa ya da Mac desteklemiyorsa jetonsuz
        // denenir (denemenin 2. ve 3. toplantısı jeton istemez); sunucu isterse aşağıda jetonla yinelenir ve o zaman hata
        // kullanıcıya gösterilir.
        let deviceCheckToken: String?
        if isKnownTrial {
            do {
                deviceCheckToken = try await HostedDeviceCheck.token()
            } catch {
                accountLogger.warning("DeviceCheck jetonu üretilemedi, jetonsuz deneniyor, hata: \(String(describing: error), privacy: .private)")
                deviceCheckToken = nil
            }
        } else {
            deviceCheckToken = nil
        }
        do {
            return try await client.startMeeting(device: device, deviceCheckToken: deviceCheckToken, clientRef: clientRef, deferred: deferred)
        } catch let error as HostedAPIError where error.code == .deviceCheckRequired && deviceCheckToken == nil {
            accountLogger.info("Sunucu DeviceCheck istedi, jetonla bir kez yeniden deneniyor")
            // App Attest meydan okuması tek kullanımlık: yeniden denemede yeni onay.
            let retryDevice: HostedDeviceAssertion? = await HostedDeviceAttestation.assertion(client: client, action: "meetings.start")
            return try await client.startMeeting(device: retryDevice, deviceCheckToken: try await HostedDeviceCheck.token(), clientRef: clientRef, deferred: deferred)
        }
    }

    /// Kayıt bitince toplantı oturumunu kapatır; not ve son geçiş sunucunun ek süresinde aynı toplantıyla sürer.
    /// Kapatılamazsa oturum kimliği saklı kalır, ağ gelince ya da sonraki açılışta yeniden denenir (aylık süre boşuna
    /// akmasın). Her durumda hak durumu yenilenir (göstergeler güncel kalsın).
    func endMeeting(meetingID: String?) async throws {
        isOfflineRecording = false
        guard let meetingID else {
            return
        }
        defer { Task { await refresh() } }
        let client: HostedClient = try HostedServices.requireClient()
        do {
            let ended: HostedEndedMeeting = try await client.endMeeting(meetingID: meetingID)
            removeHostedOpenMeetingID(meetingID: meetingID, defaults: try await signedInOpenMeetingsDefaults(client: client))
            accountLogger.info("Toplantı oturumu kapandı, dakika: \(ended.minutes ?? 0, privacy: .public)")
        } catch {
            // Kapatılamadı: kimlik açık oturumlar listesinde kalır, yetim kapatma (ağ gelince, öne gelince, açılışta)
            // kapatır. "Şimdiki toplantı" yine bırakılır; yoksa yetim sayılmaz ve aylık süre en çok süreye kadar akardı.
            if shouldClearCurrentMeeting(currentMeetingID: currentMeeting?.meetingId, endedMeetingID: meetingID) {
                currentMeeting = nil
            }
            throw error
        }
        // Bu arada yeni kayıt başladıysa onun oturumuna dokunulmaz.
        if shouldClearCurrentMeeting(currentMeetingID: currentMeeting?.meetingId, endedMeetingID: meetingID) {
            currentMeeting = nil
        }
    }

    /// Oturumdaki hesabın kapatılamamış sunucu oturumlarını (uygulama çöktü, kapatma isteği başarısız oldu) kapatır; o
    /// oturumla kayıt sürüyorsa dokunmaz. Sunucu oturumu zaten kapalı ya da bilinmiyorsa kayıt silinir; ağ hatasında
    /// sonra yeniden denenir. Oturum yoksa bir şey yapmaz (başka hesapların listesi o hesap girince kapatılır).
    func closeOrphanedMeeting() async {
        let client: HostedClient
        let defaults: UserDefaults
        do {
            client = try HostedServices.requireClient()
            guard let userID = try await client.signedInUserID() else {
                return
            }
            defaults = try hostedOpenMeetingsDefaults(userID: userID)
        } catch {
            accountLogger.warning("Açık kalan toplantı oturumları okunamadı, sonra yeniden denenecek, hata: \(String(describing: error), privacy: .private)")
            return
        }
        migrateLegacyHostedOpenMeetingIDs(defaults: defaults)
        for meetingID in orphanedMeetingIDs(openIDs: loadHostedOpenMeetingIDs(defaults: defaults), recordingMeetingID: currentMeeting?.meetingId) {
            do {
                let ended: HostedEndedMeeting = try await client.endMeeting(meetingID: meetingID)
                removeHostedOpenMeetingID(meetingID: meetingID, defaults: defaults)
                accountLogger.info("Açık kalan toplantı oturumu kapatıldı, dakika: \(ended.minutes ?? 0, privacy: .public)")
            } catch let error as HostedAPIError where !isRetryableHostedError(error: error) {
                removeHostedOpenMeetingID(meetingID: meetingID, defaults: defaults)
                accountLogger.warning("Açık kalan toplantı oturumu sunucuda yok ya da kapalı, kod: \(error.rawCode, privacy: .public)")
            } catch {
                accountLogger.warning("Açık kalan toplantı oturumu kapatılamadı, sonra yeniden denenecek, hata: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Bekleyen kaydın (çevrimdışı kaydedilmiş ya da içe aktarılmış) sunucu oturumunu hazırlar. Kayıt daha önce bir oturuma bağlandıysa o kullanılır;
    /// yoksa oturum "ertelenmiş" açılır (sunucu hakları denetler, süren canlı kaydın oturumunu kapatmaz; `clientRef`
    /// yinelenen denemenin ikinci oturum açmasını önler), kayda bağlanır ve hemen kapatılır: toplantı süresi sayılmaz,
    /// aylık kullanıma sesin gerçek süresi yazılır (son geçiş); not ve son geçiş sunucunun ek süresinde (30 dk) bu
    /// oturumla üretilir. Bağlı oturumun ek süresi geçtiyse (önceki deneme yarıda kaldı) son geçiş planı oturumu yeniden
    /// işleme için açar (bkz. `hostedFinalPassPlan`).
    func prepareQueuedMeeting(recordID: String) async -> HostedQueuedMeetingPreparation {
        if case .signedIn(let entitlements) = state, hostedStartBlock(entitlements: entitlements) != nil, hostedServerMeetingIDOrNil(recordID: recordID) == nil {
            return .blocked(reason: queuedBlockReason(entitlements: entitlements))
        }
        do {
            let client: HostedClient = try HostedServices.requireClient()
            if let linked = hostedServerMeetingIDOrNil(recordID: recordID) {
                do {
                    _ = try await client.endMeeting(meetingID: linked)
                    accountLogger.info("Bekleyen kaydın bağlı sunucu oturumu hazır")
                    Task { await refresh() }
                    return .ready(serverMeetingID: linked)
                } catch let error as HostedAPIError where error.code == .notFound {
                    // Oturum sunucuda yok (temizlendi ya da başka hesabındı): bağ silinir, kayıt yeni oturum açar.
                    accountLogger.warning("Bekleyen kaydın bağlı oturumu sunucuda yok, bağ silindi")
                    try removeHostedMeetingLink(recordID: recordID)
                }
            }
            let started: HostedStartedMeeting = try await openServerMeeting(client: client, clientRef: recordID, deferred: true)
            let serverMeetingID: String = started.meetingId
            try saveHostedMeetingLink(link: HostedMeetingLink(recordID: recordID, serverMeetingID: serverMeetingID, createdAt: Date()))
            _ = try await client.endMeeting(meetingID: serverMeetingID)
            accountLogger.info("Çevrimdışı kaydın sunucu oturumu hazır")
            Task { await refresh() }
            return .ready(serverMeetingID: serverMeetingID)
        } catch where isOfflineStartError(error: error) {
            return .waitingForNetwork
        } catch {
            accountLogger.warning("Çevrimdışı kayıt sunucuda işlenemiyor, hata: \(String(describing: error), privacy: .private)")
            return .rejected(reason: userFacingMessage(error: error))
        }
    }

    /// İçe aktarılan kaydı oturumdaki kullanıcıya yazar (kuyruğa alınırken); oturum yoksa `notSignedIn`.
    func claimQueuedRecord(recordID: String) async throws {
        guard let userID = try await HostedServices.requireClient().signedInUserID() else {
            throw HostedClientError.notSignedIn
        }
        saveHostedRecordOwner(recordID: recordID, userId: userID)
    }

    /// Oturumdaki kullanıcı (Anahtar Zinciri'nden, ağsız); oturum yoksa nil.
    func signedInUserID() async throws -> String? {
        try await HostedServices.requireClient().signedInUserID()
    }

    /// Bekleyen kaydın şimdilik işlenememe nedeni (hak durumundan).
    private func queuedBlockReason(entitlements: HostedEntitlements) -> String {
        switch hostedStartBlock(entitlements: entitlements) {
        case .trialEnded:
            String(localized: "Ücretsiz denemen bittiği için bu toplantı işlenemedi. Ses bu Mac'te kalır; abone olunca kendiliğinden işlenir.")
        case .monthlyCapReached:
            String(localized: "Bu ayki kullanım sınırın dolduğu için bu toplantı işlenemedi. Ses bu Mac'te kalır; sınır sıfırlanınca kendiliğinden işlenir.")
        case .subscriptionEnded:
            String(localized: "Aboneliğin sona erdiği için bu toplantı işlenemedi. Ses bu Mac'te kalır; yeniden abone olunca kendiliğinden işlenir.")
        case .none:
            String(localized: "Bu toplantı şimdilik işlenemedi; kendiliğinden yeniden denenecek.")
        }
    }

    /// İşlemi çalıştırır, sonra durumu yeniler; hata kullanıcıya gösterilir.
    private func perform(operation: @escaping @Sendable (HostedClient) async throws -> Void) async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation(try HostedServices.requireClient())
        } catch {
            accountLogger.error("Hesap işlemi başarısız, hata: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
        }
        await refresh()
    }
}

/// Kayıt başında sunucu oturumunun sonucu.
enum HostedMeetingStart {
    /// Sunucu oturumu açıldı.
    case online(HostedStartedMeeting)
    /// Sunucuya ulaşılamadı; kayıt çevrimdışı, en çok bu kadar dakika (son bilinen hak durumundan).
    case offline(maxMinutes: Int)
}

/// Açık (kapatılamamış) sunucu oturumlarının anahtarı (uygulama çökse de sonra kapatılır). Liste oturumu açan hesabın
/// ayar alanındadır (bkz. `hostedOpenMeetingsDefaults`); önceki sürümlerde ortak ayarlardaydı.
private let hostedOpenMeetingsKey: String = "hosted.openMeetingIDs"
/// Çevrimdışı kayıt izninin UserDefaults anahtarı.
private let hostedOfflinePermitKey: String = "hosted.offlinePermit"

/// 0.1.4'ün tek açık oturum anahtarı: yeni listeye taşınır (bkz. `migrateLegacyHostedOpenMeetingIDs`).
private let legacyHostedOpenMeetingKey: String = "hosted.openMeetingID"

/// Hesabın açık sunucu oturumlarının tutulduğu ayar alanı (bkz. `hostedAccountDefaults`). Liste hesap başınadır:
/// başka bir hesapla giriş yapılınca önceki hesabın oturumları yeni hesabın jetonuyla kapatılmaya çalışılıp (sunucu
/// bulamaz) listeden düşmez; o hesap yeniden girince kapatılır.
private func hostedOpenMeetingsDefaults(userID: String) throws -> UserDefaults {
    try hostedAccountDefaults(accountKey: accountDataKey(userId: userID))
}

/// Önceki sürümlerin ortak ayarlardaki açık oturumlarını (liste ve 0.1.4'ün tek kaydı) oturumdaki hesabın listesine
/// katar ve eskilerini siler (yetim kapatma sonra kapatır). Başka bir hesabın oturumuysa sunucu bulamaz ve yetim kapatma
/// onu listeden siler (önceki davranış).
private func migrateLegacyHostedOpenMeetingIDs(defaults: UserDefaults) {
    let shared: [String] = UserDefaults.standard.stringArray(forKey: hostedOpenMeetingsKey) ?? []
    let legacy: String? = UserDefaults.standard.string(forKey: legacyHostedOpenMeetingKey)
    guard !shared.isEmpty || legacy != nil else {
        return
    }
    let merged: [String] = shared.reduce(loadHostedOpenMeetingIDs(defaults: defaults)) { (ids: [String], meetingID: String) -> [String] in
        addingOpenMeeting(ids: ids, meetingID: meetingID)
    }
    defaults.set(mergingLegacyOpenMeeting(ids: merged, legacy: legacy), forKey: hostedOpenMeetingsKey)
    UserDefaults.standard.removeObject(forKey: hostedOpenMeetingsKey)
    UserDefaults.standard.removeObject(forKey: legacyHostedOpenMeetingKey)
    accountLogger.info("Önceki sürümden kalan açık toplantı oturumları hesabın listesine taşındı, sayı: \(shared.count + (legacy == nil ? 0 : 1), privacy: .public)")
}

/// Hesabın saklanan açık sunucu oturumları (yoksa boş).
private func loadHostedOpenMeetingIDs(defaults: UserDefaults) -> [String] {
    defaults.stringArray(forKey: hostedOpenMeetingsKey) ?? []
}

/// Açık sunucu oturumunu hesabın listesine ekler.
private func addHostedOpenMeetingID(meetingID: String, defaults: UserDefaults) {
    defaults.set(addingOpenMeeting(ids: loadHostedOpenMeetingIDs(defaults: defaults), meetingID: meetingID), forKey: hostedOpenMeetingsKey)
}

/// Kapatılan oturumu hesabın listesinden çıkarır.
private func removeHostedOpenMeetingID(meetingID: String, defaults: UserDefaults) {
    defaults.set(removingOpenMeeting(ids: loadHostedOpenMeetingIDs(defaults: defaults), meetingID: meetingID), forKey: hostedOpenMeetingsKey)
}

private func clearHostedOpenMeetingIDs(defaults: UserDefaults) {
    defaults.removeObject(forKey: hostedOpenMeetingsKey)
}

/// Kaydın sunucu oturumu; bağ yoksa ya da bağlar okunamazsa nil (okunamazsa hata loglanır).
private func hostedServerMeetingIDOrNil(recordID: String) -> String? {
    do {
        return hostedServerMeetingID(recordID: recordID, links: try loadHostedMeetingLinks())
    } catch {
        accountLogger.error("Kayıt–oturum bağları okunamadı, hata: \(String(describing: error), privacy: .private)")
        return nil
    }
}

/// Çevrimdışı kayıt iznini saklar (nil: izin yok, saklı olan silinir).
private func saveHostedOfflinePermit(permit: HostedOfflinePermit?) {
    guard let permit else {
        clearHostedOfflinePermit()
        return
    }
    do {
        UserDefaults.standard.set(try JSONEncoder().encode(permit), forKey: hostedOfflinePermitKey)
    } catch {
        accountLogger.error("Çevrimdışı kayıt izni saklanamadı, hata: \(String(describing: error), privacy: .private)")
    }
}

/// Saklanan çevrimdışı kayıt izni; yoksa ya da bozuksa nil (bozuksa hata loglanır, izin yok sayılır).
func loadHostedOfflinePermit() -> HostedOfflinePermit? {
    guard let data = UserDefaults.standard.data(forKey: hostedOfflinePermitKey) else {
        return nil
    }
    do {
        return try JSONDecoder().decode(HostedOfflinePermit.self, from: data)
    } catch {
        accountLogger.error("Çevrimdışı kayıt izni okunamadı, hata: \(String(describing: error), privacy: .private)")
        return nil
    }
}

private func clearHostedOfflinePermit() {
    UserDefaults.standard.removeObject(forKey: hostedOfflinePermitKey)
}

/// Uygulama kapanırken oturumdaki hesabın (`userID`; yoksa bir şey yapılmaz) açık sunucu oturumlarını kapatmayı dener
/// (en çok 3 sn bekler; olmazsa sonraki açılışta kapatılır).
@MainActor
private func endOpenMeetingBeforeQuit(userID: String?) {
    guard let userID else {
        return
    }
    let defaults: UserDefaults
    do {
        defaults = try hostedOpenMeetingsDefaults(userID: userID)
    } catch {
        accountLogger.error("Kapanışta açık oturum listesi okunamadı, hata: \(String(describing: error), privacy: .private)")
        return
    }
    let meetingIDs: [String] = loadHostedOpenMeetingIDs(defaults: defaults)
    guard !meetingIDs.isEmpty else {
        return
    }
    let client: HostedClient
    switch HostedServices.client {
    case .success(let value):
        client = value
    case .failure(let error):
        accountLogger.error("Kapanışta sunucu bağlantısı yok, hata: \(String(describing: error), privacy: .private)")
        return
    }
    let done: DispatchSemaphore = DispatchSemaphore(value: 0)
    Task.detached {
        for meetingID in meetingIDs {
            do {
                _ = try await client.endMeeting(meetingID: meetingID)
                // Ana aktöre geçilmez: ana iş parçacığı aşağıda bu görevi bekliyor (geçseydi kapanış her seferinde 3 sn
                // takılırdı); UserDefaults iş parçacığı güvenlidir.
                removeHostedOpenMeetingID(meetingID: meetingID, defaults: defaults)
            } catch {
                accountLogger.warning("Kapanışta toplantı oturumu kapatılamadı, sonraki açılışta denenecek, hata: \(String(describing: error), privacy: .private)")
            }
        }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 3)
}
