// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalTranscriptionBenchmark",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "local-transcription-benchmark",
            targets: ["LocalTranscriptionBenchmark"]
        )
    ],
    dependencies: [
        .package(name: "SpeakApp", path: "../.."),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0")
    ],
    targets: [
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.1.3/"
                + "TranscribeCpp.xcframework.zip",
            checksum: "b7a3442e2f3552cac1ee71b5e164934dd4db243f6b4b16b1e3e3ed5d1645eefd"
        ),
        .target(
            name: "LocalTranscriptionBenchmarkKit",
            dependencies: [
                .product(name: "SpeakCore", package: "SpeakApp")
            ]
        ),
        .executableTarget(
            name: "LocalTranscriptionBenchmark",
            dependencies: [
                "LocalTranscriptionBenchmarkKit",
                .product(name: "SpeakCore", package: "SpeakApp"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                "CTranscribe"
            ]
        ),
        .testTarget(
            name: "LocalTranscriptionBenchmarkTests",
            dependencies: [
                "LocalTranscriptionBenchmarkKit",
                .product(name: "SpeakCore", package: "SpeakApp")
            ]
        )
    ]
)
