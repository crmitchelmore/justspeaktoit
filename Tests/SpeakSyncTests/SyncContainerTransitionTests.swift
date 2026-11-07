import XCTest
import SpeakCore
@testable import SpeakSync

final class SyncContainerTransitionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SyncContainerTransitionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func seedState() {
        for key in SyncContainerTransition.containerScopedKeys + ["ios.synced"] {
            defaults.set("value", forKey: key)
        }
        defaults.set(true, forKey: SyncConfiguration.dataSyncEnabledKey)
    }

    func testFamilyResolution_sharedFlagSelectsMacContainerOnBothPlatforms() {
        XCTAssertEqual(SyncConfiguration.resolveFamily(legacy: .iOS, sharedContainerEnabled: true), .macOS)
        XCTAssertEqual(SyncConfiguration.resolveFamily(legacy: .iOS, sharedContainerEnabled: false), .iOS)
        XCTAssertEqual(SyncConfiguration.resolveFamily(legacy: .macOS, sharedContainerEnabled: false), .macOS)
        let shared = SyncConfiguration.resolveFamily(legacy: .iOS, sharedContainerEnabled: true)
        for train in ReleaseTrain.allCases {
            XCTAssertEqual(shared.containerIdentifier(in: train), train.macCloudContainer)
        }
    }

    func testUnchangedLegacyContainer_keepsStateAndRecordsIt() {
        seedState()
        let reset = SyncContainerTransition.resetIfContainerChanged(
            to: "iCloud.legacy", legacy: "iCloud.legacy", defaults: defaults, additionalKeys: ["ios.synced"]
        )
        XCTAssertFalse(reset)
        for key in SyncContainerTransition.containerScopedKeys + ["ios.synced"] {
            XCTAssertNotNil(defaults.object(forKey: key), key)
        }
        XCTAssertEqual(defaults.string(forKey: SyncContainerTransition.lastContainerKey), "iCloud.legacy")
    }

    func testMoveFromLegacyContainer_clearsOnlyContainerScopedStateOnce() {
        seedState()
        XCTAssertTrue(SyncContainerTransition.resetIfContainerChanged(
            to: "iCloud.shared", legacy: "iCloud.legacy", defaults: defaults, additionalKeys: ["ios.synced"]
        ))
        for key in SyncContainerTransition.containerScopedKeys + ["ios.synced"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertTrue(defaults.bool(forKey: SyncConfiguration.dataSyncEnabledKey), "user switches survive")
        XCTAssertEqual(defaults.string(forKey: SyncContainerTransition.lastContainerKey), "iCloud.shared")

        seedState()
        XCTAssertFalse(SyncContainerTransition.resetIfContainerChanged(
            to: "iCloud.shared", legacy: "iCloud.legacy", defaults: defaults, additionalKeys: ["ios.synced"]
        ))
        XCTAssertNotNil(defaults.object(forKey: SyncConfiguration.syncTokenKey))
    }

    func testRollbackToLegacyContainer_resetsAgain() {
        defaults.set("iCloud.shared", forKey: SyncContainerTransition.lastContainerKey)
        seedState()
        XCTAssertTrue(SyncContainerTransition.resetIfContainerChanged(
            to: "iCloud.legacy", legacy: "iCloud.legacy", defaults: defaults
        ))
        XCTAssertNil(defaults.object(forKey: SyncConfiguration.syncTokenKey))
    }

    func testContainerScopedKeys_coverEveryPerDatabaseMarker() {
        XCTAssertEqual(Set(SyncContainerTransition.containerScopedKeys), [
            "speak.sync.serverChangeToken",
            "speak.sync.zoneCreated",
            "speak.sync.subscriptionCreated",
            "speak.sync.comparison.serverChangeToken",
            "speak.keysync.accountIdentifier"
        ])
    }
}
