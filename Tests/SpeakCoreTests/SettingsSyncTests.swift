import XCTest

@testable import SpeakCore

/// Tests for SettingsSync's UserDefaults fallback path.
///
/// iCloud (NSUbiquitousKeyValueStore) is not available in the test sandbox
/// (no entitlements), so `SettingsSync.shared.isAvailable` is `false` and
/// all reads/writes go through `UserDefaults.standard`. Each test cleans
/// up the keys it writes in `tearDown`.
final class SettingsSyncTests: XCTestCase {

    private let sut = SettingsSync.shared
    private var keysToCleanup: [SettingsSync.SyncKey] = []

    override func tearDown() {
        for key in keysToCleanup {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        keysToCleanup.removeAll()
        super.tearDown()
    }

    // MARK: - Availability

    func testIsAvailable_inTestSandbox_isFalse() {
        // iCloud entitlement not granted in unit test sandbox
        XCTAssertFalse(sut.isAvailable)
    }

    func testSynchronize_whenUnavailable_returnsTrue() {
        // When iCloud is unavailable, synchronize() is a no-op that returns true
        XCTAssertTrue(sut.synchronize())
    }

    func testLastSyncDate_whenUnavailable_isNil() {
        XCTAssertNil(sut.lastSyncDate)
    }

    // MARK: - String set/get via UserDefaults fallback

    func testSetString_thenGet_roundtrips() {
        let key = SettingsSync.SyncKey.selectedModel
        keysToCleanup.append(key)
        sut.set("whisper-large", forKey: key)
        XCTAssertEqual(sut.string(forKey: key), "whisper-large")
    }

    func testSetStringNil_clearsExistingValue() {
        let key = SettingsSync.SyncKey.selectedModel
        keysToCleanup.append(key)
        sut.set("initial", forKey: key)
        sut.set(nil as String?, forKey: key)
        XCTAssertNil(sut.string(forKey: key))
    }

    func testSetString_overwrite_returnsLatestValue() {
        let key = SettingsSync.SyncKey.darkModePreference
        keysToCleanup.append(key)
        sut.set("light", forKey: key)
        sut.set("dark", forKey: key)
        XCTAssertEqual(sut.string(forKey: key), "dark")
    }

    func testGetString_keyNeverSet_returnsNil() {
        let key = SettingsSync.SyncKey.showConfidenceScore
        // Ensure the key is not set (clean state)
        UserDefaults.standard.removeObject(forKey: key.rawValue)
        XCTAssertNil(sut.string(forKey: key))
    }

    // MARK: - Bool set/get via UserDefaults fallback

    func testSetBoolTrue_thenGet_returnsTrue() {
        let key = SettingsSync.SyncKey.autoStartRecording
        keysToCleanup.append(key)
        sut.set(true, forKey: key)
        XCTAssertTrue(sut.bool(forKey: key))
    }

    func testSetBoolFalse_thenGet_returnsFalse() {
        let key = SettingsSync.SyncKey.hapticFeedback
        keysToCleanup.append(key)
        sut.set(false, forKey: key)
        XCTAssertFalse(sut.bool(forKey: key))
    }

    func testSetBool_overwrite_returnsLatestValue() {
        let key = SettingsSync.SyncKey.autoStartRecording
        keysToCleanup.append(key)
        sut.set(true, forKey: key)
        sut.set(false, forKey: key)
        XCTAssertFalse(sut.bool(forKey: key))
    }

    func testBool_differentKeysAreIndependent() {
        let keyA = SettingsSync.SyncKey.autoStartRecording
        let keyB = SettingsSync.SyncKey.hapticFeedback
        keysToCleanup.append(contentsOf: [keyA, keyB])
        sut.set(true, forKey: keyA)
        sut.set(false, forKey: keyB)
        XCTAssertTrue(sut.bool(forKey: keyA))
        XCTAssertFalse(sut.bool(forKey: keyB))
    }

    // MARK: - SyncKey enum integrity

    func testSyncKey_allCases_haveNonEmptyRawValues() {
        for key in SettingsSync.SyncKey.allCases {
            XCTAssertFalse(key.rawValue.isEmpty, "\(key) should have a non-empty raw value")
        }
    }

    func testSyncKey_allCases_haveUniqueRawValues() {
        let rawValues = SettingsSync.SyncKey.allCases.map(\.rawValue)
        let unique = Set(rawValues)
        XCTAssertEqual(rawValues.count, unique.count, "All SyncKey raw values should be unique")
    }
}
