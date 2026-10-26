import Foundation
import Testing
@testable import AINotepadCore

/// Gerçek bulut çağrısı yapan testler yalnızca bu ortam değişkeni "1" ise çalışır.
let cloudTestsEnabled: Bool = ProcessInfo.processInfo.environment["AINOTEPAD_CLOUD_TESTS"] == "1"

/// Bulut testleri bunun altında ve sırayla çalışır.
@Suite(.enabled(if: cloudTestsEnabled), .serialized)
struct CloudTests {}

/// Bulut test anahtarı okunamadı.
struct CloudKeyError: Error {
    let account: String
    let exitCode: Int32
}

/// Kullanıcının `security add-generic-password` ile kaydettiği anahtarı okur.
/// `security` aracı öğeyi kendisi oluşturduğu için Keychain izin penceresi çıkmaz.
func cloudKey(account: SecretAccount) throws -> String {
    let process: Process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", keychainService, "-a", account.rawValue, "-w"]
    let output: Pipe = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CloudKeyError(account: account.rawValue, exitCode: process.terminationStatus)
    }
    let data: Data = output.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
