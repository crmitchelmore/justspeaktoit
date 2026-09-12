import Foundation
import XCTest

/// Guards the App Store submission requirements that live in build manifests
/// and bundle metadata rather than in Swift code. Every assertion here stands
/// for a rejection or an upload warning the project has to avoid: purpose
/// strings App Review reads verbatim (guideline 5.1.1), the per-binary privacy
/// manifests Apple scans for required-reason APIs (ITMS-91053), and the
/// purpose strings an extension binary needs once it references a TCC API
/// (ITMS-90683).
final class IOSAppStoreComplianceTests: XCTestCase {

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SpeakCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private func contents(of relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func plist(at relativePath: String) throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(parsed as? [String: Any], "Expected \(relativePath) to parse as a dictionary")
    }

    // MARK: - Info.plist declared in the Tuist manifest

    func testCameraPurposeString_describesHowTheCameraIsUsed() throws {
        let manifest = try contents(of: "Project.swift")
        XCTAssertFalse(
            manifest.contains("does not use the camera"),
            "A purpose string that denies using the camera is a guideline 5.1.1 rejection"
        )
        XCTAssertTrue(
            manifest.contains("uses the camera to scan the QR code"),
            "NSCameraUsageDescription should name the QR configuration transfer that needs the camera"
        )
    }

    func testMicrophonePurposeString_disclosesOffDeviceTranscription() throws {
        let manifest = try contents(of: "Project.swift")
        XCTAssertTrue(
            manifest.contains("transcription provider you choose in Settings"),
            "NSMicrophoneUsageDescription should say recordings can leave the device"
        )
    }

    func testDeviceCapabilities_doNotClaimThe32BitArmv7Slice() throws {
        let manifest = try contents(of: "Project.swift")
        XCTAssertTrue(
            manifest.contains("\"UIRequiredDeviceCapabilities\": [\"arm64\"]"),
            "The iOS app must override Tuist's armv7 default; it ships arm64-only against iOS 17"
        )
    }

    func testExportCompliance_declaresNonExemptEncryption() throws {
        let manifest = try contents(of: "Project.swift")
        XCTAssertTrue(
            manifest.contains("\"ITSAppUsesNonExemptEncryption\": true"),
            "CryptoKit AES-GCM key sync is not a Category 5 Part 2 exemption Apple lists"
        )
        XCTAssertTrue(
            manifest.contains("TUIST_ITS_ENCRYPTION_COMPLIANCE_CODE"),
            "The BIS approval code must be injectable rather than hard-coded as a placeholder"
        )
    }

    // MARK: - Keyboard extension

    func testKeyboardExtension_alwaysShipsTheInfoPlistThatDeclaresItsPurposeStrings() throws {
        let manifest = try contents(of: "Project.swift")
        XCTAssertTrue(
            manifest.contains("let iosKeyboardInfoPlist: InfoPlist = .file(")
                && manifest.contains("trainPlistPath(\"JustSpeakKeyboard/Info.plist\")"),
            "The keyboard binary references record-permission and Speech APIs in every configuration, "
                + "so the purpose strings cannot be gated on the direct-capture flag"
        )
    }

    func testKeyboardInfoPlist_declaresMicrophoneAndSpeechPurposeStrings() throws {
        let info = try plist(at: "JustSpeakKeyboard/Info.plist")
        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            let value = info[key] as? String
            XCTAssertFalse(
                (value ?? "").isEmpty,
                "\(key) is required: KeyboardDictationEngine references the matching API"
            )
        }
    }

    func testKeyboardSourcesStillReferenceTheAPIsThatRequireThosePurposeStrings() throws {
        let engine = try contents(of: "JustSpeakKeyboard/KeyboardDictationEngine.swift")
        XCTAssertTrue(
            engine.contains("requestRecordPermission") && engine.contains("SFSpeechRecognizer"),
            "If the keyboard stops touching these APIs, revisit the purpose strings instead of "
                + "leaving unused TCC declarations in the bundle"
        )
    }

    // MARK: - Privacy manifests

    /// Apple reads a privacy manifest per binary, so each embedded extension
    /// needs its own copy rather than relying on the host app's.
    func testEveryShippedIOSBundleCarriesAPrivacyManifest() throws {
        let manifests = [
            "SpeakiOSApp/PrivacyInfo.xcprivacy",
            "JustSpeakToItWidgetExtension/PrivacyInfo.xcprivacy",
            "JustSpeakKeyboard/PrivacyInfo.xcprivacy"
        ]
        for path in manifests {
            let privacy = try plist(at: path)
            XCTAssertEqual(privacy["NSPrivacyTracking"] as? Bool, false, "\(path) must declare tracking")
            XCTAssertNotNil(
                privacy["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
                "\(path) must declare its required-reason APIs"
            )
        }
    }

    func testExtensionPrivacyManifests_areBundledByTheirTargets() throws {
        let manifest = try contents(of: "Project.swift")
        XCTAssertTrue(manifest.contains("\"JustSpeakKeyboard/PrivacyInfo.xcprivacy\""))
        XCTAssertTrue(manifest.contains("\"JustSpeakToItWidgetExtension/PrivacyInfo.xcprivacy\""))
    }

    func testExtensionPrivacyManifests_declareTheSharedDefaultsTheyRead() throws {
        let paths = [
            "JustSpeakToItWidgetExtension/PrivacyInfo.xcprivacy",
            "JustSpeakKeyboard/PrivacyInfo.xcprivacy"
        ]
        for path in paths {
            let privacy = try plist(at: path)
            let declarations = try XCTUnwrap(privacy["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
            let categories = declarations.compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
            XCTAssertTrue(
                categories.contains("NSPrivacyAccessedAPICategoryUserDefaults"),
                "\(path): both extensions link SpeakCore, which reads the App Group defaults"
            )
        }
    }

    func testAppPrivacyManifest_declaresTranscriptTextLeavingTheDevice() throws {
        let privacy = try plist(at: "SpeakiOSApp/PrivacyInfo.xcprivacy")
        let collected = try XCTUnwrap(privacy["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let types = collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        XCTAssertTrue(types.contains("NSPrivacyCollectedDataTypeAudioData"))
        XCTAssertTrue(
            types.contains("NSPrivacyCollectedDataTypeOtherUserContent"),
            "Post-processing and voice output send transcript text to third-party providers"
        )
    }
}
