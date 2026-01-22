import ProjectDescription

let project = Project(
    name: "Just Speak to It",
    organizationName: "Just Speak to It",
    packages: [
        .package(path: .relativeToRoot(".")),
        .remote(url: "https://github.com/sparkle-project/Sparkle.git", requirement: .upToNextMajor(from: "2.6.0"))
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
                .glob(pattern: "Resources/AppIcon.icns")
            ],
            entitlements: .file(path: "Config/SpeakMacOS.entitlements"),
            dependencies: [
                .package(product: "SpeakCore"),
                .package(product: "Sparkle")
            ],
            settings: .settings(base: [
                "DEVELOPMENT_TEAM": "8X4ZN58TYH",
                "CODE_SIGN_STYLE": "Automatic",
                "CODE_SIGN_IDENTITY": "Apple Development",
                "PRODUCT_BUNDLE_IDENTIFIER": "com.justspeaktoit.mac"
            ])
        ),
        .target(
            name: "SpeakiOS",
            destinations: .iOS,
            product: .app,
            productName: "JustSpeakToIt",
            bundleId: "com.justspeaktoit.ios",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .default,
            sources: ["SpeakiOSApp/**"],
            entitlements: .file(path: "SpeakiOS.entitlements"),
            dependencies: [
                .package(product: "SpeakCore"),
                .package(product: "SpeakiOSLib"),
                .target(name: "JustSpeakToItWidgetExtension")
            ],
            settings: .settings(base: [
                "CURRENT_PROJECT_VERSION": "1",
                "INFOPLIST_KEY_CFBundleDisplayName": "Just Speak to It",
                "MARKETING_VERSION": "0.1.0",
                "INFOPLIST_KEY_NSMicrophoneUsageDescription": "Just Speak to It needs microphone access for voice transcription.",
                "INFOPLIST_KEY_NSSpeechRecognitionUsageDescription": "Just Speak to It uses speech recognition to transcribe your voice.",
                "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
                "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
                "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
                "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
                "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
            ])
        ),
        .target(
            name: "JustSpeakToItWidgetExtension",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "com.justspeaktoit.ios.JustSpeakToItWidgetExtension",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .file(path: "JustSpeakToItWidgetExtension/Info.plist"),
            sources: ["JustSpeakToItWidgetExtension/**"],
            dependencies: [
                .package(product: "SpeakCore")
            ],
            settings: .settings(base: [
                "CURRENT_PROJECT_VERSION": "1",
                "MARKETING_VERSION": "0.1.0"
            ])
        )
    ]
)
