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
    /// Son başlatılan toplantının sınırları (kayıt panelinde ve Ayarlar'da gösterilir).
    private(set) var currentMeeting: HostedStartedMeeting?
    /// Ana penceredeki kullanım bildirimi (%80, %100, son deneme toplantısı, deneme bitti). Her biri dönem başına bir
    /// kez gösterilir (UserDefaults'ta `hostedNoticeStorageKey` ile işaretlenir); kapatılınca ya da durum değişince kalkar.
    private(set) var visibleNotice: HostedUsageNotice?
    @ObservationIgnored private var isRefreshing: Bool = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Ağ geri gelince hak durumu yeniden okunur (bkz. `retryUnknownStatus`).
    @ObservationIgnored private let pathMonitor: NWPathMonitor = NWPathMonitor()
    /// Açık giriş penceresi: oturum bitene dek tutulmalı (yoksa sistem pencereyi kapatır).
    @ObservationIgnored private var webSession: ASWebAuthenticationSession?
    @ObservationIgnored private let presenter: HostedWebSignInPresenter = HostedWebSignInPresenter()

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: .hostedSessionEnded, object: nil, queue: .main) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.currentMeeting = nil
                self?.state = .signedOut
                self?.errorMessage = userFacingMessage(error: HostedClientError.sessionEnded)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                Task { await self.retryUnknownStatus() }
            }
        })
        pathMonitor.pathUpdateHandler = { [weak self] (path: NWPath) -> Void in
            guard path.status == .satisfied else {
                return
            }
            Task { @MainActor in
                await self?.retryUnknownStatus()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.senoldogan.AINotepad.hosted.path"))
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
        isRefreshing = true
        defer { isRefreshing = false }
        let client: HostedClient
        let hasSession: Bool
        do {
            client = try HostedServices.requireClient()
            hasSession = try await client.isSignedIn()
        } catch {
            accountLogger.error("Hesap okunamadı, hata: \(String(describing: error), privacy: .private)")
            state = .unavailable(message: userFacingMessage(error: error))
            return
        }
        guard hasSession else {
            state = .signedOut
            return
        }
        do {
            await HostedDeviceAttestation.prepare(client: client)
            let entitlements: HostedEntitlements = try await client.entitlements()
            state = .signedIn(entitlements)
            updateNotice(entitlements: entitlements, now: Date())
        } catch HostedClientError.notSignedIn, HostedClientError.sessionEnded {
            state = .signedOut
        } catch {
            accountLogger.error("Hak durumu okunamadı, hata: \(String(describing: error), privacy: .private)")
            let message: String = userFacingMessage(error: error)
            if case .signedIn = state {
                errorMessage = message
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
        let key: String = hostedNoticeStorageKey(notice: notice, userId: entitlements.userId, now: now)
        guard !UserDefaults.standard.bool(forKey: key) else {
            visibleNotice = nil
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        visibleNotice = notice
        accountLogger.info("Kullanım bildirimi gösteriliyor, tür: \(notice.rawValue, privacy: .public)")
    }

    /// Bildirimi kapatır (bu dönemde yeniden gösterilmez).
    func dismissNotice() {
        visibleNotice = nil
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

    /// Girişi uygulama içi giriş penceresinde (ASWebAuthenticationSession) yapar: yeni ham nonce üretilir, sitedeki
    /// giriş sayfası nonce'un SHA-256'sıyla açılır; kullanıcı Apple ya da Google hesabını seçer, site
    /// `com.senoldogan.ainotepad.hosted://auth/<apple|google>#idToken=…` adresine yönlendirir ve dönüş Launch Services'e
    /// uğramadan doğrudan bu pencereye gelir (başka bir uygulama ya da eski bir kopya dönüşü alamaz). Dönüş bu denemenin
    /// nonce'uyla eşleşirse varsa eski oturum kapatılır ve kimlik jetonu ham nonce'la sağlayıcının giriş ucuna gider.
    /// Kullanıcı pencereyi kapatırsa hata gösterilmez. (Developer ID ile dağıtılan uygulama Apple ile girişi kendisi
    /// yapamaz; giriş sitede yapılır.)
    func signIn() async {
        guard pendingBrowserSignIn == nil else {
            return
        }
        errorMessage = nil
        let attempt: HostedBrowserSignInAttempt
        let page: URL
        do {
            attempt = try makeHostedBrowserSignInAttempt(now: Date())
            page = hostedBrowserSignInPage(siteBase: try HostedServices.siteBase(), nonceHash: hostedNonceHash(nonce: attempt.rawNonce))
        } catch {
            accountLogger.error("Giriş başlatılamadı, hata: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
            return
        }
        pendingBrowserSignIn = attempt
        defer {
            pendingBrowserSignIn = nil
            webSession = nil
        }
        accountLogger.info("Giriş penceresi açılıyor")
        let callbackURL: URL
        do {
            switch try await runWebSignIn(page: page) {
            case .canceled:
                accountLogger.info("Giriş penceresi kapatıldı")
                return
            case .callback(let url):
                callbackURL = url
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
        await perform { (client: HostedClient) async throws -> Void in
            try await endPreviousSession(client: client)
            switch callback.provider {
            case .apple:
                try await client.signInWithApple(identityToken: callback.identityToken, nonce: callback.rawNonce)
            case .google:
                try await client.signInWithGoogle(identityToken: callback.identityToken, nonce: callback.rawNonce)
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
            let session: ASWebAuthenticationSession = ASWebAuthenticationSession(url: page, callback: .customScheme(hostedURLScheme)) { (url: URL?, error: (any Error)?) -> Void in
                if let url {
                    finish(.success(.callback(url)))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    finish(.success(.canceled))
                } else {
                    finish(.failure(HostedBrowserSignInError.sessionNotStarted(reason: error.map { String(describing: $0) } ?? "dönüş adresi yok")))
                }
            }
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
        await refresh()
    }

    /// Hesabı ve sunucudaki tüm verilerini siler (bitmemiş abonelik Stripe'ta iptal edilir).
    func deleteAccount() async {
        await perform { (client: HostedClient) async throws -> Void in
            try await client.deleteAccount()
        }
        currentMeeting = nil
    }

    // MARK: Ödeme

    /// Stripe Checkout'u tarayıcıda açar; bitmemiş abonelik varsa Müşteri Portalı açılır.
    func subscribe() async {
        await perform { (client: HostedClient) async throws -> Void in
            do {
                NSWorkspace.shared.open(try await client.checkoutURL())
            } catch let error as HostedAPIError where error.code == .subscriptionExists {
                NSWorkspace.shared.open(try await client.portalURL())
            }
        }
    }

    /// Stripe Müşteri Portalı (kart, fatura, iptal).
    func manageSubscription() async {
        await perform { (client: HostedClient) async throws -> Void in
            NSWorkspace.shared.open(try await client.portalURL())
        }
    }

    // MARK: Toplantı

    /// Kayıt başında toplantı oturumu açar (deneme hakkı ya da abonelik buradan düşer); reddedilirse hata fırlatılır
    /// ve kayıt başlamaz. App Attest destekleniyorsa onay eklenir. Apple DeviceCheck jetonu yalnızca hesabın deneme
    /// olduğu biliniyorsa gönderilir; hak durumu bilinmiyorsa jetonsuz denenir ve sunucu `device_check_required`
    /// derse bir kez jetonla yinelenir (aboneler DeviceCheck'e hiç takılmaz). Jeton üretilemezse kayıt başlamaz.
    func startMeeting() async throws -> HostedStartedMeeting {
        let client: HostedClient = try HostedServices.requireClient()
        let device: HostedDeviceAssertion? = await HostedDeviceAttestation.assertion(client: client, action: "meetings.start")
        let deviceCheckToken: String? = isKnownTrial ? try await HostedDeviceCheck.token() : nil
        let started: HostedStartedMeeting
        do {
            started = try await client.startMeeting(device: device, deviceCheckToken: deviceCheckToken)
        } catch let error as HostedAPIError where error.code == .deviceCheckRequired && deviceCheckToken == nil {
            accountLogger.info("Sunucu DeviceCheck istedi, jetonla bir kez yeniden deneniyor")
            // App Attest meydan okuması tek kullanımlık: yeniden denemede yeni onay.
            let retryDevice: HostedDeviceAssertion? = await HostedDeviceAttestation.assertion(client: client, action: "meetings.start")
            started = try await client.startMeeting(device: retryDevice, deviceCheckToken: try await HostedDeviceCheck.token())
        }
        currentMeeting = started
        accountLogger.info("Toplantı oturumu açıldı, en çok dakika: \(started.maxDurationMinutes, privacy: .public)")
        Task { await refresh() }
        return started
    }

    /// Kayıt bitince toplantı oturumunu kapatır; not ve son geçiş sunucunun ek süresinde aynı toplantıyla sürer.
    /// Kapatma başarısız olsa da hak durumu yenilenir (göstergeler güncel kalsın).
    func endMeeting() async throws {
        guard let meeting = currentMeeting else {
            return
        }
        defer { Task { await refresh() } }
        let client: HostedClient = try HostedServices.requireClient()
        let ended: HostedEndedMeeting = try await client.endMeeting(meetingID: meeting.meetingId)
        currentMeeting = nil
        accountLogger.info("Toplantı oturumu kapandı, dakika: \(ended.minutes ?? 0, privacy: .public)")
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
