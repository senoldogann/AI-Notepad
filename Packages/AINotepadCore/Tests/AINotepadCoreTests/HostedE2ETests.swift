import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import AINotepadCore

// Yerel sunucuyu `Process` ile hazırlar: yalnızca macOS'ta derlenir (iOS'ta `Process` yok).
#if os(macOS)

/// Yerel sunucuya karşı uçtan uca deneme yalnızca açıkça istenirse: `AINOTEPAD_HOSTED_E2E=1` ve sunucunun adresi
/// `AINOTEPAD_HOSTED_BASE` (ör. `http://127.0.0.1:8787`). Önce `server/` içinde: `.dev.vars` (sahte gizli değerler),
/// `npm run migrate:local`, `npx wrangler dev`. Denemeler üçüncü taraf servislere (Anthropic, ElevenLabs, Stripe, Apple)
/// istek göndermez: her senaryo sunucunun üst servisten önce verdiği kararı (hak, sınır, oturum) dener. Yerel
/// sunucunun ayarları `server/wrangler.jsonc` geliştirme `vars`'ıdır (3 deneme toplantısı, 7 gün, ayda 10 saat,
/// günlük harcama tavanı 25 $, deneme tavanı 10 $, `DEVICECHECK_POLICY=off`).
let hostedE2EEnabled: Bool = ProcessInfo.processInfo.environment["AINOTEPAD_HOSTED_E2E"] == "1"

/// Bellekte oturum (Anahtar Zinciri'ne dokunulmaz).
private final class MemoryTokenStorage: HostedTokenStorage {
    private let tokens: Mutex<HostedTokens?>

    init(tokens initial: HostedTokens?) {
        tokens = Mutex(initial)
    }

    func load() throws -> HostedTokens? {
        tokens.withLock { $0 }
    }

    func save(tokens saved: HostedTokens) throws {
        tokens.withLock { $0 = saved }
    }

    func clear() throws {
        tokens.withLock { $0 = nil }
    }
}

/// Oturum kapanınca çağrılan geri çağrının sayacı.
private final class SessionEndCounter: Sendable {
    let count: Mutex<Int> = Mutex(0)
}

/// Yerel D1'de SQL çalıştırır (`wrangler d1 execute --local`; üretim veritabanına hiç dokunmaz).
private func executeLocalD1(sql: String) throws {
    let process: Process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["npx", "wrangler", "d1", "execute", "ainotepad", "--local", "--command", sql]
    process.currentDirectoryURL = serverDirectory()
    let output: Pipe = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let log: String = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw HostedClientError.malformedResponse(path: "wrangler d1 execute", status: Int(process.terminationStatus), body: log)
    }
}

/// `wrangler d1 execute --json` çıktısındaki toplantı satırı.
private struct MeetingEndRow: Decodable {
    let ended_at: Int?
}

/// `wrangler d1 execute --json` çıktısındaki bir ifadenin sonucu.
private struct MeetingEndStatement: Decodable {
    let results: [MeetingEndRow]
}

/// Yerel D1'deki toplantı oturumu kapanmış mı (`ended_at` dolu); oturum yoksa hata.
private func localMeetingIsEnded(meetingID: String) throws -> Bool {
    let process: Process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["npx", "wrangler", "d1", "execute", "ainotepad", "--local", "--json", "--command", "SELECT ended_at FROM meeting_sessions WHERE id = '\(meetingID)';"]
    process.currentDirectoryURL = serverDirectory()
    let output: Pipe = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data: Data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let row = try JSONDecoder().decode([MeetingEndStatement].self, from: data).first?.results.first else {
        throw HostedClientError.malformedResponse(path: "wrangler d1 execute --json", status: Int(process.terminationStatus), body: String(decoding: data, as: UTF8.self))
    }
    return row.ended_at != nil
}

/// Toplantı kaydı (yalnızca kuyruğun sahiplik ayrımı için gereken alanlarla).
private func queuedRecord(id: String) -> MeetingRecord {
    MeetingRecord(
        id: id, title: id, startedAt: Date(), endedAt: Date(), language: nil, status: .queued, failureMessage: nil,
        liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false,
        engine: .local, notice: nil, meNeedsFinalPass: nil
    )
}

/// Şimdiki an (ms, sunucunun sakladığı biçim).
private func nowMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
}

/// Sunucunun gün ve ay anahtarları ("YYYY-MM-DD", "YYYY-MM"; UTC).
private func utcDayKey() -> String {
    String(ISO8601DateFormatter().string(from: Date()).prefix(10))
}

private func utcMonthKey() -> String {
    String(utcDayKey().prefix(7))
}

/// Apple ve Google kimlik jetonları yerelde üretilemediği için oturum yerel D1'e doğrudan eklenir (kullanıcı, oturum
/// ailesi ve yenileme jetonu; sunucunun saklama biçimi: SHA-256 onaltılık). İstemci bu jetonla `/v1/auth/refresh`
/// üzerinden gerçek oturumu alır; giriş ucundan sonraki her adım uygulamanınkiyle aynıdır.
private func insertSession(refreshToken: String) throws -> String {
    let hash: String = SHA256.hash(data: Data(refreshToken.utf8)).map { String(format: "%02x", $0) }.joined()
    let now: Int = nowMs()
    let userID: String = "e2e-\(UUID().uuidString.lowercased())"
    let familyID: String = "e2e-\(UUID().uuidString.lowercased())"
    try executeLocalD1(sql: [
        "INSERT INTO users (id, created_at) VALUES ('\(userID)', \(now));",
        "INSERT INTO refresh_families (id, user_id, created_at) VALUES ('\(familyID)', '\(userID)', \(now));",
        "INSERT INTO refresh_tokens (token_hash, family_id, created_at, expires_at) VALUES ('\(hash)', '\(familyID)', \(now), \(now + 24 * 3_600_000));",
    ].joined(separator: " "))
    return userID
}

/// Rastgele base64url jeton (sunucunun ürettiğiyle aynı biçim).
private func randomToken() -> String {
    Data((0..<32).map { (_: Int) -> UInt8 in UInt8.random(in: 0...255) }).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// Yerel sunucunun adresi.
private func localServerBase() throws -> URL {
    let base: String = try #require(ProcessInfo.processInfo.environment["AINOTEPAD_HOSTED_BASE"], "AINOTEPAD_HOSTED_BASE (wrangler dev adresi) gerekli")
    return try parseHostedBaseURL(value: base)
}

/// Giriş uçlarının IP hız sınırı (`AUTH_IP_LIMITER`, dakikada 10; yenileme ve çıkış da sayılır) yerelde de uygulanır:
/// işlem `rate_limited` alırsa bir dakika beklenip yeniden denenir (en çok 3 bekleme).
private func awaitingAuthLimit<Value: Sendable>(operation: () async throws -> Value) async throws -> Value {
    for _ in 1...3 {
        do {
            return try await operation()
        } catch let error as HostedAPIError where error.code == .rateLimited {
            try await Task.sleep(for: .seconds(61))
        }
    }
    return try await operation()
}

/// Yeni kullanıcı ve yenileme jetonuyla oturum açmış istemci (erişim jetonu alınmış).
private struct SignedInUser {
    let client: HostedClient
    let storage: MemoryTokenStorage
    let userID: String
    let seedRefreshToken: String
}

private func signedInUser(baseURL: URL) async throws -> SignedInUser {
    let seedRefreshToken: String = randomToken()
    let userID: String = try insertSession(refreshToken: seedRefreshToken)
    let storage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(
        accessToken: "gecersiz", refreshToken: seedRefreshToken, accessExpiresAt: Date.distantPast, userId: userID
    ))
    let client: HostedClient = HostedClient(baseURL: baseURL, storage: storage) { () async -> Void in }
    _ = try await awaitingAuthLimit { try await client.validAccessToken() }
    return SignedInUser(client: client, storage: storage, userID: userID, seedRefreshToken: seedRefreshToken)
}

/// Yeni bir deneme hesabının ilk toplantısı IP başına günlük deneme sınırına (yerelde 3) sayılır; yerel veritabanı
/// çalıştırmalar arasında kaldığı için önceki çalıştırmaların bugünkü sayaçları silinir.
private func resetLocalTrialStarts() throws {
    try executeLocalD1(sql: "DELETE FROM trial_starts; DELETE FROM deleted_trial_starts;")
}

/// Denemesi başlamış (bir deneme toplantısı devralınmış) kullanıcı: IP sınırına girmeden deneme toplantısı açabilir.
private func markTrialStarted(userID: String, usedMeetings: Int, startedAtMs: Int) throws {
    try executeLocalD1(sql: "UPDATE users SET carried_trial_meetings = \(usedMeetings), trial_started_at = \(startedAtMs) WHERE id = '\(userID)';")
}

/// Toplantı dışı (hesap) yapay zekâ çağrısı: uygulamanın Sor, notu yeniden yazma ve paylaşım çevirisi yolu.
private func accountLLMProvider(baseURL: URL, client: HostedClient) -> LLMProvider {
    .hosted(HostedLLMConfig(baseURL: baseURL, credentials: client, scope: .account))
}

/// Kısa bir istek (sunucunun ret kararı üst servisten önce verilir; gövde Anthropic'e gitmez).
private func smallRequest() -> LLMRequest {
    translationRequest(sentence: "Hyvää huomenta.", context: [], language: .english)
}

/// İşlemin fırlattığı sunucu hatası; başka hata ya da başarı denemeyi düşürür.
private func hostedError(operation: () async throws -> Void) async -> HostedAPIError? {
    do {
        try await operation()
        Issue.record("Sunucu hatası bekleniyordu, işlem başarılı oldu")
        return nil
    } catch let error as HostedAPIError {
        return error
    } catch LLMError.hosted(let error) {
        return error
    } catch {
        Issue.record("Sunucu hatası bekleniyordu, gelen: \(error)")
        return nil
    }
}

/// Kod tanınmadığında gösterilen genel metin: kullanıcıya ne yapacağını söylemez; eşleşen her kodda bundan farklı
/// olmalı.
private func genericHostedMessage(status: Int) -> String {
    hostedErrorMessage(error: HostedAPIError(code: nil, rawCode: "http_\(status)", status: status, serverMessage: "", path: "/"))
}

/// 1 sn sessiz 16 kHz mono 16 bit PCM WAV (sunucu süreyi başlıktan okur).
private func silentWav() -> Data {
    let sampleRate: UInt32 = 16_000
    let dataBytes: UInt32 = sampleRate * 2
    var data: Data = Data()
    let append32: (UInt32) -> Void = { (value: UInt32) -> Void in withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let append16: (UInt16) -> Void = { (value: UInt16) -> Void in withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8))
    append32(36 + dataBytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append32(16)
    append16(1)
    append16(1)
    append32(sampleRate)
    append32(sampleRate * 2)
    append16(2)
    append16(16)
    data.append(contentsOf: Array("data".utf8))
    append32(dataBytes)
    data.append(Data(count: Int(dataBytes)))
    return data
}

@Suite(.enabled(if: hostedE2EEnabled), .serialized) struct HostedE2ETests {
    // Oturum (yenileme jetonuyla) → /v1/me → toplantı başlat (deneme düşer) → bitir → erişim jetonu yenilenir →
    // yanıtı kaybolmuş yenilemenin 10 dakika içindeki tekrarı kabul edilir → halef kullanıldıktan sonra eski jeton
    // yeniden gelirse tüm oturumlar düşer ve istemci çıkış yapar.
    @Test func signInMeetingAndRefreshAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        try resetLocalTrialStarts()
        let seedRefreshToken: String = randomToken()
        let userID: String = try insertSession(refreshToken: seedRefreshToken)

        let storage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(
            accessToken: "gecersiz", refreshToken: seedRefreshToken, accessExpiresAt: Date.distantPast, userId: userID
        ))
        let ended: SessionEndCounter = SessionEndCounter()
        let client: HostedClient = HostedClient(baseURL: baseURL, storage: storage) { () async -> Void in
            ended.count.withLock { $0 += 1 }
        }
        #expect(try await client.isSignedIn())

        let before: HostedEntitlements = try await awaitingAuthLimit { try await client.entitlements() }
        #expect(hostedPlanStatus(entitlements: before) == .trial(left: before.trialMeetingsTotal, total: before.trialMeetingsTotal))
        #expect(before.trialEndsAt == nil)
        #expect(before.monthlyHoursCap > 0)

        let started: HostedStartedMeeting = try await client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false)
        #expect(started.kind == "trial")
        #expect(started.trialMeetingsLeft == before.trialMeetingsTotal - 1)
        #expect(await client.currentMeetingID() == started.meetingId)
        let credentials: HostedLLMCredentials = try await client.meetingLLMCredentials()
        #expect(credentials.meetingID == started.meetingId)

        let during: HostedEntitlements = try await client.entitlements()
        #expect(during.trialMeetingsLeft == before.trialMeetingsTotal - 1)
        // Deneme süresi ilk toplantıyla başlar.
        #expect(during.trialEndsAt != nil)
        let finished: HostedEndedMeeting = try await client.endMeeting(meetingID: started.meetingId)
        #expect(finished.meetingId == started.meetingId)
        #expect(finished.minutes == 1)

        // Erişim jetonu bitmiş sayılınca istek öncesi yenilenir; yenileme jetonu döner.
        let original: HostedTokens = try #require(try storage.load())
        try storage.save(tokens: HostedTokens(accessToken: original.accessToken, refreshToken: original.refreshToken, accessExpiresAt: Date.distantPast, userId: original.userId))
        let refreshingClient: HostedClient = HostedClient(baseURL: baseURL, storage: storage) { () async -> Void in
            ended.count.withLock { $0 += 1 }
        }
        _ = try await refreshingClient.entitlements()
        let rotated: HostedTokens = try #require(try storage.load())
        #expect(rotated.refreshToken != original.refreshToken)
        #expect(rotated.accessExpiresAt > Date())

        // Yanıtı kaybolmuş yenilemenin tekrarı (yerine geçen jeton henüz kullanılmamış, 10 dakikalık süre içinde): oturum
        // düşmez, yeni bir çift verilir; kullanılmamış eski halef geçersizleşir.
        let retryStorage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(
            accessToken: original.accessToken, refreshToken: original.refreshToken, accessExpiresAt: Date.distantPast, userId: original.userId
        ))
        let retryClient: HostedClient = HostedClient(baseURL: baseURL, storage: retryStorage) { () async -> Void in
            ended.count.withLock { $0 += 1 }
        }
        _ = try await retryClient.entitlements()
        let retried: HostedTokens = try #require(try retryStorage.load())
        #expect(retried.refreshToken != original.refreshToken)
        #expect(retried.refreshToken != rotated.refreshToken)
        #expect(ended.count.withLock { $0 } == 0)

        // Halef kullanıldıktan sonra (yeni çift bir kez daha yenilendi) eski jeton yeniden gelirse çalınmış sayılır: sunucu
        // tüm oturum ailesini kapatır, istemci yerel oturumu siler ve bildirir. Önce giriş uçlarının IP sınırı (dakikada
        // 10, diğer denemelerle ortak) sıfırlansın diye beklenir.
        try await Task.sleep(for: .seconds(61))
        // Halefi ayrı bir istemci kullanır (istemci jetonları bellekte tutar; depoyu dışarıdan değiştirmek yenilemez).
        let successorStorage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(
            accessToken: retried.accessToken, refreshToken: retried.refreshToken, accessExpiresAt: Date.distantPast, userId: retried.userId
        ))
        let successorClient: HostedClient = HostedClient(baseURL: baseURL, storage: successorStorage) { () async -> Void in }
        _ = try await successorClient.entitlements()
        let newest: HostedTokens = try #require(try successorStorage.load())
        #expect(newest.refreshToken != retried.refreshToken)
        let replayStorage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(
            accessToken: original.accessToken, refreshToken: original.refreshToken, accessExpiresAt: Date.distantPast, userId: original.userId
        ))
        let replayClient: HostedClient = HostedClient(baseURL: baseURL, storage: replayStorage) { () async -> Void in
            ended.count.withLock { $0 += 1 }
        }
        await #expect(throws: HostedClientError.sessionEnded) { _ = try await replayClient.entitlements() }
        #expect(try replayStorage.load() == nil)
        #expect(ended.count.withLock { $0 } == 1)
        // Aile düştüğü için en yeni jeton da artık geçmez.
        let familyClient: HostedClient = HostedClient(baseURL: baseURL, storage: MemoryTokenStorage(tokens: HostedTokens(
            accessToken: newest.accessToken, refreshToken: newest.refreshToken, accessExpiresAt: Date.distantPast, userId: newest.userId
        ))) { () async -> Void in }
        await #expect(throws: HostedClientError.sessionEnded) { _ = try await familyClient.entitlements() }
    }

    // Rapor ucu: geri bildirim ve çökme raporu hesap ister. Jetonsuz geri bildirim 401 `unauthorized` alır (uygulama
    // giriş yoksa sunucuya gitmeden "giriş yap" der); hesaplı (bearer) geri bildirim ve çökme raporu 2xx alır.
    @Test func reportsRequireAccountAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let diagnostics: ReportDiagnostics = currentReportDiagnostics(bundle: .main, platformName: "macOS")
        let feedback: ReportRequest = try feedbackReport(message: "Uçtan uca deneme geri bildirimi.", email: "e2e@ornek.fi", diagnostics: diagnostics)
        let anonymous: HostedAPIError? = await hostedError {
            try await submitReport(report: feedback, destination: ReportDestination(baseURL: baseURL, accessToken: nil))
        }
        #expect(anonymous?.code == .unauthorized)

        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try await submitReport(report: feedback, destination: ReportDestination(baseURL: baseURL, accessToken: try await user.client.validAccessToken()))
        let payload: Data = Data(#"{"crashDiagnostics":[{"diagnosticMetaData":{"appVersion":"0.1.4","appBuildVersion":"5","osVersion":"macOS 26.1","exceptionType":1,"signal":11}}]}"#.utf8)
        let crash: CrashDiagnostic = try #require(try crashDiagnostics(payload: payload).first)
        try await submitReport(
            report: try crashReportRequest(payload: payload, diagnostic: crash),
            destination: ReportDestination(baseURL: baseURL, accessToken: try await user.client.validAccessToken())
        )
    }

    // Bir hesabın yolculuğu, her adımda uygulamanın gösterdiği durum ve hata metni: yeni deneme (toplantı dışı yapay
    // zekâ `trial_not_started`, portal `subscription_required`, toplantısız canlı istek yerelde `noActiveMeeting`) →
    // deneme bitti (`trial_exhausted`, toplantı dışı `subscription_required`) → abonelik etkin → aylık sınır dolu
    // (`monthly_cap_reached`) → ödeme gecikti (ek süre) → abonelik iptal edildi.
    @Test func accountJourneyStatesAndMessagesAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        let client: HostedClient = user.client
        let account: LLMProvider = accountLLMProvider(baseURL: baseURL, client: client)

        // 1. Yeni hesap, deneme başlamadı.
        let fresh: HostedEntitlements = try await client.entitlements()
        #expect(fresh.plan == .trial)
        #expect(hostedPlanStatus(entitlements: fresh) == .trial(left: fresh.trialMeetingsTotal, total: fresh.trialMeetingsTotal))
        #expect(fresh.trialEndsAt == nil)
        let notStarted: HostedAPIError? = await hostedError { _ = try await sendLLM(provider: account, request: smallRequest()) }
        #expect(notStarted?.code == .trialNotStarted)
        #expect(notStarted?.status == 403)
        if let notStarted {
            #expect(userFacingMessage(error: LLMError.hosted(notStarted)) != genericHostedMessage(status: 403))
            #expect(userFacingMessage(error: LLMError.hosted(notStarted)) == hostedErrorMessage(error: notStarted))
        }
        let portal: HostedAPIError? = await hostedError { _ = try await client.portalURL() }
        #expect(portal?.code == .subscriptionRequired)
        // Kayıt sırasındaki istekler (canlı çeviri, "Ne kaçırdım?") toplantı ister: toplantı yokken ağa çıkmadan durur.
        let meetingScoped: LLMProvider = .hosted(HostedLLMConfig(baseURL: baseURL, credentials: client, scope: .meeting))
        await #expect(throws: HostedClientError.noActiveMeeting) { _ = try await sendLLM(provider: meetingScoped, request: smallRequest()) }
        #expect(stopsLiveTranslation(error: HostedClientError.noActiveMeeting))

        // 2. Deneme toplantıları harcandı.
        try markTrialStarted(userID: user.userID, usedMeetings: fresh.trialMeetingsTotal, startedAtMs: nowMs())
        let exhausted: HostedEntitlements = try await client.entitlements()
        #expect(hostedPlanStatus(entitlements: exhausted) == .trial(left: 0, total: exhausted.trialMeetingsTotal))
        #expect(exhausted.trialEndsAt != nil)
        let exhaustedStart: HostedAPIError? = await hostedError { _ = try await client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false) }
        #expect(exhaustedStart?.code == .trialExhausted)
        #expect(exhaustedStart?.status == 402)
        let exhaustedAsk: HostedAPIError? = await hostedError { _ = try await sendLLM(provider: account, request: smallRequest()) }
        #expect(exhaustedAsk?.code == .subscriptionRequired)
        if let exhaustedAsk {
            #expect(stopsLiveTranslation(error: LLMError.hosted(exhaustedAsk)))
        }

        // 3. Abonelik etkin (webhook'un yazdığı satır).
        let periodEnd: Int = nowMs() + 30 * 86_400_000
        try executeLocalD1(sql: """
            INSERT INTO subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, current_period_end, last_event_created, updated_at)
            VALUES ('\(user.userID)', 'cus_\(user.userID)', 'sub_\(user.userID)', 'active', \(periodEnd), 1, \(nowMs()));
            """)
        let subscribed: HostedEntitlements = try await client.entitlements()
        #expect(subscribed.plan == .subscription)
        #expect(subscribed.subscription?.access == .active)
        if case .subscribed = hostedPlanStatus(entitlements: subscribed) {
        } else {
            Issue.record("Etkin abonelik `.subscribed` görünmeli: \(hostedPlanStatus(entitlements: subscribed))")
        }

        // 4. Bu ayın süresi doldu: abonelik toplantısı başlamaz.
        let capSeconds: Int = Int(subscribed.monthlyHoursCap * 3600)
        try executeLocalD1(sql: "INSERT INTO monthly_usage (user_id, month, audio_seconds) VALUES ('\(user.userID)', '\(utcMonthKey())', \(capSeconds));")
        let capped: HostedEntitlements = try await client.entitlements()
        #expect(capped.monthlyHoursUsed >= capped.monthlyHoursCap)
        let cappedStart: HostedAPIError? = await hostedError { _ = try await client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false) }
        #expect(cappedStart?.code == .monthlyCapReached)
        if let cappedStart {
            #expect(userFacingMessage(error: cappedStart) != genericHostedMessage(status: 403))
        }

        // 5. Ödeme alınamadı: ek süre boyunca erişim sürer.
        try executeLocalD1(sql: "UPDATE subscriptions SET status = 'past_due', past_due_since = \(nowMs()), current_period_end = \(nowMs() - 86_400_000) WHERE user_id = '\(user.userID)';")
        let pastDue: HostedEntitlements = try await client.entitlements()
        #expect(pastDue.plan == .subscription)
        #expect(pastDue.subscription?.access == .grace)
        if case .grace = hostedPlanStatus(entitlements: pastDue) {
        } else {
            Issue.record("Ek süredeki abonelik `.grace` görünmeli: \(hostedPlanStatus(entitlements: pastDue))")
        }

        // 6. Abonelik iptal edildi: sunucu planı denemeye döndürür (deneme toplantıları harcanmış); uygulama bunu
        // "deneme bitti" değil "abonelik sona erdi" olarak gösterir ve yeniden abone olmayı önerir.
        try executeLocalD1(sql: "UPDATE subscriptions SET status = 'canceled', past_due_since = NULL WHERE user_id = '\(user.userID)';")
        let canceled: HostedEntitlements = try await client.entitlements()
        #expect(canceled.plan == .trial)
        #expect(canceled.subscription?.access == HostedSubscriptionAccess.none)
        if case .expired = hostedPlanStatus(entitlements: canceled) {
            #expect(hostedStartBlock(entitlements: canceled) == .subscriptionEnded)
        } else {
            Issue.record("İptal edilmiş abonelik `.expired` görünmeli: \(hostedPlanStatus(entitlements: canceled))")
        }
        let canceledAsk: HostedAPIError? = await hostedError { _ = try await sendLLM(provider: account, request: smallRequest()) }
        #expect(canceledAsk?.code == .subscriptionRequired)
    }

    // Günlük harcama tavanları: deneme tavanı dolunca deneme toplantısı ve denemedeki toplantı dışı yapay zekâ
    // `trial_capacity_reached`, genel tavan dolunca toplantı `spend_ceiling_reached` alır; ikisi de kalıcı sayılır
    // (yeniden denenmez) ve canlı çeviriyi durdurur. Bugünkü harcama sayaçları deneme sonunda geri alınır.
    @Test func spendCeilingsAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 1, startedAtMs: nowMs())
        let bump: Int = 1_000_000_000_000
        let day: String = utcDayKey()

        try executeLocalD1(sql: "INSERT INTO daily_spend (day, micro_usd, trial_micro_usd) VALUES ('\(day)', 0, \(bump)) ON CONFLICT(day) DO UPDATE SET trial_micro_usd = trial_micro_usd + \(bump);")
        let trialStart: HostedAPIError? = await hostedError { _ = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false) }
        let trialAsk: HostedAPIError? = await hostedError {
            _ = try await sendLLM(provider: accountLLMProvider(baseURL: baseURL, client: user.client), request: smallRequest())
        }
        try executeLocalD1(sql: "UPDATE daily_spend SET trial_micro_usd = trial_micro_usd - \(bump) WHERE day = '\(day)';")
        #expect(trialStart?.code == .trialCapacityReached)
        #expect(trialAsk?.code == .trialCapacityReached)
        if let trialAsk {
            #expect(!isRetryableHostedError(error: trialAsk))
            #expect(stopsLiveTranslation(error: LLMError.hosted(trialAsk)))
        }

        try executeLocalD1(sql: "INSERT INTO daily_spend (day, micro_usd) VALUES ('\(day)', \(bump)) ON CONFLICT(day) DO UPDATE SET micro_usd = micro_usd + \(bump);")
        let ceilingStart: HostedAPIError? = await hostedError { _ = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false) }
        try executeLocalD1(sql: "UPDATE daily_spend SET micro_usd = micro_usd - \(bump) WHERE day = '\(day)';")
        #expect(ceilingStart?.code == .spendCeilingReached)
        #expect(ceilingStart?.status == 503)
        if let ceilingStart {
            #expect(!isRetryableHostedError(error: ceilingStart))
            #expect(userFacingMessage(error: ceilingStart) != genericHostedMessage(status: 503))
        }
    }

    // Son geçiş yüklemesi: toplantıda süren bir ses isteği varken (ör. zaman aşımına uğrayan yüklemenin istemci
    // tekrarı) sunucu `409 transcription_in_progress` döner; ses hakkı kapanmış toplantı `403 transcription_closed`.
    // İkisi de üst servise gitmeden reddedilir.
    @Test func finalPassUploadConflictsAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 1, startedAtMs: nowMs())
        let started: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false)
        let wav: URL = FileManager.default.temporaryDirectory.appending(path: "ainotepad-e2e-\(UUID().uuidString).wav", directoryHint: .notDirectory)
        try silentWav().write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let now: Int = nowMs()
        try executeLocalD1(sql: """
            INSERT INTO usage_reservations (id, user_id, meeting_id, kind, month, day, tokens, trial_account_tokens, account_tokens, audio_seconds, estimated_micro_usd, trial_spend, created_at, expires_at)
            VALUES ('e2e-\(UUID().uuidString.lowercased())', '\(user.userID)', '\(started.meetingId)', 'audio', '\(utcMonthKey())', '\(utcDayKey())', 0, 0, 0, 1, 0, 1, \(now), \(now + 600_000));
            """)
        let inProgress: HostedAPIError? = await hostedError {
            _ = try await user.client.transcribe(meetingID: started.meetingId, wavFile: wav, languageCode: nil, keyterms: [], uploadKey: try makeUploadKey(), timeoutSec: 30)
        }
        try executeLocalD1(sql: "DELETE FROM usage_reservations WHERE meeting_id = '\(started.meetingId)';")
        #expect(inProgress?.status == 409)
        #expect(inProgress?.rawCode == "transcription_in_progress")
        // İstemci kodu tanır: son geçiş bekleyip yeniden dener (HostedFinalTranscriber), kullanıcı genel hata görmez.
        #expect(inProgress?.code == .transcriptionInProgress)
        if let inProgress {
            #expect(userFacingMessage(error: inProgress) != genericHostedMessage(status: 409))
        }

        try executeLocalD1(sql: "UPDATE meeting_sessions SET transcription_closed = 1 WHERE id = '\(started.meetingId)';")
        let closed: HostedAPIError? = await hostedError {
            _ = try await user.client.transcribe(meetingID: started.meetingId, wavFile: wav, languageCode: nil, keyterms: [], uploadKey: try makeUploadKey(), timeoutSec: 30)
        }
        #expect(closed?.code == .transcriptionClosed)
        _ = try await user.client.endMeeting(meetingID: started.meetingId)
    }

    // Çevrimdışı kaydedilmiş toplantı bağlantı gelince açılır: aynı kayıt kimliğiyle (`clientRef`) yinelenen başlatma
    // (yanıt kaybolduysa, uygulama yeniden açıldıysa) aynı oturumu döndürür, deneme bir kez düşer; oturum hemen
    // kapatılsa da ses hakkı en çok sürece açıktır ve not için ek süre başlar.
    @Test func deferredMeetingStartIsIdempotentAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        // Yeni deneme kullanıcısı IP başına günlük deneme sayısına yazılır: tek başına tekrar koşunca sınıra takılmasın.
        try resetLocalTrialStarts()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        let before: HostedEntitlements = try await user.client.entitlements()
        let recordID: String = "kayit-\(UUID().uuidString.lowercased())"
        let first: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: recordID, deferred: true)
        _ = try await user.client.endMeeting(meetingID: first.meetingId)
        let repeated: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: recordID, deferred: true)
        #expect(repeated.meetingId == first.meetingId)
        #expect(repeated.maxDurationMinutes == first.maxDurationMinutes)
        let after: HostedEntitlements = try await user.client.entitlements()
        #expect(after.trialMeetingsLeft == before.trialMeetingsLeft - 1)
        // Kapatma tekrarı zararsız; kapalı oturum yapay zekâ çağrısı için ek sürede açık.
        let ended: HostedEndedMeeting = try await user.client.endMeeting(meetingID: first.meetingId)
        #expect(ended.meetingId == first.meetingId)
        let other: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: "kayit-\(UUID().uuidString.lowercased())", deferred: false)
        #expect(other.meetingId != first.meetingId)
        _ = try await user.client.endMeeting(meetingID: other.meetingId)
    }

    // Ek süresi (30 dk) geçmiş toplantı: toplantı kapsamlı çağrı `meeting_not_active` alır; "Tekrar işle" oturumu
    // yeniden işleme için açar (`reprocessMeeting`, en çok iki kez; yeni deneme düşmez), sonra çağrı yine geçer. Sınır
    // dolunca `reprocess_limit_reached` ve kullanıcı genel hata değil gerçek nedeni görür.
    @Test func reprocessAfterGraceAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 1, startedAtMs: nowMs())
        let started: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false)
        _ = try await user.client.endMeeting(meetingID: started.meetingId)
        let stillOpen: HostedReprocessedMeeting = try await user.client.reprocessMeeting(meetingID: started.meetingId)
        #expect(stillOpen.reprocessesLeft == 2)
        let before: HostedEntitlements = try await user.client.entitlements()
        let ageMeeting: String = """
            UPDATE meeting_sessions SET started_at = started_at - 7200000, max_ends_at = max_ends_at - 7200000,
              ended_at = ended_at - 7200000, reprocess_until = CASE WHEN reprocess_until IS NULL THEN NULL ELSE reprocess_until - 7200000 END
            WHERE id = '\(started.meetingId)';
            """
        try executeLocalD1(sql: ageMeeting)
        let wav: URL = FileManager.default.temporaryDirectory.appending(path: "ainotepad-e2e-\(UUID().uuidString).wav", directoryHint: .notDirectory)
        try silentWav().write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        let expired: HostedAPIError? = await hostedError {
            _ = try await user.client.transcribe(meetingID: started.meetingId, wavFile: wav, languageCode: nil, keyterms: [], uploadKey: try makeUploadKey(), timeoutSec: 30)
        }
        #expect(expired?.code == .meetingNotActive)

        let first: HostedReprocessedMeeting = try await user.client.reprocessMeeting(meetingID: started.meetingId)
        #expect(first.reprocessesLeft == 1)
        #expect(first.usableUntil > Date())
        try executeLocalD1(sql: ageMeeting)
        let second: HostedReprocessedMeeting = try await user.client.reprocessMeeting(meetingID: started.meetingId)
        #expect(second.reprocessesLeft == 0)
        try executeLocalD1(sql: ageMeeting)
        let limited: HostedAPIError? = await hostedError { _ = try await user.client.reprocessMeeting(meetingID: started.meetingId) }
        #expect(limited?.code == .reprocessLimitReached)
        if let limited {
            #expect(userFacingMessage(error: limited) != genericHostedMessage(status: 409))
        }
        let after: HostedEntitlements = try await user.client.entitlements()
        #expect(after.trialMeetingsLeft == before.trialMeetingsLeft)
        // Ölü bağ (sunucuda olmayan ya da başka hesabın oturumu) `not_found` döner: kuyruk bağı silip yeni oturum açar.
        let missing: HostedAPIError? = await hostedError { _ = try await user.client.endMeeting(meetingID: UUID().uuidString.lowercased()) }
        #expect(missing?.code == .notFound)
        let foreign: SignedInUser = try await signedInUser(baseURL: baseURL)
        let foreignReprocess: HostedAPIError? = await hostedError { _ = try await foreign.client.reprocessMeeting(meetingID: started.meetingId) }
        #expect(foreignReprocess?.code == .notFound)
    }

    // İçe aktarılan dosya kayıt gibi sayılır: kuyruk sunucu oturumunu `clientRef` ile açar, deneme hakkı düşer; deneme
    // bitince yeni içe aktarma reddedilir (`trial_exhausted`, ses Mac'te kalır), ama yarıda kalmış içe aktarmanın aynı
    // kimlikle yinelenen açılışı (uygulama kapanıp açıldı) yine aynı oturumu döndürür.
    @Test func importedFileCountsLikeRecordingAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 2, startedAtMs: nowMs())
        let importID: String = "ice-aktarim-\(UUID().uuidString.lowercased())"
        let imported: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: importID, deferred: true)
        #expect(imported.kind == "trial")
        #expect(imported.trialMeetingsLeft == 0)
        _ = try await user.client.endMeeting(meetingID: imported.meetingId)
        let repeated: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: importID, deferred: true)
        #expect(repeated.meetingId == imported.meetingId)
        let refused: HostedAPIError? = await hostedError {
            _ = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: "ice-aktarim-\(UUID().uuidString.lowercased())", deferred: true)
        }
        #expect(refused?.code == .trialExhausted)
        let after: HostedEntitlements = try await user.client.entitlements()
        #expect(hostedStartBlock(entitlements: after) == .trialEnded)
    }

    // Çıkış ve hesap silme: ikisinde de yerel oturum silinir; eski yenileme jetonu artık geçmez (istemci "oturum
    // kapandı" der ve kayıtlı oturumu siler).
    @Test func signOutAndDeleteAccountAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()

        let leaving: SignedInUser = try await signedInUser(baseURL: baseURL)
        try await awaitingAuthLimit { try await leaving.client.signOut() }
        #expect(try await leaving.client.isSignedIn() == false)
        await #expect(throws: HostedClientError.notSignedIn) { _ = try await leaving.client.entitlements() }
        let stale: HostedTokens = HostedTokens(accessToken: "gecersiz", refreshToken: leaving.seedRefreshToken, accessExpiresAt: Date.distantPast, userId: leaving.userID)
        let staleStorage: MemoryTokenStorage = MemoryTokenStorage(tokens: stale)
        let staleClient: HostedClient = HostedClient(baseURL: baseURL, storage: staleStorage) { () async -> Void in }
        await #expect(throws: HostedClientError.sessionEnded) {
            _ = try await awaitingAuthLimit { try await staleClient.entitlements() }
        }
        #expect(try staleStorage.load() == nil)

        let deleting: SignedInUser = try await signedInUser(baseURL: baseURL)
        let current: HostedTokens = try #require(try deleting.storage.load())
        try await deleting.client.deleteAccount()
        #expect(try await deleting.client.isSignedIn() == false)
        let deletedStorage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(
            accessToken: "gecersiz", refreshToken: current.refreshToken, accessExpiresAt: Date.distantPast, userId: current.userId
        ))
        let deletedClient: HostedClient = HostedClient(baseURL: baseURL, storage: deletedStorage) { () async -> Void in }
        await #expect(throws: HostedClientError.sessionEnded) {
            _ = try await awaitingAuthLimit { try await deletedClient.entitlements() }
        }
    }

    // Çevrimdışı kayıt → bağlantı gelince işlenir: sunucuya ulaşılamazken (kapalı kapı, erişim jetonunun süresi de
    // dolmuş) toplantı başlatma gerçek URLSession hatasıyla "çevrimdışı" sayılır, oturum düşmez ve son hak durumunun
    // izni kayda süre verir. Aynı Mac'te başka hesap açılınca kayıt o hesapla işlenmez. Bağlantı gelince (uygulama
    // yeniden açılmış gibi yeni istemci, aynı jeton deposu) kayıt kendi kimliğiyle ertelenmiş oturum açar, yinelenen
    // açılış aynı oturumu döndürür, süren canlı toplantı kapanmaz ve deneme yalnızca sahibinden bir kez düşer.
    @Test func offlineRecordingIsProcessedWhenBackOnlineAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        try resetLocalTrialStarts()
        let owner: SignedInUser = try await signedInUser(baseURL: baseURL)
        let lastKnown: HostedEntitlements = try await owner.client.entitlements()
        let permit: HostedOfflinePermit = try #require(hostedOfflinePermit(entitlements: lastKnown, now: Date()))
        let live: HostedStartedMeeting = try await owner.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: "canli-\(UUID().uuidString.lowercased())", deferred: false)

        // Sunucuya ulaşılamıyor; erişim jetonu da bitmiş (yenileme de ağa çıkmalı).
        let stored: HostedTokens = try #require(try owner.storage.load())
        try owner.storage.save(tokens: HostedTokens(accessToken: stored.accessToken, refreshToken: stored.refreshToken, accessExpiresAt: Date.distantPast, userId: stored.userId))
        let endedSessions: SessionEndCounter = SessionEndCounter()
        let offline: HostedClient = HostedClient(baseURL: try parseHostedBaseURL(value: "http://127.0.0.1:1"), storage: owner.storage) { () async -> Void in
            endedSessions.count.withLock { $0 += 1 }
        }
        let recordID: String = "kayit-\(UUID().uuidString.lowercased())"
        do {
            _ = try await offline.startMeeting(device: nil, deviceCheckToken: nil, clientRef: recordID, deferred: false)
            Issue.record("Kapalı kapıya başlatma başarılı olmamalı")
        } catch {
            #expect(isOfflineStartError(error: error), "Ulaşılamayan sunucu çevrimdışı kayda düşmeli: \(error)")
        }
        #expect(try await offline.isSignedIn())
        #expect(endedSessions.count.withLock { $0 } == 0)
        #expect(try owner.storage.load()?.refreshToken == stored.refreshToken)
        #expect(hostedOfflineRecordingMinutes(permit: permit, userId: try owner.storage.load()?.userId, now: Date(), maxAgeSec: hostedOfflinePermitMaxAgeSec) == permit.maxMinutes)

        // Aynı Mac'te başka hesap: kayıt onun kuyruğunda değil, onun denemesi düşmez.
        let other: SignedInUser = try await signedInUser(baseURL: baseURL)
        let otherBefore: HostedEntitlements = try await other.client.entitlements()
        let owners: [String: String] = [recordID: owner.userID]
        let asOther: HostedQueuedRecords = hostedQueuedRecords(records: [queuedRecord(id: recordID)], owners: owners, userId: other.userID)
        #expect(asOther.own.isEmpty)
        #expect(asOther.foreign.map(\.id) == [recordID])

        // Bağlantı geldi: sahibinin kuyruğunda; ertelenmiş oturum açılır, yinelenen açılış aynı oturumu döndürür.
        let online: HostedClient = HostedClient(baseURL: baseURL, storage: owner.storage) { () async -> Void in }
        let asOwner: HostedQueuedRecords = hostedQueuedRecords(records: [queuedRecord(id: recordID)], owners: owners, userId: try #require(try await online.signedInUserID()))
        #expect(asOwner.own.map(\.id) == [recordID])
        let queued: HostedStartedMeeting = try await awaitingAuthLimit {
            try await online.startMeeting(device: nil, deviceCheckToken: nil, clientRef: recordID, deferred: true)
        }
        #expect(queued.meetingId != live.meetingId)
        _ = try await online.endMeeting(meetingID: queued.meetingId)
        let repeated: HostedStartedMeeting = try await online.startMeeting(device: nil, deviceCheckToken: nil, clientRef: recordID, deferred: true)
        #expect(repeated.meetingId == queued.meetingId)
        #expect(try localMeetingIsEnded(meetingID: live.meetingId) == false, "Ertelenmiş kayıt süren canlı toplantıyı kapatmamalı")
        #expect(try localMeetingIsEnded(meetingID: queued.meetingId))
        let ownerAfter: HostedEntitlements = try await online.entitlements()
        #expect(ownerAfter.trialMeetingsLeft == lastKnown.trialMeetingsLeft - 2)
        #expect(try await other.client.entitlements().trialMeetingsLeft == otherBefore.trialMeetingsLeft)
        _ = try await online.endMeeting(meetingID: live.meetingId)
    }
}

#endif
