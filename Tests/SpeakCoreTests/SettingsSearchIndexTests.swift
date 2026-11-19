import XCTest

@testable import SpeakCore

final class SettingsSearchIndexTests: XCTestCase {
    private let macIndex = SettingsSearchIndex(entries: SettingsSearchCatalog.entries(for: .macOS))
    private let iOSIndex = SettingsSearchIndex(entries: SettingsSearchCatalog.entries(for: .iOS))

    func testSearch_exactTitleRanksFirst() {
        XCTAssertEqual(macIndex.search("Microphone").first?.entry.id, "general.microphone")
        XCTAssertEqual(macIndex.search("silence detection").first?.entry.id, "transcription.silenceDetection")
    }

    func testSearch_prefixTypeaheadMatchesTitle() {
        XCTAssertEqual(macIndex.search("micro").first?.entry.id, "general.microphone")
        XCTAssertEqual(macIndex.search("trig").first?.entry.id, "shortcuts.triggerKey")
    }

    func testSearch_keywordAndSynonymFindsSettingByIntent() {
        let escape = macIndex.search("discard recording")
        XCTAssertEqual(escape.first?.entry.id, "shortcuts.activation")
        XCTAssertNotNil(escape.first?.matchedKeyword)
        XCTAssertTrue(macIndex.search("hotkey").contains { $0.entry.id == "shortcuts.triggerKey" })
        XCTAssertEqual(macIndex.search("dark mode").first?.entry.id, "general.appearance")
        XCTAssertTrue(macIndex.search("mic").contains { $0.entry.id == "general.microphone" })
    }

    func testSearch_inflectionsAndStopWordsStillMatch() {
        let results = macIndex.search("cancelled with escape")
        XCTAssertEqual(results.first?.entry.id, "shortcuts.activation")
    }

    func testSearch_keepAudioOnCancelIsFoundByIntent() {
        for query in ["keep audio", "discard", "delete recording", "keep audio when cancelled"] {
            XCTAssertEqual(macIndex.search(query).first?.entry.id, "shortcuts.activation", query)
            XCTAssertEqual(iOSIndex.search(query).first?.entry.id, "ios.recordings", query)
        }
    }

    func testSearch_toleratesTypos() {
        XCTAssertEqual(macIndex.search("microphnoe").first?.entry.id, "general.microphone")
        XCTAssertEqual(macIndex.search("apperance").first?.entry.id, "general.appearance")
    }

    func testSearch_requiresEveryWordAndReturnsNothingForNonsense() {
        XCTAssertTrue(macIndex.search("zzqxv").isEmpty)
        XCTAssertTrue(macIndex.search("   ").isEmpty)
        XCTAssertFalse(macIndex.search("microphone zzqxv").contains { $0.entry.id == "general.microphone" })
    }

    func testSearch_findsSettingByPersistedName() {
        XCTAssertTrue(macIndex.search("runAtLogin").contains { $0.entry.id == "general.appBehaviour" })
    }

    func testSearch_respectsPlatformProjection() {
        XCTAssertTrue(iOSIndex.search("action button").contains { $0.entry.id == "ios.hardwareTrigger" })
        XCTAssertFalse(macIndex.search("action button").contains { $0.entry.id == "ios.hardwareTrigger" })
        XCTAssertEqual(iOSIndex.search("Appearance").first?.entry.id, "general.appearance")
    }

    func testCompletions_extendTypedText() {
        let completions = macIndex.completions(for: "laun")
        XCTAssertTrue(completions.contains("launch at login"), "\(completions)")
        XCTAssertTrue(macIndex.completions(for: "").isEmpty)
        XCTAssertLessThanOrEqual(macIndex.completions(for: "s", limit: 3).count, 3)
    }

    func testRecents_dedupeAndCap() {
        var recents: [String] = []
        for id in ["a1", "b2", "a1", "c3"] { recents = SettingsSearchRecents.recording(id, in: recents, limit: 2) }
        XCTAssertEqual(recents, ["c3", "a1"])
        XCTAssertEqual(SettingsSearchRecents.decode(SettingsSearchRecents.encode(recents)), recents)
        XCTAssertEqual(SettingsSearchRecents.decode(""), [])
    }

    func testEditDistance() {
        XCTAssertTrue(SettingsSearchIndex.isWithin(1, "colour", "color"))
        XCTAssertFalse(SettingsSearchIndex.isWithin(1, "colour", "clr"))
        XCTAssertTrue(SettingsSearchIndex.isWithin(2, "microphnoe", "microphone"))
    }
}

/// Catalogue invariants every host relies on.
final class SettingsSearchCatalogTests: XCTestCase {
    func testIdentifiersAreUniqueAndStable() {
        let ids = SettingsSearchCatalog.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate settings search ids")
        for id in ids {
            XCTAssertNil(id.rangeOfCharacter(from: .whitespacesAndNewlines), "\(id) must not contain whitespace")
        }
    }

    func testTitlesAreUniquePerPlatform() {
        for platform in [SettingsSearchPlatforms.macOS, .iOS, .windows, .linux] {
            let titles = SettingsSearchCatalog.entries(for: platform).filter { !$0.isSectionRoot }.map(\.title)
            XCTAssertEqual(titles.count, Set(titles).count, "Duplicate titles for \(platform): \(titles)")
        }
    }

    func testEveryEntryIsDescribedAndShownSomewhere() {
        for entry in SettingsSearchCatalog.entries {
            XCTAssertFalse(entry.title.isEmpty, entry.id)
            XCTAssertFalse(entry.summary.isEmpty, entry.id)
            XCTAssertFalse(entry.platforms.isEmpty, entry.id)
        }
    }

    func testEverySectionHasARoot() {
        let roots = Set(SettingsSearchCatalog.entries.filter(\.isSectionRoot).map(\.section))
        XCTAssertEqual(roots, Set(SettingsSearchSection.allCases))
    }

    func testSuggestedEntriesExist() {
        let ids = Set(SettingsSearchCatalog.entries.map(\.id))
        for id in SettingsSearchCatalog.suggestedEntryIDs {
            XCTAssertTrue(ids.contains(id), "Suggested entry \(id) is not in the catalogue")
        }
    }

    func testSettingKeysAreOwnedOncePerPlatform() {
        for platform in [SettingsSearchPlatforms.macOS, .iOS] {
            var owners: [String: String] = [:]
            for entry in SettingsSearchCatalog.entries(for: platform) {
                for key in entry.settingKeys {
                    XCTAssertNil(owners[key], "\(key) is indexed by both \(owners[key] ?? "") and \(entry.id)")
                    owners[key] = entry.id
                }
            }
        }
    }

    func testTitleLookupFindsCards() {
        XCTAssertEqual(SettingsSearchCatalog.entry(title: "Microphone", platform: .macOS)?.id, "general.microphone")
        XCTAssertEqual(SettingsSearchCatalog.entry(title: "Behavior", platform: .iOS)?.id, "ios.behavior")
        XCTAssertNil(SettingsSearchCatalog.entry(title: "Behavior", platform: .macOS))
    }
}
