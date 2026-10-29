import Foundation

/// Abonelik sunucusunun hata kodları; `server/src/errors.ts` ile birebir aynıdır.
public enum HostedErrorCode: String, Sendable, CaseIterable, Equatable {
    case badRequest = "bad_request"
    case invalidBody = "invalid_body"
    case unauthorized
    case invalidToken = "invalid_token"
    case forbidden
    case notFound = "not_found"
    case methodNotAllowed = "method_not_allowed"
    case lengthRequired = "length_required"
    case payloadTooLarge = "payload_too_large"
    case unsupportedMediaType = "unsupported_media_type"
    case rateLimited = "rate_limited"
    case turnstileFailed = "turnstile_failed"
    case attestationRequired = "attestation_required"
    case attestationInvalid = "attestation_invalid"
    case assertionInvalid = "assertion_invalid"
    case challengeInvalid = "challenge_invalid"
    case subscriptionRequired = "subscription_required"
    case subscriptionExists = "subscription_exists"
    case trialExhausted = "trial_exhausted"
    case trialNotStarted = "trial_not_started"
    case trialIPLimit = "trial_ip_limit"
    case trialDeviceUsed = "trial_device_used"
    case deviceCheckRequired = "device_check_required"
    case deviceCheckInvalid = "device_check_invalid"
    case monthlyCapReached = "monthly_cap_reached"
    case dailyCapReached = "daily_cap_reached"
    case transcriptionClosed = "transcription_closed"
    case transcriptionInProgress = "transcription_in_progress"
    case meetingNotActive = "meeting_not_active"
    case reprocessLimitReached = "reprocess_limit_reached"
    case meetingBudgetExhausted = "meeting_budget_exhausted"
    case audioTooLong = "audio_too_long"
    case upstreamRejected = "upstream_rejected"
    case upstreamUnavailable = "upstream_unavailable"
    case spendCeilingReached = "spend_ceiling_reached"
    case trialCapacityReached = "trial_capacity_reached"
    case deepgramUnavailable = "deepgram_unavailable"
    case deepgramGrantLimit = "deepgram_grant_limit"
    case webhookInvalid = "webhook_invalid"
    case internalError = "internal_error"
}

/// Sunucunun döndürdüğü hata (`{"error": {"code", "message"}}`). Kod tanınmıyorsa ya da gövde bu biçimde değilse
/// `code` nil'dir; `rawCode` sunucunun yazdığı kod (ya da `http_<durum>`).
public struct HostedAPIError: Error, Sendable, Equatable {
    public let code: HostedErrorCode?
    public let rawCode: String
    public let status: Int
    /// Sunucunun açıklaması; yalnızca hata ayıklama içindir (arayüz kendi yerelleştirilmiş metnini gösterir).
    public let serverMessage: String
    /// İsteğin yolu (ör. `/v1/meetings/start`).
    public let path: String

    public init(code: HostedErrorCode?, rawCode: String, status: Int, serverMessage: String, path: String) {
        self.code = code
        self.rawCode = rawCode
        self.status = status
        self.serverMessage = serverMessage
        self.path = path
    }
}

/// İstemci tarafında oturum, adres ya da yanıt sorunu. Jetonlar hiçbir zaman hataya girmez.
public enum HostedClientError: Error, Sendable, Equatable {
    /// Kayıtlı oturum yok.
    case notSignedIn
    /// Sunucu yenileme jetonunu reddetti (süresi doldu, çıkış yapıldı ya da jeton yeniden kullanıldığı için tüm
    /// oturumlar kapatıldı); yerel oturum silindi.
    case sessionEnded
    /// Yayın derlemesinde https olmayan sunucu adresi.
    case insecureBaseURL(url: String)
    /// Info.plist'teki adres eksik ya da geçersiz.
    case invalidBaseURL(value: String)
    /// Info.plist'te Anahtar Zinciri servis adı yok (derleme yapılandırması hatası).
    case keychainServiceNotConfigured(key: String)
    /// Sunucuya ulaşılamıyor ve son bilinen hak durumu çevrimdışı kayda izin vermiyor (7 günden eski ya da izin yok).
    case offlineNotAllowed
    /// Kayıt çevrimdışı sürüyor: toplantıya bağlı yapay zekâ çağrıları (canlı çeviri…) yapılamaz.
    case offlineRecording
    /// Yapay zekâ çağrısı için açık toplantı oturumu yok.
    case noActiveMeeting
    /// Sunucuya ulaşılamadı.
    case network(path: String, reason: String)
    /// Yanıt beklenen biçimde değil; gövde hata ayıklama içindir (jeton içermez).
    case malformedResponse(path: String, status: Int, body: String)
    /// Sunucu bu uç noktayı tanımıyor (uygulama sunucudan yeni): işlem yapılmaz.
    case serverOutdated(path: String)
}

/// Apple DeviceCheck jetonu üretilemedi (ücretsiz deneme toplantısı için gerekir).
public enum HostedDeviceCheckError: Error, Sendable, Equatable {
    /// Bu Mac'te DeviceCheck desteklenmiyor.
    case unsupported
    /// Jeton üretilemedi; neden hata ayıklama içindir.
    case tokenFailed(reason: String)
}

/// Sunucu hata gövdesinin biçimi.
private struct RawHostedErrorBody: Decodable {
    struct Detail: Decodable {
        let code: String
        let message: String
    }

    let error: Detail
}

/// Başarısız yanıttan hata üretir: gövde `{"error": {...}}` değilse kod `http_<durum>`, mesaj gövdenin ilk 500
/// karakteri olur. Saf fonksiyondur.
public func parseHostedAPIError(status: Int, data: Data, path: String) -> HostedAPIError {
    let body: RawHostedErrorBody
    do {
        body = try JSONDecoder().decode(RawHostedErrorBody.self, from: data)
    } catch {
        // Sunucu dışından (ör. vekil, Cloudflare sayfası) gelen gövde: durum ve gövdenin başı hatada kalır.
        return HostedAPIError(code: nil, rawCode: "http_\(status)", status: status, serverMessage: String(String(decoding: data, as: UTF8.self).prefix(500)), path: path)
    }
    return HostedAPIError(code: HostedErrorCode(rawValue: body.error.code), rawCode: body.error.code, status: status, serverMessage: body.error.message, path: path)
}

/// Aynı istek bir süre sonra başarılı olabilir mi: hız sınırı, üst servis kesintisi ve sunucu hatası. Günlük harcama
/// tavanı (503), kotalar ve ret kodları kalıcıdır. Saf fonksiyondur.
public func isRetryableHostedError(error: HostedAPIError) -> Bool {
    switch error.code {
    case .rateLimited, .upstreamUnavailable, .internalError:
        return true
    case .none:
        return error.status == 408 || error.status >= 500
    default:
        return false
    }
}

/// Sunucu hatasının kullanıcıya gösterilen, ne yapılacağını söyleyen metni. Saf fonksiyondur.
public func hostedErrorMessage(error: HostedAPIError) -> String {
    guard let code = error.code else {
        return String(localized: "Sunucu isteği şu an tamamlayamadı. Biraz sonra yeniden dene.")
    }
    switch code {
    case .trialExhausted:
        return String(localized: "Ücretsiz denemen bitti (3 toplantı ya da 7 gün). Devam etmek için abone ol.")
    case .trialNotStarted:
        return String(localized: "Ücretsiz deneme ilk toplantıyla başlar; önce bir toplantı başlat.")
    case .trialIPLimit:
        return String(localized: "Bu ağdan bugün çok fazla yeni deneme başlatıldı. Yarın yeniden dene ya da abone ol.")
    case .trialDeviceUsed:
        return String(localized: "Bu Mac'te ücretsiz deneme daha önce başka bir hesapla kullanıldı. Devam etmek için Ayarlar › Hesap'tan abone ol.")
    case .deviceCheckRequired:
        return String(localized: "Ücretsiz deneme için bu Mac'in Apple doğrulaması gerekiyor; uygulamayı güncelleyip yeniden dene.")
    case .deviceCheckInvalid:
        return String(localized: "Bu Mac Apple tarafından doğrulanamadı; uygulamayı yeniden açıp tekrar dene.")
    case .monthlyCapReached:
        // Aynı kod farklı sınırlardan gelir: hangisi olduğu isteğin yolundan (kayıt, son geçiş ya da yapay zekâ).
        return monthlyCapMessage(path: error.path)
    case .dailyCapReached:
        return dailyCapMessage(path: error.path)
    case .subscriptionRequired:
        return String(localized: "Bu işlem için abonelik gerekiyor. Ayarlar › Hesap'tan abone ol.")
    case .subscriptionExists:
        return String(localized: "Zaten bir aboneliğin var; \"Hesabı yönet\" ile düzenleyebilirsin.")
    case .trialCapacityReached:
        return String(localized: "Ücretsiz denemeler bugün kapasitede. Yarın yeniden dene ya da Ayarlar › Hesap'tan abone ol.")
    case .spendCeilingReached:
        return String(localized: "Servis bugün çok yoğun; yeni toplantılar ve yapay zekâ istekleri geçici olarak durduruldu. Biraz sonra yeniden dene.")
    case .meetingNotActive:
        return String(localized: "Bu toplantının sunucu oturumu kapandı (kayıt bitiminden 30 dakika sonra ya da en çok süre dolunca). Kayıtlı toplantıyı \"Tekrar işle\" ile yeniden işleyebilir ya da yeni bir toplantı başlatabilirsin.")
    case .reprocessLimitReached:
        return String(localized: "Bu toplantı en çok iki kez yeniden işlenebilir; mevcut metin ve not korunur.")
    case .transcriptionClosed:
        return String(localized: "Bu toplantının ses işleme hakkı kapandı (gönderilen ses toplantının süresini aştı). Canlı metin kullanılır.")
    case .transcriptionInProgress:
        return String(localized: "Bu toplantının sesi zaten işleniyor; bitince yeniden dene.")
    case .deepgramUnavailable:
        return String(localized: "Bulut canlı metni şu an kullanılamıyor; canlı metin bu Mac'te üretiliyor.")
    case .deepgramGrantLimit:
        return String(localized: "Bulut canlı metnine bu toplantıda çok sık yeniden bağlanıldı; canlı metin bu Mac'te sürüyor.")
    case .meetingBudgetExhausted:
        return String(localized: "Bu toplantının yapay zekâ kullanım hakkı doldu.")
    case .audioTooLong:
        return String(localized: "Ses, toplantının süresinden ya da bu ay kalan süreden uzun; gönderilemedi.")
    case .unauthorized, .invalidToken:
        return String(localized: "Oturumun sona erdi; Ayarlar › Hesap'tan yeniden giriş yap.")
    case .rateLimited:
        return String(localized: "Çok fazla istek gönderildi; biraz bekleyip yeniden dene.")
    case .turnstileFailed:
        return String(localized: "İnsan doğrulaması başarısız; giriş sayfasını yenileyip yeniden dene.")
    case .attestationRequired:
        return String(localized: "Bu sürüm cihaz doğrulaması istiyor; uygulamayı güncelle.")
    case .attestationInvalid, .assertionInvalid, .challengeInvalid:
        return String(localized: "Bu Mac doğrulanamadı; uygulamayı yeniden açıp tekrar dene.")
    case .upstreamRejected:
        return String(localized: "Yapay zekâ ya da konuşma tanıma servisi isteği reddetti. Sorun sürerse bize yaz.")
    case .upstreamUnavailable:
        return String(localized: "Yapay zekâ ya da konuşma tanıma servisi şu an yanıt vermiyor; biraz sonra yeniden dene.")
    case .payloadTooLarge:
        return String(localized: "Gönderilen veri sunucunun sınırını aşıyor.")
    case .forbidden:
        return String(localized: "Bu işleme izin yok.")
    case .internalError:
        return String(localized: "Sunucuda beklenmeyen bir hata oluştu; biraz sonra yeniden dene.")
    case .badRequest, .invalidBody, .notFound, .methodNotAllowed, .lengthRequired, .unsupportedMediaType, .webhookInvalid:
        return String(localized: "Bu sürüm sunucuyla uyuşmuyor. Uygulamayı güncelleyip yeniden dene.")
    }
}

/// `monthly_cap_reached` metni: kayıt başlatma ve son geçişte aylık kayıt saatleri, yapay zekâ çağrısında toplantı dışı
/// yapay zekâ payı (kayıt etkilenmez). Saf fonksiyondur.
private func monthlyCapMessage(path: String) -> String {
    switch path {
    case "/v1/meetings/start":
        String(localized: "Bu ayki kayıt saatlerin doldu; yeni kayıt ay başında açılır. Notların ve toplantıların kullanılabilir.")
    case "/v1/transcribe":
        String(localized: "Bu ayki kayıt saatlerin bu kaydı işlemeye yetmiyor; canlı metin kullanılır. Sınır ay başında sıfırlanır.")
    case "/v1/llm/messages":
        String(localized: "Bu ayki yapay zekâ payın doldu (Sor, notu yeniden yazma…); ay başında sıfırlanır. Kayıt yapmaya devam edebilirsin.")
    default:
        String(localized: "Bu ayki kullanım sınırına ulaştın; sınır ay başında sıfırlanır.")
    }
}

/// `daily_cap_reached` metni: günlük toplantı başlatma, günlük yapay zekâ payı ya da günlük rapor sınırı. Saf
/// fonksiyondur.
private func dailyCapMessage(path: String) -> String {
    switch path {
    case "/v1/meetings/start":
        String(localized: "Bugün başlatılabilecek toplantı sayısına ulaştın; yarın yeniden dene.")
    case "/v1/llm/messages":
        String(localized: "Bugünkü yapay zekâ payın doldu (Sor, notu yeniden yazma…); yarın yeniden dene. Kayıt yapmaya devam edebilirsin.")
    case "/v1/reports":
        String(localized: "Bugün çok fazla rapor gönderildi; yarın yeniden dene.")
    default:
        String(localized: "Bugünkü kullanım sınırına ulaştın; yarın yeniden dene.")
    }
}

/// İstemci hatasının kullanıcıya gösterilen metni. Saf fonksiyondur.
public func hostedClientMessage(error: HostedClientError) -> String {
    switch error {
    case .notSignedIn:
        String(localized: "Giriş yapılmamış. Ayarlar › Hesap'tan Apple ya da Google ile giriş yap.")
    case .sessionEnded:
        String(localized: "Oturumun kapandı (çıkış yapılmış ya da güvenlik nedeniyle tüm oturumlar kapatılmış). Yeniden giriş yap.")
    case .insecureBaseURL:
        String(localized: "Uygulamanın sunucu ayarı güvenli değil; uygulamayı güncelle ya da yeniden kur.")
    case .invalidBaseURL:
        String(localized: "Uygulamanın sunucu ayarı eksik ya da bozuk; uygulamayı yeniden kur.")
    case .keychainServiceNotConfigured:
        String(localized: "Uygulamanın Anahtar Zinciri ayarı eksik; uygulamayı yeniden kur.")
    case .offlineNotAllowed:
        String(localized: "Sunucuya ulaşılamıyor ve hesap durumun son 7 günde doğrulanmadı. Kayıt için internete bağlan.")
    case .offlineRecording:
        String(localized: "Kayıt çevrimdışı sürüyor: canlı çeviri kapalı; not ve konuşmacılar bağlantı gelince hazırlanır.")
    case .noActiveMeeting:
        String(localized: "Yapay zekâ özellikleri bir toplantı sırasında ve bittikten kısa süre sonrasına kadar kullanılabilir; önce bir toplantı başlat.")
    case .network:
        String(localized: "Sunucuya ulaşılamadı; internet bağlantını kontrol et.")
    case .malformedResponse(_, let status, _):
        String(localized: "Sunucudan beklenmeyen bir yanıt geldi. Uygulamayı güncelleyip yeniden dene.")
    case .serverOutdated:
        String(localized: "Sunucu bu işlemi henüz desteklemiyor (güncelleniyor). Toplantı işlenmedi; biraz sonra \"Tekrar işle\" ile yeniden dene.")
    }
}

/// DeviceCheck hatasının kullanıcıya gösterilen metni. Saf fonksiyondur.
public func hostedDeviceCheckMessage(error: HostedDeviceCheckError) -> String {
    switch error {
    case .unsupported:
        String(localized: "Bu Mac Apple'ın cihaz doğrulamasını (DeviceCheck) desteklemiyor; ücretsiz deneme başlatılamıyor. Abone olarak devam edebilirsin.")
    case .tokenFailed:
        String(localized: "Bu Mac Apple ile doğrulanamadı (DeviceCheck). İnternet bağlantını kontrol edip yeniden dene.")
    }
}

/// Canlı çeviri bu kayıtta durmalı mı: anahtar reddedildi (401/403) ya da abonelik sunucusu toplantının yapay zekâ
/// hakkını kapattı (oturum yok, toplantı kapalı, bütçe ya da sınır doldu, harcama tavanı). Her cümle aynı hatayı
/// almasın diye çeviri durur; cümleler "Tekrar dene"de kalır. Saf fonksiyondur.
public func stopsLiveTranslation(error: any Error) -> Bool {
    switch error {
    case LLMError.http(let status, _, _, _):
        return status == 401 || status == 403
    case LLMError.hosted(let hosted):
        return isClosedHostedAccess(error: hosted)
    case let client as HostedClientError:
        switch client {
        case .notSignedIn, .sessionEnded, .noActiveMeeting, .insecureBaseURL, .invalidBaseURL, .keychainServiceNotConfigured, .offlineNotAllowed, .offlineRecording,
             .serverOutdated:
            return true
        case .network, .malformedResponse:
            return false
        }
    default:
        return false
    }
}

/// Sunucu bu kullanıcının yapay zekâ erişimini şimdilik kapattı mı (yeniden denemek aynı sonucu verir). Saf fonksiyondur.
private func isClosedHostedAccess(error: HostedAPIError) -> Bool {
    switch error.code {
    case .unauthorized, .invalidToken, .forbidden, .subscriptionRequired, .trialExhausted, .monthlyCapReached, .dailyCapReached,
         .meetingNotActive, .meetingBudgetExhausted, .spendCeilingReached, .trialCapacityReached:
        return true
    default:
        return false
    }
}
