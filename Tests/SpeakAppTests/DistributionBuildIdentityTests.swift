import Foundation
import XCTest

final class DistributionBuildIdentityTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testMacDistributionChannels_useDistinctBundleIdentifiers() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Project.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(manifest.contains("\"com.justspeaktoit.mac.appstore\""))
        XCTAssertTrue(manifest.contains("\"com.justspeaktoit.mac\""))
        XCTAssertTrue(manifest.contains("bundleId: macBundleIdentifier"))
        XCTAssertTrue(manifest.contains("PRODUCT_BUNDLE_IDENTIFIER\": .string(macBundleIdentifier)"))
    }

    func testMacAppStoreWorkflow_exportsTheAppStoreIdentifier() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-appstore.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(workflow.contains("BUNDLE_ID: com.justspeaktoit.mac.appstore"))
        XCTAssertTrue(workflow.contains("<key>com.justspeaktoit.mac.appstore</key>"))
        XCTAssertFalse(workflow.contains("<key>com.justspeaktoit.mac</key>"))
        XCTAssertTrue(workflow.contains("APPLE_TEAM_ID.$BUNDLE_ID"))
        XCTAssertTrue(workflow.contains("com.apple.application-identifier"))
        XCTAssertTrue(workflow.contains("com.apple.developer.icloud-container-identifiers"))
        XCTAssertTrue(workflow.contains("iCloud.com.justspeaktoit"))
        XCTAssertTrue(workflow.contains("$0 == \"iCloud.com.justspeaktoit\""))
        XCTAssertFalse(workflow.contains("grep -Fq \"iCloud.com.justspeaktoit\""))
        XCTAssertFalse(workflow.contains("Entitlements.application-identifier"))
    }

    func testDirectMacRelease_runsKeychainTestsBeforeInstallingSigningKeychain() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-mac.yml"),
            encoding: .utf8
        )

        let testStep = try XCTUnwrap(workflow.range(of: "- name: Run Tests (Release Config)"))
        let signingStep = try XCTUnwrap(workflow.range(of: "- name: Import Code Signing Certificate"))

        XCTAssertLessThan(testStep.lowerBound, signingStep.lowerBound)
    }

    func testDirectMacRelease_retriesStaplingAcceptedNotarizationTickets() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-mac.yml"),
            encoding: .utf8
        )
        let retryScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/retry-staple.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(workflow.contains("bash scripts/retry-staple.sh \"$APP_PATH\""))
        XCTAssertTrue(workflow.contains("bash scripts/retry-staple.sh \"$DMG_PATH\""))
        XCTAssertTrue(retryScript.contains("stapler staple"))
        XCTAssertTrue(retryScript.contains("stapler validate"))
        XCTAssertTrue(retryScript.contains("STAPLE_MAX_ATTEMPTS:-6"))
        XCTAssertTrue(retryScript.contains("[[ ! -e \"$ARTIFACT_PATH\" ]]"))
        XCTAssertTrue(retryScript.contains("STAPLE_MAX_ATTEMPTS must be a positive integer"))
        XCTAssertTrue(retryScript.contains("RETRY_DELAY > 300"))
    }

    func testPlatformAppTargets_doNotCompileTheOtherPlatformsUI() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Project.swift"),
            encoding: .utf8
        )
        let macTarget = try targetBlock(named: "SpeakApp", in: manifest)
        let iosTarget = try targetBlock(named: "SpeakiOS", in: manifest)

        XCTAssertTrue(macTarget.contains("sources: [\"Sources/SpeakApp/**\"]"))
        XCTAssertFalse(macTarget.contains("SpeakiOSApp"))
        XCTAssertFalse(macTarget.contains("SpeakiOSLib"))
        XCTAssertFalse(macTarget.contains("JustSpeakToItWidgetExtension"))
        XCTAssertFalse(macTarget.contains("JustSpeakKeyboard"))

        XCTAssertTrue(iosTarget.contains("sources: [\"SpeakiOSApp/**\"]"))
        XCTAssertTrue(iosTarget.contains(".package(product: \"SpeakiOSLib\")"))
        XCTAssertTrue(iosTarget.contains(".target(name: \"JustSpeakKeyboard\")"))
        XCTAssertFalse(iosTarget.contains("Sources/SpeakApp"))
        XCTAssertFalse(iosTarget.contains("SpeakHotKeys"))
        XCTAssertFalse(iosTarget.contains("Sparkle"))
    }

    func testIOSKeyboardTargetUsesPublicExtensionConfiguration() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Project.swift"),
            encoding: .utf8
        )
        let keyboardTarget = try targetBlock(named: "JustSpeakKeyboard", in: manifest)
        let infoPlist = try String(
            contentsOf: repositoryRoot.appendingPathComponent("JustSpeakKeyboard/Info.plist"),
            encoding: .utf8
        )

        XCTAssertTrue(keyboardTarget.contains("bundleId: \"com.justspeaktoit.ios.keyboard\""))
        XCTAssertTrue(keyboardTarget.contains("product: .appExtension"))
        XCTAssertTrue(keyboardTarget.contains("settings: .settings(base: iosKeyboardSettings)"))
        XCTAssertTrue(manifest.contains("\"APPLICATION_EXTENSION_API_ONLY\": \"YES\""))
        XCTAssertTrue(infoPlist.contains("com.apple.keyboard-service"))
        XCTAssertTrue(infoPlist.contains("RequestsOpenAccess"))
        XCTAssertTrue(infoPlist.contains("$(PRODUCT_MODULE_NAME).KeyboardViewController"))
    }

    func testIOSKeyboardUsesInstantSessionLivePreviewAndRetainsHistory() throws {
        let keyboard = try String(
            contentsOf: repositoryRoot.appendingPathComponent("JustSpeakKeyboard/KeyboardViewController.swift"),
            encoding: .utf8
        )
        let instantCoordinator = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(keyboard.contains("extensionContext.open"))
        XCTAssertTrue(keyboard.contains("if requestID == nil, isInstantReady"))
        XCTAssertTrue(keyboard.contains("Open Just Speak once"))
        XCTAssertTrue(keyboard.contains("KeyboardHandoffSignal.postRequestChanged"))
        XCTAssertTrue(keyboard.contains("Stop & Insert"))
        XCTAssertTrue(keyboard.contains("keyboardLiveTranscript"))
        XCTAssertTrue(keyboard.contains("completed transcripts remain in History"))
        XCTAssertFalse(keyboard.contains("Results are deleted after insertion"))
        XCTAssertTrue(instantCoordinator.contains("input.installTap"))
        XCTAssertTrue(instantCoordinator.contains("requiresLiveActivity: false"))
        XCTAssertTrue(instantCoordinator.contains("updateInterim"))
        XCTAssertFalse(instantCoordinator.contains(".write("))
        XCTAssertFalse(instantCoordinator.contains(".upload("))
        XCTAssertTrue(instantCoordinator.contains("saveToHistory: true"))
    }

    func testIOSReleaseWorkflowSignsAndValidatesKeyboardExtension() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-ios.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(workflow.contains("IOS_KEYBOARD_APPSTORE_PROFILE"))
        XCTAssertTrue(workflow.contains("ios-keyboard-appstore.provisionprofile"))
        XCTAssertTrue(workflow.contains("com.justspeaktoit.ios.keyboard"))
        XCTAssertTrue(workflow.contains("--capability APP_GROUPS"))
        XCTAssertFalse(workflow.contains("--recreate"))
        XCTAssertTrue(workflow.contains("Keyboard provisioning profile does not authorize group.com.justspeaktoit.ios"))
        XCTAssertTrue(workflow.contains("ios-keyboard-appstore.plist"))
        XCTAssertTrue(workflow.contains("plutil -extract Entitlements xml1"))
        XCTAssertTrue(workflow.contains("<string>group.com.justspeaktoit.ios</string>"))
        XCTAssertFalse(workflow.contains("Entitlements.com.apple.security.application-groups.0"))
        XCTAssertTrue(workflow.contains("KEYBOARD_PROFILE_UUID_PLACEHOLDER"))
        XCTAssertTrue(workflow.contains("JustSpeakKeyboard.appex"))
        XCTAssertTrue(workflow.contains("keyboard-entitlements.plist"))
        XCTAssertTrue(workflow.contains("APP_ICLOUD_CONTAINER"))
        XCTAssertTrue(workflow.contains("iCloud container mismatch"))
        XCTAssertTrue(workflow.contains("iCloud.com.justspeaktoit.ios"))

        let profileBootstrap = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/create-ios-app-store-profile.rb"),
            encoding: .utf8
        )
        XCTAssertTrue(profileBootstrap.contains("path: \"/v1/bundleIds\""))
        XCTAssertTrue(profileBootstrap.contains("/bundleIdCapabilities\""))
        XCTAssertFalse(profileBootstrap.contains("/bundleIdCapabilities?limit="))
        XCTAssertTrue(profileBootstrap.contains("path: \"/v1/bundleIdCapabilities\""))
        XCTAssertTrue(profileBootstrap.contains("capabilityType: capability_type"))
        XCTAssertFalse(profileBootstrap.contains("method: Net::HTTP::Delete"))
        XCTAssertFalse(profileBootstrap.contains("profiles.each do |stale_profile|"))
    }

    func testIOSReleaseWorkflowRequiresAnExplicitSemanticVersion() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-ios.yml"),
            encoding: .utf8
        )

        let versionInputStart = try XCTUnwrap(workflow.range(of: "      version:\n")?.lowerBound)
        let buildInputStart = try XCTUnwrap(workflow.range(of: "      build_number:\n")?.lowerBound)
        let versionInput = workflow[versionInputStart..<buildInputStart]
        XCTAssertTrue(versionInput.contains("required: true"))
        XCTAssertTrue(versionInput.contains("type: string"))

        let validationStart = try XCTUnwrap(workflow.range(of: "      - name: Determine Version\n")?.lowerBound)
        let buildNumberStart = try XCTUnwrap(workflow.range(of: "      - name: Determine Build Number\n")?.lowerBound)
        let validation = workflow[validationStart..<buildNumberStart]
        XCTAssertTrue(validation.contains("INPUT_VERSION: ${{ inputs.version }}"))
        XCTAssertTrue(validation.contains("iOS release version is required"))
        XCTAssertTrue(validation.contains("VERSION is not authoritative for TestFlight"))
        XCTAssertTrue(validation.contains("must be semantic version text"))

        let patternPrefix = "VERSION_PATTERN='"
        let patternStart = try XCTUnwrap(validation.range(of: patternPrefix)?.upperBound)
        let patternEnd = try XCTUnwrap(validation[patternStart...].firstIndex(of: "'"))
        let pattern = String(validation[patternStart..<patternEnd])
        let regex = try NSRegularExpression(pattern: pattern)
        func isAccepted(_ value: String) -> Bool {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.firstMatch(in: value, range: range)?.range == range
        }
        XCTAssertTrue(isAccepted("2.29.2"))
        XCTAssertTrue(isAccepted("0.0.0"))
        XCTAssertFalse(isAccepted(""))
        XCTAssertFalse(isAccepted("01.2.3"))
        XCTAssertFalse(isAccepted("2.00.3"))
        XCTAssertFalse(isAccepted("v2.29.2"))
        XCTAssertFalse(isAccepted("2.29"))
        XCTAssertFalse(workflow.contains("leave empty to use VERSION file"))
        XCTAssertFalse(workflow.contains("VERSION=$(cat VERSION)"))
    }

    func testIOSApp_declaresRequiredBackgroundModes() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Project.swift"),
            encoding: .utf8
        )
        let iosTarget = try targetBlock(named: "SpeakiOS", in: manifest)

        XCTAssertTrue(iosTarget.contains("\"UIBackgroundModes\": [\"audio\", \"remote-notification\"]"))
    }

    private func targetBlock(named name: String, in manifest: String) throws -> Substring {
        let marker = ".target(\n            name: \"\(name)\""
        let start = try XCTUnwrap(manifest.range(of: marker)?.lowerBound)
        let remainder = manifest[start...]
        let nextTarget = remainder.dropFirst(marker.count).range(of: "\n        .target(")?.lowerBound
        let end = nextTarget ?? manifest.endIndex
        return manifest[start..<end]
    }
}
