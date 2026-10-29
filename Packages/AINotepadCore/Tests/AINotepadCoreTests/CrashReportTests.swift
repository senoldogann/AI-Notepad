import Foundation
import Testing
@testable import AINotepadCore

/// `MXDiagnosticPayload.jsonRepresentation()` biçiminde örnek: bir çökme (iki iş parçacığı; çöken ikincisi) ve bir donma.
private let samplePayload: String = """
{
  "timeStampBegin" : "2026-10-27 00:00:00",
  "timeStampEnd" : "2026-10-27 23:59:00",
  "crashDiagnostics" : [
    {
      "version" : "1.0.0",
      "callStackTree" : {
        "callStackPerThread" : true,
        "callStacks" : [
          {
            "threadAttributed" : false,
            "callStackRootFrames" : [
              { "binaryUUID" : "11111111-1111-1111-1111-111111111111", "offsetIntoBinaryTextSegment" : 4096, "sampleCount" : 1, "binaryName" : "libsystem_kernel.dylib", "address" : 7000000000 }
            ]
          },
          {
            "threadAttributed" : true,
            "callStackRootFrames" : [
              {
                "binaryUUID" : "22222222-2222-2222-2222-222222222222", "offsetIntoBinaryTextSegment" : 74565, "sampleCount" : 1, "binaryName" : "AINotepad", "address" : 4295041861,
                "subFrames" : [
                  {
                    "binaryUUID" : "33333333-3333-3333-3333-333333333333", "offsetIntoBinaryTextSegment" : 255, "sampleCount" : 1, "binaryName" : "SwiftUI", "address" : 7100000255,
                    "subFrames" : [
                      { "binaryUUID" : "44444444-4444-4444-4444-444444444444", "offsetIntoBinaryTextSegment" : 16, "sampleCount" : 1, "binaryName" : "dyld", "address" : 7200000016 }
                    ]
                  }
                ]
              }
            ]
          }
        ]
      },
      "diagnosticMetaData" : {
        "appBuildVersion" : "3",
        "appVersion" : "0.1.2",
        "regionFormat" : "FI",
        "exceptionType" : 1,
        "osVersion" : "macOS 26.0 (25A354)",
        "deviceType" : "Mac15,3",
        "signal" : 11,
        "exceptionCode" : 0,
        "platformArchitecture" : "arm64",
        "terminationReason" : "Namespace SIGNAL, Code 11 Segmentation fault: 11",
        "virtualMemoryRegionInfo" : "0 is not in any region.",
        "bundleIdentifier" : "com.senoldogan.AINotepad"
      }
    }
  ],
  "hangDiagnostics" : [
    {
      "version" : "1.0.0",
      "callStackTree" : {
        "callStackPerThread" : true,
        "callStacks" : [
          {
            "threadAttributed" : true,
            "callStackRootFrames" : [
              { "binaryUUID" : "22222222-2222-2222-2222-222222222222", "offsetIntoBinaryTextSegment" : 512, "sampleCount" : 20, "binaryName" : "AINotepad", "address" : 4294967808 }
            ]
          }
        ]
      },
      "diagnosticMetaData" : {
        "appBuildVersion" : "3",
        "appVersion" : "0.1.2",
        "osVersion" : "macOS 26.0 (25A354)",
        "platformArchitecture" : "arm64",
        "hangDuration" : "6 sec"
      }
    }
  ]
}
"""

@Suite struct CrashReportTests {
    // Çökme önce, donma sonra; çöken iş parçacığının çerçeveleri tepeden aşağı.
    @Test func summarisesCrashAndHang() throws {
        let diagnostics: [CrashDiagnostic] = try crashDiagnostics(payload: Data(samplePayload.utf8))
        #expect(diagnostics.map(\.kind) == [.crash, .hang])
        let crash: CrashDiagnostic = diagnostics[0]
        #expect(crash.appVersion == "0.1.2")
        #expect(crash.appBuild == "3")
        #expect(crash.osVersion == "macOS 26.0 (25A354)")
        #expect(crash.topFrames == ["AINotepad + 0x12345", "SwiftUI + 0xff", "dyld + 0x10"])
        #expect(crashCause(diagnostic: crash) == "EXC_BAD_ACCESS · SIGSEGV")
        #expect(crashCause(diagnostic: diagnostics[1]) == "6 sec")
    }

    // CPU/disk teşhisi gibi çökme ve donma içermeyen paket boş özet verir (saklanmaz).
    @Test func payloadWithoutCrashOrHangIsEmpty() throws {
        let payload: String = #"{"timeStampBegin":"x","timeStampEnd":"y","cpuExceptionDiagnostics":[]}"#
        #expect(try crashDiagnostics(payload: Data(payload.utf8)).isEmpty)
    }

    // Çökme raporu saklanan MetricKit JSON'unu olduğu gibi, çöken sürüm ve sistemle taşır; mesaj ve e-posta yok.
    @Test func crashReportRequestCarriesPayload() throws {
        let payload: Data = Data(samplePayload.utf8)
        let crash: CrashDiagnostic = try crashDiagnostics(payload: payload)[0]
        let request: ReportRequest = try crashReportRequest(payload: payload, diagnostic: crash)
        #expect(request == ReportRequest(kind: .crash, message: nil, email: nil, appVersion: "0.1.2 (3)", os: "macOS 26.0 (25A354)", payload: samplePayload))
        let encoded: [String: String] = try JSONDecoder().decode([String: String].self, from: try JSONEncoder().encode(request))
        #expect(Set(encoded.keys) == ["kind", "appVersion", "os", "payload"])
        #expect(encoded["kind"] == "crash")
        let tooLarge: Data = Data(repeating: 0x20, count: reportPayloadLimitBytes + 1)
        #expect(throws: ReportError.payloadTooLarge(bytes: reportPayloadLimitBytes + 1, limit: reportPayloadLimitBytes)) {
            try crashReportRequest(payload: tooLarge, diagnostic: crash)
        }
    }

    // Şerit yalnız görülmemiş, çökme içeren en yeni raporu gösterir.
    @Test func announcesNewestUnseenCrash() throws {
        let diagnostics: [CrashDiagnostic] = try crashDiagnostics(payload: Data(samplePayload.utf8))
        let hangOnly: CrashReport = CrashReport(id: "c", receivedAt: Date(timeIntervalSince1970: 300), diagnostics: [diagnostics[1]])
        let newer: CrashReport = CrashReport(id: "b", receivedAt: Date(timeIntervalSince1970: 200), diagnostics: diagnostics)
        let older: CrashReport = CrashReport(id: "a", receivedAt: Date(timeIntervalSince1970: 100), diagnostics: diagnostics)
        #expect(crashReportToAnnounce(reports: [hangOnly, newer, older], seenIDs: []) == newer)
        #expect(crashReportToAnnounce(reports: [hangOnly, newer, older], seenIDs: ["b"]) == older)
        #expect(crashReportToAnnounce(reports: [hangOnly, newer, older], seenIDs: ["a", "b"]) == nil)
    }

    // Saklama yalnız çökme/donma içeren paketi yazar; okuma yeniden eskiye sıralar, bozuk dosyayı ayrı bildirir.
    @Test func savesAndLoadsReports() throws {
        let directory: URL = FileManager.default.temporaryDirectory.appending(path: "crash-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("geçici klasör silinemedi: \(error)")
            }
        }
        let id: String = try #require(try saveDiagnosticPayload(payload: Data(samplePayload.utf8), directory: directory, receivedAt: Date()))
        #expect(try saveDiagnosticPayload(payload: Data(#"{"cpuExceptionDiagnostics":[]}"#.utf8), directory: directory, receivedAt: Date()) == nil)
        try Data("bozuk".utf8).write(to: directory.appending(path: "bozuk.json", directoryHint: .notDirectory))
        let result: CrashReportLoadResult = try loadCrashReports(directory: directory)
        #expect(result.reports.map(\.id) == [id])
        #expect(result.reports[0].containsCrash)
        #expect(result.unreadableFiles == ["bozuk.json"])
    }
}
