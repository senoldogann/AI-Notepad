// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AINotepadCore",
    // Arayüz metinleri Türkçe yazılır; çalışma anında uygulamanın String Catalog'undan (ana paket) çevrilir.
    defaultLocalization: "tr",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AINotepadCore", targets: ["AINotepadCore"]),
        .library(name: "AINotepadUI", targets: ["AINotepadUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "AINotepadCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ]
        ),
        .target(
            name: "AINotepadUI",
            dependencies: ["AINotepadCore"]
        ),
        // Tasarımı gözle kontrol etmek için örnek verilerle ada ve paneli açan geliştirme aracı (uygulamaya girmez).
        .executableTarget(
            name: "AINotepadPreview",
            dependencies: ["AINotepadUI", "AINotepadCore"]
        ),
        .testTarget(
            name: "AINotepadUITests",
            dependencies: ["AINotepadUI", "AINotepadCore"]
        ),
        .testTarget(
            name: "AINotepadCoreTests",
            dependencies: ["AINotepadCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
