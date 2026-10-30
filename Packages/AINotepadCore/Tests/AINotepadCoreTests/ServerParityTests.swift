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

    // Yapay zekâ amaçları ve telemetri listeleri sunucunun dizileriyle birebir aynı olmalı: eksik amaç 400
    // `llm_purpose_invalid`, eksik telemetri değeri `invalid_body` alır (istek düşer).
    @Test func telemetryListsMatchServer() throws {
        let purpose: String = try String(contentsOf: serverDirectory().appending(path: "src/llm/purpose.ts"), encoding: .utf8)
        #expect(try serverArray(source: purpose, name: "llmPurposes") == LLMPurpose.allCases.map(\.rawValue))
        let telemetry: String = try String(contentsOf: serverDirectory().appending(path: "src/telemetry.ts"), encoding: .utf8)
        #expect(try serverArray(source: telemetry, name: "telemetryCountKinds") == TelemetryCountKind.allCases.map(\.rawValue))
        #expect(try serverArray(source: telemetry, name: "telemetryDurationKinds") == TelemetryDurationKind.allCases.map(\.rawValue))
        #expect(try serverArray(source: telemetry, name: "telemetryIntegrations") == TelemetryIntegration.allCases.map(\.rawValue))
        #expect(try serverArray(source: telemetry, name: "telemetryExportFormats") == TelemetryExportFormat.allCases.map(\.rawValue))
        #expect(try serverArray(source: telemetry, name: "telemetryLanguages") == ShareLanguage.allCases.map(\.rawValue))
    }
}

/// Sunucu kaynağındaki `export const <ad> = [ ... ] as const;` dizisinin dizgeleri (sırasıyla).
private func serverArray(source: String, name: String) throws -> [String] {
    let start: Substring = try #require(source.firstRange(of: "export const \(name) = [").map { source[$0.upperBound...] })
    let body: Substring = try #require(start.firstRange(of: "] as const;").map { start[..<$0.lowerBound] })
    return body.matches(of: #/"([A-Za-z_-]+)"/#).map { String($0.output.1) }
}
