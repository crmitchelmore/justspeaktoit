import ProjectDescription
import Foundation

// Read version from VERSION file
let version: String = {
    let versionFile = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .appendingPathComponent("VERSION")
    return (try? String(contentsOf: versionFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.1.0"
}()

let appProfileName = ProcessInfo.processInfo.environment["APP_PROFILE_NAME"]
let widgetProfileName = ProcessInfo.processInfo.environment["WIDGET_PROFILE_NAME"]

var iosAppSettings: [String: SettingValue] = [
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "CURRENT_PROJECT_VERSION": "1",
    "MARKETING_VERSION": "\(version)"
]

// Build-time feature flag: the OpenClaw tab is hidden by default (App Store
// builds ship without it). Generate the project with `SHOW_OPENCLAW_TAB=1
// tuist generate` to bring the tab back for internal testing. Gated in code via
// the `SHOW_OPENCLAW_TAB` Swift active compilation condition (see
// SpeakiOSApp/FeatureFlags.swift).
if ProcessInfo.processInfo.environment["SHOW_OPENCLAW_TAB"] != nil {
    iosAppSettings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) SHOW_OPENCLAW_TAB"
}

// Distribution channel selection for macOS. The app compiles from one codebase into
// two flavours: Developer ID / direct download (default) and Mac App Store. Generate
// with `TUIST_APP_STORE=1 tuist generate` to produce a sandboxed App Store build: it
// defines the `APP_STORE` Swift active compilation condition (gates Sparkle self-update
// and the downloaded local-model runtimes — see Sources/SpeakCore/DistributionChannel.swift)
// and selects the sandboxed entitlements file.
//
// NOTE: the env var MUST be `TUIST_`-prefixed. Tuist only forwards environment variables
// whose names start with `TUIST_` into the manifest evaluation process, so a plain
// `APP_STORE=1` is silently ignored here and the manifest would fall back to the direct
// (non-sandboxed) entitlements. The Swift compilation condition itself stays `APP_STORE`
// (that is what the `#if !APP_STORE` source guards check).
// Parse an explicit truthy value so `TUIST_APP_STORE=0` (or an empty value) predictably
// selects the direct build instead of silently enabling the App Store variant.
let appStoreFlag = (ProcessInfo.processInfo.environment["TUIST_APP_STORE"] ?? "").lowercased()
let isAppStoreBuild = ["1", "true", "yes"].contains(appStoreFlag)
let macEntitlementsPath = isAppStoreBuild
    ? "Config/SpeakMacOS.AppStore.entitlements"
    : "Config/SpeakMacOS.entitlements"
var macAppSettings: [String: SettingValue] = [
    "DEVELOPMENT_TEAM": "8X4ZN58TYH",
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "PRODUCT_BUNDLE_IDENTIFIER": "com.justspeaktoit.mac"
]
if isAppStoreBuild {
    macAppSettings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) APP_STORE"
}

var iosWidgetSettings: [String: SettingValue] = [
    "CURRENT_PROJECT_VERSION": "1",
    "MARKETING_VERSION": "\(version)"
]

func configureManualSigning(for settings: inout [String: SettingValue], profileName: String) {
    settings["PROVISIONING_PROFILE_SPECIFIER"] = .string(profileName)
    settings["CODE_SIGN_STYLE"] = "Manual"
    settings["CODE_SIGN_IDENTITY"] = "Apple Distribution"
}

if let appProfileName {
    configureManualSigning(for: &iosAppSettings, profileName: appProfileName)
}

if let widgetProfileName {
    configureManualSigning(for: &iosWidgetSettings, profileName: widgetProfileName)
}

let project = Project(
    name: "Just Speak to It",
    organizationName: "Just Speak to It",
    packages: [
        .package(path: .relativeToRoot(".")),
        .remote(url: "https://github.com/sparkle-project/Sparkle.git", requirement: .upToNextMajor(from: "2.6.0")),
        .remote(url: "https://github.com/getsentry/sentry-cocoa.git", requirement: .upToNextMajor(from: "9.3.0")),
        .remote(url: "https://github.com/argmaxinc/argmax-oss-swift.git", requirement: .upToNextMajor(from: "0.9.0"))
    ],
    settings: .settings(
        base: [
            "DEVELOPMENT_TEAM": "8X4ZN58TYH",
            "CODE_SIGN_STYLE": "Automatic"
        ]
    ),
    targets: [
        .target(
            name: "SpeakApp",
            destinations: .macOS,
            product: .app,
            productName: "JustSpeakToIt",
            bundleId: "com.justspeaktoit.mac",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .file(path: "Config/AppInfo.plist"),
            sources: ["Sources/SpeakApp/**"],
            resources: [
                .glob(pattern: "Resources/AppIcon.icns"),
                .glob(pattern: "Resources/Sounds/**")
            ],
            entitlements: .file(path: .relativeToRoot(macEntitlementsPath)),
            dependencies: [
                .package(product: "SpeakCore"),
                .package(product: "SpeakSync"),
                .package(product: "SpeakHotKeys"),
                .package(product: "WhisperKit"),
                .package(product: "Sparkle"),
                .package(product: "Sentry")
            ],
            settings: .settings(base: macAppSettings)
        ),
        .target(
            name: "SpeakiOS",
            destinations: .iOS,
            product: .app,
            productName: "JustSpeakToIt",
            bundleId: "com.justspeaktoit.ios",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .extendingDefault(with: [
                "UILaunchStoryboardName": "LaunchScreen",
                "UIRequiresFullScreen": false,
                "CFBundleDisplayName": "Just Speak to It",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NSMicrophoneUsageDescription": "Just Speak to It needs microphone access for voice transcription.",
                "NSSpeechRecognitionUsageDescription": "Just Speak to It uses speech recognition to transcribe your voice.",
                "NSCameraUsageDescription": "Just Speak to It does not use the camera, but a linked library requires this declaration.",
                // Export compliance: the app uses only standard, published encryption
                // (AES-GCM and PBKDF2 via CryptoKit) to protect the user's own API keys
                // for end-to-end encrypted iCloud/CloudKit key sync, alongside OS-provided
                // HTTPS and Keychain. This qualifies for the U.S. EAR Category 5 Part 2
                // export exemption, so the app uses no *non-exempt* encryption.
                "ITSAppUsesNonExemptEncryption": false,
                "NSSupportsLiveActivities": true,
                "UIBackgroundModes": ["audio"],
                "UIApplicationShortcutItems": [
                    [
                        "UIApplicationShortcutItemType": "com.justspeaktoit.ios.quickaction.transcribe",
                        "UIApplicationShortcutItemTitle": "Transcribe Voice",
                        "UIApplicationShortcutItemSubtitle": "Start or stop recording",
                        "UIApplicationShortcutItemIconSymbolName": "mic.fill"
                    ]
                ],
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "com.justspeaktoit.ios",
                        "CFBundleURLSchemes": ["justspeaktoit"]
                    ]
                ]
            ]),
            sources: ["SpeakiOSApp/**"],
            resources: [
                "SpeakiOSApp/Assets.xcassets",
                "SpeakiOSApp/Resources/LaunchScreen.storyboard",
                "SpeakiOSApp/PrivacyInfo.xcprivacy"
            ],
            entitlements: .file(path: "SpeakiOS.entitlements"),
            dependencies: [
                .package(product: "SpeakCore"),
                .package(product: "SpeakiOSLib"),
                .package(product: "SpeakSync"),
                .target(name: "JustSpeakToItWidgetExtension")
            ],
            settings: .settings(base: iosAppSettings)
        ),
        .target(
            name: "JustSpeakToItWidgetExtension",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "com.justspeaktoit.ios.JustSpeakToItWidgetExtension",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .file(path: "JustSpeakToItWidgetExtension/Info.plist"),
            sources: ["JustSpeakToItWidgetExtension/**"],
            entitlements: .file(path: "JustSpeakToItWidgetExtension/JustSpeakToItWidgetExtension.entitlements"),
            dependencies: [
                .package(product: "SpeakCore"),
                .package(product: "SpeakiOSLib")
            ],
            settings: .settings(base: iosWidgetSettings)
        ),
        .target(
            name: "SpeakAppUITests",
            destinations: .macOS,
            product: .uiTests,
            bundleId: "com.justspeaktoit.uitests",
            sources: ["Tests/SpeakAppUITests/**"],
            dependencies: [
                .target(name: "SpeakApp")
            ]
        ),
        .target(
            name: "SpeakiOSUITests",
            destinations: .iOS,
            product: .uiTests,
            bundleId: "com.justspeaktoit.ios.uitests",
            deploymentTargets: .iOS("17.0"),
            sources: ["Tests/SpeakiOSUITests/**"],
            dependencies: [
                .target(name: "SpeakiOS")
            ]
        ),
        .target(
            name: "SpeakiOSTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.justspeaktoit.ios.tests",
            deploymentTargets: .iOS("17.0"),
            sources: ["Tests/SpeakiOSTests/**"],
            dependencies: [
                .target(name: "SpeakiOS"),
                .package(product: "SpeakiOSLib")
            ]
        )
    ]
)
