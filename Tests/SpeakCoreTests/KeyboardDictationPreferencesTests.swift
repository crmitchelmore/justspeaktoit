import XCTest

@testable import SpeakCore

final class KeyboardDictationPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: KeyboardDictationPreferencesStore!

    override func setUp() {
        super.setUp()
        suiteName = "KeyboardDictationPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = KeyboardDictationPreferencesStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultSelectionIsAutomaticWithNoQuickSwitch() {
        let selection = store.selection()

        XCTAssertEqual(selection.selectedIdentifier, TranscriptionLanguageCatalog.automaticIdentifier)
        XCTAssertNil(selection.nextQuickIdentifier)
    }

    func testMirroringAppPreferenceBuildsQuickRing() {
        store.mirrorAppPreference(selectedIdentifier: "en_GB")

        let selection = store.selection()
        XCTAssertEqual(selection.selectedIdentifier, "en_GB")
        XCTAssertEqual(
            selection.quickIdentifiers,
            ["en_GB", TranscriptionLanguageCatalog.automaticIdentifier]
        )
        XCTAssertEqual(selection.nextQuickIdentifier, TranscriptionLanguageCatalog.automaticIdentifier)
    }

    func testMirroringKeepsKeyboardChosenLanguages() {
        store.mirrorAppPreference(selectedIdentifier: "en_GB")
        store.select("fr_FR")
        store.mirrorAppPreference(selectedIdentifier: "de_DE")

        let selection = store.selection()
        XCTAssertEqual(selection.selectedIdentifier, "de_DE")
        XCTAssertTrue(selection.quickIdentifiers.contains("fr_FR"))
        XCTAssertTrue(selection.quickIdentifiers.contains("en_GB"))
    }

    func testQuickRingCyclesThroughAllLanguages() {
        store.mirrorAppPreference(selectedIdentifier: "en_GB")
        store.select("fr_FR")

        var selection = store.selection()
        XCTAssertEqual(selection.selectedIdentifier, "fr_FR")

        var visited: [String] = [selection.selectedIdentifier]
        for _ in 0..<(selection.quickIdentifiers.count - 1) {
            guard let next = selection.nextQuickIdentifier else {
                return XCTFail("Expected a next quick language")
            }
            selection = store.select(next)
            visited.append(selection.selectedIdentifier)
        }

        XCTAssertEqual(Set(visited), Set(selection.quickIdentifiers))
        XCTAssertEqual(selection.nextQuickIdentifier, visited.first)
    }

    func testQuickRingIsCappedAndDeduplicated() {
        for identifier in ["en_GB", "fr_FR", "de_DE", "es_ES", "ja_JP", "en_GB"] {
            store.mirrorAppPreference(selectedIdentifier: identifier)
        }

        let selection = store.selection()
        XCTAssertEqual(selection.selectedIdentifier, "en_GB")
        XCTAssertEqual(selection.quickIdentifiers.count, KeyboardLanguageSelection.maxQuickOptions)
        XCTAssertEqual(Set(selection.quickIdentifiers).count, selection.quickIdentifiers.count)
    }

    func testBlankIdentifierNormalisesToAutomatic() {
        store.mirrorAppPreference(selectedIdentifier: "  ")

        XCTAssertEqual(
            store.selection().selectedIdentifier,
            TranscriptionLanguageCatalog.automaticIdentifier
        )
    }

    func testMissingAppGroupIsSafe() {
        let unavailable = KeyboardDictationPreferencesStore(defaults: nil)

        XCTAssertEqual(unavailable.selection(), .automaticOnly)
        XCTAssertEqual(unavailable.mirrorAppPreference(selectedIdentifier: "en_GB").selectedIdentifier, "en_GB")
        XCTAssertEqual(unavailable.selection(), .automaticOnly)
    }

    // MARK: - Dictation profile

    func testDefaultProfileIsVerbatim() {
        let selection = store.profileSelection()

        XCTAssertEqual(selection.selectedIdentifier, KeyboardDictationProfileCatalog.verbatimIdentifier)
        XCTAssertFalse(selection.polishes)
        XCTAssertNotNil(selection.nextQuickIdentifier)
    }

    func testMirroringPostProcessingOnSelectsTheCleanupProfile() {
        store.mirrorAppProfilePreference(polishesTranscripts: true)

        XCTAssertEqual(
            store.profileSelection().selectedIdentifier,
            KeyboardDictationProfileCatalog.cleanupIdentifier
        )
    }

    /// The app decides *whether* the keyboard polishes; the chip decides *how*.
    func testMirroringKeepsAKeyboardChosenPolishingProfile() {
        store.mirrorAppProfilePreference(polishesTranscripts: true)
        store.selectProfile(KeyboardDictationProfileCatalog.messageIdentifier)

        store.mirrorAppProfilePreference(polishesTranscripts: true)

        XCTAssertEqual(
            store.profileSelection().selectedIdentifier,
            KeyboardDictationProfileCatalog.messageIdentifier
        )
    }

    func testMirroringPostProcessingOffReturnsToVerbatim() {
        store.selectProfile(KeyboardDictationProfileCatalog.messageIdentifier)

        store.mirrorAppProfilePreference(polishesTranscripts: false)

        XCTAssertEqual(store.profileSelection(), .verbatim)
    }

    func testProfileRingCyclesThroughEveryProfileAndWrapsAround() {
        var selection = store.profileSelection()
        var visited: [String] = [selection.selectedIdentifier]

        for _ in 0..<(selection.quickIdentifiers.count - 1) {
            guard let next = selection.nextQuickIdentifier else {
                return XCTFail("Expected a next quick profile")
            }
            selection = store.selectProfile(next)
            visited.append(selection.selectedIdentifier)
        }

        XCTAssertEqual(visited, selection.quickIdentifiers)
        XCTAssertEqual(selection.nextQuickIdentifier, visited.first)
    }

    func testProfileSelectionSurvivesAStoreRestart() {
        store.selectProfile(KeyboardDictationProfileCatalog.messageIdentifier)

        let restarted = KeyboardDictationPreferencesStore(defaults: defaults)

        XCTAssertEqual(
            restarted.profileSelection().selectedIdentifier,
            KeyboardDictationProfileCatalog.messageIdentifier
        )
    }

    func testProfileFromAFutureSchemaVersionIsIgnored() {
        let future = KeyboardProfileSelection(
            schemaVersion: KeyboardProfileSelection.schemaVersion + 1,
            selectedIdentifier: KeyboardDictationProfileCatalog.messageIdentifier
        )
        defaults.set(try? JSONEncoder().encode(future), forKey: "keyboardDictation.profile.v1")

        XCTAssertEqual(store.profileSelection(), .verbatim)
    }

    func testProfileSelectionIsIndependentOfTheLanguageSelection() {
        store.mirrorAppPreference(selectedIdentifier: "fr_FR")
        store.selectProfile(KeyboardDictationProfileCatalog.cleanupIdentifier)

        XCTAssertEqual(store.selection().selectedIdentifier, "fr_FR")
        XCTAssertEqual(
            store.profileSelection().selectedIdentifier,
            KeyboardDictationProfileCatalog.cleanupIdentifier
        )
    }

    func testMissingAppGroupIsSafeForProfiles() {
        let unavailable = KeyboardDictationPreferencesStore(defaults: nil)

        XCTAssertEqual(unavailable.profileSelection(), .verbatim)
        XCTAssertTrue(unavailable.mirrorAppProfilePreference(polishesTranscripts: true).polishes)
        XCTAssertEqual(unavailable.profileSelection(), .verbatim)
    }

    func testChipLabels() {
        XCTAssertEqual(
            KeyboardLanguageSelection.chipLabel(for: TranscriptionLanguageCatalog.automaticIdentifier),
            "Auto"
        )
        XCTAssertEqual(KeyboardLanguageSelection.chipLabel(for: "en_GB"), "EN-GB")
        XCTAssertEqual(KeyboardLanguageSelection.chipLabel(for: ""), "Auto")
    }
}
