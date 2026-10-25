// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AINotepadCore",
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
            ]
        ),
        .target(
            name: "AINotepadUI",
            dependencies: ["AINotepadCore"]
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
