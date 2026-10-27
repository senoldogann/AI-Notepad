import Foundation
import Testing
@testable import AINotepadCore

/// Gerçek Keychain'de, uygulamanınkinden ayrı bir test servisinde çalışır.
// iOS simülatöründe paket testleri barındırıcı uygulamasız çalışır ve Anahtar Zinciri yetkisi (entitlement) yoktur;
// iPhone'da Anahtar Zinciri uygulamanın kendisinde (eşitleme aşaması) denenir.
@Suite(.serialized, .enabled(if: keychainTestsAvailable)) struct KeychainTests {
    let service: String = "AINotepad.tests"

    @Test func saveThenReadReturnsValue() throws {
        try saveSecret(service: service, account: .deepgram, value: "abc")
        #expect(try readSecret(service: service, account: .deepgram) == "abc")
        try deleteSecret(service: service, account: .deepgram)
    }

    @Test func saveOverwritesExisting() throws {
        try saveSecret(service: service, account: .elevenlabs, value: "a")
        try saveSecret(service: service, account: .elevenlabs, value: "b")
        #expect(try readSecret(service: service, account: .elevenlabs) == "b")
        try deleteSecret(service: service, account: .elevenlabs)
    }

    @Test func readMissingThrowsNotFound() throws {
        try deleteSecret(service: service, account: .deepgram)
        #expect(throws: KeychainError.notFound(service: "AINotepad.tests", account: "deepgram")) {
            try readSecret(service: service, account: .deepgram)
        }
    }

    @Test func secretExistsReflectsState() throws {
        try deleteSecret(service: service, account: .elevenlabs)
        #expect(try secretExists(service: service, account: .elevenlabs) == false)
        try saveSecret(service: service, account: .elevenlabs, value: "x")
        #expect(try secretExists(service: service, account: .elevenlabs) == true)
        try deleteSecret(service: service, account: .elevenlabs)
    }
}

/// Anahtar Zinciri testleri yalnızca macOS'ta çalışır (bkz. `KeychainTests`).
#if os(macOS)
let keychainTestsAvailable: Bool = true
#else
let keychainTestsAvailable: Bool = false
#endif
