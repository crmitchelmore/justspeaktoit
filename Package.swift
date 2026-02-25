// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpeakApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "SpeakHotKeys", targets: ["SpeakHotKeys"]),
        .library(name: "SpeakCore", targets: ["SpeakCore"]),
        .library(name: "SpeakSync", targets: ["SpeakSync"]),
        .library(name: "SpeakiOSLib", targets: ["SpeakiOSLib"]),
        .executable(name: "SpeakApp", targets: ["SpeakApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/realm/SwiftLint.git", from: "0.55.0"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat.git", from: "0.53.6"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.3.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0")
    ],
    targets: [
        .target(
            name: "SpeakHotKeys",
            path: "Sources/SpeakHotKeys"
        ),
        .target(
            name: "SpeakCore"
        ),
        .target(
            name: "SpeakSync",
            path: "Sources/SpeakSync"
        ),
        .target(
            name: "SpeakiOSLib",
            dependencies: ["SpeakCore", "SpeakSync"],
            path: "Sources/SpeakiOS",
            exclude: ["SpeakiOSApp.swift"]
        ),
        .executableTarget(
            name: "SpeakApp",
            dependencies: [
                "SpeakCore",
                "SpeakSync",
                "SpeakHotKeys",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa")
            ]
        ),
        .executableTarget(
            name: "SpeakHotKeysDemo",
            dependencies: ["SpeakHotKeys"],
            path: "Sources/SpeakHotKeysDemo"
        ),
        .testTarget(
            name: "SpeakCoreTests",
            dependencies: ["SpeakCore"]
        ),
        .testTarget(
            name: "SpeakAppTests",
            dependencies: ["SpeakApp"]
        ),
        .testTarget(
            name: "SpeakAppSnapshotTests",
            dependencies: [
                "SpeakApp",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ]
        )
    ]
)
