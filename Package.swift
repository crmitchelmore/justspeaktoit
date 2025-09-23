// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpeakApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SpeakApp", targets: ["SpeakApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/realm/SwiftLint.git", from: "0.55.0"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat.git", from: "0.53.6")
    ],
    targets: [
        .executableTarget(
            name: "SpeakApp"
        ),
        .testTarget(
            name: "SpeakAppTests",
            dependencies: ["SpeakApp"]
        )
    ]
)
