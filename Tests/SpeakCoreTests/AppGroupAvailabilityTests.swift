import XCTest

@testable import SpeakCore

final class AppGroupAvailabilityTests: XCTestCase {
    private var suiteName: String!
    private var suiteDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppGroupAvailabilityTests.\(UUID().uuidString)"
        suiteDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suiteDefaults.removePersistentDomain(forName: suiteName)
        suiteDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// A mis-signed product can construct a suite `UserDefaults` while the
    /// container probe fails; availability must follow the container.
    func testReportsUnavailableWithoutContainerEvenWhenSuiteDefaultsExist() {
        let defaults = AppGroupAvailability.verifiedDefaults(
            groupIdentifier: suiteName,
            containerURL: { _ in nil },
            makeDefaults: { _ in self.suiteDefaults }
        )

        XCTAssertNil(defaults)
    }

    func testReturnsSuiteDefaultsWhenContainerExists() {
        var probedIdentifier: String?

        let defaults = AppGroupAvailability.verifiedDefaults(
            groupIdentifier: suiteName,
            containerURL: { identifier in
                probedIdentifier = identifier
                return FileManager.default.temporaryDirectory
            },
            makeDefaults: { _ in self.suiteDefaults }
        )

        XCTAssertEqual(probedIdentifier, suiteName)
        XCTAssertTrue(defaults === suiteDefaults)
    }

    func testReportsUnavailableWhenSuiteCannotBeCreated() {
        let defaults = AppGroupAvailability.verifiedDefaults(
            groupIdentifier: suiteName,
            containerURL: { _ in FileManager.default.temporaryDirectory },
            makeDefaults: { _ in nil }
        )

        XCTAssertNil(defaults)
    }

    func testProbesTheSharedAppGroupIdentifierByDefault() {
        var probedIdentifier: String?

        _ = AppGroupAvailability.verifiedDefaults(
            containerURL: { identifier in
                probedIdentifier = identifier
                return nil
            },
            makeDefaults: { _ in self.suiteDefaults }
        )

        XCTAssertEqual(probedIdentifier, KeyboardHandoffStore.appGroupIdentifier)
    }

    /// The one consistent failure behaviour: every App Group store built
    /// without verified defaults reports itself unavailable.
    func testStoresBuiltWithoutVerifiedDefaultsReportUnavailable() {
        XCTAssertFalse(KeyboardHandoffStore(defaults: nil).isAvailable)
        XCTAssertFalse(KeyboardInstantDictationStore(defaults: nil).isAvailable)
        XCTAssertFalse(KeyboardDictationPreferencesStore(defaults: nil).isAvailable)
    }
}
