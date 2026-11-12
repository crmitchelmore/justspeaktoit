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

    func testExportCompliance_declaresOperatingSystemEncryptionExemption() throws {
        let manifest = try contents(of: "Project.swift")
        XCTAssertTrue(
            manifest.contains("\"ITSAppUsesNonExemptEncryption\": false"),
            "Apple exempts encryption limited to its operating system"
        )
        XCTAssertFalse(
            manifest.contains("ITSEncryptionExportComplianceCode"),
            "OS-only encryption must not stamp an unapproved export code"
        )
    }

    func testAppleAppIntentDescriptionsAvoidRejectedTerms() throws {
        let roots = [
            "Sources/SpeakiOS", "Sources/SpeakApp", "JustSpeakWatchShared", "JustSpeakWatch",
            "JustSpeakToItWidgetExtension", "JustSpeakWatchWidget", "JustSpeakShare", "JustSpeakKeyboard"
        ]
        var checked = 0
        for root in roots {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(
                at: repositoryRoot.appendingPathComponent(root), includingPropertiesForKeys: nil
            ))
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                guard source.contains("import AppIntents") else { continue }
                for description in try intentDescriptions(in: source, path: file.path) {
                    for term in ["iPhone", "Siri"] {
                        XCTAssertFalse(
                            description.localizedCaseInsensitiveContains(term),
                            "\(file.path): ITMS-90626 prohibits '\(term)' in App Intent descriptions"
                        )
                    }
                    XCTAssertTrue(description.hasSuffix("."), "\(file.path): description must end with a period")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "No App Intent descriptions were checked")
    }

    private func intentDescriptions(in source: String, path: String) throws -> [String] {
        let initializer = #"IntentDescription\s*\(\s*"#
        let literalProperty = #"\bstatic\s+(?:var|let)\s+description\s*:\s*IntentDescription\s*\{\s*"#
        let pattern = "(?:" + initializer + "|" + literalProperty + #")("""[\s\S]*?"""|"(?:\\.|[^"\\])*")\s*[,)}]"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        let matches = expression.matches(in: source, range: range)
        let declarations = try NSRegularExpression(pattern: #"\bstatic\s+(?:var|let)\s+description\b"#)
        XCTAssertEqual(
            matches.count, declarations.numberOfMatches(in: source, range: range),
            "\(path): keep intent descriptions as direct string literals so the source guard can check them"
        )
        return matches.map {
            let literal = (source as NSString).substring(with: $0.range(at: 1))
            XCTAssertFalse(literal.contains("\\("), "\(path): interpolated descriptions require a metadata audit")
            XCTAssertFalse(literal.contains("\\u"), "\(path): escaped descriptions require a metadata audit")
            let quotes = literal.hasPrefix("\"\"\"") ? 3 : 1
            return String(literal.dropFirst(quotes).dropLast(quotes))
                .replacingOccurrences(of: #"\\\r?\n\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func testDescriptionSourceGuardReadsInitializersAndLiteralRepresentations() throws {
        let source = #"""
        static var description: IntentDescription { IntentDescription("Uses iPhone.") }
        static var description: IntentDescription { "Uses Siri." }
        static var description: IntentDescription {
            IntentDescription("""
                Uses si\
                ri.
                """)
        }
        """#
        XCTAssertEqual(
            try intentDescriptions(in: source, path: "fixture"),
            ["Uses iPhone.", "Uses Siri.", "Uses siri."]
        )
    }

    func testIOSAppShortcutCountStaysWithinApplesLimit() throws {
        let source = try contents(of: "Sources/SpeakiOS/Activity/TranscriptionShortcuts.swift")
        let expression = try NSRegularExpression(pattern: #"\bAppShortcut\s*\("#)
        let count = expression.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThanOrEqual(count, 10, "Apple permits at most ten App Shortcuts per app")
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
            "JustSpeakKeyboard/PrivacyInfo.xcprivacy",
            "JustSpeakShare/PrivacyInfo.xcprivacy",
            "JustSpeakWatch/PrivacyInfo.xcprivacy",
            "JustSpeakWatchWidget/PrivacyInfo.xcprivacy"
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
        XCTAssertTrue(manifest.contains("\"JustSpeakShare/PrivacyInfo.xcprivacy\""))
        XCTAssertTrue(manifest.contains("\"JustSpeakWatch/PrivacyInfo.xcprivacy\""))
        XCTAssertTrue(manifest.contains("\"JustSpeakWatchWidget/PrivacyInfo.xcprivacy\""))
    }

    func testSharedTranscriptionTimersHaveARequiredReasonDeclaration() throws {
        let privacy = try plist(at: "SpeakiOSApp/PrivacyInfo.xcprivacy")
        let entries = try XCTUnwrap(privacy["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let bootTime = try XCTUnwrap(entries.first {
            $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategorySystemBootTime"
        })
        XCTAssertTrue((bootTime["NSPrivacyAccessedAPITypeReasons"] as? [String])?.contains("35F9.1") == true)
    }

    func testShareExtensionUsesTheSelectedReleaseTrainIdentityAndStorage() throws {
        let project = try contents(of: "Project.swift")
        for expression in [
            #"trainIdentifier("com.justspeaktoit.ios.share")"#,
            #"trainPlistPath("JustSpeakShare/Info.plist")"#,
            #"trainPlistPath("JustSpeakShare/JustSpeakShare.entitlements")"#
        ] {
            XCTAssertTrue(project.contains(expression), "Share extension must not embed Stable identity in Alpha")
        }
    }

    func testExtensionPrivacyManifests_declareTheSharedDefaultsTheyRead() throws {
        let paths = [
            "SpeakiOSApp/PrivacyInfo.xcprivacy",
            "JustSpeakToItWidgetExtension/PrivacyInfo.xcprivacy",
            "JustSpeakKeyboard/PrivacyInfo.xcprivacy"
        ]
        for path in paths {
            let privacy = try plist(at: path)
            let declarations = try XCTUnwrap(privacy["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
            for (category, reason) in [
                ("NSPrivacyAccessedAPICategoryUserDefaults", "1C8F.1"),
                ("NSPrivacyAccessedAPICategoryFileTimestamp", "C617.1")
            ] {
                let declaration = try XCTUnwrap(declarations.first {
                    $0["NSPrivacyAccessedAPIType"] as? String == category
                })
                let reasons = try XCTUnwrap(declaration["NSPrivacyAccessedAPITypeReasons"] as? [String])
                XCTAssertTrue(reasons.contains(reason), "\(path): missing \(category)/\(reason)")
            }
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

    /// Sentry supplies an installation ID independently of sendDefaultPii.
    func testAppPrivacyManifest_declaresInstallationLinkedSentryDiagnostics() throws {
        let privacy = try plist(at: "SpeakiOSApp/PrivacyInfo.xcprivacy")
        let collected = try XCTUnwrap(privacy["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        for type in [
            "NSPrivacyCollectedDataTypeCrashData", "NSPrivacyCollectedDataTypePerformanceData",
            "NSPrivacyCollectedDataTypeOtherDiagnosticData", "NSPrivacyCollectedDataTypeDeviceID"
        ] {
            let entry = try XCTUnwrap(collected.first { $0["NSPrivacyCollectedDataType"] as? String == type }, type)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true, type)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false, type)
        }
    }

    /// The iOS app compiles the Mac's Sentry configuration and credential
    /// scrubber rather than a copy, so the two cannot drift apart.
    func testIOSApp_compilesTheSharedSentryConfigurationAndScrubber() throws {
        let manifest = try contents(of: "Project.swift")
        XCTAssertTrue(manifest.contains("\"Sources/SpeakApp/Analytics/SentryManager.swift\""))
        XCTAssertTrue(manifest.contains("\"Sources/SpeakApp/Analytics/SentryEventScrubber.swift\""))
        let launch = try contents(of: "SpeakiOSApp/SpeakiOSApp.swift")
        XCTAssertTrue(launch.contains("SentryManager.start()"))
    }
}
