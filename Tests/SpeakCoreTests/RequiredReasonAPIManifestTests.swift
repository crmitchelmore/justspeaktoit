import Foundation
import XCTest

/// Fails when an iOS or watchOS bundle's code (its own sources plus the
/// statically linked modules) references a required-reason API category that
/// the bundle's own `PrivacyInfo.xcprivacy` does not declare. App Store
/// Connect rejects such uploads with ITMS-91053, per binary, so a declaration
/// in the host app does not cover an extension.
final class RequiredReasonAPIManifestTests: XCTestCase {

    private struct Bundle {
        let manifest: String
        let sourceRoots: [String]
    }

    private struct Category {
        let name: String
        let patterns: [String]
        /// Approved first-party reasons from Apple's NSPrivacyAccessedAPIType
        /// reference. Third-party SDK wrapper reasons are deliberately absent.
        let approvedReasons: Set<String>
    }

    private static let categories: [Category] = [
        Category(
            name: "NSPrivacyAccessedAPICategoryActiveKeyboards",
            patterns: [#"\bactiveInputModes\b"#],
            approvedReasons: ["3EC4.1", "54BD.1"]
        ),
        Category(
            name: "NSPrivacyAccessedAPICategorySystemBootTime",
            patterns: [#"\bsystemUptime\b"#, #"\bmach_absolute_time\b"#, #"\bKERN_BOOTTIME\b"#],
            approvedReasons: ["35F9.1", "8FFB.1", "3D61.1"]
        ),
        Category(
            name: "NSPrivacyAccessedAPICategoryDiskSpace",
            patterns: [
                #"\bvolumeAvailableCapacity\w*Key\b"#, #"\bvolumeTotalCapacityKey\b"#,
                #"\bsystemFreeSize\b"#, #"\bsystemSize\b"#, #"\bstatv?fs\("#, #"\bfstatv?fs\("#
            ],
            approvedReasons: ["85F4.1", "E174.1", "7D9E.1", "B728.1"]
        ),
        Category(
            name: "NSPrivacyAccessedAPICategoryFileTimestamp",
            patterns: [
                #"\bcreationDateKey\b"#, #"\bcontentModificationDateKey\b"#,
                #"\bNSFileCreationDate\b"#, #"\bNSFileModificationDate\b"#,
                #"\bFileAttributeKey\.(creationDate|modificationDate)\b"#,
                #"\[\.(creationDate|modificationDate)\]"#, #"\b[lf]?stat\("#
            ],
            approvedReasons: ["DDA9.1", "C617.1", "3B52.1"]
        ),
        Category(
            name: "NSPrivacyAccessedAPICategoryUserDefaults",
            patterns: [#"\bUserDefaults\b"#, #"@AppStorage\b"#],
            approvedReasons: ["CA92.1", "1C8F.1", "AC6B.1"]
        )
    ]

    /// Source roots compiled into, or statically linked by, each bundle (see
    /// the targets in `Project.swift` and the products in `Package.swift`).
    private static let bundles: [Bundle] = [
        Bundle(
            manifest: "SpeakiOSApp/PrivacyInfo.xcprivacy",
            sourceRoots: ["SpeakiOSApp", "Sources/SpeakiOS", "Sources/SpeakCore", "Sources/SpeakWatchCore"]
        ),
        Bundle(
            manifest: "JustSpeakKeyboard/PrivacyInfo.xcprivacy",
            sourceRoots: ["JustSpeakKeyboard", "Sources/SpeakCore", "Sources/SpeakWatchCore"]
        ),
        Bundle(
            manifest: "JustSpeakShare/PrivacyInfo.xcprivacy",
            sourceRoots: ["JustSpeakShare", "Sources/SpeakCore", "Sources/SpeakWatchCore"]
        ),
        Bundle(
            manifest: "JustSpeakToItWidgetExtension/PrivacyInfo.xcprivacy",
            sourceRoots: [
                "JustSpeakToItWidgetExtension", "Sources/SpeakiOS", "Sources/SpeakCore", "Sources/SpeakWatchCore"
            ]
        ),
        Bundle(
            manifest: "JustSpeakWatch/PrivacyInfo.xcprivacy",
            sourceRoots: ["JustSpeakWatch", "JustSpeakWatchShared", "Sources/SpeakWatchCore"]
        ),
        Bundle(
            manifest: "JustSpeakWatchWidget/PrivacyInfo.xcprivacy",
            sourceRoots: ["JustSpeakWatchWidget", "JustSpeakWatchShared", "Sources/SpeakWatchCore"]
        )
    ]

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SpeakCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    func testEveryBundleDeclaresTheRequiredReasonAPIsItsCodeReferences() throws {
        var sourcesByRoot: [String: [(path: String, text: String)]] = [:]
        for bundle in Self.bundles {
            let declared = try declarations(in: bundle.manifest)
            for root in bundle.sourceRoots where sourcesByRoot[root] == nil {
                sourcesByRoot[root] = try swiftSources(under: root)
            }
            let sources = bundle.sourceRoots.flatMap { sourcesByRoot[$0] ?? [] }
            for category in Self.categories {
                guard let use = try firstUse(of: category, in: sources) else { continue }
                XCTAssertNotNil(
                    declared[category.name],
                    "\(bundle.manifest) must declare \(category.name): \(use) references it (ITMS-91053)"
                )
            }
        }
    }

    func testDeclaredReasonsAreApprovedForTheirCategory() throws {
        let reasonsByCategory = Dictionary(uniqueKeysWithValues: Self.categories.map { ($0.name, $0.approvedReasons) })
        for bundle in Self.bundles {
            for (category, reasons) in try declarations(in: bundle.manifest) {
                let approved = try XCTUnwrap(reasonsByCategory[category], "\(bundle.manifest): unknown \(category)")
                XCTAssertFalse(reasons.isEmpty, "\(bundle.manifest): \(category) needs a reason")
                XCTAssertTrue(
                    Set(reasons).isSubset(of: approved),
                    "\(bundle.manifest): \(category) reasons \(reasons) are not all in \(approved.sorted())"
                )
            }
        }
    }

    /// The keyboard is a feature of a dictation app, not the app's primary
    /// functionality, so `3EC4.1` (custom keyboard apps) would misstate it.
    func testActiveKeyboardReadsUseTheCustomisedInterfaceReason() throws {
        for manifest in ["SpeakiOSApp/PrivacyInfo.xcprivacy", "JustSpeakKeyboard/PrivacyInfo.xcprivacy"] {
            let reasons = try declarations(in: manifest)["NSPrivacyAccessedAPICategoryActiveKeyboards"]
            XCTAssertEqual(reasons, ["54BD.1"], manifest)
        }
    }

    func testScannerDetectsTheActiveKeyboardsCall() throws {
        let category = try XCTUnwrap(Self.categories.first { $0.name.hasSuffix("ActiveKeyboards") })
        let sample = [(path: "Sample.swift", text: "let count = UITextInputMode.activeInputModes.count")]
        XCTAssertNotNil(try firstUse(of: category, in: sample))
    }

    // MARK: - Helpers

    private func declarations(in manifest: String) throws -> [String: [String]] {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(manifest))
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], manifest
        )
        let entries = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]], manifest)
        var result: [String: [String]] = [:]
        for entry in entries {
            let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String, manifest)
            result[category] = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
        }
        return result
    }

    private func swiftSources(under root: String) throws -> [(path: String, text: String)] {
        let base = repositoryRoot.appendingPathComponent(root)
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [(path: String, text: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = root + url.path.dropFirst(base.path.count)
            files.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertFalse(files.isEmpty, "\(root) has no Swift sources; update the bundle map")
        return files
    }

    private func firstUse(of category: Category, in sources: [(path: String, text: String)]) throws -> String? {
        let expressions = try category.patterns.map { try NSRegularExpression(pattern: $0) }
        for source in sources {
            let range = NSRange(source.text.startIndex..., in: source.text)
            if expressions.contains(where: { $0.firstMatch(in: source.text, range: range) != nil }) {
                return source.path
            }
        }
        return nil
    }
}
