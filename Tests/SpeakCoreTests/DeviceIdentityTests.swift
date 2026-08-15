import XCTest
@testable import SpeakCore

final class DeviceIdentityTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: InMemoryDeviceIdentityStore!

    override func setUp() {
        super.setUp()
        suiteName = "DeviceIdentityTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = InMemoryDeviceIdentityStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        store = nil
        super.tearDown()
    }

    private func resolve(makeDeviceId: @escaping () -> String = { "generated-id" }) -> String {
        DeviceIdentity.mobileDeviceId(store: store, defaults: defaults, makeDeviceId: makeDeviceId)
    }

    // MARK: - Fresh install

    func testFreshInstallGeneratesAndPersistsToKeychainAndDefaults() {
        let id = resolve()

        XCTAssertEqual(id, "generated-id")
        XCTAssertEqual(store.loadDeviceId(), "generated-id")
        XCTAssertEqual(defaults.string(forKey: DeviceIdentity.deviceIdDefaultsKey), "generated-id")
    }

    func testRepeatedResolutionIsStableAndGeneratesOnlyOnce() {
        var generatorCalls = 0
        let makeDeviceId: () -> String = {
            generatorCalls += 1
            return "generated-\(generatorCalls)"
        }

        let first = resolve(makeDeviceId: makeDeviceId)
        let second = resolve(makeDeviceId: makeDeviceId)

        XCTAssertEqual(first, "generated-1")
        XCTAssertEqual(second, first)
        XCTAssertEqual(generatorCalls, 1)
    }

    // MARK: - Migration from UserDefaults

    func testExistingDefaultsValueIsMigratedIntoKeychain() {
        defaults.set("legacy-id", forKey: DeviceIdentity.deviceIdDefaultsKey)

        let id = resolve()

        XCTAssertEqual(id, "legacy-id", "Upgrading an existing install must keep its paired device ID")
        XCTAssertEqual(store.loadDeviceId(), "legacy-id")
    }

    // MARK: - Reinstall

    func testKeychainValueSurvivesClearedDefaults() {
        store.storeDeviceId("keychain-id")
        // Reinstall wipes UserDefaults; the Keychain item remains.

        let id = resolve(makeDeviceId: {
            XCTFail("A retained Keychain identity must not be regenerated")
            return "unexpected"
        })

        XCTAssertEqual(id, "keychain-id")
    }

    func testKeychainWinsOverStaleDefaultsValue() {
        store.storeDeviceId("keychain-id")
        defaults.set("stale-defaults-id", forKey: DeviceIdentity.deviceIdDefaultsKey)

        XCTAssertEqual(resolve(), "keychain-id")
    }

    // MARK: - Keychain loss

    func testLosingBothStoresMintsANewIdentity() {
        // Explicit reset: with no surviving identity the device presents a new
        // ID, so the Mac treats it as unpaired and the normal pairing flow
        // re-establishes trust.
        let id = resolve()

        XCTAssertEqual(id, "generated-id")
        XCTAssertEqual(store.loadDeviceId(), "generated-id")
    }

    func testDefaultsMirrorKeepsIdentityStableWhenKeychainWritesFail() {
        store.failsWrites = true

        let first = resolve(makeDeviceId: { "generated-1" })
        let second = resolve(makeDeviceId: { "generated-2" })

        XCTAssertEqual(first, "generated-1")
        XCTAssertEqual(second, first, "The UserDefaults mirror is the fallback when the Keychain is unwritable")
    }
}

/// In-memory `DeviceIdentityStoring` seam for tests.
private final class InMemoryDeviceIdentityStore: DeviceIdentityStoring, @unchecked Sendable {
    var failsWrites = false
    private var storedId: String?

    func loadDeviceId() -> String? {
        storedId
    }

    func storeDeviceId(_ id: String) {
        guard !failsWrites else { return }
        storedId = id
    }
}
