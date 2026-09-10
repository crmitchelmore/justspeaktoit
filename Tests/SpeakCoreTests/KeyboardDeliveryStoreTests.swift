import Foundation
import XCTest
@testable import SpeakCore

/// The App Group store behind keyboard delivery. Each key has exactly one
/// writing process, so the two roles are modelled as two store instances over
/// the same suite — as `KeyboardHandoffCrossProcessTests` does for the hand-off.
final class KeyboardDeliveryStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var app: KeyboardDeliveryStore!
    private var keyboard: KeyboardDeliveryStore!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let documentA = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "KeyboardDeliveryStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        app = KeyboardDeliveryStore(defaults: defaults)
        keyboard = KeyboardDeliveryStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    func testTarget_isVisibleToTheAppUntilItLapses() throws {
        keyboard.publishTarget(documentIdentifier: documentA, now: now)
        XCTAssertEqual(app.openTarget(now: now)?.documentIdentifier, documentA)
        XCTAssertNotNil(
            app.openTarget(now: now.addingTimeInterval(KeyboardTargetRecord.lifetime - 0.5))
        )
        // No dismissal callback needed: the advertisement expires on its own,
        // which is the only guarantee available when the extension is killed.
        XCTAssertNil(
            app.openTarget(now: now.addingTimeInterval(KeyboardTargetRecord.lifetime + 0.5))
        )
    }

    func testTargetRefresh_isThrottledButAlwaysFollowsADocumentChange() throws {
        let first = try XCTUnwrap(keyboard.publishTarget(documentIdentifier: documentA, now: now))
        let throttled = try XCTUnwrap(
            keyboard.publishTarget(documentIdentifier: documentA, now: now.addingTimeInterval(0.5))
        )
        XCTAssertEqual(first.expiresAt, throttled.expiresAt)

        let refreshed = try XCTUnwrap(
            keyboard.publishTarget(
                documentIdentifier: documentA,
                now: now.addingTimeInterval(KeyboardTargetRecord.refreshInterval + 0.1)
            )
        )
        XCTAssertGreaterThan(refreshed.expiresAt, first.expiresAt)

        let moved = try XCTUnwrap(
            keyboard.publishTarget(documentIdentifier: UUID(), now: now.addingTimeInterval(0.6))
        )
        XCTAssertNotEqual(moved.documentIdentifier, documentA)
    }

    func testSecureTarget_isStoredButNeverCountsAsOpen() {
        keyboard.publishTarget(documentIdentifier: documentA, isSecureField: true, now: now)
        XCTAssertNil(app.openTarget(now: now))
    }

    func testClearTarget_withdrawsTheAdvertisementImmediately() {
        keyboard.publishTarget(documentIdentifier: documentA, now: now)
        keyboard.clearTarget()
        XCTAssertNil(app.openTarget(now: now))
    }

    func testOffer_agesOutAndItsClaimSurvivesUntilTheNextOfferReplacesIt() throws {
        let offer = try XCTUnwrap(app.publishOffer(sampleOffer()))
        XCTAssertEqual(keyboard.pendingOffer(now: now)?.offerID, offer.offerID)
        XCTAssertNil(
            keyboard.pendingOffer(now: now.addingTimeInterval(KeyboardPickupOffer.latePickupLifetime + 1))
        )

        keyboard.claimOffer(offer.offerID, now: now)
        XCTAssertEqual(app.claim()?.offerID, offer.offerID)

        // A fresh offer clears the stale claim, so the keyboard can take it.
        let next = try XCTUnwrap(app.publishOffer(sampleOffer()))
        XCTAssertNil(keyboard.claim())
        XCTAssertEqual(keyboard.pendingOffer(now: now)?.offerID, next.offerID)
    }

    func testPreferences_defaultToHandBackOnAndAutoInsertOff() {
        XCTAssertTrue(keyboard.preferences().handsBackAfterInsert)
        XCTAssertFalse(keyboard.preferences().autoInsertsMatchingPickup)

        app.publishPreferences(
            KeyboardDeliveryPreferences(handsBackAfterInsert: false, autoInsertsMatchingPickup: true)
        )
        XCTAssertFalse(keyboard.preferences().handsBackAfterInsert)
        XCTAssertTrue(keyboard.preferences().autoInsertsMatchingPickup)
    }

    /// Without Full Access the App Group is inaccessible. Every write must be a
    /// visible no-op rather than a silent partial success: no target is
    /// advertised, so hardware triggers keep their existing behaviour, and no
    /// offer is ever readable, so no chip appears.
    func testWithoutTheSharedContainer_everythingDegradesToNothingHappening() {
        let unavailable = KeyboardDeliveryStore(defaults: nil)
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertNil(unavailable.publishTarget(documentIdentifier: documentA, now: now))
        XCTAssertNil(unavailable.openTarget(now: now))
        XCTAssertNil(unavailable.publishOffer(sampleOffer()))
        XCTAssertNil(unavailable.pendingOffer(now: now))
        XCTAssertNil(unavailable.claimOffer(UUID(), now: now))
        XCTAssertNil(unavailable.claim())
        XCTAssertEqual(unavailable.preferences(), .default)
        unavailable.clearTarget()
        unavailable.clearOffer()
    }

    func testAFutureSchema_fallsBackToTheSafeDefaultInsteadOfGuessing() throws {
        let future = KeyboardDeliveryPreferences(
            schemaVersion: KeyboardDeliveryPreferences.schemaVersion + 1,
            handsBackAfterInsert: false,
            autoInsertsMatchingPickup: true
        )
        defaults.set(try JSONEncoder().encode(future), forKey: "keyboardDelivery.preferences.v1")
        XCTAssertEqual(keyboard.preferences(), .default)
    }

    private func sampleOffer() -> KeyboardPickupOffer {
        KeyboardPickupOffer(
            text: "captured in the pocket",
            source: .watch,
            mode: .latePickup,
            createdAt: now,
            expiresAt: now.addingTimeInterval(KeyboardPickupOffer.latePickupLifetime)
        )
    }
}
