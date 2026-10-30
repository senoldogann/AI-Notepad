import Foundation
import os

private let hostedLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Hosted")

/// Sunucu isteği başına en çok deneme.
private let hostedAttempts: Int = 3

/// Kısa JSON isteklerinin zaman aşımı.
private let hostedRequestTimeoutSec: Double = 30

// Sunucunun beklediği gövdeler (alan adları sunucununkilerdir).
/// Apple ve Google ile giriş: kimlik jetonu ve ham nonce.
private struct IdentityTokenSignInBody: Encodable {
    let identityToken: String
    let nonce: String
}

private struct RefreshBody: Encodable {
    let refreshToken: String
}

/// Toplantı başlatma: App Attest onayı, Apple DeviceCheck jetonu (base64) ve istemcinin kayıt kimliği (`clientRef`:
/// aynı kayıt için yinelenen başlatma sunucuda aynı oturumu döndürür, deneme hakkı ya da süre iki kez düşmez); nil
/// alanlar gövdeye yazılmaz.
private struct MeetingStartBody: Encodable {
    let device: HostedDeviceAssertion?
    let deviceCheckToken: String?
    let clientRef: String
    /// Sonradan işlenen kayıt: sunucu açık toplantıyı (süren canlı kaydı) kapatmaz. Yalnızca `true` iken yazılır
    /// (nil gövdeye yazılmaz): alanı bilmeyen eski sunucu canlı kaydın başlatmasını reddetmesin.
    let deferred: Bool?
}

/// Toplantı başlatma gövdesi: `deferred` yalnızca `true` iken yazılır (eski sunucu bilinmeyen alanı reddeder).
func meetingStartBody(device: HostedDeviceAssertion?, deviceCheckToken: String?, clientRef: String, deferred: Bool) throws -> Data {
    try JSONEncoder().encode(MeetingStartBody(device: device, deviceCheckToken: deviceCheckToken, clientRef: clientRef, deferred: deferred ? true : nil))
}

private struct DeviceChallengeBody: Encodable {
    let purpose: String
}

private struct DeviceAttestBody: Encodable {
    let keyId: String
    let attestation: String
    let challenge: String
}

/// `POST /v1/transcribe` adresi: dil (sabitse) ve konuşmacı ayırma açık. Anahtar terimler adrese değil
/// `x-keyterms` başlığına yazılır (bkz. `hostedKeytermsHeader`): adresler vekil ve sunucu loglarında kalabilir. Saf
/// fonksiyondur.
public func hostedTranscribeURL(baseURL: URL, languageCode: String?) -> URL {
    let items: [URLQueryItem] = (languageCode.map { [URLQueryItem(name: "language_code", value: $0)] } ?? [])
        + [URLQueryItem(name: "diarize", value: "true")]
    return baseURL.appending(path: "v1/transcribe").appending(queryItems: items)
}

/// Anahtar terimler başlığı (`x-keyterms`): terimlerin UTF-8 JSON dizisinin dolgusuz base64url'i; terim yoksa nil
/// (başlık gönderilmez). Saf fonksiyondur.
public func hostedKeytermsHeader(keyterms: [String]) throws -> String? {
    guard !keyterms.isEmpty else {
        return nil
    }
    let json: Data = try JSONEncoder().encode(keyterms)
    return json.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Abonelik sunucusunun bağlantısı: oturum (Anahtar Zinciri'nde), jeton yenileme, hak durumu, toplantı oturumu, ödeme,
/// cihaz doğrulama ve ses yükleme. Jetonlar ve içerik loglanmaz.
///
/// Yenileme tek uçuşludur: aynı anda gelen istekler tek yenilemeyi bekler (yenileme jetonu iki kez gönderilirse sunucu
/// bunu çalınma sayar ve tüm oturumları kapatır). Sunucu yenilemeyi 401 ile reddederse yerel oturum silinir ve
/// `onSessionEnded` çağrılır.
public actor HostedClient: HostedLLMCredentialSource {
    public nonisolated let baseURL: URL
    /// Her isteğe eklenen sürüm başlıkları (bkz. `HostedClientInfo`).
    public nonisolated let clientInfo: HostedClientInfo
    private let storage: any HostedTokenStorage
    private let onSessionEnded: @Sendable () async -> Void
    private var cachedTokens: HostedTokens?
    private var tokensLoaded: Bool = false
    private var refreshTask: Task<HostedTokens, any Error>?
    /// Oturumun kuşağı: giriş, çıkış, hesap silme ve yenileme reddinde artar (bkz. `isCurrentSessionGeneration`).
    private var sessionGeneration: Int = 0
    /// Yapay zekâ çağrılarının bağlandığı toplantı: son başlatılan (bittikten sonra da ek süre boyunca kullanılır).
    private var meetingID: String?
    /// Doğrulanmış App Attest anahtarı (base64); `/v1/me` cihazın deneme hakkını da göstersin diye gönderilir.
    private var deviceKeyID: String?

    public init(clientInfo: HostedClientInfo, baseURL: URL, storage: any HostedTokenStorage, onSessionEnded: @escaping @Sendable () async -> Void) {
        self.clientInfo = clientInfo
        self.baseURL = baseURL
        self.storage = storage
        self.onSessionEnded = onSessionEnded
    }

    // MARK: Oturum

    /// Kayıtlı oturum var mı.
    public func isSignedIn() throws -> Bool {
        try tokens() != nil
    }

    /// Apple ile giriş: kimlik jetonu ve Apple'a SHA-256'sı verilen ham nonce.
    public func signInWithApple(identityToken: String, nonce: String) async throws {
        try await startSession(path: "/v1/auth/apple", body: try encoded(body: IdentityTokenSignInBody(identityToken: identityToken, nonce: nonce)))
    }

    /// Google ile giriş: sitenin döndürdüğü Google kimlik jetonu ve SHA-256'sı giriş sayfasına verilen ham nonce.
    public func signInWithGoogle(identityToken: String, nonce: String) async throws {
        try await startSession(path: "/v1/auth/google", body: try encoded(body: IdentityTokenSignInBody(identityToken: identityToken, nonce: nonce)))
    }

    /// Çıkış: sunucuda oturum ailesi kapatılır, yerel oturum her durumda silinir; sunucuya ulaşılamadıysa hata
    /// silmeden sonra fırlatılır.
    public func signOut() async throws {
        guard let current = try tokens() else {
            return
        }
        meetingID = nil
        // Süren yenileme bu oturumu geri yazmasın.
        sessionGeneration += 1
        var logoutError: (any Error)?
        do {
            _ = try await send(path: "/v1/auth/logout", isRetryable: isRetryableRepeatableRequest, request: try jsonRequest(
                path: "/v1/auth/logout", method: "POST", body: try encoded(body: RefreshBody(refreshToken: current.refreshToken)), accessToken: nil, timeoutSec: hostedRequestTimeoutSec
            ))
        } catch let error as HostedAPIError where error.status == 401 {
            hostedLogger.info("Çıkış: oturum sunucuda zaten kapalı, kod: \(error.rawCode, privacy: .public)")
        } catch {
            logoutError = error
        }
        try setTokens(nil)
        hostedLogger.info("Çıkış yapıldı")
        if let logoutError {
            throw logoutError
        }
    }

    /// Hesabı siler (`DELETE /v1/me`, tekrarı zararsız) ve yerel oturumu kaldırır.
    public func deleteAccount() async throws {
        _ = try await authorized(path: "/v1/me", method: "DELETE", body: nil, isRetryable: isRetryableRepeatableRequest)
        meetingID = nil
        sessionGeneration += 1
        try setTokens(nil)
        hostedLogger.info("Hesap silindi")
    }

    // MARK: Haklar, toplantı, ödeme

    /// `GET /v1/me`.
    public func entitlements() async throws -> HostedEntitlements {
        try decode(HostedEntitlements.self, data: try await authorized(path: "/v1/me", method: "GET", body: nil, isRetryable: isRetryableRepeatableRequest), path: "/v1/me")
    }

    /// Toplantı oturumu açar; reddedilirse (`trial_exhausted`, `trial_device_used`, `monthly_cap_reached`…)
    /// `HostedAPIError`. `deviceCheckToken` (Apple DeviceCheck, base64) denemesi henüz bir Mac'e bağlanmamış hesabın
    /// deneme toplantısında gerekir. Açılan toplantı yapay zekâ çağrılarının toplantısı olur.
    public func startMeeting(device: HostedDeviceAssertion?, deviceCheckToken: String?, clientRef: String, deferred: Bool) async throws -> HostedStartedMeeting {
        let path: String = "/v1/meetings/start"
        let body: Data = try meetingStartBody(device: device, deviceCheckToken: deviceCheckToken, clientRef: clientRef, deferred: deferred)
        let started: HostedStartedMeeting = try decode(
            HostedStartedMeeting.self,
            data: try await authorized(path: path, method: "POST", body: body, isRetryable: isRetryableOneShotRequest),
            path: path
        )
        meetingID = started.meetingId
        hostedLogger.info("Toplantı oturumu açıldı, tür: \(started.kind, privacy: .public), en çok dakika: \(started.maxDurationMinutes, privacy: .public)")
        return started
    }

    /// Ek süresi geçmiş toplantıyı yeniden işleme için açar (`POST /v1/meetings/{id}/reprocess`): son geçiş kaydın
    /// kullanılmamış ses hakkıyla, toplantı kapsamlı yapay zekâ kendi bütçesiyle bir süre daha kullanılabilir. Toplantı
    /// zaten açıksa hak harcanmaz. Sınır dolduysa `reprocess_limit_reached`.
    public func reprocessMeeting(meetingID: String) async throws -> HostedReprocessedMeeting {
        let path: String = "/v1/meetings/\(meetingID)/reprocess"
        return try decode(HostedReprocessedMeeting.self, data: try await authorized(path: path, method: "POST", body: nil, isRetryable: isRetryableRepeatableRequest), path: path)
    }

    /// Toplantıyı bitirir; not ve son geçiş sunucunun ek süresi boyunca aynı toplantıyla sürer.
    public func endMeeting(meetingID ended: String) async throws -> HostedEndedMeeting {
        let path: String = "/v1/meetings/\(ended)/end"
        return try decode(HostedEndedMeeting.self, data: try await authorized(path: path, method: "POST", body: nil, isRetryable: isRetryableRepeatableRequest), path: path)
    }

    /// Yapay zekâ çağrılarının toplantısını bırakır (çevrimdışı kayıt başladı): canlı istekler önceki bir toplantının
    /// bütçesine yazılmasın.
    public func clearCurrentMeeting() {
        meetingID = nil
    }

    /// Oturumun kullanıcı kimliği (Anahtar Zinciri'nden; ağsız); oturum yoksa nil.
    public func signedInUserID() throws -> String? {
        try tokens()?.userId
    }

    /// Yapay zekâ çağrılarının toplantısı; yoksa nil.
    public func currentMeetingID() -> String? {
        meetingID
    }

    /// Seçilen planın Stripe Checkout adresi; `referralCode` doğrulanmış davet kodudur (yoksa nil). Bitmemiş abonelik
    /// varsa `subscription_exists`; davet kodu geçersizse `referral_*`.
    public func checkoutURL(plan: HostedBillingPlan, referralCode: String?) async throws -> URL {
        let path: String = "/v1/billing/checkout"
        let body: Data = try encoded(body: HostedCheckoutBody(plan: plan, referralCode: referralCode))
        return try decode(HostedURLResponse.self, data: try await authorized(path: path, method: "POST", body: body, isRetryable: isRetryableRepeatableRequest), path: path).url
    }

    /// `GET /v1/referral`: abonenin davet kodu ve davet sayıları.
    public func referral() async throws -> HostedReferral {
        let path: String = "/v1/referral"
        return try decode(HostedReferral.self, data: try await authorized(path: path, method: "GET", body: nil, isRetryable: isRetryableRepeatableRequest), path: path)
    }

    /// Davet kodunu ödemeden önce sunucuya doğrulatır; geçerliyse sadeleşmiş kodu döndürür, değilse `referral_*`.
    public func validateReferral(code: String) async throws -> HostedReferralValidation {
        let path: String = "/v1/referral/validate"
        let body: Data = try encoded(body: HostedReferralValidateBody(code: code))
        return try decode(HostedReferralValidation.self, data: try await authorized(path: path, method: "POST", body: body, isRetryable: isRetryableRepeatableRequest), path: path)
    }

    /// Stripe Müşteri Portalı adresi.
    public func portalURL() async throws -> URL {
        let path: String = "/v1/billing/portal"
        return try decode(HostedURLResponse.self, data: try await authorized(path: path, method: "POST", body: nil, isRetryable: isRetryableRepeatableRequest), path: path).url
    }

    // MARK: Cihaz doğrulama

    /// App Attest meydan okuması (`attest` ya da `assert`).
    public func deviceChallenge(purpose: String) async throws -> HostedDeviceChallenge {
        let path: String = "/v1/device/challenge"
        return try decode(
            HostedDeviceChallenge.self,
            data: try await authorized(path: path, method: "POST", body: try encoded(body: DeviceChallengeBody(purpose: purpose)), isRetryable: isRetryableRepeatableRequest),
            path: path
        )
    }

    /// App Attest anahtarını sunucuya kaydeder (tek seferlik).
    public func attestDevice(keyID: String, attestation: String, challenge: String) async throws {
        let body: Data = try encoded(body: DeviceAttestBody(keyId: keyID, attestation: attestation, challenge: challenge))
        _ = try await authorized(path: "/v1/device/attest", method: "POST", body: body, isRetryable: isRetryableOneShotRequest)
    }

    /// Doğrulanmış cihaz anahtarı (yoksa nil); `/v1/me` isteklerinde gönderilir.
    public func setDeviceKeyID(keyID: String?) {
        deviceKeyID = keyID
    }

    // MARK: Ses ve yapay zekâ

    /// 16 kHz mono 16 bit FLAC dosyasını (`writeHostedFlacChunks`) `/v1/transcribe`'a ham gövde olarak gönderir
    /// (`audio/flac`; sunucu süreyi STREAMINFO'dan okur); ElevenLabs yanıtının JSON'unu döndürür.
    /// `uploadKey`: parçanın yükleme anahtarı (32 bayt base64url; parçanın her yeniden denemesinde aynı): yanıt yolda
    /// kaybolursa sunucu sesi yeniden işlemeden ve faturalamadan aynı sonucu döndürür.
    public func transcribe(meetingID: String, flacFile: URL, languageCode: String?, keyterms: [String], uploadKey: String, timeoutSec: Double) async throws -> Data {
        let path: String = "/v1/transcribe"
        let url: URL = hostedTranscribeURL(baseURL: baseURL, languageCode: languageCode)
        let keytermsHeader: String? = try hostedKeytermsHeader(keyterms: keyterms)
        let attempt: @Sendable (String) async throws -> (Data, URLResponse) = { [clientInfo] (accessToken: String) async throws -> (Data, URLResponse) in
            var request: URLRequest = withHostedClientHeaders(request: URLRequest(url: url), info: clientInfo)
            request.httpMethod = "POST"
            request.timeoutInterval = timeoutSec
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
            request.setValue(meetingID, forHTTPHeaderField: "x-meeting-id")
            request.setValue("audio/flac", forHTTPHeaderField: "content-type")
            request.setValue(uploadKey, forHTTPHeaderField: "x-upload-key")
            if let keytermsHeader {
                request.setValue(keytermsHeader, forHTTPHeaderField: "x-keyterms")
            }
            return try await URLSession.shared.upload(for: request, fromFile: flacFile)
        }
        return try await authorizedOperation(path: path, isRetryable: isRetryableRepeatableRequest, operation: attempt)
    }

    /// Açık toplantı için tek bağlantılık kısa ömürlü Deepgram jetonu (`POST /v1/live/deepgram-token`). Sunucu
    /// reddederse (`deepgram_unavailable`, `deepgram_grant_limit`, `meeting_not_active`) `HostedAPIError`. Jeton
    /// loglanmaz ve saklanmaz.
    public func deepgramGrant(meetingID: String) async throws -> HostedDeepgramGrant {
        let path: String = "/v1/live/deepgram-token"
        let attempt: @Sendable (String) async throws -> (Data, URLResponse) = { [baseURL, clientInfo] (accessToken: String) async throws -> (Data, URLResponse) in
            var request: URLRequest = withHostedClientHeaders(
                request: try hostedJSONRequest(baseURL: baseURL, path: path, method: "POST", body: nil, accessToken: accessToken, timeoutSec: hostedRequestTimeoutSec), info: clientInfo
            )
            request.setValue(meetingID, forHTTPHeaderField: "x-meeting-id")
            return try await URLSession.shared.data(for: request)
        }
        return try decode(HostedDeepgramGrant.self, data: try await authorizedOperation(path: path, isRetryable: isRetryableRepeatableRequest, operation: attempt), path: path)
    }

    // MARK: Telemetri

    /// Güvenilirlik ve süre olaylarını gönderir (`POST /v1/telemetry`, gövde `hostedTelemetryEventsBody`). Sunucu
    /// toplamlara ekler: tekrar iki kez sayabileceği için yalnızca işlenmediği kesin hatalar yeniden denenir.
    public func sendTelemetryEvents(body: Data) async throws {
        _ = try await authorized(path: "/v1/telemetry", method: "POST", body: body, isRetryable: isRetryableOneShotRequest)
    }

    /// Bir günün özellik kullanımını gönderir (`POST /v1/telemetry/features`, gövde `hostedFeatureUsageBody`). Sunucu
    /// hesap başına günü bir kez sayar (tekrarı zararsız); o gün zaten sayıldıysa false döner.
    public func sendFeatureUsage(body: Data) async throws -> Bool {
        let path: String = "/v1/telemetry/features"
        return try decode(HostedFeatureUsageResponse.self, data: try await authorized(path: path, method: "POST", body: body, isRetryable: isRetryableRepeatableRequest), path: path).counted
    }

    /// Erişim jetonunu süresine bakmadan yeniler (yapay zekâ çağrısı 401 aldıysa; tek uçuşlu).
    public func refreshAccessToken() async throws {
        _ = try await refreshedTokens()
    }

    /// Toplantıya bağlı yapay zekâ çağrısının jetonu ve toplantısı.
    public func meetingLLMCredentials() async throws -> HostedLLMCredentials {
        guard let meetingID else {
            throw HostedClientError.noActiveMeeting
        }
        return HostedLLMCredentials(accessToken: try await validAccessToken(), meetingID: meetingID)
    }

    // MARK: Jetonlar

    /// Geçerli erişim jetonu; bitmek üzereyse önce yenilenir.
    public func validAccessToken() async throws -> String {
        switch hostedTokenAction(tokens: try tokens(), now: Date(), leewaySec: hostedAccessTokenLeewaySec) {
        case .signedOut:
            throw HostedClientError.notSignedIn
        case .use(let accessToken):
            return accessToken
        case .refresh:
            return try await refreshedTokens().accessToken
        }
    }

    /// Jetonları yeniler; süren bir yenileme varsa onu bekler.
    private func refreshedTokens() async throws -> HostedTokens {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let current = try tokens() else {
            throw HostedClientError.notSignedIn
        }
        let generation: Int = sessionGeneration
        let task: Task<HostedTokens, any Error> = Task { try await self.performRefresh(refreshToken: current.refreshToken, generation: generation) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(refreshToken: String, generation: Int) async throws -> HostedTokens {
        let path: String = "/v1/auth/refresh"
        let request: URLRequest = try jsonRequest(
            path: path, method: "POST", body: try encoded(body: RefreshBody(refreshToken: refreshToken)), accessToken: nil, timeoutSec: hostedRequestTimeoutSec
        )
        let result: HostedRefreshResult
        do {
            // Zaman aşımı ve kopan bağlantıda aynı jetonla hemen yeniden denenir (bkz. `isRetryableRepeatableRequest`).
            let response: (data: Data, status: Int) = try await send(path: path, isRetryable: isRetryableRepeatableRequest, request: request)
            result = try hostedRefreshResult(status: response.status, data: response.data, receivedAt: Date())
        } catch let error as HostedAPIError {
            result = hostedRefreshFailure(error: error)
        }
        return try await settleRefresh(result: result, generation: generation)
    }

    /// Yenileme sonucunu uygular: yeni jetonlar saklanır; ret oturumu siler ve bildirir; diğer hatalar fırlatılır.
    /// Yenileme sürerken oturum değiştiyse (çıkış, hesap silme, yeni giriş) sonuç uygulanmaz: `notSignedIn` ya da yeni
    /// oturumla yeniden denenir (bkz. `isCurrentSessionGeneration`).
    private func settleRefresh(result: HostedRefreshResult, generation: Int) async throws -> HostedTokens {
        guard isCurrentSessionGeneration(started: generation, current: sessionGeneration) else {
            hostedLogger.info("Yenileme oturum değiştikten sonra döndü, sonucu uygulanmadı")
            throw HostedClientError.notSignedIn
        }
        switch result {
        case .refreshed(let refreshed):
            try setTokens(refreshed)
            return refreshed
        case .revoked(let error):
            hostedLogger.warning("Yenileme reddedildi, oturum kapatılıyor, kod: \(error.rawCode, privacy: .public)")
            meetingID = nil
            sessionGeneration += 1
            try setTokens(nil)
            await onSessionEnded()
            throw HostedClientError.sessionEnded
        case .failed(let error):
            throw error
        }
    }

    private func startSession(path: String, body: Data) async throws {
        let response: (data: Data, status: Int) = try await send(
            path: path, isRetryable: isRetryableOneShotRequest,
            request: try jsonRequest(path: path, method: "POST", body: body, accessToken: nil, timeoutSec: hostedRequestTimeoutSec)
        )
        let session: HostedSessionResponse = try decode(HostedSessionResponse.self, data: response.data, path: path)
        meetingID = nil
        sessionGeneration += 1
        try setTokens(hostedTokens(response: session, receivedAt: Date()))
        hostedLogger.info("Giriş yapıldı, yol: \(path, privacy: .public)")
    }

    private func tokens() throws -> HostedTokens? {
        if !tokensLoaded {
            cachedTokens = try storage.load()
            tokensLoaded = true
        }
        return cachedTokens
    }

    private func setTokens(_ tokens: HostedTokens?) throws {
        if let tokens {
            try storage.save(tokens: tokens)
        } else {
            try storage.clear()
        }
        cachedTokens = tokens
        tokensLoaded = true
    }

    // MARK: İstekler

    /// Kimlikli JSON isteği; sunucu erişim jetonunu 401 ile reddederse jeton bir kez yenilenip istek yinelenir.
    private func authorized(path: String, method: String, body: Data?, isRetryable: @escaping @Sendable (HostedAttemptFailure) -> Bool) async throws -> Data {
        let deviceKey: String? = path == "/v1/me" && method == "GET" ? deviceKeyID : nil
        let make: @Sendable (String) throws -> URLRequest = { [baseURL, clientInfo] (accessToken: String) throws -> URLRequest in
            var request: URLRequest = withHostedClientHeaders(
                request: try hostedJSONRequest(baseURL: baseURL, path: path, method: method, body: body, accessToken: accessToken, timeoutSec: hostedRequestTimeoutSec), info: clientInfo
            )
            if let deviceKey {
                request.setValue(deviceKey, forHTTPHeaderField: "x-device-key-id")
            }
            return request
        }
        return try await authorizedOperation(path: path, isRetryable: isRetryable) { (accessToken: String) async throws -> (Data, URLResponse) in
            try await URLSession.shared.data(for: try make(accessToken))
        }
    }

    private func authorizedOperation(
        path: String, isRetryable: @escaping @Sendable (HostedAttemptFailure) -> Bool, operation: @escaping @Sendable (String) async throws -> (Data, URLResponse)
    ) async throws -> Data {
        let accessToken: String = try await validAccessToken()
        do {
            return try await send(path: path, isRetryable: isRetryable) { try await operation(accessToken) }.data
        } catch let error as HostedAPIError where error.status == 401 {
            hostedLogger.warning("Erişim jetonu reddedildi, yenilenip yeniden denenecek, yol: \(path, privacy: .public), kod: \(error.rawCode, privacy: .public)")
            let refreshed: HostedTokens = try await refreshedTokens()
            return try await send(path: path, isRetryable: isRetryable) { try await operation(refreshed.accessToken) }.data
        }
    }

    private func jsonRequest(path: String, method: String, body: Data?, accessToken: String?, timeoutSec: Double) throws -> URLRequest {
        withHostedClientHeaders(request: try hostedJSONRequest(baseURL: baseURL, path: path, method: method, body: body, accessToken: accessToken, timeoutSec: timeoutSec), info: clientInfo)
    }

    private func send(path: String, isRetryable: @escaping @Sendable (HostedAttemptFailure) -> Bool, request: URLRequest) async throws -> (data: Data, status: Int) {
        try await send(path: path, isRetryable: isRetryable) { try await URLSession.shared.data(for: request) }
    }

    private func send(
        path: String, isRetryable: @Sendable (HostedAttemptFailure) -> Bool, operation: @Sendable () async throws -> (Data, URLResponse)
    ) async throws -> (data: Data, status: Int) {
        try await sendHostedRequest(path: path, isRetryable: isRetryable, operation: operation)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, data: Data, path: String) throws -> Value {
        do {
            return try hostedJSONDecoder().decode(type, from: data)
        } catch {
            // Oturum yanıtları jeton taşır: gövde hataya yazılmaz, yalnızca çözme hatası.
            throw HostedClientError.malformedResponse(path: path, status: 200, body: String(describing: error))
        }
    }

    private func encoded<Body: Encodable>(body: Body) throws -> Data {
        try JSONEncoder().encode(body)
    }
}

/// İsteği gönderir: başarısız deneme `isRetryable` uygunsa geri çekilerek (sunucunun `retry-after`'ına uyarak)
/// en çok 3 kez denenir, her başarısızlık uyarı loglanır; son hata fırlatılır. 2xx dışı yanıt `HostedAPIError`,
/// ağ hatası `HostedClientError.network` olur.
func sendHostedRequest(
    path: String, isRetryable: @Sendable (HostedAttemptFailure) -> Bool, operation: @Sendable () async throws -> (Data, URLResponse)
) async throws -> (data: Data, status: Int) {
    var lastError: any Error = HostedClientError.network(path: path, reason: "istek gönderilmedi")
    for attempt in 1...hostedAttempts {
        let failure: HostedAttemptFailure
        var retryAfter: String?
        do {
            let (data, response): (Data, URLResponse) = try await operation()
            guard let http = response as? HTTPURLResponse else {
                throw HostedClientError.malformedResponse(path: path, status: 0, body: "HTTP yanıtı değil")
            }
            if (200..<300).contains(http.statusCode) {
                return (data: data, status: http.statusCode)
            }
            let error: HostedAPIError = parseHostedAPIError(status: http.statusCode, data: data, path: path)
            announceIfSubscriptionRequired(error: error)
            lastError = error
            failure = .server(error)
            retryAfter = http.value(forHTTPHeaderField: "retry-after")
        } catch let error as URLError {
            lastError = HostedClientError.network(path: path, reason: "\(error.code.rawValue): \(error.localizedDescription)")
            failure = .network(error.code)
        }
        guard attempt < hostedAttempts, isRetryable(failure) else {
            throw lastError
        }
        hostedLogger.warning("Sunucu isteği başarısız, yeniden denenecek, yol: \(path, privacy: .public), deneme: \(attempt, privacy: .public), hata: \(attemptDescription(failure: failure), privacy: .public)")
        try await Task.sleep(for: .seconds(retryDelay(retryAfterHeader: retryAfter, attempt: attempt)))
    }
    throw lastError
}

/// Yeniden deneme logunun hata özeti (kod ve durum; içerik yok). Saf fonksiyondur.
private func attemptDescription(failure: HostedAttemptFailure) -> String {
    switch failure {
    case .network(let code):
        "ağ \(code.rawValue)"
    case .server(let error):
        "\(error.rawCode) (HTTP \(error.status))"
    }
}

/// JSON isteği: yol temel adrese eklenir; gövde varsa `application/json`, jeton varsa bearer. Saf fonksiyondur.
func hostedJSONRequest(baseURL: URL, path: String, method: String, body: Data?, accessToken: String?, timeoutSec: Double) throws -> URLRequest {
    var request: URLRequest = URLRequest(url: baseURL.appending(path: String(path.drop { $0 == "/" })))
    request.httpMethod = method
    request.timeoutInterval = timeoutSec
    if let body {
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
    }
    if let accessToken {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
    }
    return request
}
