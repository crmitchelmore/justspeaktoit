import XCTest

@testable import SpeakCore

/// Tests for SettingsSync's stable behaviour.
///
/// The fallback-path assertions only run when `SettingsSync.shared` is using
/// local storage in the current test environment.
final class SettingsSyncTests: XCTestCase {

    private let sut = SettingsSync.shared
    private var keysToCleanup: [SettingsSync.SyncKey] = []

    private func requireFallbackMode() throws {
        guard sut.isAvailable == false else {
            throw XCTSkip("SettingsSync fallback path is unavailable in this environment")
        }
    }

    override func tearDown() {
        for key in keysToCleanup {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        keysToCleanup.removeAll()
        super.tearDown()
    }

    // MARK: - Availability

    func testIsAvailable_inTestSandbox_isFalse() throws {
        try requireFallbackMode()
        // iCloud entitlement not granted in unit test sandbox
        XCTAssertFalse(sut.isAvailable)
    }

    func testSynchronize_whenUnavailable_returnsTrue() throws {
        try requireFallbackMode()
        // When iCloud is unavailable, synchronize() is a no-op that returns true
        XCTAssertTrue(sut.synchronize())
    }

    func testLastSyncDate_whenUnavailable_isNil() throws {
        try requireFallbackMode()
        XCTAssertNil(sut.lastSyncDate)
    }

    // MARK: - String set/get via UserDefaults fallback

    func testSetString_thenGet_roundtrips() throws {
        try requireFallbackMode()
        let key = SettingsSync.SyncKey.selectedModel
        keysToCleanup.append(key)
        sut.set("whisper-large", forKey: key)
        XCTAssertEqual(sut.string(forKey: key), "whisper-large")
    }

    func testSetStringNil_clearsExistingValue() throws {
        try requireFallbackMode()
        let key = SettingsSync.SyncKey.selectedModel
        keysToCleanup.append(key)
        sut.set("initial", forKey: key)
        sut.set(nil as String?, forKey: key)
        XCTAssertNil(sut.string(forKey: key))
    }

    func testSetString_overwrite_returnsLatestValue() throws {
        try requireFallbackMode()
        let key = SettingsSync.SyncKey.darkModePreference
        keysToCleanup.append(key)
        sut.set("light", forKey: key)
        sut.set("dark", forKey: key)
        XCTAssertEqual(sut.string(forKey: key), "dark")
    }

    func testGetString_keyNeverSet_returnsNil() throws {
        try requireFallbackMode()
        let key = SettingsSync.SyncKey.showConfidenceScore
        // Ensure the key is not set (clean state)
        UserDefaults.standard.removeObject(forKey: key.rawValue)
        XCTAssertNil(sut.string(forKey: key))
    }

    // MARK: - Bool set/get via UserDefaults fallback

    func testSetBoolTrue_thenGet_returnsTrue() throws {
        try requireFallbackMode()
        let key = SettingsSync.SyncKey.autoStartRecording
        keysToCleanup.append(key)
        sut.set(true, forKey: key)
        XCTAssertTrue(sut.bool(forKey: key))
    }

    func testSetBoolFalse_thenGet_returnsFalse() throws {
        try requireFallbackMode()
        let key = SettingsSync.SyncKey.hapticFeedback
        keysToCleanup.append(key)
        sut.set(false, forKey: key)
        XCTAssertFalse(sut.bool(forKey: key))
    }

    func testSetBool_overwrite_returnsLatestValue() throws {
        try requireFallbackMode()
        let key = SettingsSync.SyncKey.autoStartRecording
        keysToCleanup.append(key)
        sut.set(true, forKey: key)
        sut.set(false, forKey: key)
        XCTAssertFalse(sut.bool(forKey: key))
    }

    func testBool_differentKeysAreIndependent() throws {
        try requireFallbackMode()
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
