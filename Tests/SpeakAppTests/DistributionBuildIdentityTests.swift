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

    func testIOSReleaseWorkflowSignsAndValidatesKeyboardExtension() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-ios.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(workflow.contains("IOS_KEYBOARD_APPSTORE_PROFILE"))
        XCTAssertTrue(workflow.contains("ios-keyboard-appstore.provisionprofile"))
        XCTAssertTrue(workflow.contains("com.justspeaktoit.ios.keyboard"))
        XCTAssertTrue(workflow.contains("--capability APP_GROUPS"))
        XCTAssertTrue(workflow.contains("--recreate"))
        XCTAssertTrue(workflow.contains("Keyboard provisioning profile does not authorize group.com.justspeaktoit.ios"))
        XCTAssertTrue(workflow.contains(".Entitlements[\"com.apple.security.application-groups\"]"))
        XCTAssertFalse(workflow.contains("Entitlements.com.apple.security.application-groups.0"))
        XCTAssertTrue(workflow.contains("KEYBOARD_PROFILE_UUID_PLACEHOLDER"))
        XCTAssertTrue(workflow.contains("JustSpeakKeyboard.appex"))
        XCTAssertTrue(workflow.contains("keyboard-entitlements.plist"))

        let profileBootstrap = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/create-ios-app-store-profile.rb"),
            encoding: .utf8
        )
        XCTAssertTrue(profileBootstrap.contains("path: \"/v1/bundleIds\""))
        XCTAssertTrue(profileBootstrap.contains("/bundleIdCapabilities\""))
        XCTAssertFalse(profileBootstrap.contains("/bundleIdCapabilities?limit="))
        XCTAssertTrue(profileBootstrap.contains("path: \"/v1/bundleIdCapabilities\""))
        XCTAssertTrue(profileBootstrap.contains("capabilityType: capability_type"))
        XCTAssertTrue(profileBootstrap.contains("method: Net::HTTP::Delete"))
        XCTAssertTrue(profileBootstrap.contains("profiles.each do |stale_profile|"))
        XCTAssertTrue(profileBootstrap.contains("path: \"/v1/profiles/#{stale_profile.fetch('id')}\""))
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
