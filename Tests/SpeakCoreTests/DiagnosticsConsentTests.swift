import XCTest

@testable import SpeakCore

final class DiagnosticsConsentTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "DiagnosticsConsentTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDecision_isUndecidedAndCollectsNothingUntilAsked() {
        let consent = DiagnosticsConsent(defaults: defaults)

        XCTAssertEqual(consent.decision, .undecided)
        XCTAssertTrue(consent.needsDecision)
        XCTAssertFalse(consent.permitsCollection)
    }

    func testRecord_grantThenWithdraw_persistsEachAnswer() {
        let consent = DiagnosticsConsent(defaults: defaults, notificationCenter: NotificationCenter())

        consent.record(granted: true)
        XCTAssertTrue(DiagnosticsConsent(defaults: defaults).permitsCollection)

        consent.record(granted: false)
        let reloaded = DiagnosticsConsent(defaults: defaults)
        XCTAssertEqual(reloaded.decision, .declined)
        XCTAssertFalse(reloaded.permitsCollection)
        XCTAssertFalse(reloaded.needsDecision)
    }

    func testRecord_postsAChangeSoTheReporterCanStopAtOnce() {
        let center = NotificationCenter()
        let consent = DiagnosticsConsent(defaults: defaults, notificationCenter: center)
        let posted = expectation(forNotification: DiagnosticsConsent.didChangeNotification, object: consent,
                                 notificationCenter: center)

        consent.record(granted: false)

        wait(for: [posted], timeout: 1)
    }

    func testDecision_unknownStoredValueIsTreatedAsUndecided() {
        defaults.set("maybe", forKey: DiagnosticsConsent.defaultsKey)

        XCTAssertFalse(DiagnosticsConsent(defaults: defaults).permitsCollection)
        XCTAssertTrue(DiagnosticsConsent(defaults: defaults).needsDecision)
    }
}
