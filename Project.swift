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
let keyboardProfileName = ProcessInfo.processInfo.environment["KEYBOARD_PROFILE_NAME"]
let watchProfileName = ProcessInfo.processInfo.environment["TUIST_WATCH_PROFILE_NAME"]
let watchWidgetProfileName = ProcessInfo.processInfo.environment["TUIST_WATCH_WIDGET_PROFILE_NAME"]
let macAppStoreProfileName = ProcessInfo.processInfo.environment["TUIST_MAC_PROFILE_NAME"]
    ?? ProcessInfo.processInfo.environment["MAC_PROFILE_NAME"]

var iosAppSettings: [String: SettingValue] = [
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "CURRENT_PROJECT_VERSION": "1",
    "MARKETING_VERSION": "\(version)"
]

// Build-time feature flags for iOS. Both features are hidden by default.
// `TUIST_IOS_KEYBOARD=1 tuist generate` is the only way to include the custom
// keyboard extension in the generated project and host app. The matching Swift
// condition gates app activation and setup UI (see SpeakiOSApp/FeatureFlags.swift).
let iosKeyboardFlag = (ProcessInfo.processInfo.environment["TUIST_IOS_KEYBOARD"] ?? "").lowercased()
let isIOSKeyboardEnabled = ["1", "true", "yes"].contains(iosKeyboardFlag)
// `TUIST_WATCH_APP=1 tuist generate` includes the Apple Watch companion app
// and defines `WATCH_APP_FEATURE`, which gates the iPhone-side
// WatchConnectivity receiver (see SpeakiOSApp/FeatureFlags.swift). Off by
// default so CI and release signing are unaffected until a provisioning
// profile exists for the watch bundle id.
let watchAppFlag = (ProcessInfo.processInfo.environment["TUIST_WATCH_APP"] ?? "").lowercased()
let isWatchAppEnabled = ["1", "true", "yes"].contains(watchAppFlag)
var iosActiveCompilationConditions: [String] = []
var iosTestSettings: [String: SettingValue] = [:]
var iosTestResourceElements: [ResourceFileElement] = [
    "SpeakiOS.entitlements",
    "JustSpeakToItWidgetExtension/JustSpeakToItWidgetExtension.entitlements"
]

if ProcessInfo.processInfo.environment["SHOW_OPENCLAW_TAB"] != nil {
    iosActiveCompilationConditions.append("SHOW_OPENCLAW_TAB")
}
if isIOSKeyboardEnabled {
    iosActiveCompilationConditions.append("IOS_KEYBOARD_FEATURE")
    iosTestSettings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) IOS_KEYBOARD_FEATURE"
    iosTestResourceElements.append("JustSpeakKeyboard/JustSpeakKeyboard.entitlements")
}
if isWatchAppEnabled {
    iosActiveCompilationConditions.append("WATCH_APP_FEATURE")
}
if !iosActiveCompilationConditions.isEmpty {
    iosAppSettings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = .string(
        "$(inherited) \(iosActiveCompilationConditions.joined(separator: " "))"
    )
}

// Distribution channel selection for macOS. The app compiles from one codebase into
// two flavours: Developer ID / direct download (default) and Mac App Store. Generate
// with `TUIST_APP_STORE=1 tuist generate` to produce a sandboxed App Store build: it
// defines the `APP_STORE` Swift active compilation condition (gates Sparkle self-update
// and external executable model runtimes — see Sources/SpeakCore/DistributionChannel.swift)
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
let macInfoPlistPath = isAppStoreBuild
    ? "Config/AppInfo.AppStore.plist"
    : "Config/AppInfo.plist"
// Keep the existing direct-download identity stable for Sparkle updates while giving
// the App Store build its own LaunchServices identity. A distinct identifier is
// required for both variants to coexist and for TestFlight's Open button to resolve
// the App Store build instead of an already-installed direct build.
let macProductName = isAppStoreBuild ? "JustSpeakToItAppStore" : "JustSpeakToIt"
let macBundleIdentifier = isAppStoreBuild
    ? "com.justspeaktoit.mac.appstore"
    : "com.justspeaktoit.mac"
var macAppSettings: [String: SettingValue] = [
    "DEVELOPMENT_TEAM": "8X4ZN58TYH",
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "PRODUCT_BUNDLE_IDENTIFIER": .string(macBundleIdentifier)
]

var iosWidgetSettings: [String: SettingValue] = [
    "CURRENT_PROJECT_VERSION": "1",
    "MARKETING_VERSION": "\(version)"
]

var iosKeyboardSettings: [String: SettingValue] = [
    "APPLICATION_EXTENSION_API_ONLY": "YES",
    "CURRENT_PROJECT_VERSION": "1",
    "MARKETING_VERSION": "\(version)",
    "SKIP_INSTALL": "YES"
]

var watchAppSettings: [String: SettingValue] = [
    "CURRENT_PROJECT_VERSION": "1",
    "MARKETING_VERSION": "\(version)"
]

// The watch widget extension shares source with the watch app (the record
// intent and the shared-container payloads); `WATCH_WIDGET_EXTENSION` selects
// the extension-side branch of `StartWatchRecordingIntent`, which cannot touch
// the microphone from a widget process.
var watchWidgetSettings: [String: SettingValue] = [
    "CURRENT_PROJECT_VERSION": "1",
    "MARKETING_VERSION": "\(version)",
    "SKIP_INSTALL": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) WATCH_WIDGET_EXTENSION"
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

if let keyboardProfileName {
    configureManualSigning(for: &iosKeyboardSettings, profileName: keyboardProfileName)
}

if let watchProfileName {
    configureManualSigning(for: &watchAppSettings, profileName: watchProfileName)
}

if let watchWidgetProfileName {
    configureManualSigning(for: &watchWidgetSettings, profileName: watchWidgetProfileName)
}

if isAppStoreBuild {
    macAppSettings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) APP_STORE"
    macAppSettings["CODE_SIGN_IDENTITY"] = "Apple Distribution"
    if let macAppStoreProfileName, !macAppStoreProfileName.isEmpty {
        configureManualSigning(for: &macAppSettings, profileName: macAppStoreProfileName)
    }
}

var projectPackages: [Package] = [
    .package(path: .relativeToRoot(".")),
    .remote(url: "https://github.com/getsentry/sentry-cocoa.git", requirement: .upToNextMajor(from: "9.3.0")),
    .remote(url: "https://github.com/argmaxinc/argmax-oss-swift.git", requirement: .upToNextMajor(from: "0.9.0")),
    .remote(url: "https://github.com/FluidInference/FluidAudio.git", requirement: .exact("0.15.5"))
]
if !isAppStoreBuild {
    projectPackages += [
        .remote(url: "https://github.com/sparkle-project/Sparkle.git", requirement: .upToNextMajor(from: "2.6.0"))
    ]
}

var macAppDependencies: [TargetDependency] = [
    .package(product: "SpeakCore"),
    .package(product: "SpeakSync"),
    .package(product: "SpeakHotKeys"),
    .package(product: "WhisperKit"),
    .package(product: "FluidAudio"),
    .package(product: "Sentry")
]
if !isAppStoreBuild {
    macAppDependencies += [
        .package(product: "Sparkle")
    ]
}

var iosAppDependencies: [TargetDependency] = [
    .package(product: "SpeakCore"),
    .package(product: "SpeakiOSLib"),
    .package(product: "SpeakSync"),
    .target(name: "JustSpeakToItWidgetExtension")
]
if isIOSKeyboardEnabled {
    iosAppDependencies.append(.target(name: "JustSpeakKeyboard"))
}
if isWatchAppEnabled {
    iosAppDependencies.append(.target(name: "JustSpeakWatchApp"))
}

let macAppTarget: Target = .target(
    name: "SpeakApp",
    destinations: .macOS,
    product: .app,
    productName: macProductName,
    bundleId: macBundleIdentifier,
    deploymentTargets: .macOS("14.0"),
    infoPlist: .file(path: .relativeToRoot(macInfoPlistPath)),
    sources: ["Sources/SpeakApp/**"],
    resources: [
        .glob(pattern: "Resources/AppIcon.icns"),
        .glob(pattern: "Resources/Sounds/**")
    ],
    entitlements: .file(path: .relativeToRoot(macEntitlementsPath)),
    dependencies: macAppDependencies,
    settings: .settings(base: macAppSettings)
)

let iosAppTarget: Target = .target(
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
        "NSLocalNetworkUsageDescription":
            "Just Speak to It uses your local network to connect iPhone and Mac for Send to Mac transcription transfer.",
        "NSBonjourServices": ["_speaktransport._tcp"],
        "NSCameraUsageDescription": "Just Speak to It does not use the camera, but a linked library requires this declaration.",
        // Export compliance: the app uses only standard, published encryption
        // (AES-GCM and PBKDF2 via CryptoKit) to protect the user's own API keys
        // for end-to-end encrypted iCloud/CloudKit key sync, alongside OS-provided
        // HTTPS and Keychain. This qualifies for the U.S. EAR Category 5 Part 2
        // export exemption, so the app uses no *non-exempt* encryption.
        "ITSAppUsesNonExemptEncryption": false,
        "NSSupportsLiveActivities": true,
        "UIBackgroundModes": ["audio", "remote-notification"],
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
    dependencies: iosAppDependencies,
    settings: .settings(base: iosAppSettings)
)

let watchAppTarget: Target = .target(
    name: "JustSpeakWatchApp",
    destinations: [.appleWatch],
    product: .app,
    productName: "JustSpeakToItWatch",
    // Watch app bundle ids must be prefixed with the companion iOS app's
    // bundle id.
    bundleId: "com.justspeaktoit.ios.watchkitapp",
    deploymentTargets: .watchOS("10.0"),
    infoPlist: .extendingDefault(with: [
        "WKApplication": true,
        "WKCompanionAppBundleIdentifier": "com.justspeaktoit.ios",
        "CFBundleDisplayName": "Just Speak to It",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "NSMicrophoneUsageDescription":
            "Just Speak to It records audio on your watch and transcribes it on your iPhone.",
        // The audio background mode is what keeps a capture running once the
        // wrist drops and the screen turns off: an AVAudioSession activated
        // while the app is frontmost stays alive for as long as audio flows.
        // Deliberately *not* one of the `WKBackgroundModes` extended-runtime
        // types (self-care/mindfulness/physical-therapy/alarm) — none of them
        // describes dictation, and all are frontmost-only. See the rationale
        // in JustSpeakWatch/WatchRecordingRuntime.swift.
        "UIBackgroundModes": ["audio"]
    ]),
    // The watch target cannot depend on the SpeakCore package product
    // (several transitive package manifests do not declare watchOS support),
    // so it compiles the shared watch files directly. Pure Foundation;
    // unit-tested via SpeakCoreTests. `JustSpeakWatchShared` is the source the
    // watch app and its widget extension both compile.
    sources: [
        "JustSpeakWatch/**",
        "JustSpeakWatchShared/**",
        "Sources/SpeakCore/WatchCaptureProtocol.swift",
        "Sources/SpeakCore/WatchComplicationState.swift",
        "Sources/SpeakCore/WatchRecordingLifecycle.swift",
        "Sources/SpeakCore/WatchRecordingToggleSerialiser.swift",
        "Sources/SpeakCore/WatchSharedContainer.swift"
    ],
    entitlements: .file(path: "JustSpeakWatch/JustSpeakWatch.entitlements"),
    dependencies: [
        .target(name: "JustSpeakWatchWidgetExtension")
    ],
    settings: .settings(base: watchAppSettings)
)

// Watch-face complication + Smart Stack entry. Embedded in the watch app, so
// it is gated by the same `TUIST_WATCH_APP` flag: the complication bundle id
// needs its own provisioning profile and the App Group must be registered for
// both watch bundle ids (see Docs/watch-provisioning.md).
let watchWidgetTarget: Target = .target(
    name: "JustSpeakWatchWidgetExtension",
    destinations: [.appleWatch],
    product: .appExtension,
    // Extension bundle ids must be prefixed with the containing watch app's.
    bundleId: "com.justspeaktoit.ios.watchkitapp.complication",
    deploymentTargets: .watchOS("10.0"),
    infoPlist: .file(path: "JustSpeakWatchWidget/Info.plist"),
    sources: [
        "JustSpeakWatchWidget/**",
        "JustSpeakWatchShared/**",
        "Sources/SpeakCore/WatchCaptureProtocol.swift",
        "Sources/SpeakCore/WatchComplicationState.swift",
        "Sources/SpeakCore/WatchSharedContainer.swift"
    ],
    entitlements: .file(path: "JustSpeakWatchWidget/JustSpeakWatchWidget.entitlements"),
    settings: .settings(base: watchWidgetSettings)
)

let keyboardTarget: Target = .target(
    name: "JustSpeakKeyboard",
    destinations: .iOS,
    product: .appExtension,
    bundleId: "com.justspeaktoit.ios.keyboard",
    deploymentTargets: .iOS("17.0"),
    infoPlist: .file(path: "JustSpeakKeyboard/Info.plist"),
    sources: ["JustSpeakKeyboard/**/*.swift"],
    entitlements: .file(path: "JustSpeakKeyboard/JustSpeakKeyboard.entitlements"),
    dependencies: [
        .package(product: "SpeakCore")
    ],
    settings: .settings(base: iosKeyboardSettings)
)

let widgetTarget: Target = .target(
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
)

let macUITestsTarget: Target = .target(
    name: "SpeakAppUITests",
    destinations: .macOS,
    product: .uiTests,
    bundleId: "com.justspeaktoit.uitests",
    sources: ["Tests/SpeakAppUITests/**"],
    dependencies: [
        .target(name: "SpeakApp")
    ]
)

let iosUITestsTarget: Target = .target(
    name: "SpeakiOSUITests",
    destinations: .iOS,
    product: .uiTests,
    bundleId: "com.justspeaktoit.ios.uitests",
    deploymentTargets: .iOS("17.0"),
    sources: ["Tests/SpeakiOSUITests/**"],
    dependencies: [
        .target(name: "SpeakiOS")
    ],
    settings: .settings(base: iosTestSettings)
)

let iosTestsTarget: Target = .target(
    name: "SpeakiOSTests",
    destinations: .iOS,
    product: .unitTests,
    bundleId: "com.justspeaktoit.ios.tests",
    deploymentTargets: .iOS("17.0"),
    sources: ["Tests/SpeakiOSTests/**"],
    resources: .resources(iosTestResourceElements),
    dependencies: [
        .target(name: "SpeakiOS"),
        .package(product: "SpeakCore"),
        .package(product: "SpeakiOSLib")
    ],
    settings: .settings(base: iosTestSettings)
)

// Targets are assembled in statements (rather than one conditional array
// expression) to keep the manifest type-checkable in reasonable time.
var projectTargets: [Target] = [macAppTarget, iosAppTarget]
if isWatchAppEnabled {
    projectTargets.append(watchAppTarget)
    projectTargets.append(watchWidgetTarget)
}
if isIOSKeyboardEnabled {
    projectTargets.append(keyboardTarget)
}
projectTargets += [widgetTarget, macUITestsTarget, iosUITestsTarget, iosTestsTarget]

let project = Project(
    name: "Just Speak to It",
    organizationName: "Just Speak to It",
    packages: projectPackages,
    settings: .settings(
        base: [
            "DEVELOPMENT_TEAM": "8X4ZN58TYH",
            "CODE_SIGN_STYLE": "Automatic"
        ]
    ),
    targets: projectTargets
)
