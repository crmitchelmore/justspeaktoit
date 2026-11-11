import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// Fails when a settings card, section or persisted setting is added without a
/// `SettingsSearchCatalog` entry, so new features are always searchable.
/// See Docs/settings-search.md.
final class SettingsSearchCoverageTests: XCTestCase {
    /// Persisted settings that are deliberately not searchable, with the reason.
    private static let unindexedMacSettings: [String: String] = [
        "trackedAPIKeyIdentifiers": "Bookkeeping for stored keys; each key card is indexed at runtime."
    ]

    private static let unindexedIOSSettings: [String: String] = [
        "credentialsAvailable": "Derived state, not a user setting.",
        "transcriptClipboardNoticeVersion": "Records which clipboard notice was shown."
    ]

    func testEveryMacSettingsCardIsIndexed() throws {
        let files = try swiftFiles(under: "Sources/SpeakApp")
        var missing: [String] = []
        for (path, source) in files {
            for title in matches(of: #"(?:Shortcut)?SettingsCard\(\s*title:\s*"([^"]+)""#, in: source)
            where SettingsSearchCatalog.entry(title: title, platform: .macOS) == nil {
                missing.append("\(path): \(title)")
            }
        }
        XCTAssertTrue(missing.isEmpty, "Add SettingsSearchCatalog entries for: \(missing)")
    }

    func testRuntimeTitledMacCardsDeclareASearchEntry() throws {
        // The API-key cards are indexed per provider by MacSettingsSearch.apiKeyEntries.
        let runtimeIndexed: Set<String> = ["SettingsView+APIKeys.swift"]
        let files = try swiftFiles(under: "Sources/SpeakApp")
        var undeclared: [String] = []
        let pattern = try NSRegularExpression(pattern: #"SettingsCard\(\s*title:\s*[^"\s]"#)
        for (path, source) in files where !runtimeIndexed.contains((path as NSString).lastPathComponent) {
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                let tail = (source as NSString).substring(
                    with: NSRange(location: match.range.location, length: min(300, range.length - match.range.location))
                )
                if !tail.contains("searchEntryID:") { undeclared.append(path) }
            }
        }
        XCTAssertTrue(undeclared.isEmpty, "Cards with computed titles need searchEntryID: \(undeclared)")
    }

    func testEveryIOSSettingsSectionIsIndexed() throws {
        let paths = [
            "Sources/SpeakiOS/Views/SettingsView.swift",
            "Sources/SpeakiOS/Views/FocusCaptureSettingsSection.swift"
        ]
        var unregistered: [String] = []
        var missing: [String] = []
        for path in paths {
            let source = try read(path)
            unregistered += matches(of: #"(?<![A-Za-z])Section\("([^"]+)""#, in: source).map { "\(path): \($0)" }
            for title in matches(of: #"SearchableSettingsSection\("([^"]+)""#, in: source)
            where SettingsSearchCatalog.entry(title: title, platform: .iOS) == nil {
                missing.append("\(path): \(title)")
            }
        }
        XCTAssertTrue(unregistered.isEmpty, "Use SearchableSettingsSection for top-level sections: \(unregistered)")
        XCTAssertTrue(missing.isEmpty, "Add iOS SettingsSearchCatalog entries for: \(missing)")
    }

    func testEveryPersistedMacSettingIsIndexed() throws {
        // AppSettings and its domain preference stores live in Settings/AppSettings*.swift.
        let sources = try swiftFiles(under: "Sources/SpeakApp/Settings")
            .filter { ($0.0 as NSString).lastPathComponent.hasPrefix("AppSettings") }
        let published = sources.flatMap { publishedProperties(in: $0.1) }
        assertIndexed(published, platform: .macOS, exemptions: Self.unindexedMacSettings)
    }

    func testEveryPersistedIOSSettingIsIndexed() throws {
        let published = publishedProperties(in: try read("Sources/SpeakiOS/Settings/AppSettings.swift"))
            .filter { !$0.hasSuffix("APIKey") }  // Each key is indexed at runtime from the API Keys list.
        assertIndexed(published, platform: .iOS, exemptions: Self.unindexedIOSSettings)
    }

    func testEverySettingsTabHasASearchableRoot() {
        let roots = Set(SettingsSearchCatalog.entries(for: .macOS).filter(\.isSectionRoot).map(\.section))
        for tab in SettingsTab.allCases {
            XCTAssertTrue(roots.contains(tab.searchSection), "\(tab) has no searchable root")
            XCTAssertEqual(MacSettingsSearch.sidebarItem(for: tab.searchSection), .settings(tab))
        }
    }

    func testAPIKeyEntriesCoverEveryKeyCard() {
        let entries = MacSettingsSearch.apiKeyEntries(transcriptionProviders: [])
        let ids = Set(entries.map(\.id))
        XCTAssertTrue(ids.contains(MacSettingsSearch.apiKeyEntryPrefix + "general-openrouter"))
        for provider in TTSProvider.apiKeyCardProviders {
            XCTAssertTrue(ids.contains(MacSettingsSearch.apiKeyEntryPrefix + "tts-\(provider.id)"), provider.id)
        }
    }

    // MARK: - Helpers

    private func assertIndexed(
        _ published: [String], platform: SettingsSearchPlatforms, exemptions: [String: String]
    ) {
        let indexed = Set(SettingsSearchCatalog.entries(for: platform).flatMap(\.settingKeys))
        let missing = published.filter { !indexed.contains($0) && exemptions[$0] == nil }
        XCTAssertTrue(
            missing.isEmpty,
            "Index these settings in a SettingsSearchCatalog entry's settingKeys, or exempt them: \(missing)"
        )
    }

    private func publishedProperties(in source: String) -> [String] {
        matches(of: #"@Published\s+(?:private\(set\)\s+)?var\s+(\w+)"#, in: source)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftFiles(under relativePath: String) throws -> [(String, String)] {
        let root = repositoryRoot.appendingPathComponent(relativePath)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var files: [(String, String)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append((url.path, try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    private func matches(of pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }
}
