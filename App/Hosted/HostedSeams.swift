import AINotepadCore
import os
import Foundation

// Abonelik sürümünün paylaşılan koda bağlandığı noktalar (`#if HOSTED_EDITION` ile çağrılır): LLM sağlayıcısı, son
// geçiş, kurulum eksikleri, canlı metin motoru ve rapor hedefi.

/// Abonelik sürümünde motor seçimi gizlidir: `AppModel`'in yerel motoru WhisperKit'tir; her kaydın canlı motoru
/// (Deepgram ya da Mac) kayıt başında sunucuya göre seçilir (`hostedLiveChoice`).
let hostedLocalEngine: LiveEngine = .whisperKit

private let seamsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedSeams")

/// Abonelik sürümünde canlı metnin motoru ve nedeni (Ayarlar › Tanılama).
struct HostedLiveStatus: Equatable {
    let engine: HostedLiveEngine
    let reason: String
}

/// Kaydın canlı motoru: hibrit oturumun başlangıcı ve tanılamadaki durumu.
struct HostedLiveChoice {
    let start: HybridLiveStart
    let status: HostedLiveStatus
}

/// Kaydın canlı motorunu seçer (toplantı oturumu açıldıktan sonra): sunucu `liveEngine: deepgram` diyorsa ilk jeton
/// istenir; alınırsa Deepgram (model ve adres seçenekleri jetondan, sonraki her bağlantı yeni jeton alır; ilk jeton
/// kullanılmadan atılır, yalnızca hakkı ve seçenekleri doğrular). Sunucu Mac'i önerirse, hak durumu bilinmiyorsa ya da
/// jeton alınamazsa (bütçe, ağ, sunucu) Mac'te; neden tanılamada görünür. Jeton saklanmaz ve loglanmaz.
@MainActor
func hostedLiveChoice(language: MeetingLanguage, keyterms: [String]) async -> HostedLiveChoice {
    let expected: HostedLiveStatus = hostedExpectedLiveStatus(account: .shared)
    guard expected.engine == .deepgram else {
        return HostedLiveChoice(start: .local, status: expected)
    }
    let client: HostedClient
    let meetingID: String
    let grant: HostedDeepgramGrant
    do {
        client = try HostedServices.requireClient()
        guard let current = await client.currentMeetingID() else {
            throw HostedClientError.noActiveMeeting
        }
        meetingID = current
        grant = try await client.deepgramGrant(meetingID: meetingID)
    } catch {
        seamsLogger.warning("Deepgram jetonu alınamadı, canlı metin Mac'te, hata: \(String(describing: error), privacy: .private)")
        return HostedLiveChoice(
            start: .local,
            status: HostedLiveStatus(engine: .whisperKit, reason: String(localized: "Bulut canlı metni için jeton alınamadı: \(userFacingMessage(error: error))"))
        )
    }
    let source: DeepgramLiveSource = DeepgramLiveSource(language: language, keyterms: keyterms, options: hostedDeepgramListenOptions(grant: grant)) {
        () async throws -> String in
        try await client.deepgramGrant(meetingID: meetingID).accessToken
    }
    return HostedLiveChoice(start: .deepgram(source), status: HostedLiveStatus(engine: .deepgram, reason: String(localized: "Sunucu bulut canlı metnine izin verdi")))
}

/// Sunucunun önerdiği canlı motor (son okunan hak durumundan): `deepgram` ise bulut, değilse Mac ve nedeni.
@MainActor
func hostedExpectedLiveStatus(account: HostedAccount) -> HostedLiveStatus {
    switch account.state {
    case .signedIn(let entitlements):
        switch hostedLiveEngine(entitlements: entitlements) {
        case .deepgram:
            return HostedLiveStatus(engine: .deepgram, reason: String(localized: "Sunucu bulut canlı metnine izin veriyor"))
        case .whisperKit:
            return HostedLiveStatus(engine: .whisperKit, reason: String(localized: "Sunucu bulut canlı metnini kapattı ya da ayrılan kapasite doldu"))
        }
    case .signedInStatusUnknown:
        return HostedLiveStatus(engine: .whisperKit, reason: String(localized: "Hesap durumu okunamadı (sunucuya ulaşılamıyor)"))
    case .loading:
        return HostedLiveStatus(engine: .whisperKit, reason: String(localized: "Hesap durumu okunuyor"))
    case .signedOut:
        return HostedLiveStatus(engine: .whisperKit, reason: String(localized: "Giriş yapılmamış"))
    case .unavailable:
        return HostedLiveStatus(engine: .whisperKit, reason: String(localized: "Hesap kullanılamıyor"))
    }
}

/// Sor (toplantı dışı yapay zekâ) şu an neden kullanılamıyor; kullanılabiliyorsa nil. Deneme ilk toplantıyla başlar
/// (`trialEndsAt` o zaman dolar): abonelik erişimi olmayan, denemesi başlamamış hesap önce bir toplantı kaydetmeli.
/// Sunucu çağrılmaz; diğer retler (deneme bitti, sınır) sunucunun hatasıyla gösterilir.
@MainActor
func hostedAskUnavailableReason(account: HostedAccount) -> String? {
    guard case .signedIn(let entitlements) = account.state, entitlements.plan == .trial, entitlements.trialEndsAt == nil else {
        return nil
    }
    return String(localized: "Önce bir toplantı kaydet: ücretsiz deneme ilk toplantıyla başlar, sonra toplantılarına soru sorabilirsin.")
}

/// Açılışta Mac modeli (~630 MB) yüklensin mi: yalnızca giriş yapılmış ve sunucu bulut canlı metnini önermiyorsa (ya
/// da hak durumu okunamadıysa: çevrimdışıyken bulut da kullanılamaz). Bulut kullanılabiliyorsa model ilk Mac'e geçişte
/// iner; giriş yapılmamışsa hiç inmez.
@MainActor
func hostedPreloadsLocalModel(account: HostedAccount) -> Bool {
    switch account.state {
    case .signedIn(let entitlements):
        return hostedLiveEngine(entitlements: entitlements) == .whisperKit
    case .signedInStatusUnknown:
        return true
    case .loading, .signedOut, .unavailable:
        return false
    }
}

/// Kayıt sırasındaki ve kaydın hemen ardındaki yapay zekâ çağrıları: son açılan toplantının bütçesinden düşer.
func hostedMeetingLLMProvider() throws -> LLMProvider {
    let client: HostedClient = try HostedServices.requireClient()
    return .hosted(HostedLLMConfig(baseURL: client.baseURL, credentials: client, scope: .meeting))
}

/// Her zaman kullanılabilen yapay zekâ çağrıları (Sor, notu yeniden yazma, düzenleme, paylaşım çevirisi, görev aracı):
/// toplantı kimliği gönderilmez, kullanıcının sınırlarına sayılır.
func hostedAccountLLMProvider() throws -> LLMProvider {
    let client: HostedClient = try HostedServices.requireClient()
    return .hosted(HostedLLMConfig(baseURL: client.baseURL, credentials: client, scope: .account))
}

/// Son geçiş: kayıt sunucunun `/v1/transcribe` ucuyla (ElevenLabs Scribe) yazıya dökülür; toplantı oturumu yoksa
/// (ör. ek süre geçtikten sonra "Tekrar işle") atlanır, nedeni toplantıda görünür.
func hostedFinalPassPlan(keyterms: [String]) async -> FinalPassPlan {
    let client: HostedClient
    do {
        client = try HostedServices.requireClient()
    } catch {
        return .skip(reason: userFacingMessage(error: error))
    }
    guard let meetingID = await client.currentMeetingID() else {
        return .skip(reason: userFacingMessage(error: HostedClientError.noActiveMeeting))
    }
    return .run(HostedFinalTranscriber(client: client, meetingID: meetingID, keyterms: keyterms))
}

/// Kurulum eksikleri (menüde ve Ana sayfada): sunucu adresi geçersizse ya da giriş yapılmamışsa.
func hostedSetupProblems() async -> [String] {
    do {
        guard try await HostedServices.requireClient().isSignedIn() else {
            return [userFacingMessage(error: HostedClientError.notSignedIn)]
        }
        return []
    } catch {
        return [userFacingMessage(error: error)]
    }
}

/// Geri bildirim ve çökme raporunun hedefi: abonelik sunucusu; rapor hesaba bağlanır (bearer). Sunucu jetonsuz
/// raporu kabul etmez: giriş yapılmamışsa `HostedClientError.notSignedIn` (kullanıcıya "giriş yap" denir).
func hostedReportDestination() async throws -> ReportDestination {
    let client: HostedClient = try HostedServices.requireClient()
    return ReportDestination(baseURL: client.baseURL, accessToken: try await client.validAccessToken())
}
