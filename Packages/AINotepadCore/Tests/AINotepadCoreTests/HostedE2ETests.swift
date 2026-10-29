import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import AINotepadCore

// Yerel sunucuyu `Process` ile hazırlar: yalnızca macOS'ta derlenir (iOS'ta `Process` yok).
#if os(macOS)

/// Yerel sunucuya karşı uçtan uca deneme yalnızca açıkça istenirse: `AINOTEPAD_HOSTED_E2E=1` ve sunucunun adresi
/// `AINOTEPAD_HOSTED_BASE` (ör. `http://127.0.0.1:8787`). Önce `server/` içinde: `.dev.vars` (sahte gizli değerler),
/// `npm run migrate:local`, `npx wrangler dev`.
let hostedE2EEnabled: Bool = ProcessInfo.processInfo.environment["AINOTEPAD_HOSTED_E2E"] == "1"

/// Deponun `server/` klasörü (bu dosya `Packages/AINotepadCore/Tests/AINotepadCoreTests` içinde).
private func serverDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "server", directoryHint: .isDirectory)
}

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

/// Apple ve Google kimlik jetonları yerelde üretilemediği için oturum yerel D1'e doğrudan eklenir (kullanıcı, oturum
/// ailesi ve yenileme jetonu; sunucunun saklama biçimi: SHA-256 onaltılık). İstemci bu jetonla `/v1/auth/refresh`
/// üzerinden gerçek oturumu alır; giriş ucundan sonraki her adım uygulamanınkiyle aynıdır.
private func insertSession(refreshToken: String) throws -> String {
    let hash: String = SHA256.hash(data: Data(refreshToken.utf8)).map { String(format: "%02x", $0) }.joined()
    let now: Int = Int(Date().timeIntervalSince1970 * 1000)
    let userID: String = "e2e-\(UUID().uuidString.lowercased())"
    let familyID: String = "e2e-\(UUID().uuidString.lowercased())"
    let sql: String = [
        "INSERT INTO users (id, created_at) VALUES ('\(userID)', \(now));",
        "INSERT INTO refresh_families (id, user_id, created_at) VALUES ('\(familyID)', '\(userID)', \(now));",
        "INSERT INTO refresh_tokens (token_hash, family_id, created_at, expires_at) VALUES ('\(hash)', '\(familyID)', \(now), \(now + 24 * 3_600_000));",
    ].joined(separator: " ")
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

@Suite(.enabled(if: hostedE2EEnabled), .serialized) struct HostedE2ETests {
    // Oturum (yenileme jetonuyla) → /v1/me → toplantı başlat (deneme düşer) → bitir → erişim jetonu yenilenir →
    // eski yenileme jetonu yeniden kullanılınca tüm oturumlar düşer ve istemci çıkış yapar.
    @Test func signInMeetingAndRefreshAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
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

        let before: HostedEntitlements = try await client.entitlements()
        #expect(hostedPlanStatus(entitlements: before) == .trial(left: before.trialMeetingsTotal, total: before.trialMeetingsTotal))
        #expect(before.monthlyHoursCap > 0)

        let started: HostedStartedMeeting = try await client.startMeeting(device: nil, deviceCheckToken: nil)
        #expect(started.kind == "trial")
        #expect(started.trialMeetingsLeft == before.trialMeetingsTotal - 1)
        #expect(await client.currentMeetingID() == started.meetingId)
        let credentials: HostedLLMCredentials = try await client.meetingLLMCredentials()
        #expect(credentials.meetingID == started.meetingId)

        let during: HostedEntitlements = try await client.entitlements()
        #expect(during.trialMeetingsLeft == before.trialMeetingsTotal - 1)
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

        // Eski yenileme jetonu yeniden kullanılırsa sunucu tüm oturum ailesini kapatır; istemci yerel oturumu siler.
        let replayStorage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(
            accessToken: original.accessToken, refreshToken: original.refreshToken, accessExpiresAt: Date.distantPast, userId: original.userId
        ))
        let replayClient: HostedClient = HostedClient(baseURL: baseURL, storage: replayStorage) { () async -> Void in
            ended.count.withLock { $0 += 1 }
        }
        await #expect(throws: HostedClientError.sessionEnded) { _ = try await replayClient.entitlements() }
        #expect(try replayStorage.load() == nil)
        #expect(ended.count.withLock { $0 } == 1)
        // Aile düştüğü için döndürülmüş jeton da artık geçmez.
        let familyClient: HostedClient = HostedClient(baseURL: baseURL, storage: MemoryTokenStorage(tokens: HostedTokens(
            accessToken: rotated.accessToken, refreshToken: rotated.refreshToken, accessExpiresAt: Date.distantPast, userId: rotated.userId
        ))) { () async -> Void in }
        await #expect(throws: HostedClientError.sessionEnded) { _ = try await familyClient.entitlements() }
    }

    // Rapor ucu: hesapsız geri bildirim ve hesaplı (bearer) çökme raporu 2xx alır.
    @Test func reportsAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let diagnostics: ReportDiagnostics = currentReportDiagnostics(bundle: .main, platformName: "macOS")
        try await submitReport(
            report: try feedbackReport(message: "Uçtan uca deneme geri bildirimi.", email: "e2e@ornek.fi", diagnostics: diagnostics),
            destination: ReportDestination(baseURL: baseURL, accessToken: nil)
        )

        let seedRefreshToken: String = randomToken()
        let userID: String = try insertSession(refreshToken: seedRefreshToken)
        let client: HostedClient = HostedClient(baseURL: baseURL, storage: MemoryTokenStorage(tokens: HostedTokens(
            accessToken: "gecersiz", refreshToken: seedRefreshToken, accessExpiresAt: Date.distantPast, userId: userID
        ))) { () async -> Void in }
        let payload: Data = Data(#"{"crashDiagnostics":[{"diagnosticMetaData":{"appVersion":"0.1.3","appBuildVersion":"4","osVersion":"macOS 26.1","exceptionType":1,"signal":11}}]}"#.utf8)
        let crash: CrashDiagnostic = try #require(try crashDiagnostics(payload: payload).first)
        try await submitReport(
            report: try crashReportRequest(payload: payload, diagnostic: crash),
            destination: ReportDestination(baseURL: baseURL, accessToken: try await client.validAccessToken())
        )
    }
}

#endif
