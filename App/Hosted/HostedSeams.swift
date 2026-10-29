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
@MainActor
func hostedMeetingLLMProvider() throws -> LLMProvider {
    // Çevrimdışı kayıtta toplantı oturumu yok: canlı çağrılar yapılmaz (önceki toplantının bütçesine yazılmaz).
    guard !HostedAccount.shared.isOfflineRecording else {
        throw HostedClientError.offlineRecording
    }
    let client: HostedClient = try HostedServices.requireClient()
    return .hosted(HostedLLMConfig(baseURL: client.baseURL, credentials: client, scope: .meeting))
}

/// Kaydı biten toplantının notu: kaydın kendi sunucu oturumunun bütçesinden (bkz. `HostedMeetingLink`); kaydın oturumu
/// yoksa hesap çağrısı (kullanıcının toplantı dışı payından), başka bir toplantının bütçesi asla kullanılmaz.
func hostedRecordedMeetingLLMProvider(recordID: String) throws -> LLMProvider {
    let client: HostedClient = try HostedServices.requireClient()
    guard let serverMeetingID = hostedServerMeetingID(recordID: recordID, links: try loadHostedMeetingLinks()) else {
        return .hosted(HostedLLMConfig(baseURL: client.baseURL, credentials: client, scope: .account))
    }
    return .hosted(HostedLLMConfig(baseURL: client.baseURL, credentials: client, scope: .recordedMeeting(serverMeetingID: serverMeetingID)))
}

/// Her zaman kullanılabilen yapay zekâ çağrıları (Sor, notu yeniden yazma, düzenleme, paylaşım çevirisi, görev aracı):
/// toplantı kimliği gönderilmez, kullanıcının sınırlarına sayılır.
func hostedAccountLLMProvider() throws -> LLMProvider {
    let client: HostedClient = try HostedServices.requireClient()
    return .hosted(HostedLLMConfig(baseURL: client.baseURL, credentials: client, scope: .account))
}

/// Son geçiş: kayıt sunucunun `/v1/transcribe` ucuyla (ElevenLabs Scribe) yazıya dökülür; ses yalnızca kaydın kendi
/// sunucu oturumuna yazılır (bkz. `HostedMeetingLink`), başka bir toplantının bütçesinden düşmez. Kaydın oturumu
/// yoksa (içe aktarılan dosya, eski kayıt) son geçiş atlanır ve nedeni toplantıda görünür; oturumun ses hakkı kapandıysa
/// sunucu reddeder ve nedeni yine toplantıda görünür.
func hostedFinalPassPlan(keyterms: [String], recordID: String) async -> FinalPassPlan {
    let client: HostedClient
    let links: [HostedMeetingLink]
    do {
        client = try HostedServices.requireClient()
        links = try loadHostedMeetingLinks()
    } catch {
        return .skip(reason: userFacingMessage(error: error))
    }
    guard let meetingID = hostedServerMeetingID(recordID: recordID, links: links) else {
        return .skip(reason: String(localized: "Bu toplantı sunucuda bir kayıt oturumuna bağlı değil; konuşmacılar canlı metinden kalır."))
    }
    return .run(HostedFinalTranscriber(client: client, meetingID: meetingID, keyterms: keyterms))
}

/// Kayıt–sunucu oturumu bağlarının UserDefaults anahtarı.
private let hostedMeetingLinksKey: String = "hosted.meetingLinks"

/// Saklanan bağlar (yoksa boş); bozuk kayıt `StorageError`.
func loadHostedMeetingLinks() throws -> [HostedMeetingLink] {
    guard let data = UserDefaults.standard.data(forKey: hostedMeetingLinksKey) else {
        return []
    }
    do {
        return try JSONDecoder().decode([HostedMeetingLink].self, from: data)
    } catch {
        throw StorageError.writeFailed(path: hostedMeetingLinksKey, reason: "bağlar okunamadı: \(error.localizedDescription)")
    }
}

/// Kaydı sunucu oturumuna bağlar (en yeni `hostedMeetingLinkCapacity` bağ tutulur).
func saveHostedMeetingLink(link: HostedMeetingLink) throws {
    let links: [HostedMeetingLink] = appendingHostedMeetingLink(links: try loadHostedMeetingLinks(), link: link, capacity: hostedMeetingLinkCapacity)
    UserDefaults.standard.set(try JSONEncoder().encode(links), forKey: hostedMeetingLinksKey)
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

/// Abonelikte kaydı engelleyen hak durumu (deneme bitti, aylık sınır doldu); hak durumu okunmamışsa ya da kayıt
/// başlayabilirse nil (bkz. `hostedStartBlock`).
@MainActor
func hostedStartBlockNotice() -> StartBlockNotice? {
    // Hak durumu okunamıyorsa (çevrimdışı) kayıt, son bilinen hak durumu son 7 günde izin verdiyse çevrimdışı başlar;
    // vermediyse neden burada yazar (başlatıp hata göstermek yerine).
    if case .signedInStatusUnknown = HostedAccount.shared.state {
        let permit: HostedOfflinePermit? = loadHostedOfflinePermit()
        guard hostedOfflineRecordingMinutes(permit: permit, userId: permit?.userId, now: Date(), maxAgeSec: hostedOfflinePermitMaxAgeSec) == nil else {
            return nil
        }
        return StartBlockNotice(reason: userFacingMessage(error: HostedClientError.offlineNotAllowed), action: .retry)
    }
    guard case .signedIn(let entitlements) = HostedAccount.shared.state, let block = hostedStartBlock(entitlements: entitlements) else {
        return nil
    }
    switch block {
    case .trialEnded:
        return StartBlockNotice(reason: String(localized: "Ücretsiz denemen bitti. Kayda devam etmek için abone ol."), action: .subscribe)
    case .monthlyCapReached:
        return StartBlockNotice(
            reason: String(localized: "Bu ayki kullanım sınırın doldu; \(hostedResetDayText(now: Date())) tarihinde sıfırlanır."), action: .openAccount
        )
    case .subscriptionEnded:
        return StartBlockNotice(reason: String(localized: "Aboneliğin sona erdi. Kayda devam etmek için yeniden abone ol."), action: .subscribe)
    }
}
