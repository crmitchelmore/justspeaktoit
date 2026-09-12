import Foundation
import XCTest

@testable import SpeakCore

/// Issue #990: the app pushes "look again" to the keyboard instead of letting
/// it poll for a phase change, a new interim, or a new offer.
///
/// The Darwin notification itself carries no payload and cannot be observed
/// from a host unit test, so what is tested here is the contract around it:
/// *who* announces, *when*, and that the record the keyboard would then read
/// is already correct. The announcement closure is injected, which is also how
/// the "app announces, extension never does" rule is proved.
final class KeyboardStatusSignalTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "keyboard-status-signal-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    func testEveryAppSideWrite_wakesTheKeyboard() throws {
        let wakes = Counter()
        let app = KeyboardHandoffStore(
            defaults: defaults,
            role: .containingApp,
            announceStatusChange: { wakes.increment() }
        )
        let ext = KeyboardHandoffStore(
            defaults: defaults,
            role: .keyboardExtension,
            announceStatusChange: { wakes.increment() }
        )

        let request = try ext.createRequest(now: now)
        // The extension owns the intent key; it has its own signal in the
        // other direction and must never post this one.
        XCTAssertEqual(wakes.count, 0)

        _ = try app.markRecording(requestID: request.requestID, now: now)
        XCTAssertEqual(wakes.count, 1)

        _ = try app.updateInterim(requestID: request.requestID, transcript: "hello", now: now)
        XCTAssertEqual(wakes.count, 2)

        _ = try app.markTranscribing(requestID: request.requestID, now: now)
        _ = try app.complete(requestID: request.requestID, transcript: "Hello.", now: now)
        XCTAssertEqual(wakes.count, 4)
    }

    func testAFailedWriteDoesNotWakeTheKeyboard() throws {
        let wakes = Counter()
        let app = KeyboardHandoffStore(
            defaults: defaults,
            role: .containingApp,
            announceStatusChange: { wakes.increment() }
        )
        // No request exists, so there is nothing for the keyboard to read.
        XCTAssertThrowsError(try app.markRecording(requestID: UUID(), now: now))
        XCTAssertEqual(wakes.count, 0)
    }

    func testAnUnavailableAppGroup_neitherWritesNorWakes() throws {
        // Without Full Access there is no shared container: every write is a
        // no-op, so there is never anything worth waking the keyboard for.
        let wakes = Counter()
        let app = KeyboardHandoffStore(
            defaults: nil,
            role: .containingApp,
            announceStatusChange: { wakes.increment() }
        )
        XCTAssertThrowsError(try app.markRecording(requestID: UUID(), now: now))
        XCTAssertEqual(wakes.count, 0)

        let delivery = KeyboardDeliveryStore(
            defaults: nil,
            announceStatusChange: { wakes.increment() }
        )
        XCTAssertNil(delivery.publishOffer(sampleOffer()))
        XCTAssertEqual(wakes.count, 0)
    }

    func testPublishingAnOffer_wakesTheKeyboard() throws {
        let wakes = Counter()
        let delivery = KeyboardDeliveryStore(
            defaults: defaults,
            announceStatusChange: { wakes.increment() }
        )
        XCTAssertNotNil(delivery.publishOffer(sampleOffer()))
        XCTAssertEqual(wakes.count, 1)
    }

    // MARK: - The status-expiry rewrite an interim used to always do

    func testStatusExpiryRefresh_isSkippedWhilePlentyOfLifetimeRemains() {
        let expires = now.addingTimeInterval(KeyboardHandoffStore.requestLifetime)
        XCTAssertFalse(
            KeyboardHandoffStore.statusExpiryNeedsRefresh(expiresAt: expires, now: now)
        )
        // Right on the threshold, and past it, the expiry is pushed out again.
        let atThreshold = now.addingTimeInterval(KeyboardHandoffStore.statusExpiryRefreshThreshold)
        XCTAssertTrue(
            KeyboardHandoffStore.statusExpiryNeedsRefresh(expiresAt: atThreshold, now: now)
        )
        XCTAssertTrue(
            KeyboardHandoffStore.statusExpiryNeedsRefresh(
                expiresAt: now.addingTimeInterval(30),
                now: now
            )
        )
    }

    func testALongDictation_stillCannotTimeOutMidSentence() throws {
        let ext = KeyboardHandoffStore(defaults: defaults, role: .keyboardExtension)
        let app = KeyboardHandoffStore(defaults: defaults, role: .containingApp)
        let request = try ext.createRequest(now: now)
        _ = try app.markRecording(requestID: request.requestID, now: now)

        // Speak past the point where the original status expiry would lapse.
        // The skipped rewrites are the ones that had nothing to do; the one
        // that matters still happens.
        var clock = now
        for _ in 0..<12 {
            clock = clock.addingTimeInterval(20)
            _ = try app.updateInterim(
                requestID: request.requestID,
                transcript: "still speaking at \(clock.timeIntervalSince(now))",
                now: clock
            )
        }
        let record = try XCTUnwrap(app.record(matching: request.requestID, now: clock))
        XCTAssertEqual(record.phase, .recording)
        XCTAssertGreaterThan(record.expiresAt, clock)
    }

    private func sampleOffer() -> KeyboardPickupOffer {
        KeyboardPickupOffer(
            text: "Hello.",
            source: .hardwareTrigger,
            mode: .latePickup,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
    }
}
