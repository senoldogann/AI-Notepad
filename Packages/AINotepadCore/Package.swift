// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AINotepadCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AINotepadCore", targets: ["AINotepadCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "AINotepadCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .testTarget(
            name: "AINotepadCoreTests",
            dependencies: ["AINotepadCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
