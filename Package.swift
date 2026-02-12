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
        .library(name: "SpeakiOSLib", targets: ["SpeakiOSLib"]),
        .executable(name: "SpeakApp", targets: ["SpeakApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/realm/SwiftLint.git", from: "0.55.0"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat.git", from: "0.53.6"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.3.0")
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
            name: "SpeakiOSLib",
            dependencies: ["SpeakCore"],
            path: "Sources/SpeakiOS",
            exclude: ["SpeakiOSApp.swift"]
        ),
        .executableTarget(
            name: "SpeakApp",
            dependencies: [
                "SpeakCore",
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
            name: "SpeakAppTests",
            dependencies: ["SpeakApp"]
        )
    ]
)
