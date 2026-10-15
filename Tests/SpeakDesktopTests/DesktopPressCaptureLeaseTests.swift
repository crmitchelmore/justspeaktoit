import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopPressCaptureLeaseTests: XCTestCase {
    func testHold_AdmitsBufferedPCMOnceAndReleaseJoinsDelivery() async throws {
        let worker = PressCaptureTestWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let identity = pressCaptureIdentity(), admission = pressCaptureAdmission()
        var gestures = HotKeyGestureMachine()
        XCTAssertEqual(gestures.keyDown(at: 0), [])
        let token = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        try await lease.waitUntilReady(token)
        await worker.emit(Data([1, 0, 2, 0]))
        XCTAssertTrue(log.pcm.isEmpty)
        XCTAssertEqual(gestures.deadlineReached(at: gestures.holdThreshold), [.holdStart])
        try await lease.reserve(token, identity: identity, admission: admission)
        try await lease.adopt(token, identity: identity, admission: admission, sink: log.append)
        await assertPressPhase(lease, .adopted)
        await worker.emit(Data([3, 0]))
        XCTAssertEqual(gestures.keyUp(at: 1), [.holdEnd])
        await lease.cancel(token)
        await lease.cancel(token)
        try await lease.settle()
        await worker.emit(Data([4, 0]))
        await assertPressPhase(lease, .idle)
        XCTAssertEqual(log.pcm, Data([1, 0, 2, 0, 3, 0]))
        let closes = await worker.closes
        XCTAssertEqual(closes.count, 1)
        XCTAssertTrue(log.failures.isEmpty)
    }

    func testDoubleTap_UsesSameOpenWithoutClassifyingSpeechOrPublishingBeforeAdmission() async throws {
        let worker = PressCaptureTestWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let identity = pressCaptureIdentity(), admission = pressCaptureAdmission()
        var gestures = HotKeyGestureMachine()
        _ = gestures.keyDown(at: 0)
        let token = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        try await lease.waitUntilReady(token)
        await worker.emit(Data([1, 0]))
        XCTAssertEqual(gestures.keyUp(at: 0.05), [])
        _ = gestures.keyDown(at: 0.1)
        await worker.emit(Data([2, 0]))
        XCTAssertTrue(log.pcm.isEmpty)
        XCTAssertEqual(gestures.keyUp(at: 0.15), [.doubleTap])
        try await lease.reserve(token, identity: identity, admission: admission)
        try await lease.adopt(token, identity: identity, admission: admission, sink: log.append)
        await lease.cancel(token)
        try await lease.settle()
        XCTAssertEqual(log.pcm, Data([1, 0, 2, 0]))
        let opens = await worker.opens
        XCTAssertEqual(opens.count, 1)
    }

    func testSingleTapExpiryAndReset_DiscardSpeculationAndCloseExactlyOnce() async throws {
        for reset in [false, true] {
            let worker = PressCaptureTestWorker()
            let log = PressCaptureTestLog()
            let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
            var gestures = HotKeyGestureMachine()
            _ = gestures.keyDown(at: 0)
            let token = try await lease.begin(
                identity: pressCaptureIdentity(), admission: pressCaptureAdmission(), limits: pressCaptureLimits()
            )
            try await lease.waitUntilReady(token)
            await worker.emit(Data([1, 0]))
            if reset {
                XCTAssertEqual(gestures.reset(), [])
            } else {
                _ = gestures.keyUp(at: 0.1)
                XCTAssertEqual(gestures.deadlineReached(at: 0.1 + gestures.doubleTapWindow), [.singleTap])
            }
            await lease.cancel(token)
            await lease.cancel(token)
            try await lease.settle()
            XCTAssertTrue(log.pcm.isEmpty)
            let closes = await worker.closes
            XCTAssertEqual(closes.count, 1)
        }
    }

    func testLateOpen_AbandonedReservationCannotReopenUntilRealCloseAcknowledges() async throws {
        let worker = PressCaptureTestWorker(holdOpens: true, holdCloses: true)
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let identity = pressCaptureIdentity(), admission = pressCaptureAdmission()
        let token = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        await worker.waitForOpens()
        try await lease.reserve(token, identity: identity, admission: admission)
        await lease.cancel(token)
        await assertPressPhase(lease, .closing)
        await assertPressError(.occupied) {
            _ = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        }
        await worker.emit(Data([1, 0]))
        await worker.releaseOpens()
        await worker.waitForCloses()
        await assertPressPhase(lease, .closing)
        let settled = PressCaptureTestLog()
        let wait = Task { try await lease.settle(); settled.finish() }
        XCTAssertFalse(settled.finished)
        await worker.releaseCloses()
        try await wait.value
        await assertPressPhase(lease, .idle)
        let next = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        try await lease.waitUntilReady(next)
        await lease.cancel(token)
        await assertPressPhase(lease, .open)
        await lease.cancel(next)
        try await lease.settle()
        let maximum = await worker.maximumActive, closes = await worker.closes
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(closes.count, 2)
        XCTAssertTrue(log.pcm.isEmpty)
    }

    func testShutdown_PendingOpenClosesLateAndNeverAdmitsAgain() async throws {
        let worker = PressCaptureTestWorker(holdOpens: true)
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let token = try await lease.begin(
            identity: pressCaptureIdentity(), admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        await worker.waitForOpens()
        await lease.shutdown()
        await lease.shutdown()
        await worker.releaseOpens()
        try await lease.settle()
        await assertPressError(.staleLease) { try await lease.waitUntilReady(token) }
        await assertPressError(.closed) {
            _ = try await lease.begin(
                identity: pressCaptureIdentity(), admission: pressCaptureAdmission(), limits: pressCaptureLimits()
            )
        }
        let closes = await worker.closes
        XCTAssertEqual(closes.count, 1)
    }

    func testCancellation_JoinsActiveDeliveryBeforeWorkerCloseWithoutBlockingControlActor() async throws {
        let worker = PressCaptureTestWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let identity = pressCaptureIdentity(), admission = pressCaptureAdmission()
        let token = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        try await lease.reserve(token, identity: identity, admission: admission)
        try await lease.waitUntilReady(token)
        let entered = expectation(description: "Delivery active")
        let release = DispatchSemaphore(value: 0)
        try await lease.adopt(token, identity: identity, admission: admission) { data in
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            log.append(data)
        }
        await worker.emit(Data([1, 0]))
        await fulfillment(of: [entered], timeout: 2)
        await lease.cancel(token)
        await assertPressPhase(lease, .closing)
        let beforeJoin = await worker.closes
        XCTAssertTrue(beforeJoin.isEmpty)
        release.signal()
        try await lease.settle()
        let afterJoin = await worker.closes
        XCTAssertEqual(afterJoin.count, 1)
        XCTAssertEqual(log.pcm, Data([1, 0]))
    }

    func testWorkerFailure_IsLatchedAndOldCallbacksCannotFailReplacementLease() async throws {
        let worker = PressCaptureTestWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let identity = pressCaptureIdentity(), admission = pressCaptureAdmission()
        let first = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        try await lease.waitUntilReady(first)
        let openIDs = await worker.opens
        let oldID = try XCTUnwrap(openIDs.first)
        for _ in 0..<100 { await worker.fail(id: oldID, message: "Device lost") }
        try await lease.settle()
        await assertPressPhase(lease, .idle)
        XCTAssertEqual(log.failures, [.captureFailed("Device lost")])
        let second = try await lease.begin(identity: identity, admission: admission, limits: pressCaptureLimits())
        try await lease.waitUntilReady(second)
        await worker.fail(id: oldID, message: "Late old error")
        await worker.emit(Data([99, 0]), id: oldID)
        await assertPressPhase(lease, .open)
        XCTAssertEqual(log.failures, [.captureFailed("Device lost")])
        await lease.cancel(second)
        try await lease.settle()
        let closes = await worker.closes
        XCTAssertEqual(closes.count, 2)
    }

    func testCancelledBeforeOpenDispatch_DoesNotInvokeWorker() async throws {
        let worker = PressCaptureTestWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        try await lease.beginAndCancelForTest()
        try await lease.settle()
        let opens = await worker.opens, closes = await worker.closes
        XCTAssertTrue(opens.isEmpty)
        XCTAssertTrue(closes.isEmpty)
        await assertPressPhase(lease, .idle)
    }
}

private extension DesktopPressCaptureLease {
    func beginAndCancelForTest() throws {
        let token = try begin(
            identity: pressCaptureIdentity(), admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        cancel(token)
    }
}
