import Foundation
import SpeakCore
import XCTest

/// Windows and Linux settings search: ranking over the shared catalogue plus
/// coverage guards that fail when a new desktop setting or heading isn't indexed.
/// See Docs/settings-search.md.
final class DesktopSettingsSearchTests: XCTestCase {
    /// Linux headings that are containers for indexed fields, not destinations.
    private static let unindexedLinuxHeadings: Set<String> = [
        "Dictation preferences", "Account Voice provider key"
    ]

    func testEveryConfigurationFieldIsSearchableAndOpensItsField() {
        let session = DesktopSettingsSearchSession(platform: .linux)
        for (index, field) in DesktopConfiguration.fields.enumerated() {
            let target = DesktopSettingsSearch.target(
                for: DesktopSettingsSearch.entries(for: .linux).first {
                    $0.id == DesktopSettingsSearch.fieldEntryPrefix + field.key
                }!
            )
            XCTAssertEqual(target.fieldIndex, index, field.key)
            XCTAssertEqual(target.destination, DesktopSettingsSearch.destination(forFieldGroup: field.group))
        }
        XCTAssertFalse(session.results(for: "silence").isEmpty)
    }

    func testEveryPortablePreferenceIsIndexedOnDesktop() {
        let indexed = Set(DesktopSettingsSearch.entries(for: .linux).flatMap(\.settingKeys))
            .union(DesktopSettingsSearch.entries(for: .windows).flatMap(\.settingKeys))
        let missing = ApplicationPreferenceKey.allCases.map(\.rawValue)
            .filter { !indexed.contains($0) && Self.unindexedPreferences[$0] == nil }
        XCTAssertTrue(
            missing.isEmpty,
            "Index these preferences in DesktopConfiguration.fields or a desktop catalogue entry: \(missing)"
        )
    }

    func testEveryLinuxSettingsHeadingIsIndexed() throws {
        let directory = repositoryRoot.appendingPathComponent("Sources/CLinuxSupport")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "c" }
        var missing: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let headings = matches(of: #"\bgroup\("([^"]+)"\)"#, in: source)
                + matches(of: #"adw_preferences_group_set_title\([^,]+,\s*"([^"]+)"\)"#, in: source)
            for heading in headings where !Self.unindexedLinuxHeadings.contains(heading)
                && SettingsSearchCatalog.entry(title: heading, platform: .linux) == nil {
                missing.append("\(file.lastPathComponent): \(heading)")
            }
        }
        XCTAssertTrue(missing.isEmpty, "Add .linux SettingsSearchCatalog entries for: \(missing)")
    }

    /// Windows headings that need no entry of their own, and why.
    private static let unindexedWindowsHeadings: [String: String] = [
        "About": "The About page root is indexed.",
        "iCloud": "The iCloud Sync page's card; desktop.cloudSync (\"iCloud sync\") indexes it.",
        "Dictation preferences": "Container dialog; every DesktopConfiguration field is indexed.",
        "App profiles": "Dialog opened by Per-app profiles, which is indexed.",
        "Post-processing": "Dialog opened by Clean-up; the Post-processing page root is indexed.",
        "Voice output": "Dialog opened by Read aloud; the Voice Output page root is indexed.",
        "Corrections": "Editor opened by Personal corrections, which is indexed.",
        "Pronunciation": "Editor opened by Pronunciation dictionary, which is indexed.",
        "Recording corrections": "Per-recording editor opened from History, not a setting.",
        "Legacy word dictionary": "Sub-editor of the Pronunciation dictionary, which is indexed.",
        "Stored correction candidates": "Sub-editor of Personal corrections, which is indexed."
    ]

    /// Every Windows settings card (`layoutSettingsCard`), group box and dialog caption
    /// ("<Title> — Just Speak to It") must have a `.windows` catalogue entry.
    func testEveryWindowsSettingsHeadingIsIndexed() throws {
        let directory = repositoryRoot.appendingPathComponent("Sources/CWindowsSupport")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "cpp" }
        var missing: [String] = []
        var cards = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let cardTitles = matches(
                of: #"layoutSettingsCard\(\s*window,[^,]+,[^,]+,\s*0x[0-9A-Fa-f]+,\s*((?:[^,"]|"[^"]*")+),"#, in: source
            ).flatMap { matches(of: #"L"([^"]+)""#, in: $0) }
            cards += cardTitles.count
            let headings = cardTitles
                + matches(of: #"L"([^"]+)",\s*BS_GROUPBOX"#, in: source)
                + matches(of: #"L"([^"]+) (?:—|-) Just Speak to It""#, in: source)
            for heading in headings where Self.unindexedWindowsHeadings[heading] == nil
                && SettingsSearchCatalog.entry(title: heading, platform: .windows) == nil {
                missing.append("\(file.lastPathComponent): \(heading)")
            }
        }
        XCTAssertGreaterThan(cards, 10, "The Windows card scan no longer finds layoutSettingsCard titles.")
        XCTAssertTrue(missing.isEmpty, "Add .windows SettingsSearchCatalog entries for: \(missing)")
    }

    func testWindowsSessionOpensCardsOnTheirPages() throws {
        let session = DesktopSettingsSearchSession(platform: .windows)
        let rows = session.results(for: "pronunciation dictionary")
        XCTAssertEqual(rows.first?.title, "Pronunciation dictionary")
        XCTAssertEqual(try XCTUnwrap(session.choose(0)).destination, .pronunciation)
        let azure = try XCTUnwrap(DesktopSettingsSearch.entries(for: .windows).first { $0.id == "apiKeys.azure" })
        XCTAssertEqual(DesktopSettingsSearch.target(for: azure).destination, .transcription)
        XCTAssertNil(DesktopSettingsSearch.entries(for: .linux).first { $0.id.hasPrefix("windows.") })
    }

    func testSessionRanksResultsAndRecordsRecents() throws {
        let session = DesktopSettingsSearchSession(platform: .linux)
        XCTAssertTrue(session.results(for: "").isEmpty)
        let rows = session.results(for: "microphone")
        XCTAssertEqual(rows.first?.title, "Microphone")
        XCTAssertEqual(rows.first?.identifier, "settingsSearchResult.general.microphone")
        XCTAssertEqual(try XCTUnwrap(session.choose(0)).destination, .general)
        XCTAssertEqual(session.results(for: "").first?.title, "Microphone")
        XCTAssertNil(session.choose(99))
    }

    func testDesktopPagesHaveRootsAndTargets() {
        let roots = DesktopSettingsSearch.entries(for: .windows).filter(\.isSectionRoot)
        XCTAssertFalse(roots.isEmpty)
        XCTAssertEqual(
            DesktopSettingsSearch.target(for: roots.first { $0.section == .shortcuts }!).destination, .keyboard
        )
        let cloud = DesktopSettingsSearch.entries(for: .linux).first { $0.id == "desktop.cloudSync" }
        XCTAssertEqual(cloud.map { DesktopSettingsSearch.target(for: $0).destination }, .cloudSync)
    }

    /// Persisted preferences with no desktop control, and why.
    private static let unindexedPreferences: [String: String] = {
        let appleOnly = "Apple-only; no Windows or Linux control."
        let state = "Internal state, not a user setting."
        return [
            "localTranscriptionMode": appleOnly, "localStreamingModelSource": appleOnly,
            "rememberedLocalTranscriptionSource": state, "rememberedRemoteTranscriptionMode": state,
            "showStatusBarIconInDockOnly": appleOnly, "trackedKeyIdentifiers": state,
            "deepgramStopGracePeriod": "Legacy key migrated to liveStopGracePeriod.",
            "mistralTTSModel": appleOnly, "ttsSpeed": appleOnly, "ttsPitch": appleOnly, "ttsAutoPlay": appleOnly,
            "ttsSaveToDirectory": appleOnly, "ttsUseSSML": appleOnly, "livePolishTailWindowChars": state,
            "enableSendToMac": appleOnly, "paidAccessRoutingEnabled": appleOnly, "simpleModelChoices": appleOnly,
            "ttsPronunciationDictionary": "Edited on the Pronunciation page, whose page root is indexed.",
            "assemblyAIIgnoredPronunciationTerms": "Edited on the Pronunciation page, whose page root is indexed."
        ]
    }()

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func matches(of pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }
}
