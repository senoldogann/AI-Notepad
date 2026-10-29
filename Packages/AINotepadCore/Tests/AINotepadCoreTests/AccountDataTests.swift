import Foundation
import Testing
@testable import AINotepadCore

/// Sahte kullanıcı kimlikleri ve anahtarları (abonelik sunucusundaki kimliklere benzer).
private let userA: String = "google:1234567890"
private let userB: String = "apple:000123.abcdef"
private let keyA: String = accountDataKey(userId: userA)
private let keyB: String = accountDataKey(userId: userB)

/// Testin toplantısı (yalnızca kimlik ve başlık önemli).
private func sampleMeeting(id: String) -> MeetingRecord {
    MeetingRecord(
        id: id, title: "Toplantı \(id)", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil, language: nil, status: .done,
        failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false,
        engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

/// Eski (hesapsız) düzende bir veri klasörü kurar: üç toplantı (biri B'nin bekleyen kaydı), gizli dosya, bir Sor
/// sohbeti, kişiler, ses izleri ve paylaşılan modeller ile çökme raporları.
private func makeLegacyDataRoot() throws -> URL {
    let root: URL = try temporaryDirectory()
    let sessions: URL = root.appending(path: "Sessions", directoryHint: .isDirectory)
    for id in ["20260101-090000", "20260102-090000", "20260103-090000"] {
        let folder: URL = sessions.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try saveMeeting(record: sampleMeeting(id: id), directory: folder)
        try Data("ses".utf8).write(to: folder.appending(path: "me.caf"))
    }
    try Data().write(to: sessions.appending(path: ".DS_Store"))
    let ask: URL = root.appending(path: "AskHistory", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: ask, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: ask.appending(path: "sohbet.json"))
    try Data("{\"saved\":[]}".utf8).write(to: root.appending(path: "People.json"))
    try Data("[]".utf8).write(to: root.appending(path: "Voices.json"))
    let models: URL = root.appending(path: "Models", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    try Data("model".utf8).write(to: models.appending(path: "weights.bin"))
    let crashes: URL = root.appending(path: "CrashReports", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: crashes.appending(path: "rapor.json"))
    return root
}

/// Klasördeki toplantıların kimlikleri (sıralı).
private func meetingIDs(sessions: URL) -> [String] {
    loadMeetings(sessionsDirectory: sessions).meetings.map(\.id).sorted()
}

/// Dosyanın disk düğüm numarası (taşımanın kopya değil yeniden adlandırma olduğunu doğrulamak için).
private func fileNumber(url: URL) throws -> Int {
    try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
}

@Suite struct AccountDataTests {
    // Anahtar kimlikten belirlenimli türer, klasör adı olarak güvenlidir ve kimliği açık etmez.
    @Test func accountKeyIsStableHexAndDistinct() {
        #expect(keyA == accountDataKey(userId: userA))
        #expect(keyA != keyB)
        #expect(keyA.count == 32)
        #expect(isValidAccountDataKey(key: keyA))
        #expect(!keyA.contains("google"))
        #expect(!isValidAccountDataKey(key: "../Sessions"))
        #expect(!isValidAccountDataKey(key: keyA.uppercased()))
        #expect(!isValidAccountDataKey(key: String(keyA.prefix(31))))
        #expect(!isValidAccountDataKey(key: ""))
    }

    // Hesap klasörleri veri klasörünün altında, `Accounts/<anahtar>`.
    @Test func accountPathsLiveUnderAccounts() {
        let root: URL = URL(filePath: "/tmp/AINotepad Hosted", directoryHint: .isDirectory)
        #expect(AppPaths.accountDataDirectory(dataRoot: root, accountKey: keyA).path == "/tmp/AINotepad Hosted/Accounts/\(keyA)")
        #expect(AppPaths.accountSessionsDirectory(dataRoot: root, accountKey: keyA).path == "/tmp/AINotepad Hosted/Accounts/\(keyA)/Sessions")
        #expect(AppPaths.legacyClaimFile(dataRoot: root).path == "/tmp/AINotepad Hosted/Accounts/legacy-owner")
    }

    // Giriş yapan hesaba göre: giriş yoksa veri yüklü kalır, ilk girişte yüklenir, başka hesapta yeniden başlatılır.
    @Test func transitionFollowsSignedInAccount() {
        #expect(accountDataTransition(loadedKey: nil, signedInKey: nil) == .keep)
        #expect(accountDataTransition(loadedKey: keyA, signedInKey: nil) == .keep)
        #expect(accountDataTransition(loadedKey: nil, signedInKey: keyA) == .activate(accountKey: keyA))
        #expect(accountDataTransition(loadedKey: keyA, signedInKey: keyA) == .keep)
        #expect(accountDataTransition(loadedKey: keyA, signedInKey: keyB) == .relaunch(accountKey: keyB))
    }

    // Süreç tek hesabın verisini yükler: aynı hesap yeniden yüklenebilir, başka hesap için yeniden başlatma gerekir.
    // (Test sürecinin Info.plist'inde hesap başına veri kapalıdır; yüklenen anahtar diğer testlerin yollarını değiştirmez.)
    @Test func processLoadsOnlyOneAccount() throws {
        #expect(throws: StorageError.invalidAccountKey(key: "../x")) { try AppPaths.activateAccount(key: "../x") }
        #expect(!AppPaths.isAccountScoped(bundle: .main))
        try AppPaths.activateAccount(key: keyA)
        try AppPaths.activateAccount(key: keyA)
        #expect(AppPaths.activeAccountKey() == keyA)
        #expect(throws: StorageError.accountSwitchRequiresRelaunch(active: keyA, requested: keyB)) { try AppPaths.activateAccount(key: keyB) }
        #expect(AppPaths.activeAccountKey() == keyA)
    }

    // Eski veri ilk sahiplenen hesabındır; ikinci hesap ona dokunmaz.
    @Test func claimDecision() {
        #expect(legacyDataClaim(claimOwner: nil, accountKey: keyA) == .claim)
        #expect(legacyDataClaim(claimOwner: keyA, accountKey: keyA) == .resume)
        #expect(legacyDataClaim(claimOwner: keyA, accountKey: keyB) == .ownedByAnotherAccount)
    }

    // MCP: yalnızca sunucunun açıldığı hesap, hâlâ giriş yapmışsa ve arşivi hazırsa okunur.
    @Test func mcpArchiveAccess() {
        #expect(accountArchiveAccess(startedKey: keyA, currentKey: keyA, archiveExists: true) == .allowed)
        #expect(accountArchiveAccess(startedKey: keyA, currentKey: nil, archiveExists: true) == .signedOut)
        #expect(accountArchiveAccess(startedKey: keyA, currentKey: keyB, archiveExists: true) == .accountChanged)
        #expect(accountArchiveAccess(startedKey: keyA, currentKey: keyA, archiveExists: false) == .notPrepared)
    }

    // Plan: başka hesaba yazılmış bekleyen kayıt sahibine, geri kalan her şey sahiplenen hesaba.
    @Test func movesSendForeignRecordsToTheirOwner() {
        let root: URL = URL(filePath: "/tmp/veri", directoryHint: .isDirectory)
        let legacy: LegacyUserData = LegacyUserData(sessionEntries: ["m1", "m2"], askHistoryEntries: ["s.json"], rootFiles: ["People.json"])
        let moves: [DataMove] = legacyDataMoves(dataRoot: root, legacy: legacy, claimantKey: keyA, recordOwnerKeys: ["m2": keyB, "m9": keyB])
        #expect(moves.map(\.source.path) == ["/tmp/veri/Sessions/m1", "/tmp/veri/Sessions/m2", "/tmp/veri/AskHistory/s.json", "/tmp/veri/People.json"])
        #expect(moves.map(\.destination.path) == [
            "/tmp/veri/Accounts/\(keyA)/Sessions/m1", "/tmp/veri/Accounts/\(keyB)/Sessions/m2",
            "/tmp/veri/Accounts/\(keyA)/AskHistory/s.json", "/tmp/veri/Accounts/\(keyA)/People.json",
        ])
        #expect(legacyDataMoves(dataRoot: root, legacy: LegacyUserData(sessionEntries: [], askHistoryEntries: [], rootFiles: []), claimantKey: keyA, recordOwnerKeys: [:]).isEmpty)
    }

    // Uçtan uca (geçici klasörde): ilk hesap eski veriyi yeniden adlandırarak alır, B'nin bekleyen kaydı B'ye gider,
    // paylaşılanlar yerinde kalır; ikinci hesap yalnızca kendi kaydını görür ve eski veriye dokunmaz.
    @Test func firstAccountClaimsLegacyDataAndSecondStartsEmpty() throws {
        let root: URL = try makeLegacyDataRoot()
        let audioBefore: Int = try fileNumber(url: root.appending(path: "Sessions/20260101-090000/me.caf"))
        let owners: [String: String] = ["20260103-090000": keyB]

        let first: LegacyMigrationResult = try migrateLegacyUserData(dataRoot: root, accountKey: keyA, recordOwnerKeys: owners)
        #expect(first.claim == .claim)
        #expect(first.moves.count == 6)
        #expect(try readLegacyClaimOwner(dataRoot: root) == keyA)
        let sessionsA: URL = AppPaths.accountSessionsDirectory(dataRoot: root, accountKey: keyA)
        let sessionsB: URL = AppPaths.accountSessionsDirectory(dataRoot: root, accountKey: keyB)
        #expect(meetingIDs(sessions: sessionsA) == ["20260101-090000", "20260102-090000"])
        #expect(meetingIDs(sessions: sessionsB) == ["20260103-090000"])
        // Kopya değil: ses dosyası aynı disk düğümü.
        #expect(try fileNumber(url: sessionsA.appending(path: "20260101-090000/me.caf")) == audioBefore)
        let accountA: URL = AppPaths.accountDataDirectory(dataRoot: root, accountKey: keyA)
        for item in ["People.json", "Voices.json", "AskHistory/sohbet.json"] {
            #expect(FileManager.default.fileExists(atPath: accountA.appending(path: item).path), "\(item) A'ya taşınmadı")
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: item).path), "\(item) eski yerde kaldı")
        }
        // Paylaşılanlar ve gizli dosya yerinde; eski klasörde toplantı kalmadı.
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Models/weights.bin").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "CrashReports/rapor.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Sessions/.DS_Store").path))
        #expect(try readLegacyUserData(dataRoot: root).isEmpty)

        // İkinci hesap: eski veri A'nın, B'nin klasöründe yalnızca kendi kaydı.
        let second: LegacyMigrationResult = try migrateLegacyUserData(dataRoot: root, accountKey: keyB, recordOwnerKeys: owners)
        #expect(second == LegacyMigrationResult(claim: .ownedByAnotherAccount, moves: [], skipped: []))
        #expect(meetingIDs(sessions: sessionsB) == ["20260103-090000"])
        #expect(!FileManager.default.fileExists(atPath: AppPaths.accountDataDirectory(dataRoot: root, accountKey: keyB).appending(path: "People.json").path))
    }

    // Uçtan uca MCP: taşımadan sonra A'nın sunucusu yalnızca A'nın toplantılarını listeler; B giriş yapınca aynı sunucu
    // arşivi okumaz, B'nin sunucusu yalnızca B'ninkini listeler.
    @Test func mcpReadsOnlyTheSignedInAccountsArchive() throws {
        let root: URL = try makeLegacyDataRoot()
        _ = try migrateLegacyUserData(dataRoot: root, accountKey: keyA, recordOwnerKeys: ["20260103-090000": keyB])
        let call: String = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}"#
        let sessionsA: URL = AppPaths.accountSessionsDirectory(dataRoot: root, accountKey: keyA)
        let sessionsB: URL = AppPaths.accountSessionsDirectory(dataRoot: root, accountKey: keyB)
        let denial: (String?) -> String? = { (currentKey: String?) -> String? in
            accountArchiveAccess(startedKey: keyA, currentKey: currentKey, archiveExists: FileManager.default.fileExists(atPath: sessionsA.path)) == .allowed
                ? nil : "reddedildi"
        }
        let asA: String = try #require(handleMCPMessage(
            line: call, loadRecords: { loadMeetings(directories: [sessionsA]).meetings }, accessDenial: { denial(keyA) },
            version: "test", noteLanguage: .english, appName: "Gistsmith"
        ))
        #expect(asA.contains("20260101-090000") && asA.contains("20260102-090000") && !asA.contains("20260103-090000"))
        let afterSwitch: String = try #require(handleMCPMessage(
            line: call, loadRecords: { loadMeetings(directories: [sessionsA]).meetings }, accessDenial: { denial(keyB) },
            version: "test", noteLanguage: .english, appName: "Gistsmith"
        ))
        #expect(afterSwitch.contains("reddedildi") && !afterSwitch.contains("20260101-090000"))
        let asB: String = try #require(handleMCPMessage(
            line: call, loadRecords: { loadMeetings(directories: [sessionsB]).meetings }, accessDenial: { nil },
            version: "test", noteLanguage: .english, appName: "Gistsmith"
        ))
        #expect(asB.contains("20260103-090000") && !asB.contains("20260101-090000") && !asB.contains("20260102-090000"))
    }

    // Eski yerde sonradan beliren veri (yarıda kalmış taşıma, eski sürüm) sahibine gider; başka hesap almaz.
    @Test func leftoversGoOnlyToTheClaimant() throws {
        let root: URL = try makeLegacyDataRoot()
        _ = try migrateLegacyUserData(dataRoot: root, accountKey: keyA, recordOwnerKeys: [:])
        let leftover: URL = root.appending(path: "Sessions/20260104-090000", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try saveMeeting(record: sampleMeeting(id: "20260104-090000"), directory: leftover)

        #expect(try migrateLegacyUserData(dataRoot: root, accountKey: keyB, recordOwnerKeys: [:]).moves.isEmpty)
        #expect(FileManager.default.fileExists(atPath: leftover.path))
        let resumed: LegacyMigrationResult = try migrateLegacyUserData(dataRoot: root, accountKey: keyA, recordOwnerKeys: [:])
        #expect(resumed.claim == .resume)
        #expect(resumed.moves.count == 1)
        #expect(meetingIDs(sessions: AppPaths.accountSessionsDirectory(dataRoot: root, accountKey: keyA)).contains("20260104-090000"))
    }

    // Hedefte aynı adlı öğe varsa yalnızca o taşınmaz (üzerine yazılmaz, silinmez, eski yerinde kalır); gerisi taşınır ve
    // hesap kilitlenmez.
    @Test func conflictSkipsOnlyTheConflictingItem() throws {
        let root: URL = try makeLegacyDataRoot()
        let existing: URL = AppPaths.accountSessionsDirectory(dataRoot: root, accountKey: keyA).appending(path: "20260102-090000", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let legacySessions: URL = root.appending(path: "Sessions", directoryHint: .isDirectory)

        let result: LegacyMigrationResult = try migrateLegacyUserData(dataRoot: root, accountKey: keyA, recordOwnerKeys: [:])
        #expect(result.skipped.map(\.source.lastPathComponent) == ["20260102-090000"])
        #expect(!result.moves.isEmpty)
        #expect(meetingIDs(sessions: legacySessions) == ["20260102-090000"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path).isEmpty)
    }

    // Hiç eski veri yoksa (yeni kurulum) ilk hesap yine sahiplenir: sonra eski yerde veri belirse de ikinci hesaba gitmez.
    @Test func freshInstallRecordsTheClaim() throws {
        let root: URL = try temporaryDirectory()
        #expect(try migrateLegacyUserData(dataRoot: root, accountKey: keyA, recordOwnerKeys: [:]) == LegacyMigrationResult(claim: .claim, moves: [], skipped: []))
        #expect(try readLegacyClaimOwner(dataRoot: root) == keyA)
    }

    // Bozuk sahiplik kaydı tahminle bir hesaba verilmez; geçersiz anahtar hiçbir şey taşımaz.
    @Test func invalidKeysAreErrors() throws {
        let root: URL = try makeLegacyDataRoot()
        #expect(throws: StorageError.invalidAccountKey(key: "../x")) {
            try migrateLegacyUserData(dataRoot: root, accountKey: "../x", recordOwnerKeys: [:])
        }
        #expect(throws: StorageError.invalidAccountKey(key: "kotu")) {
            try migrateLegacyUserData(dataRoot: root, accountKey: keyA, recordOwnerKeys: ["20260101-090000": "kotu"])
        }
        try FileManager.default.createDirectory(at: AppPaths.accountsDirectory(dataRoot: root), withIntermediateDirectories: true)
        try Data("bozuk".utf8).write(to: AppPaths.legacyClaimFile(dataRoot: root))
        #expect(throws: StorageError.invalidAccountKey(key: "bozuk")) {
            try migrateLegacyUserData(dataRoot: root, accountKey: keyA, recordOwnerKeys: [:])
        }
        #expect(meetingIDs(sessions: root.appending(path: "Sessions", directoryHint: .isDirectory)).count == 3)
    }
}
