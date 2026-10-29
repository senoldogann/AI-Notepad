import AINotepadCore
import AppKit
import Foundation
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

/// Uygulama boyunca tek sunucu bağlantısı; oturum Anahtar Zinciri'nde abonelik uygulamasının servis adıyla saklanır.
private func makeHostedClient(bundle: Bundle) -> Result<HostedClient, HostedClientError> {
    do {
        let client: HostedClient = HostedClient(
            baseURL: try hostedURL(bundle: bundle, key: "HostedAPIBase"),
            storage: HostedKeychainTokenStorage(service: hostedKeychainService)
        ) { () async -> Void in
            await MainActor.run {
                NotificationCenter.default.post(name: .hostedSessionEnded, object: nil)
            }
        }
        return .success(client)
    } catch let error as HostedClientError {
        accountLogger.error("Sunucu adresi geçersiz, hata: \(String(describing: error), privacy: .public)")
        return .failure(error)
    } catch {
        // `hostedURL` yalnızca `HostedClientError` fırlatır.
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
    /// Sunucu adresi ayarlanmamış ya da güvensiz: hesap kullanılamaz.
    case unavailable(message: String)
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
    /// Dönüşü beklenen tarayıcıda giriş denemesi (ham nonce yalnızca burada, bellekte; tek kullanımlık).
    private(set) var pendingBrowserSignIn: HostedBrowserSignInAttempt?
    /// Son başlatılan toplantının sınırları (kayıt panelinde ve Ayarlar'da gösterilir).
    private(set) var currentMeeting: HostedStartedMeeting?
    @ObservationIgnored private var sessionObserver: (any NSObjectProtocol)?

    private init() {
        sessionObserver = NotificationCenter.default.addObserver(forName: .hostedSessionEnded, object: nil, queue: .main) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.currentMeeting = nil
                self?.state = .signedOut
                self?.errorMessage = userFacingMessage(error: HostedClientError.sessionEnded)
            }
        }
    }

    /// Giriş yapılmış mı (hak durumu okunmuş olsun ya da olmasın).
    var isSignedIn: Bool {
        if case .signedIn = state {
            return true
        }
        return false
    }

    /// Son okunan hak durumu abonelik mi (erişimi olan abonelik ya da ek süre).
    private var isSubscribed: Bool {
        if case .signedIn(let entitlements) = state {
            return entitlements.plan == .subscription
        }
        return false
    }

    // MARK: Durum

    /// Oturumu ve hak durumunu sunucudan yeniden okur; App Attest destekleniyorsa cihaz önce doğrulanır (sessizce
    /// atlanır, bkz. `HostedDeviceAttestation`).
    func refresh() async {
        let client: HostedClient
        do {
            client = try HostedServices.requireClient()
        } catch {
            state = .unavailable(message: userFacingMessage(error: error))
            return
        }
        do {
            guard try await client.isSignedIn() else {
                state = .signedOut
                return
            }
            await HostedDeviceAttestation.prepare(client: client)
            state = .signedIn(try await client.entitlements())
        } catch HostedClientError.notSignedIn, HostedClientError.sessionEnded {
            state = .signedOut
        } catch {
            accountLogger.error("Hak durumu okunamadı, hata: \(String(describing: error), privacy: .public)")
            errorMessage = userFacingMessage(error: error)
            if state == .loading {
                state = .signedOut
            }
        }
    }

    // MARK: Giriş ve çıkış

    /// Tarayıcıda girişi başlatır: yeni ham nonce üretilir (önceki deneme geçersizleşir) ve sitedeki giriş sayfası
    /// nonce'un SHA-256'sıyla tarayıcıda açılır. Kullanıcı orada Apple ya da Google hesabını seçer; site uygulamayı
    /// `auth/<apple|google>#idToken=…` ile açar. (Developer ID ile dağıtılan uygulama Apple ile girişi kendisi yapamaz.)
    func startBrowserSignIn() {
        errorMessage = nil
        do {
            let attempt: HostedBrowserSignInAttempt = try makeHostedBrowserSignInAttempt(now: Date())
            let page: URL = hostedBrowserSignInPage(siteBase: try HostedServices.siteBase(), nonceHash: hostedNonceHash(nonce: attempt.rawNonce))
            pendingBrowserSignIn = attempt
            guard NSWorkspace.shared.open(page) else {
                pendingBrowserSignIn = nil
                accountLogger.error("Giriş sayfası açılamadı, adres: \(page.host() ?? "-", privacy: .public)")
                errorMessage = String(localized: "Tarayıcı açılamadı; varsayılan tarayıcını kontrol edip yeniden dene.")
                return
            }
            accountLogger.info("Tarayıcıda giriş başlatıldı")
        } catch {
            accountLogger.error("Tarayıcıda giriş başlatılamadı, hata: \(String(describing: error), privacy: .public)")
            errorMessage = userFacingMessage(error: error)
        }
    }

    /// Uygulamayı açan bağlantı (tarayıcıda girişin dönüşü): bekleyen denemeyle eşleşirse kimlik jetonu ve ham nonce
    /// sağlayıcının giriş ucuna gider. Deneme sonuç ne olursa olsun düşer (ikinci dönüş reddedilir); her ret hesap
    /// hatasında görünür.
    func handle(url: URL) async {
        let pending: HostedBrowserSignInAttempt? = pendingBrowserSignIn
        pendingBrowserSignIn = nil
        let callback: HostedBrowserSignInCallback
        do {
            callback = try resolveHostedBrowserCallback(url: url, pending: pending, now: Date(), lifetimeSec: hostedBrowserSignInLifetimeSec)
        } catch {
            accountLogger.error("Giriş dönüşü reddedildi, hata: \(String(describing: error), privacy: .public)")
            errorMessage = userFacingMessage(error: error)
            return
        }
        await perform { (client: HostedClient) async throws -> Void in
            switch callback.provider {
            case .apple:
                try await client.signInWithApple(identityToken: callback.identityToken, nonce: callback.rawNonce)
            case .google:
                try await client.signInWithGoogle(identityToken: callback.identityToken, nonce: callback.rawNonce)
            }
        }
    }

    /// Çıkış: sunucuda oturum kapatılır, yerel oturum silinir.
    func signOut() async {
        await perform { (client: HostedClient) async throws -> Void in
            try await client.signOut()
        }
        currentMeeting = nil
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
    /// ve kayıt başlamaz. App Attest destekleniyorsa onay eklenir. Abone olmayan (ya da hak durumu henüz okunmamış)
    /// hesapta Apple DeviceCheck jetonu da gönderilir: deneme bu Mac'e bağlanır; jeton üretilemezse kayıt başlamaz.
    func startMeeting() async throws -> HostedStartedMeeting {
        let client: HostedClient = try HostedServices.requireClient()
        let device: HostedDeviceAssertion? = await HostedDeviceAttestation.assertion(client: client, action: "meetings.start")
        let deviceCheckToken: String? = isSubscribed ? nil : try await HostedDeviceCheck.token()
        let started: HostedStartedMeeting = try await client.startMeeting(device: device, deviceCheckToken: deviceCheckToken)
        currentMeeting = started
        accountLogger.info("Toplantı oturumu açıldı, en çok dakika: \(started.maxDurationMinutes, privacy: .public)")
        Task { await refresh() }
        return started
    }

    /// Kayıt bitince toplantı oturumunu kapatır; not ve son geçiş sunucunun ek süresinde aynı toplantıyla sürer.
    func endMeeting() async throws {
        guard let meeting = currentMeeting else {
            return
        }
        let client: HostedClient = try HostedServices.requireClient()
        let ended: HostedEndedMeeting = try await client.endMeeting(meetingID: meeting.meetingId)
        currentMeeting = nil
        accountLogger.info("Toplantı oturumu kapandı, dakika: \(ended.minutes ?? 0, privacy: .public)")
        Task { await refresh() }
    }

    /// İşlemi çalıştırır, sonra durumu yeniler; hata kullanıcıya gösterilir.
    private func perform(operation: @escaping @Sendable (HostedClient) async throws -> Void) async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation(try HostedServices.requireClient())
        } catch {
            accountLogger.error("Hesap işlemi başarısız, hata: \(String(describing: error), privacy: .public)")
            errorMessage = userFacingMessage(error: error)
        }
        await refresh()
    }
}
