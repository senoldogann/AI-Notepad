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
    // Hakkı yoksa (deneme bitti, bu Mac'te kullanıldı) "önce toplantı kaydet" denmez: sorunca abone olma teklifi açılır.
    guard case .signedIn(let entitlements) = account.state, entitlements.plan == .trial, entitlements.trialEndsAt == nil,
          !account.requiresSubscription else {
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

/// Hesap düzeyindeki yapay zekâ çağrısından önce: hakkı yoksa (deneme bitti, bu Mac'te kullanıldı, abonelik sona erdi)
/// istek sunucuya gitmez, abone olma teklifi açılır (en çok `hostedSubscriptionPromptIntervalSec`'te bir) ve
/// `subscription_required` fırlar ("deneme ilk toplantıyla başlar" gibi yanıltıcı sunucu yanıtı yerine).
@MainActor
func requireHostedAIAllowance() throws {
    guard HostedAccount.shared.requiresSubscription else {
        return
    }
    HostedAccount.shared.promptSubscriptionIfDue()
    throw HostedAPIError(code: .subscriptionRequired, rawCode: HostedErrorCode.subscriptionRequired.rawValue, status: 402, serverMessage: "", path: "/v1/llm/messages")
}

/// Her zaman kullanılabilen yapay zekâ çağrıları (Sor, notu yeniden yazma, düzenleme, paylaşım çevirisi, görev aracı):
/// toplantı kimliği gönderilmez, kullanıcının sınırlarına sayılır.
func hostedAccountLLMProvider() throws -> LLMProvider {
    let client: HostedClient = try HostedServices.requireClient()
    return .hosted(HostedLLMConfig(baseURL: client.baseURL, credentials: client, scope: .account))
}

/// Son geçiş: kayıt sunucunun `/v1/transcribe` ucuyla (ElevenLabs Scribe) yazıya dökülür; ses yalnızca kaydın kendi
/// sunucu oturumuna yazılır (bkz. `HostedMeetingLink`), başka bir toplantının bütçesinden düşmez. Oturumun ek süresi
/// (30 dk) geçtiyse önce yeniden işleme için açılır (`reprocessMeeting`; sınırlı sayıda, yeni deneme ya da toplantı süresi
/// açmaz). Kaydın oturumu yoksa, yeniden açılamıyorsa ya da ses hakkı kapandıysa son geçiş yapılmaz ve nedeni toplantıda
/// görünür (önceki son geçiş metni varsa korunur).
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
    do {
        let reopened: HostedReprocessedMeeting = try await client.reprocessMeeting(meetingID: meetingID)
        seamsLogger.info("Kaydın sunucu oturumu işlemeye açık, kalan yeniden işleme: \(reopened.reprocessesLeft, privacy: .public)")
    } catch let error as HostedAPIError where error.code == .notFound {
        // Toplantı sunucuda varsa (kapatma isteği yanıtlanıyorsa) 404 yeniden işleme ucunun olmadığıdır: sunucu güncel
        // değil. İşleme açıkça durur; son geçiş sessizce atlanmaz.
        if await hostedMeetingExists(client: client, meetingID: meetingID) {
            seamsLogger.error("Sunucu yeniden işleme ucunu tanımıyor, işleme durdu")
            return .stop(HostedClientError.serverOutdated(path: "/v1/meetings/{id}/reprocess"))
        }
        seamsLogger.warning("Kaydın sunucu oturumu yok, son geçiş yapılmadı")
        return .skip(reason: userFacingMessage(error: error))
    } catch {
        seamsLogger.warning("Kaydın sunucu oturumu yeniden açılamadı, hata: \(String(describing: error), privacy: .private)")
        return .skip(reason: userFacingMessage(error: error))
    }
    return .run(HostedFinalTranscriber(client: client, meetingID: meetingID, keyterms: keyterms))
}

/// Toplantı sunucuda var mı: kapatma isteği (bitmiş toplantıda etkisiz) yanıtlanıyorsa evet, `not_found` ise hayır; diğer
/// hatalarda bilinmez sayılır (hayır).
private func hostedMeetingExists(client: HostedClient, meetingID: String) async -> Bool {
    do {
        _ = try await client.endMeeting(meetingID: meetingID)
        return true
    } catch {
        seamsLogger.warning("Toplantının varlığı doğrulanamadı, hata: \(String(describing: error), privacy: .private)")
        return false
    }
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

/// Kaydın bağını siler (sunucu oturumu yok).
func removeHostedMeetingLink(recordID: String) throws {
    UserDefaults.standard.set(try JSONEncoder().encode(removingHostedMeetingLink(links: try loadHostedMeetingLinks(), recordID: recordID)), forKey: hostedMeetingLinksKey)
}

/// Bekleyen kayıtların sahipleri (kayıt kimliği → kullanıcı) için UserDefaults anahtarı.
private let hostedRecordOwnersKey: String = "hosted.recordOwners"

/// Bekleyen kayıtların sahipleri; yoksa boş.
func loadHostedRecordOwners() -> [String: String] {
    UserDefaults.standard.dictionary(forKey: hostedRecordOwnersKey) as? [String: String] ?? [:]
}

/// Kaydı oturumdaki kullanıcıya yazar (kuyruğa alınırken): başka hesapla giriş yapılınca o hesaba faturalanmaz.
func saveHostedRecordOwner(recordID: String, userId: String) {
    var owners: [String: String] = loadHostedRecordOwners()
    owners[recordID] = userId
    UserDefaults.standard.set(owners, forKey: hostedRecordOwnersKey)
}

/// Bağlı kayıtların kimlikleri (okunamazsa hata).
func hostedLinkedRecordIDs() throws -> Set<String> {
    Set(try loadHostedMeetingLinks().map(\.recordID))
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
        // İzin oturumdaki kullanıcınınsa geçer (başka hesabın son izni bu hesaba kayıt açmaz).
        let permit: HostedOfflinePermit? = loadHostedOfflinePermit()
        guard hostedOfflineRecordingMinutes(permit: permit, userId: HostedAccount.shared.signedInUserIDCache, now: Date(), maxAgeSec: hostedOfflinePermitMaxAgeSec) == nil else {
            return nil
        }
        return StartBlockNotice(reason: userFacingMessage(error: HostedClientError.offlineNotAllowed), action: .retry)
    }
    guard case .signedIn(let entitlements) = HostedAccount.shared.state, let block = hostedStartBlock(entitlements: entitlements) else {
        return nil
    }
    switch block {
    case .trialEnded where HostedAccount.shared.isTrialRefusedOnThisMac:
        return StartBlockNotice(reason: String(localized: "Bu Mac'te ücretsiz deneme başka bir hesapla kullanıldı. Kayda devam etmek için abone ol."), action: .subscribe)
    case .trialEnded:
        return StartBlockNotice(reason: String(localized: "Ücretsiz denemen bitti. Kayda devam etmek için abone ol."), action: .subscribe)
    case .monthlyCapReached:
        return StartBlockNotice(
            reason: String(localized: "Bu ayki kullanım sınırın doldu; \(hostedResetDayText(now: Date())) tarihinde sıfırlanır."), action: .openAccount
        )
    case .subscriptionEnded:
        return StartBlockNotice(reason: String(localized: "Aboneliğin sona erdi. Kayda devam etmek için yeniden abone ol."), action: .subscribe)
    case .paymentOverdue:
        return StartBlockNotice(reason: String(localized: "Ödeme alınamadı. Kayda devam etmek için Ayarlar › Hesap'ta \"Hesabı yönet\"ten kartını güncelle."), action: .openAccount)
    }
}
