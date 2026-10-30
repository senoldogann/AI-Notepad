import Foundation
import Testing
@testable import AINotepadCore

/// Deponun `server/` klasörü (bu dosya `Packages/AINotepadCore/Tests/AINotepadCoreTests` içinde).
func serverDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "server", directoryHint: .isDirectory)
}

/// İstemcinin sunucuyla birebir aynı olması gereken listeleri: sunucu çalıştırılmaz, depodaki kaynak okunur; her
/// `swift test`te koşar.
@Suite struct ServerParityTests {
    // İstemcinin hata kodları sunucununkilerle birebir aynı olmalı (`HostedErrors.swift` bunu söyler): eksik kod
    // kullanıcıya "Sunucu beklenmeyen bir yanıt verdi (HTTP …)" olarak görünür (0.1.4'te `trial_not_started` böyleydi).
    @Test func clientKnowsEveryServerErrorCode() throws {
        let source: String = try String(contentsOf: serverDirectory().appending(path: "src/errors.ts"), encoding: .utf8)
        let union: Substring = try #require(source.firstRange(of: "export type ErrorCode =").map { source[$0.upperBound...] })
        let body: Substring = try #require(union.firstRange(of: ";").map { union[..<$0.lowerBound] })
        let serverCodes: Set<String> = Set(body.matches(of: #/"([a-z_]+)"/#).map { String($0.output.1) })
        #expect(serverCodes.count > 30)
        let clientCodes: Set<String> = Set(HostedErrorCode.allCases.map(\.rawValue))
        #expect(clientCodes.subtracting(serverCodes).isEmpty, "İstemcide olup sunucuda olmayan: \(clientCodes.subtracting(serverCodes).sorted())")
        let missing: [String] = serverCodes.subtracting(clientCodes).sorted()
        #expect(missing.isEmpty, "Sunucuda olup istemcide olmayan: \(missing)")
    }
}
