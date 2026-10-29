import AINotepadCore
import Foundation
import Testing

/// Deponun kökü (bu dosya `Packages/AINotepadCore/Tests/AINotepadUITests` içinde).
private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

/// Info.plist'teki anahtarın değeri (yoksa nil).
private func plistValue(plist path: String, key: String) throws -> (any Sendable)? {
    let data: Data = try Data(contentsOf: repositoryRoot().appending(path: path))
    let plist: [String: any Sendable] = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: any Sendable])
    return plist[key]
}

/// Info.plist'teki veri klasörü adı (yoksa nil).
private func dataFolderName(plist path: String) throws -> String? {
    try plistValue(plist: path, key: dataFolderInfoKey) as? String
}

@Suite struct DataFolderTests {
    // İki Mac uygulaması ayrı klasör kullanır: abonelik sürümü geliştirici sürümünün toplantılarına, seslerine,
    // modellerine ve kişilerine dokunmaz. iPhone uygulaması kendi kabında geliştirici adını kullanır.
    @Test func macTargetsUseDifferentDataFolders() throws {
        let developer: String = try #require(try dataFolderName(plist: "App/Info.plist"), "App/Info.plist'te \(dataFolderInfoKey) yok")
        let hosted: String = try #require(try dataFolderName(plist: "App/Hosted/Info.plist"), "App/Hosted/Info.plist'te \(dataFolderInfoKey) yok")
        #expect(developer == "AINotepad")
        // Abonelik sürümünün adı yapılandırmaya göre derleme ayarından gelir (project.yml `HOSTED_DATA_FOLDER_NAME`).
        #expect(hosted == "$(HOSTED_DATA_FOLDER_NAME)")
        #expect(try dataFolderName(plist: "iOS/Info.plist") == "AINotepad")
    }

    // Abonelik sürümünün Debug derlemesi yayındakinden ayrı veri klasörü ve Anahtar Zinciri servisi kullanır: yerel
    // sunucuyla denenen derleme yayındaki oturumu ve toplantıları okuyamaz, silemez. Yayın adları değişmez.
    @Test func hostedDebugBuildIsSeparatedFromRelease() throws {
        let project: String = try String(contentsOf: repositoryRoot().appending(path: "project.yml"), encoding: .utf8)
        #expect(project.contains("HOSTED_DATA_FOLDER_NAME: \"AINotepad Hosted\""))
        #expect(project.contains("HOSTED_DATA_FOLDER_NAME: \"AINotepad Hosted Debug\""))
        #expect(project.contains("HOSTED_KEYCHAIN_SERVICE: \"AINotepadHosted\""))
        #expect(project.contains("HOSTED_KEYCHAIN_SERVICE: \"AINotepadHosted.debug\""))
    }

    // Yalnızca abonelik sürümü kullanıcı verisini hesap başına ayırır; geliştirici sürümü ve iPhone eskisi gibi
    // klasörün kökünü kullanır.
    @Test func onlyHostedEditionScopesDataPerAccount() throws {
        #expect(try plistValue(plist: "App/Hosted/Info.plist", key: accountScopedDataInfoKey) as? Bool == true)
        #expect(try plistValue(plist: "App/Info.plist", key: accountScopedDataInfoKey) == nil)
        #expect(try plistValue(plist: "iOS/Info.plist", key: accountScopedDataInfoKey) == nil)
        let project: String = try String(contentsOf: repositoryRoot().appending(path: "project.yml"), encoding: .utf8)
        #expect(project.components(separatedBy: "\(accountScopedDataInfoKey): true").count == 2)
    }

    // Anahtar yoksa klasör tahmin edilmez: açık hata.
    @Test func missingKeyIsAnError() {
        #expect(throws: StorageError.self) { try AppPaths.dataFolderName(bundle: Bundle(for: BundleMarker.self)) }
    }
}

/// Test paketini bulmak için sınıf.
private final class BundleMarker {}
