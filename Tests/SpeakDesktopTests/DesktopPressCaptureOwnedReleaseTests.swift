import Foundation
@testable import SpeakDesktop
import XCTest

private actor OwnedCaptureGate {
    private var entered = false; private var released = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var departure: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true
        arrival?.resume()
        arrival = nil
        if !released { await withCheckedContinuation { departure = $0 } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { arrival = $0 } }
    }
    func release() {
        released = true
        departure?.resume()
        departure = nil
    }
}
private actor OwnedCaptureWorker: DesktopPressCaptureWorker {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private var openGate: OwnedCaptureGate?; private let openError: String?
    private var closeGate: OwnedCaptureGate?; private var closeErrors: [String]
    private var callbacks: [UUID: @Sendable (Data) -> Void] = [:]
    private var errors: [UUID: @Sendable (String) -> Void] = [:]
    private var onClose: (@Sendable () async -> Void)?
    private var active: Set<UUID> = []
    private(set) var opens: [UUID] = []; private(set) var closes: [UUID] = []
    private(set) var maximumActive = 0
    init(openGate: OwnedCaptureGate? = nil, openError: String? = nil, closeErrors: [String] = []) {
        self.openGate = openGate
        self.openError = openError
        self.closeErrors = closeErrors
    }
    func open(
        id: UUID, identity: DesktopPressCaptureIdentity, receive: @escaping @Sendable (Data) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        opens.append(id)
        active.insert(id)
        maximumActive = max(maximumActive, active.count)
        callbacks[id] = receive
        errors[id] = onFailure
        await openGate?.enter()
        if let openError { throw Failure(description: openError) }
    }
    func close(id: UUID) async throws {
        closes.append(id)
        await onClose?()
        await closeGate?.enter()
        callbacks[id]?(Data([255, 255]))
        if !closeErrors.isEmpty { throw Failure(description: closeErrors.removeFirst()) }
        active.remove(id)
    }
    func setCloseGate(_ gate: OwnedCaptureGate) { closeGate = gate }
    func setOpenGate(_ gate: OwnedCaptureGate) { openGate = gate }
    func setCloseError(_ error: String) { closeErrors.append(error) }
    func setCloseObserver(_ observer: @escaping @Sendable () async -> Void) { onClose = observer }
    func emit(_ data: Data, id: UUID) { callbacks[id]?(data) }
    func fail(_ message: String, id: UUID) { errors[id]?(message) }
}
private extension DesktopPressCaptureLease {
    func beginThenCancelOwned() throws -> DesktopPressCaptureOwnedRelease {
        let owned = try beginOwned(
            identity: pressCaptureIdentity(), admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        cancel(owned.token)
        return owned
    }
}
private func releaseOutcome(_ owned: DesktopPressCaptureOwnedRelease) async -> DesktopPressCaptureError? {
    do { try await owned.release(); return nil } catch {
        XCTAssertTrue(error is DesktopPressCaptureError, "Unexpected release error: \(error)")
        return error as? DesktopPressCaptureError
    }
}
private func releaseOwnedDrain(_ condition: NSCondition, log: PressCaptureTestLog) {
    condition.lock(); log.finish(); condition.broadcast(); condition.unlock()
}
final class DesktopPressCaptureOwnedReleaseTests: XCTestCase {
    func testAtomicNeverStartedCancellation_CompletesWithoutOpeningOrClosing() async throws {
        let worker = OwnedCaptureWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease.observingFailures(worker: worker, onFailureEvent: log.observe)
        let owned = try await lease.beginThenCancelOwned()
        try await owned.release()
        try await owned.release()
        await assertPressPhase(lease, .idle)
        let opens = await worker.opens
        let closes = await worker.closes
        XCTAssertTrue(opens.isEmpty)
        XCTAssertTrue(closes.isEmpty)
        XCTAssertTrue(log.events.isEmpty)
    }
    func testOwnedOpenAndCleanupFailure_RejectLegacyRetryUntilExplicitOwnedRetry() async throws {
        let worker = OwnedCaptureWorker(openError: "open", closeErrors: ["close"])
        let log = PressCaptureTestLog(); let identity = pressCaptureIdentity(device: "owned-device")
        let lease = DesktopPressCaptureLease.observingFailures(worker: worker, onFailureEvent: log.observe)
        let owned = try await lease.beginOwned(
            identity: identity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        await assertPressError(.cleanupFailed("close")) { try await lease.settle() }
        for _ in 0..<20 {
            await assertPressError(.cleanupFailed("close")) { try await owned.release() }
        }
        await assertPressError(.invalidPhase) { try await lease.retryClose(owned.token) }
        await assertPressError(.cleanupFailed("close")) { try await owned.release() }
        await assertPressPhase(lease, .closing)
        let refusedCloses = await worker.closes; XCTAssertEqual(refusedCloses, [owned.token.id])
        XCTAssertEqual(owned.identity, identity)
        XCTAssertEqual(log.events, [
            .init(token: owned.token, identity: identity, error: .openFailed("open")),
            .init(token: owned.token, identity: identity, error: .cleanupFailed("close"))
        ])
        await assertPressError(.occupied) {
            _ = try await lease.beginOwned(
                identity: identity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
            )
        }
        try await owned.retryRelease()
        try await owned.release()
        let closes = await worker.closes
        XCTAssertEqual(closes, [owned.token.id, owned.token.id])
        XCTAssertEqual(log.events.count, 2)
        await assertPressPhase(lease, .idle)
    }
    func testLegacyBegin_CloseFailureAndRetryPreserveSingleRetryAndSettleSuccess() async throws {
        let worker = OwnedCaptureWorker(closeErrors: ["legacy-close"]); let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let token = try await lease.begin(
            identity: pressCaptureIdentity(), admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        try await lease.waitUntilReady(token)
        await lease.cancel(token)
        await assertPressError(.cleanupFailed("legacy-close")) { try await lease.settle() }
        let initialCloses = await worker.closes; XCTAssertEqual(initialCloses, [token.id])
        try await lease.retryClose(token)
        try await lease.settle()
        let retriedCloses = await worker.closes; XCTAssertEqual(retriedCloses, [token.id, token.id])
        XCTAssertEqual(log.failures, [.cleanupFailed("legacy-close")])
        await assertPressPhase(lease, .idle)
    }
    func testPendingCancelledWaiter_JoinsLateOpenAndActualClose() async throws {
        let open = OwnedCaptureGate()
        let close = OwnedCaptureGate()
        let worker = OwnedCaptureWorker(openGate: open)
        await worker.setCloseGate(close)
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let owned = try await lease.beginOwned(
            identity: pressCaptureIdentity(), admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        await open.waitForEntry()
        let first = Task { try await owned.release(); log.finish() }
        first.cancel()
        await lease.cancel(owned.token)
        await assertPressPhase(lease, .closing)
        let beforeOpen = await worker.closes; XCTAssertTrue(beforeOpen.isEmpty)
        await open.release()
        await close.waitForEntry()
        XCTAssertFalse(log.finished)
        await assertPressError(.invalidPhase) { try await owned.retryRelease() }
        let joins = (0..<8).map { _ in Task { try await owned.release() } }
        await close.release()
        try await first.value
        for join in joins { try await join.value }
        let closes = await worker.closes
        let maximum = await worker.maximumActive
        XCTAssertEqual(closes, [owned.token.id])
        XCTAssertEqual(maximum, 1)
        await assertPressPhase(lease, .idle)
    }
    func testRelease_JoinsActiveDrainBeforeReentrantCloseAndRejectsFinalFlush() async throws {
        let worker = OwnedCaptureWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let identity = pressCaptureIdentity()
        let owned = try await lease.beginOwned(
            identity: identity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        try await lease.waitUntilReady(owned.token)
        try await lease.reserve(owned.token, identity: identity, admission: pressCaptureAdmission())
        let entered = expectation(description: "Owned drain admitted")
        let condition = NSCondition()
        try await lease.adoptDelivery(owned.token, identity: identity, admission: pressCaptureAdmission()) { pcm in
            condition.lock()
            entered.fulfill()
            while !log.finished {
                if !condition.wait(until: Date().addingTimeInterval(5)) {
                    XCTFail("Test drain gate did not release")
                    break
                }
            }
            condition.unlock()
            log.append(pcm.data)
        }
        await worker.setCloseObserver {
            await assertPressError(.occupied) {
                _ = try await lease.begin(
                    identity: identity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
                )
            }
        }
        await worker.emit(Data([1, 0]), id: owned.token.id)
        await fulfillment(of: [entered], timeout: 2)
        let release = Task { try await owned.release() }
        await lease.cancel(owned.token)
        let beforeDrain = await worker.closes
        XCTAssertTrue(beforeDrain.isEmpty)
        releaseOwnedDrain(condition, log: log)
        try await release.value
        XCTAssertEqual(log.pcm, Data([1, 0]))
        let closes = await worker.closes
        XCTAssertEqual(closes, [owned.token.id])
    }
    func testCaptureInvalidPCMAndOverflow_KeepSeparateCleanupAttemptAndRetry() async throws {
        for cause in [DesktopPressCaptureError.captureFailed("native"), .invalidPCM, .startupOverflow] {
            let worker = OwnedCaptureWorker(closeErrors: ["cleanup"])
            let log = PressCaptureTestLog()
            let lease = DesktopPressCaptureLease.observingFailures(worker: worker, onFailureEvent: log.observe)
            let identity = pressCaptureIdentity()
            let owned = try await lease.beginOwned(
                identity: identity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
            )
            try await lease.waitUntilReady(owned.token)
            try await lease.reserve(owned.token, identity: identity, admission: pressCaptureAdmission())
            if case .captureFailed = cause {
                await worker.fail("native", id: owned.token.id)
            } else {
                await worker.emit(Data(repeating: 0, count: cause == .invalidPCM ? 1 : 34), id: owned.token.id)
            }
            await assertPressError(.cleanupFailed("cleanup")) { try await owned.release() }
            XCTAssertEqual(log.events.map(\.error), [cause, .cleanupFailed("cleanup")])
            for _ in 0..<100 { await worker.fail("late", id: owned.token.id) }
            try await owned.retryRelease()
            XCTAssertEqual(log.events.count, 2)
        }
    }
}

final class DesktopPressCaptureOwnedRetryTests: XCTestCase {
    func testConcurrentExplicitRetry_JoinsOneAttemptAndDoesNotRetryAgain() async throws {
        let worker = OwnedCaptureWorker(closeErrors: ["cleanup"])
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let owned = try await lease.beginOwned(
            identity: pressCaptureIdentity(), admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        try await lease.waitUntilReady(owned.token)
        await assertPressError(.cleanupFailed("cleanup")) { try await owned.release() }
        let gate = OwnedCaptureGate()
        await worker.setCloseGate(gate)
        let first = Task { try await owned.retryRelease() }
        await gate.waitForEntry()
        let second = Task { () -> DesktopPressCaptureError? in
            do { try await owned.retryRelease(); return nil } catch {
                XCTAssertTrue(error is DesktopPressCaptureError)
                return error as? DesktopPressCaptureError
            }
        }
        let release = Task { try await owned.release() }
        first.cancel()
        await gate.release()
        try await first.value
        let secondResult = await second.value
        // This caller may join the held attempt or enter after it has settled.
        XCTAssertTrue(secondResult == nil || secondResult == .invalidPhase)
        try await release.value
        await assertPressError(.invalidPhase) { try await owned.retryRelease() }
        let closes = await worker.closes
        XCTAssertEqual(closes, [owned.token.id, owned.token.id])
        XCTAssertEqual(log.failures, [.cleanupFailed("cleanup")])
    }
    func testDeferredAResult_AfterBFailureNeverReadsOrClosesCurrentB() async throws {
        let worker = OwnedCaptureWorker(closeErrors: ["A-close"])
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease.observingFailures(worker: worker, onFailureEvent: log.observe)
        let first = try await lease.beginOwned(
            identity: pressCaptureIdentity(device: "A"), admission: pressCaptureAdmission(),
            limits: pressCaptureLimits()
        )
        try await lease.waitUntilReady(first.token)
        let receiver = OwnedCaptureGate()
        let deferred = Task {
            let error = await releaseOutcome(first)
            await receiver.enter()
            return error
        }
        await receiver.waitForEntry()
        try await first.retryRelease()
        await worker.setCloseError("B-close")
        let second = try await lease.beginOwned(
            identity: pressCaptureIdentity(device: "B"), admission: pressCaptureAdmission(),
            limits: pressCaptureLimits()
        )
        try await lease.waitUntilReady(second.token)
        await assertPressError(.cleanupFailed("B-close")) { try await second.release() }
        await receiver.release()
        let delayedError = await deferred.value
        XCTAssertEqual(delayedError, .cleanupFailed("A-close"))
        try await first.release()
        await assertPressError(.invalidPhase) { try await first.retryRelease() }
        await lease.cancel(first.token)
        await assertPressPhase(lease, .closing)
        let failure = await lease.failure
        XCTAssertEqual(failure, .cleanupFailed("B-close"))
        let beforeBRetry = await worker.closes
        XCTAssertEqual(beforeBRetry, [first.token.id, first.token.id, second.token.id])
        try await second.retryRelease()
        let maximum = await worker.maximumActive
        XCTAssertEqual(maximum, 1)
    }

    func testReleasedA_ReplayWhileBIsOpeningDoesNotJoinB() async throws {
        let worker = OwnedCaptureWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let first = try await lease.beginOwned(
            identity: pressCaptureIdentity(device: "A"), admission: pressCaptureAdmission(),
            limits: pressCaptureLimits()
        )
        try await lease.waitUntilReady(first.token)
        try await first.release()
        let opening = OwnedCaptureGate()
        await worker.setOpenGate(opening)
        let second = try await lease.beginOwned(
            identity: pressCaptureIdentity(device: "B"), admission: pressCaptureAdmission(),
            limits: pressCaptureLimits()
        )
        await opening.waitForEntry()
        let replayed = expectation(description: "A does not wait for B opening")
        let replay = Task { try await first.release(); replayed.fulfill() }
        await fulfillment(of: [replayed], timeout: 2)
        await opening.release()
        try await replay.value
        await lease.cancel(first.token)
        try await lease.waitUntilReady(second.token)
        await assertPressPhase(lease, .open)
        let closes = await worker.closes
        XCTAssertEqual(closes, [first.token.id])
        try await second.release()
    }

    func testShutdownWithPendingOpen_RetainsCleanupWithoutEnablingReopen() async throws {
        let gate = OwnedCaptureGate()
        let worker = OwnedCaptureWorker(openGate: gate)
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker, onFailure: log.fail)
        let owned = try await lease.beginOwned(
            identity: pressCaptureIdentity(), admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        await gate.waitForEntry()
        await lease.shutdown()
        let release = Task { try await owned.release() }
        await assertPressError(.closed) {
            _ = try await lease.beginOwned(
                identity: owned.identity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
            )
        }
        await gate.release()
        try await release.value
        let closes = await worker.closes
        XCTAssertEqual(closes, [owned.token.id])
    }

    func testOwnedEntry_PreservesAdmissionAndConfigurationRefusalsWithoutIO() async throws {
        let worker = OwnedCaptureWorker()
        let log = PressCaptureTestLog()
        let lease = DesktopPressCaptureLease(worker: worker) { _ in log.accept(1) }
        for (admission, error) in [
            (pressCaptureAdmission(enabled: false), DesktopPressCaptureError.refused(.disabled)),
            (pressCaptureAdmission(owner: .handsFree), .refused(.occupied(.handsFree))),
            (pressCaptureAdmission(owner: .manual), .refused(.occupied(.manual))),
            (pressCaptureAdmission(owner: .comparison), .refused(.occupied(.comparison))),
            (pressCaptureAdmission(permission: .unavailable("unknown")), .refused(.permissionUnavailable("unknown"))),
            (pressCaptureAdmission(capability: .unavailable("unqualified")),
             .refused(.capabilityUnavailable("unqualified")))
        ] {
            await assertPressError(error) {
                _ = try await lease.beginOwned(
                    identity: pressCaptureIdentity(), admission: admission, limits: pressCaptureLimits()
                )
            }
        }
        await assertPressError(.invalidConfiguration) {
            _ = try await lease.beginOwned(
                identity: pressCaptureIdentity(route: ""), admission: pressCaptureAdmission(),
                limits: pressCaptureLimits()
            )
        }
        let opens = await worker.opens
        XCTAssertTrue(opens.isEmpty)
        XCTAssertTrue(log.accepted.isEmpty)
    }
}
