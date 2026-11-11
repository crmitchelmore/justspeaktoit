import Foundation
import XCTest

@testable import SpeakCore

/// The Darwin observation hands the notification centre a retained context
/// and releases it on explicit unregister, so a late notification can never
/// reach a freed observation.
final class KeyboardHandoffSignalObservationTests: XCTestCase {
    func testInvalidate_releasesTheRegistrationAndStopsDelivery() async throws {
        let deliveries = DeliveryCount()
        let observation = KeyboardHandoffSignal.observeRequestChanges { deliveries.increment() }
        XCTAssertTrue(observation.isRegisteredForTesting)

        KeyboardHandoffSignal.postRequestChanged()
        try await waitUntil { deliveries.value > 0 }

        observation.invalidate()
        observation.invalidate()
        XCTAssertFalse(observation.isRegisteredForTesting)
        let delivered = deliveries.value
        KeyboardHandoffSignal.postRequestChanged()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(deliveries.value, delivered, "An unregistered observation never runs its handler")
    }

    func testReleasingWithoutInvalidate_unregistersBeforeTheObservationIsFreed() async throws {
        let deliveries = DeliveryCount()
        weak var released: KeyboardHandoffSignalObservation?
        do {
            let observation = KeyboardHandoffSignal.observeRequestChanges { deliveries.increment() }
            released = observation
        }
        XCTAssertNil(released, "The notification centre does not keep the observation alive")
        KeyboardHandoffSignal.postRequestChanged()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(deliveries.value, 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
}

private final class DeliveryCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
