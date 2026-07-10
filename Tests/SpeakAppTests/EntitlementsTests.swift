import XCTest

@testable import SpeakApp

/// Verifies that the macOS entitlements file contains the correct entitlements
/// for Developer ID distribution and does NOT contain restricted entitlements
/// that require provisioning profiles.
///
/// Context: Releases mac-v0.19.2 through mac-v0.19.8 were all attempts to fix
/// entitlement-related crashes. This test catches that entire class of bug at
/// CI time, before a build ever reaches users.
final class EntitlementsTests: XCTestCase {

    private var entitlements: [String: Any]!
    private let entitlementsPath = "Config/SpeakMacOS.entitlements"

    override func setUpWithError() throws {
        // Find the entitlements file relative to the package root.
        // SPM test working directory is the package root.
        let url = URL(fileURLWithPath: entitlementsPath)
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        entitlements = plist as? [String: Any]
        XCTAssertNotNil(entitlements, "Entitlements file should parse as a dictionary")
    }

    // MARK: - Required Entitlements

    func testMicrophoneEntitlement_isPresent() {
        let value = entitlements["com.apple.security.device.audio-input"] as? Bool
        XCTAssertEqual(value, true,
            "Audio input entitlement is REQUIRED for microphone access under hardened runtime")
    }

    func testAutomationEntitlement_isPresent() {
        let value = entitlements["com.apple.security.automation.apple-events"] as? Bool
        XCTAssertEqual(value, true,
            "Apple Events entitlement is required for text insertion via accessibility")
    }

    // MARK: - Developer ID Restrictions (must NOT be present)

    func testSandbox_isNotEnabled() {
        // App sandbox is incompatible with Developer ID distribution for this app.
        // It requires accessibility prompts and global hotkey monitoring.
        let value = entitlements["com.apple.security.app-sandbox"] as? Bool
        XCTAssertNotEqual(value, true,
            "App sandbox must NOT be enabled for Developer ID builds. " +
            "It breaks accessibility, hotkeys, and text insertion.")
    }

    func testICloudEntitlements_areNotActive() {
        // iCloud entitlements require a provisioning profile for Developer ID.
        // They caused crash-on-launch in mac-v0.19.2 through mac-v0.19.5.
        let iCloudContainers = entitlements["com.apple.developer.icloud-container-identifiers"]
        XCTAssertNil(iCloudContainers,
            "iCloud container entitlements must be commented out for Developer ID builds " +
            "(requires provisioning profile)")

        let iCloudServices = entitlements["com.apple.developer.icloud-services"]
        XCTAssertNil(iCloudServices,
            "iCloud services entitlements must be commented out for Developer ID builds")

        let apsEnvironment = entitlements["aps-environment"]
        XCTAssertNil(apsEnvironment,
            "APS environment must be commented out for Developer ID builds " +
            "(requires provisioning profile)")
    }

    func testKeychainSharingEntitlement_isNotActive() {
        let keychainGroups = entitlements["keychain-access-groups"]
        XCTAssertNil(keychainGroups,
            "Keychain access groups must be commented out for Developer ID builds " +
            "(requires provisioning profile)")
    }

    func testAssociatedDomainsEntitlement_isNotActive() {
        let domains = entitlements["com.apple.developer.associated-domains"]
        XCTAssertNil(domains,
            "Associated domains must be commented out for Developer ID builds " +
            "(requires provisioning profile)")
    }

    func testUbiquityKVStoreEntitlement_isNotActive() {
        let kvStore = entitlements["com.apple.developer.ubiquity-kvstore-identifier"]
        XCTAssertNil(kvStore,
            "Ubiquity KV store must be commented out for Developer ID builds " +
            "(requires provisioning profile)")
    }

    // MARK: - Entitlements File Integrity

    func testEntitlementsFile_isValidPlist() {
        // If this test runs at all, setUp succeeded, which means the file is valid.
        // This test just documents the intent.
        XCTAssertFalse(entitlements.isEmpty, "Entitlements file should not be empty")
    }

    func testEntitlementsFile_hasNoUnexpectedEntitlements() {
        // Allowlist of known entitlements. If a new one is added, this test
        // forces the developer to explicitly acknowledge it here.
        let allowedKeys: Set<String> = [
            "com.apple.security.device.audio-input",
            "com.apple.security.automation.apple-events",
            "com.apple.security.cs.disable-library-validation"
        ]

        let actualKeys = Set(entitlements.keys)
        let unexpected = actualKeys.subtracting(allowedKeys)

        XCTAssertTrue(unexpected.isEmpty,
            "Unexpected entitlements found: \(unexpected.sorted()). " +
            "If intentional, add them to the allowlist in this test.")
    }
}

/// Verifies the SANDBOXED Mac App Store entitlements file. This is the flavour
/// selected when the project is generated with `TUIST_APP_STORE=1` (see Project.swift).
/// The App Store REQUIRES the sandbox and FORBIDS
/// `com.apple.security.cs.disable-library-validation`; these tests lock that in so a
/// mis-edited file can never be submitted.
final class AppStoreEntitlementsTests: XCTestCase {

    private var entitlements: [String: Any]!
    private let entitlementsPath = "Config/SpeakMacOS.AppStore.entitlements"

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: entitlementsPath)
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        entitlements = plist as? [String: Any]
        XCTAssertNotNil(entitlements, "App Store entitlements file should parse as a dictionary")
    }

    // MARK: - Required for App Store

    func testSandbox_isEnabled() {
        let value = entitlements["com.apple.security.app-sandbox"] as? Bool
        XCTAssertEqual(value, true,
            "The App Sandbox is REQUIRED for Mac App Store distribution")
    }

    func testMicrophoneEntitlement_isPresent() {
        let value = entitlements["com.apple.security.device.audio-input"] as? Bool
        XCTAssertEqual(value, true, "Audio input is required for microphone access")
    }

    func testNetworkClientEntitlement_isPresent() {
        let value = entitlements["com.apple.security.network.client"] as? Bool
        XCTAssertEqual(value, true,
            "Outbound network is required to reach transcription/post-processing providers")
    }

    func testNetworkServerEntitlement_isPresent() {
        let value = entitlements["com.apple.security.network.server"] as? Bool
        XCTAssertEqual(value, true,
            "Inbound network is required for the Bonjour Send to Mac listener")
    }

    // MARK: - Forbidden on App Store

    func testDisableLibraryValidation_isAbsent() {
        // The Mac App Store rejects builds carrying this entitlement.
        let value = entitlements["com.apple.security.cs.disable-library-validation"]
        XCTAssertNil(value,
            "disable-library-validation is FORBIDDEN on the Mac App Store and must not " +
            "appear in the App Store entitlements file")
    }

    // MARK: - iCloud (available under the App Store managed profile)

    func testICloud_isConfiguredForSync() {
        let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        XCTAssertEqual(containers, ["iCloud.com.justspeaktoit"],
            "App Store build should be entitled for the CloudKit history-sync container")

        let services = entitlements["com.apple.developer.icloud-services"] as? [String]
        XCTAssertEqual(services?.contains("CloudKit"), true,
            "CloudKit service is required for transcription history sync")

        let kvStore = entitlements["com.apple.developer.ubiquity-kvstore-identifier"] as? String
        XCTAssertNotNil(kvStore, "iCloud KV store identifier is required for settings sync")
    }

    // MARK: - Integrity

    func testEntitlementsFile_hasNoUnexpectedEntitlements() {
        let allowedKeys: Set<String> = [
            "com.apple.security.app-sandbox",
            "com.apple.security.device.audio-input",
            "com.apple.security.network.client",
            "com.apple.security.network.server",
            "com.apple.security.files.user-selected.read-write",
            "keychain-access-groups",
            "com.apple.developer.ubiquity-kvstore-identifier",
            "com.apple.developer.icloud-container-identifiers",
            "com.apple.developer.icloud-services",
            "aps-environment"
        ]
        let unexpected = Set(entitlements.keys).subtracting(allowedKeys)
        XCTAssertTrue(unexpected.isEmpty,
            "Unexpected App Store entitlements found: \(unexpected.sorted()). " +
            "If intentional, add them to the allowlist in this test.")
    }
}
