// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The native Apple app keeps its established dependency graph. Windows and
// Linux compile the same canonical domain sources without resolving Apple-only
// packages or xcframeworks. This is a portable kernel, not a claim that every
// platform has implemented every catalogued provider or OS integration.
#if os(macOS)
let portableCoreBuild = ProcessInfo.processInfo.environment["SPEAK_PORTABLE_CORE"] == "1"
#else
let portableCoreBuild = true
#endif

// New SpeakCore files are portable by default. An Apple adapter must be
// explicitly classified here, so future domain work reaches every platform.
let appleCoreSources: [String] = [
    "AppGroupAvailability.swift",
    "AppVisualDensity.swift",
    "AppleSpeechAnalyzerLiveSession.swift",
    "AppleSpeechAnalyzerTranscriber.swift",
    "AppleSpeechAssets.swift",
    "AppleSpeechDependencyWait.swift",
    "AppleSpeechDetector.swift",
    "AppleSpeechModelPreparation.swift",
    "AppleSpeechPreparationOperations.swift",
    "AssemblyAILiveClient.swift",
    "AutoCorrectionEngine.swift",
    "AutoCorrectionStore.swift",
    "AutomationIntentSupport.swift",
    "AzureBatchTranscriptionClient.swift",
    "AzureSpeechEndpointField.swift",
    "AzureVoiceLiveClient.swift",
    "BrandColors.swift",
    "CaptureDisruptionObserver.swift",
    "CaptureEndPointing.swift",
    "CaptureHealth.swift",
    "CaptureHealthReportBuilder.swift",
    "CaptureOnboarding.swift",
    "CaptureOnboardingStore.swift",
    "CaptureSafetyClaim.swift",
    "CaptureSelfTest.swift",
    "CaptureWatchdogs.swift",
    "CartesiaLiveClient.swift",
    "CartesiaTTSAPI.swift",
    "DeepgramBalanceClient.swift",
    "DeepgramLiveClient.swift",
    "DeepgramLiveProtocol.swift",
    "DeepgramTTSAPI.swift",
    "DeprecatedCompatibility.swift",
    "DeviceIdentityStore.swift",
    "ElevenLabsBalanceClient.swift",
    "ElevenLabsLiveClient.swift",
    "FileProductAnalyticsStateStore.swift",
    "GeminiLiveClient.swift",
    "GeminiLiveProtocol.swift",
    "GeminiTTSAPI.swift",
    "GladiaLiveClient.swift",
    "GroqTTSAPI.swift",
    "HandsFreeAudioPreRollBuffer.swift",
    "HandsFreeDictation.swift",
    "KeyDerivation.swift",
    "KeyboardDelivery.swift",
    "KeyboardDeliveryPolicies.swift",
    "KeyboardDeliveryStore.swift",
    "KeyboardDictationMachine.swift",
    "KeyboardDictationPreferences.swift",
    "KeyboardDictationProfile.swift",
    "KeyboardHandoff.swift",
    "KeyboardHandoffModels.swift",
    "KeyboardHandoffStorage.swift",
    "KeyboardHandoffTransitions.swift",
    "KeyboardInstantDictation.swift",
    "KeyboardTranscriptStreamer.swift",
    "KeychainAccessibilityMigration.swift",
    "KeychainSync.swift",
    "LiveAudioConverterDrain.swift",
    "LiveTranscriptionClientFactory.swift",
    "Logging.swift",
    "MacConnection.swift",
    "MetaMuseLiveClient.swift",
    "MetaMuseVoiceTranscribe.swift",
    "MistralTTSAPI.swift",
    "MistralVoxtralLiveClient.swift",
    "ModulateLiveClient.swift",
    "OpenClawClient.swift",
    "OpenClawClientReceive.swift",
    "OpenRouterAPIClient.swift",
    "OpenRouterAudioBrowser.swift",
    "OpenRouterAudioCatalog.swift",
    "OpenRouterAudioCatalogLoader.swift",
    "OpenRouterAudioCatalogRequestOrder.swift",
    "OpenRouterAudioCatalogStorage.swift",
    "OpenRouterAudioClient+Download.swift",
    "OpenRouterAudioClient+Selection.swift",
    "OpenRouterAudioClient+Wire.swift",
    "OpenRouterAudioClient.swift",
    "OpenRouterAudioFilter.swift",
    "OpenRouterAudioModel.swift",
    "OpenRouterAudioModelDetail.swift",
    "OpenRouterAudioPreview.swift",
    "OpenRouterBalanceClient.swift",
    "PersonalLexiconService.swift",
    "PersonalLexiconStore.swift",
    "ProductAnalytics.swift",
    "ProductAnalyticsDimensions.swift",
    "PronunciationManager.swift",
    "ProviderBalanceStore.swift",
    "ProviderBalanceTransport.swift",
    "RecordingSoundPlayer.swift",
    "ReleaseNotes.swift",
    "ReleaseNotesContentView.swift",
    "ReleaseTrainCompatibility.swift",
    "RevAIBalanceClient.swift",
    "RevAILiveClient.swift",
    "SecureStorage.swift",
    "SettingsSync.swift",
    "SharedAudioImport.swift",
    "SharedRecordingInbox.swift",
    "SonioxLiveClient.swift",
    "SonioxTTSRealtime.swift",
    "SpeakCLIManifest.swift",
    "SpeechInsights/SpeechInsightsAggregate.swift",
    "SpeechInsights/SpeechInsightsConfiguration.swift",
    "SpeechInsights/SpeechInsightsEngine.swift",
    "SpeechInsights/SpeechInsightsSummary.swift",
    "SpeechInsights/SpeechInsightsSummaryBuilder.swift",
    "SpeechInsights/SpeechSessionRecord.swift",
    "SpeechInsights/SpeechTokenizer.swift",
    "SpeechmaticsLiveClient.swift",
    "SpeechmaticsTTSAPI.swift",
    "StartupDiagnostics.swift",
    "TranscriptHandoffActivity.swift",
    "TranscriptionActivityHandle.swift",
    "TranscriptionActivityManager+ResultRow.swift",
    "TranscriptionActivityManager.swift",
    "TransportChannel.swift",
    "TransportProtocol.swift",
    "WatchCaptureImportJournal.swift",
    "WatchCaptureProtocol.swift",
    "WatchComplicationState.swift",
    "WatchRecordingLifecycle.swift",
    "WatchRecordingToggleSerialiser.swift",
    "WatchSharedContainer.swift",
    "XAILiveClient.swift",
    "XAILiveFinalisation.swift",
    "XAILiveProtocol.swift",
    "XAISpeechToTextLiveClient.swift",
    "XAISpeechToTextLiveProtocol.swift",
    "XAITTSAPI.swift",
    "XAITTSRealtime.swift",
]

let portablePackage = Package(
    name: "SpeakApp",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpeakCore", targets: ["SpeakCore"]),
        .library(name: "SpeakDesktop", targets: ["SpeakDesktop"])
    ],
    targets: [
        .target(
            name: "SpeakCore",
            path: "Sources/SpeakCore",
            exclude: appleCoreSources,
            resources: [.process("Resources")],
            swiftSettings: [.define("SPEAK_PORTABLE_CORE")]
        ),
        .target(name: "SpeakDesktop", dependencies: ["SpeakCore"]),
        .target(name: "SpeakTestSupport", path: "Tests/SpeakTestSupport"),
        .testTarget(name: "SpeakDesktopTests", dependencies: ["SpeakDesktop", "SpeakCore", "SpeakTestSupport"]),
        .testTarget(
            name: "SpeakPortableTests",
            dependencies: ["SpeakCore", "SpeakTestSupport"],
            path: "Tests/SpeakPortableTests"
        )
    ]
)

#if os(Windows)
portablePackage.products.append(.executable(name: "SpeakWindows", targets: ["SpeakWindows"]))
portablePackage.targets.append(contentsOf: [
    .target(
        name: "CWindowsSupport",
        publicHeadersPath: "include",
        linkerSettings: [
            .linkedLibrary("user32"), .linkedLibrary("gdi32"), .linkedLibrary("ole32"),
            .linkedLibrary("uuid"), .linkedLibrary("advapi32"), .linkedLibrary("comdlg32"), .linkedLibrary("shell32"),
            .linkedLibrary("avrt")
        ]
    ),
    .executableTarget(name: "SpeakWindows", dependencies: ["SpeakCore", "SpeakDesktop", "CWindowsSupport"]),
    .testTarget(name: "SpeakWindowsPlatformTests", dependencies: ["CWindowsSupport"])
])
portablePackage.cxxLanguageStandard = .cxx17
#endif

let package = portableCoreBuild ? portablePackage : Package(
    name: "SpeakApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "SpeakHotKeys", targets: ["SpeakHotKeys"]),
        .library(name: "SpeakCore", targets: ["SpeakCore"]),
        .library(name: "SpeakDesktop", targets: ["SpeakDesktop"]),
        .library(name: "SpeakSync", targets: ["SpeakSync"]),
        .library(name: "SpeakiOSLib", targets: ["SpeakiOSLib"]),
        .library(name: "SpeakAutomationKit", targets: ["SpeakAutomationKit"]),
        // Test-only; a product purely so the Tuist-built iOS test bundle can
        // link the same module the SwiftPM test targets import (issue #1124).
        // Not part of the shipped API surface and not checked by the
        // public-API compatibility gate.
        .library(name: "SpeakTestSupport", targets: ["SpeakTestSupport"]),
        .executable(name: "SpeakApp", targets: ["SpeakApp"]),
        .executable(name: "speak", targets: ["SpeakCLI"]),
        .executable(
            name: "local-transcription-benchmark",
            targets: ["LocalTranscriptionBenchmark"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        // SwiftLint intentionally lives in Tooling/Package.swift, not here: it
        // pins an exact swift-syntax version that conflicts with
        // swift-snapshot-testing's constraint, and sharing one graph let a test
        // dependency silently downgrade the linter (issue #677). Run it via
        // `make lint` / scripts/swiftlint.sh.
        .package(url: "https://github.com/nicklockwood/SwiftFormat.git", from: "0.53.6"),
        .package(url: "https://github.com/jaywcjlove/PermissionFlow.git", exact: "2.11.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.3.0"),
        // Mirrored in Project.swift (`projectPackages`): Xcode resolves both
        // graphs together, so the two requirements must agree (issue #757).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-snapshot-testing.git",
            from: "1.18.0"
        )
    ],
    targets: [
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.1.3/"
                + "TranscribeCpp.xcframework.zip",
            checksum: "b7a3442e2f3552cac1ee71b5e164934dd4db243f6b4b16b1e3e3ed5d1645eefd"
        ),
        .target(name: "SpeakDesktop", dependencies: ["SpeakCore"]),
        .testTarget(name: "SpeakDesktopTests", dependencies: ["SpeakDesktop", "SpeakCore", "SpeakTestSupport"]),
        .target(
            name: "SpeakHotKeys",
            path: "Sources/SpeakHotKeys"
        ),
        .target(
            name: "SpeakCore",
            resources: [
                // Bundled release notes so the in-app "What's New" screen works offline.
                .process("Resources")
            ],
            swiftSettings: [
                // Strict concurrency checking (warnings-only under Swift 5 language
                // mode). Tuist consumes this same package target, so the setting
                // applies to Xcode builds too.
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "SpeakSync",
            dependencies: ["SpeakCore"],
            path: "Sources/SpeakSync"
        ),
        .target(
            name: "SpeakiOSLib",
            dependencies: ["SpeakCore", "SpeakSync"],
            path: "Sources/SpeakiOS"
        ),
        // Automation client library: parsing, rendering, socket client and the
        // MCP request handler. Split from the `speak` executable so every layer
        // is unit-testable without spawning a process.
        .target(
            name: "SpeakAutomationKit",
            dependencies: ["SpeakCore"],
            path: "Sources/SpeakAutomationKit"
        ),
        .executableTarget(
            name: "SpeakCLI",
            dependencies: ["SpeakAutomationKit", "SpeakCore"],
            path: "Sources/SpeakCLI"
        ),
        .executableTarget(
            name: "SpeakApp",
            dependencies: [
                "SpeakCore",
                "SpeakSync",
                "SpeakHotKeys",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "PermissionFlow", package: "PermissionFlow"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            resources: [.copy("Resources/AppIcon.icns")]
        ),
        .executableTarget(
            name: "SpeakHotKeysDemo",
            dependencies: ["SpeakHotKeys"],
            path: "Sources/SpeakHotKeysDemo"
        ),
        .target(
            name: "LocalTranscriptionBenchmarkKit",
            dependencies: ["SpeakCore"]
        ),
        .executableTarget(
            name: "LocalTranscriptionBenchmark",
            dependencies: [
                "LocalTranscriptionBenchmarkKit",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                "CTranscribe"
            ]
        ),
        // Shared test doubles (issue #1124). A plain target, not a test
        // target, so the Tuist-built iOS test bundle can compile the same
        // sources through its own glob.
        .target(
            name: "SpeakTestSupport",
            path: "Tests/SpeakTestSupport"
        ),
        .testTarget(
            name: "SpeakCoreTests",
            dependencies: ["SpeakCore", "SpeakTestSupport"]
        ),
        .testTarget(
            name: "SpeakHotKeysTests",
            dependencies: ["SpeakHotKeys"]
        ),
        .testTarget(
            name: "SpeakSyncTests",
            dependencies: ["SpeakSync"]
        ),
        .testTarget(
            name: "SpeakAppTests",
            dependencies: [
                "SpeakApp",
                "SpeakAutomationKit",
                "SpeakHotKeys",
                "SpeakTestSupport",
                // The Sentry event tests inspect the serialised payload, so the
                // test target needs the SDK types, not just SpeakApp.
                .product(name: "Sentry", package: "sentry-cocoa"),
                // Storage lifecycle tests construct unloaded SDK models.
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        ),
        .testTarget(
            name: "SpeakAppSnapshotTests",
            dependencies: [
                "SpeakApp",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            exclude: ["__Snapshots__"]
        ),
        .testTarget(
            name: "SpeakiOSTests",
            dependencies: ["SpeakiOSLib", "SpeakTestSupport"]
        ),
        .testTarget(
            name: "SpeakAutomationKitTests",
            dependencies: ["SpeakAutomationKit", "SpeakCore"]
        ),
        .testTarget(
            name: "LocalTranscriptionBenchmarkTests",
            dependencies: ["LocalTranscriptionBenchmarkKit", "SpeakCore"]
        )
    ]
)
