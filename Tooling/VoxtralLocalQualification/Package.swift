// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoxtralLocalQualification",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "voxtral-local-qualification", targets: ["VoxtralLocalQualification"])],
    dependencies: [
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "8d86630ade569728aaea3dc1a29fc44e2efa719b"
        ),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.3")
    ],
    targets: [
        .executableTarget(
            name: "VoxtralLocalQualification",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift")
            ]
        )
    ]
)
