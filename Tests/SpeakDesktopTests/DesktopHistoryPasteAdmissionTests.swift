import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopHistoryPasteAdmissionTests: XCTestCase {
    func testBegin_BurstRetainsOnlyOneRequestUntilItsConsumerFinishes() throws {
        let clock = HistoryPasteClock()
        let admission = DesktopHistoryPasteAdmission(now: { clock.now })
        let first = try XCTUnwrap(admission.begin())
        for _ in 0..<1000 { XCTAssertNil(admission.begin()) }
        XCTAssertTrue(first.isCurrent)
        first.finish()
        XCTAssertFalse(first.isCurrent)
        let next = try XCTUnwrap(admission.begin())
        first.finish()
        XCTAssertTrue(next.isCurrent)
        XCTAssertNil(admission.begin())
        next.finish()
    }

    func testExpiry_ExactBudgetIsRejectedButDoesNotReleaseThePendingSlot() throws {
        let clock = HistoryPasteClock()
        let admission = DesktopHistoryPasteAdmission(now: { clock.now })
        let request = try XCTUnwrap(admission.begin())
        clock.advance(.milliseconds(999))
        XCTAssertTrue(request.isCurrent)
        clock.advance(.milliseconds(1))
        XCTAssertFalse(request.isCurrent)
        XCTAssertNil(admission.begin())
        clock.advance(.seconds(30))
        XCTAssertNil(admission.begin())
        request.finish()
        let next = try XCTUnwrap(admission.begin())
        XCTAssertTrue(next.isCurrent)
        next.finish()
    }

    func testStop_InvalidatesPendingAndPermanentlyRefusesNewRequests() throws {
        let admission = DesktopHistoryPasteAdmission()
        let request = try XCTUnwrap(admission.begin())
        admission.stop()
        XCTAssertFalse(request.isCurrent)
        XCTAssertNil(admission.begin())
        request.finish()
        admission.stop()
        XCTAssertNil(admission.begin())
    }

    func testConcurrentBegin_OnlyOneProducerOwnsCapture() throws {
        let admission = DesktopHistoryPasteAdmission()
        let requests = HistoryPasteRequests()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if let request = admission.begin() { requests.append(request) }
        }
        XCTAssertEqual(requests.values.count, 1)
        let request = try XCTUnwrap(requests.values.first)
        request.finish()
        XCTAssertNotNil(admission.begin())
    }
}

private final class HistoryPasteClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

private final class HistoryPasteRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DesktopHistoryPasteAdmission.Request] = []
    var values: [DesktopHistoryPasteAdmission.Request] { lock.withLock { storage } }
    func append(_ request: DesktopHistoryPasteAdmission.Request) { lock.withLock { storage.append(request) } }
}
