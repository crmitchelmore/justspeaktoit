#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

/// Publishing an offer is not delivering it. These cover the one place the
/// app is allowed to conclude that a transcript reached a text field: the
/// keyboard extension's own claim on the offer (issues #1002, #1008).
@MainActor
final class KeyboardDeliveryPublisherTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: KeyboardDeliveryStore!

    private let timeout = Duration.milliseconds(300)
    private let poll = Duration.milliseconds(10)

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "KeyboardDeliveryPublisherTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = KeyboardDeliveryStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    func testNoOfferIsNotAKeyboardOutcomeAtAll() async {
        let outcome = await KeyboardDeliveryPublisher.awaitOutcome(
            for: nil,
            store: store,
            timeout: timeout,
            pollInterval: poll
        )
        XCTAssertEqual(outcome, .notOffered)
    }

    /// A late pickup is a chip the user may never tap; it is never waited on
    /// and never reported as a delivery.
    func testLatePickupIsReportedAsWaitingWithoutWaiting() async {
        let offer = self.offer(mode: .latePickup)
        store.publishOffer(offer)
        let outcome = await KeyboardDeliveryPublisher.awaitOutcome(
            for: offer,
            store: store,
            timeout: .seconds(30),
            pollInterval: poll
        )
        XCTAssertEqual(outcome, .latePickupWaiting)
    }

    func testTargetedOfferTheKeyboardClaimsIsReportedAsInserted() async {
        let offer = self.offer(mode: .targetedInsert)
        store.publishOffer(offer)
        store.claimOffer(offer.offerID)

        let outcome = await KeyboardDeliveryPublisher.awaitOutcome(
            for: offer,
            store: store,
            timeout: timeout,
            pollInterval: poll
        )
        XCTAssertEqual(outcome, .insertedInField)
    }

    /// The keyboard was closed, moved field, or suspended. The offer sits
    /// there unconsumed, so the capture must not be represented as having
    /// reached a field.
    func testTargetedOfferNobodyClaimsIsNotAFieldDelivery() async {
        let offer = self.offer(mode: .targetedInsert)
        store.publishOffer(offer)

        let outcome = await KeyboardDeliveryPublisher.awaitOutcome(
            for: offer,
            store: store,
            timeout: .milliseconds(60),
            pollInterval: .milliseconds(10)
        )
        XCTAssertEqual(outcome, .targetedButNotInserted)
    }

    /// The extension claims on its own poll cadence, so a claim that lands
    /// part-way through the wait still counts.
    func testAClaimArrivingDuringTheWaitIsObserved() async {
        let offer = self.offer(mode: .targetedInsert)
        store.publishOffer(offer)
        let store = store!
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            store.claimOffer(offer.offerID)
        }

        let outcome = await KeyboardDeliveryPublisher.awaitOutcome(
            for: offer,
            store: store,
            timeout: .seconds(2),
            pollInterval: .milliseconds(10)
        )
        XCTAssertEqual(outcome, .insertedInField)
    }

    /// A claim left over from an earlier offer is not evidence about this one.
    func testAStaleClaimForADifferentOfferProvesNothing() async {
        let previous = offer(mode: .targetedInsert)
        store.claimOffer(previous.offerID)
        let offer = self.offer(mode: .targetedInsert)
        store.publishOffer(offer)

        let outcome = await KeyboardDeliveryPublisher.awaitOutcome(
            for: offer,
            store: store,
            timeout: .milliseconds(60),
            pollInterval: .milliseconds(10)
        )
        XCTAssertEqual(outcome, .targetedButNotInserted)
    }

    private func offer(mode: KeyboardPickupOffer.Mode) -> KeyboardPickupOffer {
        let now = Date()
        return KeyboardPickupOffer(
            text: "into the field",
            source: .hardwareTrigger,
            mode: mode,
            createdAt: now,
            expiresAt: now.addingTimeInterval(KeyboardPickupOffer.latePickupLifetime),
            originDocumentIdentifier: mode == .targetedInsert ? UUID() : nil
        )
    }
}
#endif
