import Foundation
import os

private let hostedLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Hosted")

/// Sunucu isteği başına en çok deneme.
private let hostedAttempts: Int = 3

/// Kısa JSON isteklerinin zaman aşımı.
private let hostedRequestTimeoutSec: Double = 30

// Sunucunun beklediği gövdeler (alan adları sunucununkilerdir).
private struct AppleSignInBody: Encodable {
    let identityToken: String
    let nonce: String
}

private struct EmailVerifyBody: Encodable {
    let token: String
}

private struct RefreshBody: Encodable {
    let refreshToken: String
}

private struct MeetingStartBody: Encodable {
    let device: HostedDeviceAssertion?
}

private struct DeviceChallengeBody: Encodable {
    let purpose: String
}

private struct DeviceAttestBody: Encodable {
    let keyId: String
    let attestation: String
    let challenge: String
}

/// Sorgu değerinin kodlaması: `+`, `&` ve `=` da kodlanır (sunucu `+`'yı boşluk okur). Saf fonksiyondur.
private func queryValue(text: String) -> String {
    var allowed: CharacterSet = .urlQueryAllowed
    allowed.remove(charactersIn: "+&=")
    // `.urlQueryAllowed` dışındaki her karakter yüzde kodlanabilir; nil dönmez.
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
}

/// `POST /v1/transcribe` adresi: dil (sabitse), konuşmacı ayırma açık ve anahtar terimler. Saf fonksiyondur.
public func hostedTranscribeURL(baseURL: URL, languageCode: String?, keyterms: [String]) -> URL {
    let pairs: [(String, String)] = (languageCode.map { [("language_code", $0)] } ?? []) + [("diarize", "true")]
        + keyterms.map { ("keyterms", $0) }
    let query: String = pairs.map { "\($0.0)=\(queryValue(text: $0.1))" }.joined(separator: "&")
    // Sorgu yalnızca kodlanmış karakterlerden oluşur: adres her zaman geçerlidir.
    return URL(string: baseURL.appending(path: "v1/transcribe").absoluteString + "?" + query)!
}

/// Abonelik sunucusunun bağlantısı: oturum (Anahtar Zinciri'nde), jeton yenileme, hak durumu, toplantı oturumu, ödeme,
/// cihaz doğrulama ve ses yükleme. Jetonlar ve içerik loglanmaz.
///
/// Yenileme tek uçuşludur: aynı anda gelen istekler tek yenilemeyi bekler (yenileme jetonu iki kez gönderilirse sunucu
/// bunu çalınma sayar ve tüm oturumları kapatır). Sunucu yenilemeyi 401 ile reddederse yerel oturum silinir ve
/// `onSessionEnded` çağrılır.
public actor HostedClient: HostedLLMCredentialSource {
    public nonisolated let baseURL: URL
    private let storage: any HostedTokenStorage
    private let onSessionEnded: @Sendable () async -> Void
    private var cachedTokens: HostedTokens?
    private var tokensLoaded: Bool = false
    private var refreshTask: Task<HostedTokens, any Error>?
    /// Yapay zekâ çağrılarının bağlandığı toplantı: son başlatılan (bittikten sonra da ek süre boyunca kullanılır).
    private var meetingID: String?
    /// Doğrulanmış App Attest anahtarı (base64); `/v1/me` cihazın deneme hakkını da göstersin diye gönderilir.
    private var deviceKeyID: String?

    public init(baseURL: URL, storage: any HostedTokenStorage, onSessionEnded: @escaping @Sendable () async -> Void) {
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
        try await startSession(path: "/v1/auth/apple", body: try encoded(body: AppleSignInBody(identityToken: identityToken, nonce: nonce)))
    }

    /// E-posta bağlantısıyla giriş: bağlantıdaki tek kullanımlık jeton.
    public func verifyEmailLink(token: String) async throws {
        try await startSession(path: "/v1/auth/email/verify", body: try encoded(body: EmailVerifyBody(token: token)))
    }

    /// Çıkış: sunucuda oturum ailesi kapatılır, yerel oturum her durumda silinir; sunucuya ulaşılamadıysa hata
    /// silmeden sonra fırlatılır.
    public func signOut() async throws {
        guard let current = try tokens() else {
            return
        }
        meetingID = nil
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
        try setTokens(nil)
        hostedLogger.info("Hesap silindi")
    }

    // MARK: Haklar, toplantı, ödeme

    /// `GET /v1/me`.
    public func entitlements() async throws -> HostedEntitlements {
        try decode(HostedEntitlements.self, data: try await authorized(path: "/v1/me", method: "GET", body: nil, isRetryable: isRetryableRepeatableRequest), path: "/v1/me")
    }

    /// Toplantı oturumu açar; reddedilirse (`trial_exhausted`, `monthly_cap_reached`…) `HostedAPIError`. Açılan
    /// toplantı yapay zekâ çağrılarının toplantısı olur.
    public func startMeeting(device: HostedDeviceAssertion?) async throws -> HostedStartedMeeting {
        let path: String = "/v1/meetings/start"
        let started: HostedStartedMeeting = try decode(
            HostedStartedMeeting.self,
            data: try await authorized(path: path, method: "POST", body: try encoded(body: MeetingStartBody(device: device)), isRetryable: isRetryableOneShotRequest),
            path: path
        )
        meetingID = started.meetingId
        hostedLogger.info("Toplantı oturumu açıldı, tür: \(started.kind, privacy: .public), en çok dakika: \(started.maxDurationMinutes, privacy: .public)")
        return started
    }

    /// Toplantıyı bitirir; not ve son geçiş sunucunun ek süresi boyunca aynı toplantıyla sürer.
    public func endMeeting(meetingID ended: String) async throws -> HostedEndedMeeting {
        let path: String = "/v1/meetings/\(ended)/end"
        return try decode(HostedEndedMeeting.self, data: try await authorized(path: path, method: "POST", body: nil, isRetryable: isRetryableRepeatableRequest), path: path)
    }

    /// Yapay zekâ çağrılarının toplantısı; yoksa nil.
    public func currentMeetingID() -> String? {
        meetingID
    }

    /// Stripe Checkout adresi; bitmemiş abonelik varsa `subscription_exists`.
    public func checkoutURL() async throws -> URL {
        let path: String = "/v1/billing/checkout"
        return try decode(HostedURLResponse.self, data: try await authorized(path: path, method: "POST", body: nil, isRetryable: isRetryableRepeatableRequest), path: path).url
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

    /// WAV dosyasını `/v1/transcribe`'a ham gövde olarak gönderir; ElevenLabs yanıtının JSON'unu döndürür.
    public func transcribe(meetingID: String, wavFile: URL, languageCode: String?, keyterms: [String], timeoutSec: Double) async throws -> Data {
        let path: String = "/v1/transcribe"
        let url: URL = hostedTranscribeURL(baseURL: baseURL, languageCode: languageCode, keyterms: keyterms)
        let attempt: @Sendable (String) async throws -> (Data, URLResponse) = { (accessToken: String) async throws -> (Data, URLResponse) in
            var request: URLRequest = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeoutSec
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
            request.setValue(meetingID, forHTTPHeaderField: "x-meeting-id")
            request.setValue("audio/wav", forHTTPHeaderField: "content-type")
            return try await URLSession.shared.upload(for: request, fromFile: wavFile)
        }
        return try await authorizedOperation(path: path, isRetryable: isRetryableRepeatableRequest, operation: attempt)
    }

    /// Yapay zekâ çağrısının jetonu ve toplantısı.
    public func llmCredentials() async throws -> HostedLLMCredentials {
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
        let task: Task<HostedTokens, any Error> = Task { try await self.performRefresh(refreshToken: current.refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(refreshToken: String) async throws -> HostedTokens {
        let path: String = "/v1/auth/refresh"
        let request: URLRequest = try jsonRequest(
            path: path, method: "POST", body: try encoded(body: RefreshBody(refreshToken: refreshToken)), accessToken: nil, timeoutSec: hostedRequestTimeoutSec
        )
        let result: HostedRefreshResult
        do {
            let response: (data: Data, status: Int) = try await send(path: path, isRetryable: isRetryableOneShotRequest, request: request)
            result = try hostedRefreshResult(status: response.status, data: response.data, receivedAt: Date())
        } catch let error as HostedAPIError {
            result = hostedRefreshFailure(error: error)
        }
        return try await settleRefresh(result: result)
    }

    /// Yenileme sonucunu uygular: yeni jetonlar saklanır; ret oturumu siler ve bildirir; diğer hatalar fırlatılır.
    private func settleRefresh(result: HostedRefreshResult) async throws -> HostedTokens {
        switch result {
        case .refreshed(let refreshed):
            try setTokens(refreshed)
            return refreshed
        case .revoked(let error):
            hostedLogger.warning("Yenileme reddedildi, oturum kapatılıyor, kod: \(error.rawCode, privacy: .public)")
            meetingID = nil
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
        let make: @Sendable (String) throws -> URLRequest = { [baseURL] (accessToken: String) throws -> URLRequest in
            var request: URLRequest = try hostedJSONRequest(baseURL: baseURL, path: path, method: method, body: body, accessToken: accessToken, timeoutSec: hostedRequestTimeoutSec)
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
        try hostedJSONRequest(baseURL: baseURL, path: path, method: method, body: body, accessToken: accessToken, timeoutSec: timeoutSec)
    }

    private func send(path: String, isRetryable: @escaping @Sendable (HostedAttemptFailure) -> Bool, request: URLRequest) async throws -> (data: Data, status: Int) {
        try await send(path: path, isRetryable: isRetryable) { try await URLSession.shared.data(for: request) }
    }

    /// İsteği gönderir: başarısız deneme `isRetryable` uygunsa geri çekilerek (sunucunun `retry-after`'ına uyarak)
    /// en çok 3 kez denenir, her başarısızlık uyarı loglanır; son hata fırlatılır. 2xx dışı yanıt `HostedAPIError`,
    /// ağ hatası `HostedClientError.network` olur.
    private func send(
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
