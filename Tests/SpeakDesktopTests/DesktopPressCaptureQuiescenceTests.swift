import Foundation
@testable import SpeakDesktop
import XCTest

private actor QuiescenceGate {
    private let held: Bool
    private var released = false
    private var arrived = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var departures: [CheckedContinuation<Void, Never>] = []
    init(held: Bool = false) { self.held = held }
    func pass() async {
        arrived = true
        arrivals.forEach { $0.resume() }; arrivals.removeAll()
        if held, !released { await withCheckedContinuation { departures.append($0) } }
    }
    func wait() async {
        if !arrived { await withCheckedContinuation { arrivals.append($0) } }
    }
    func release() {
        released = true
        departures.forEach { $0.resume() }; departures.removeAll()
    }
}

private protocol QuiescenceFixtureWorker: DesktopPressCaptureWorker {
    var expectedCloseFailures: Int { get }
    func releaseFixtureGates() async
}

private actor QuiescingTestWorker: DesktopPressCaptureQuiescingWorker, QuiescenceFixtureWorker {
    enum Failure: Error, CustomStringConvertible {
        case quiesce, close
        var description: String { self == .quiesce ? "synthetic quiesce" : "synthetic close" }
    }
    let quiescing = QuiescenceGate(held: true)
    let closing = QuiescenceGate()
    let expectedCloseFailures: Int
    private let tail: Data
    private let failQuiesce: Bool
    private let closeFailure: String?
    private let beforeClose: @Sendable () -> Void
    private var closeErrors: Int
    private var callbacks: [UUID: @Sendable (Data) -> Void] = [:]
    private var failures: [UUID: @Sendable (String) -> Void] = [:]
    private(set) var quiesces: [UUID] = []
    private(set) var closes: [UUID] = []
    init(
        tail: Data = Data([3, 0]), failQuiesce: Bool = false, closeErrors: Int = 0,
        closeFailure: String? = nil, beforeClose: @escaping @Sendable () -> Void = {}
    ) {
        self.tail = tail; self.failQuiesce = failQuiesce; self.closeErrors = closeErrors
        self.closeFailure = closeFailure; self.beforeClose = beforeClose
        self.expectedCloseFailures = closeErrors
    }
    func open(
        id: UUID, identity: DesktopPressCaptureIdentity, receive: @escaping @Sendable (Data) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        callbacks[id] = receive; failures[id] = onFailure
    }
    func quiesce(id: UUID) async throws {
        quiesces.append(id)
        await quiescing.pass()
        callbacks[id]?(tail)
        if failQuiesce { throw Failure.quiesce }
    }
    func close(id: UUID) async throws {
        closes.append(id)
        beforeClose()
        if let closeFailure { failures[id]?(closeFailure) }
        await closing.pass()
        if closeErrors > 0 { closeErrors -= 1; throw Failure.close }
    }
    func emit(_ data: Data, id: UUID) { callbacks[id]?(data) }
    func fail(_ message: String, id: UUID) { failures[id]?(message) }
    func releaseFixtureGates() async {
        await quiescing.release()
        await closing.release()
    }
}

extension PressCaptureTestWorker: QuiescenceFixtureWorker {
    fileprivate var expectedCloseFailures: Int { 0 }
    fileprivate func releaseFixtureGates() {
        releaseOpens()
        releaseCloses()
    }
}

private struct QuiescenceSinkGate: Sendable {
    let entered = NSConditionLock(condition: 0)
    let released = NSConditionLock(condition: 0)
    func pass() {
        entered.lock(); entered.unlock(withCondition: 1)
        guard released.lock(whenCondition: 1, before: Date().addingTimeInterval(10)) else {
            return XCTFail("Synthetic PCM gate did not release")
        }
        released.unlock(withCondition: 1)
    }
    func release() { released.lock(); released.unlock(withCondition: 1) }
}

private extension XCTestCase {
    func quiescenceLease(
        _ worker: any QuiescenceFixtureWorker, log: PressCaptureTestLog,
        unblock: @escaping @Sendable () -> Void = {}
    ) -> DesktopPressCaptureLease {
        let lease = DesktopPressCaptureLease.observingFailures(worker: worker, onFailureEvent: log.observe)
        addTeardownBlock {
            unblock()
            await worker.releaseFixtureGates()
            await lease.shutdown()
            try await lease.settle()
        }
        return lease
    }

    func retainQuiescenceOwned(
        _ owned: DesktopPressCaptureOwnedRelease, worker: any QuiescenceFixtureWorker,
        unblock: @escaping @Sendable () -> Void = {}
    ) {
        addTeardownBlock {
            unblock()
            await worker.releaseFixtureGates()
            let retries = await worker.expectedCloseFailures
            do { try await owned.release() } catch let error as DesktopPressCaptureError
                where error == .cleanupFailed("synthetic close") && retries == 1 {
                try await owned.retryRelease()
            }
        }
    }

    func retainQuiescenceTask(
        _ task: Task<Void, Error>, worker: any QuiescenceFixtureWorker,
        unblock: @escaping @Sendable () -> Void = {}
    ) {
        addTeardownBlock {
            unblock()
            await worker.releaseFixtureGates()
            try await task.value
        }
    }

    func quiescenceRun(
        _ worker: any QuiescenceFixtureWorker, log: PressCaptureTestLog, adopted: Bool = true
    ) async throws -> (DesktopPressCaptureLease, DesktopPressCaptureOwnedRelease) {
        let lease = quiescenceLease(worker, log: log)
        let owned = try await lease.beginOwned(
            identity: pressCaptureIdentity(), admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        retainQuiescenceOwned(owned, worker: worker)
        try await lease.waitUntilReady(owned.token)
        if adopted {
            try await lease.reserve(owned.token, identity: owned.identity, admission: pressCaptureAdmission())
            try await lease.adopt(
                owned.token, identity: owned.identity, admission: pressCaptureAdmission(), sink: log.append
            )
        }
        return (lease, owned)
    }
}

final class DesktopPressCaptureQuiescenceTests: XCTestCase {
    func testHeldQuiesceAcceptsFinalPartialSampleExactlyOnceBeforeRetirement() async throws {
        let worker = QuiescingTestWorker()
        let log = PressCaptureTestLog()
        let (lease, owned) = try await quiescenceRun(worker, log: log)
        await worker.emit(Data([1, 0, 2, 0]), id: owned.token.id)
        let release = Task { try await owned.release(); log.finish() }
        retainQuiescenceTask(release, worker: worker)
        await worker.quiescing.wait()
        await assertPressPhase(lease, .closing)
        let before = await worker.closes
        XCTAssertTrue(before.isEmpty); XCTAssertFalse(log.finished)
        await worker.emit(Data([4, 0]), id: owned.token.id)
        let joins = (0..<8).map { _ in Task { try await owned.release() } }
        for join in joins { retainQuiescenceTask(join, worker: worker) }
        joins.first?.cancel()
        await worker.quiescing.release()
        try await release.value
        for join in joins { try await join.value }
        try await owned.release()
        XCTAssertEqual(log.pcm, Data([1, 0, 2, 0, 4, 0, 3, 0]))
        let quiesces = await worker.quiesces
        let closes = await worker.closes
        XCTAssertEqual(quiesces, [owned.token.id]); XCTAssertEqual(closes, [owned.token.id])
        XCTAssertTrue(log.events.isEmpty)
        await assertPressPhase(lease, .idle)
    }

    func testFailedQuiesceFencesButRetiresAndPublishesCorrelatedCaptureFailure() async throws {
        let worker = QuiescingTestWorker(failQuiesce: true)
        let log = PressCaptureTestLog()
        let (lease, owned) = try await quiescenceRun(worker, log: log)
        await worker.quiescing.release()
        try await owned.release()
        XCTAssertEqual(log.pcm, Data([3, 0]))
        XCTAssertEqual(log.events, [.init(
            token: owned.token, identity: owned.identity,
            error: .captureFailed("Producer quiescence failed: synthetic quiesce")
        )])
        let closes = await worker.closes
        XCTAssertEqual(closes, [owned.token.id])
        await assertPressPhase(lease, .idle)
    }

    func testPostFenceFailureIsPublishedBeforeOwnedCompletionAndNotOverwritten() async throws {
        let worker = QuiescingTestWorker(closeFailure: "late native failure")
        let log = PressCaptureTestLog()
        let (_, owned) = try await quiescenceRun(worker, log: log)
        await worker.quiescing.release()
        try await owned.release()
        XCTAssertEqual(log.events, [.init(
            token: owned.token, identity: owned.identity, error: .captureFailed("late native failure")
        )])
        for _ in 0..<20 { await worker.fail("later replacement", id: owned.token.id) }
        XCTAssertEqual(log.events.count, 1)
    }

    func testFailedRetirementRetainsExclusionAndRetryDoesNotRepeatPartialFlush() async throws {
        let worker = QuiescingTestWorker(closeErrors: 1, closeFailure: "native finalization")
        let log = PressCaptureTestLog()
        let (lease, owned) = try await quiescenceRun(worker, log: log)
        await worker.quiescing.release()
        await assertPressError(.cleanupFailed("synthetic close")) { try await owned.release() }
        XCTAssertEqual(log.events.map(\.error), [
            .captureFailed("native finalization"), .cleanupFailed("synthetic close")
        ])
        await assertPressError(.invalidPhase) { try await lease.retryClose(owned.token) }
        await assertPressError(.occupied) {
            _ = try await lease.begin(
                identity: owned.identity, admission: pressCaptureAdmission(), limits: pressCaptureLimits()
            )
        }
        try await owned.retryRelease()
        let quiesces = await worker.quiesces
        let closes = await worker.closes
        XCTAssertEqual(quiesces, [owned.token.id])
        XCTAssertEqual(closes, [owned.token.id, owned.token.id])
        XCTAssertEqual(log.pcm, Data([3, 0])); XCTAssertEqual(log.events.count, 2)
    }

    func testFailedQuiesceAndRetirementKeepOriginalCauseThroughExplicitRetry() async throws {
        let worker = QuiescingTestWorker(failQuiesce: true, closeErrors: 1, closeFailure: "secondary native failure")
        let log = PressCaptureTestLog()
        let (_, owned) = try await quiescenceRun(worker, log: log)
        await worker.quiescing.release()
        await assertPressError(.cleanupFailed("synthetic close")) { try await owned.release() }
        try await owned.retryRelease()
        XCTAssertEqual(log.events.map(\.error), [
            .captureFailed("Producer quiescence failed: synthetic quiesce"), .cleanupFailed("synthetic close")
        ])
        XCTAssertEqual(log.pcm, Data([3, 0]))
        let quiesces = await worker.quiesces
        XCTAssertEqual(quiesces, [owned.token.id])
    }

    func testEarlierRelayCauseWinsAndNonAdoptedRunNeverQuiesces() async throws {
        let worker = QuiescingTestWorker(closeFailure: "native after invalid PCM")
        let log = PressCaptureTestLog()
        let (_, owned) = try await quiescenceRun(worker, log: log)
        await worker.emit(Data([1]), id: owned.token.id)
        try await owned.release()
        XCTAssertEqual(log.events.map(\.error), [.invalidPCM])
        let skipped = await worker.quiesces
        XCTAssertTrue(skipped.isEmpty)
        let nextLog = PressCaptureTestLog()
        let (_, next) = try await quiescenceRun(worker, log: nextLog, adopted: false)
        try await next.release()
        let stillSkipped = await worker.quiesces
        XCTAssertTrue(stillSkipped.isEmpty)
        XCTAssertTrue(nextLog.pcm.isEmpty)
    }
}

final class DesktopPressCaptureQuiescenceRaceTests: XCTestCase {
    func testOldTicketAndCallbacksCannotQuiesceCloseOrFailNewRun() async throws {
        let worker = QuiescingTestWorker()
        let log = PressCaptureTestLog()
        let (lease, first) = try await quiescenceRun(worker, log: log)
        await worker.quiescing.release()
        try await first.release()
        let next = try await lease.beginOwned(
            identity: pressCaptureIdentity(device: "next"), admission: pressCaptureAdmission(),
            limits: pressCaptureLimits()
        )
        retainQuiescenceOwned(next, worker: worker)
        try await lease.waitUntilReady(next.token)
        try await lease.reserve(next.token, identity: next.identity, admission: pressCaptureAdmission())
        try await lease.adopt(next.token, identity: next.identity, admission: pressCaptureAdmission(), sink: log.append)
        await lease.cancel(first.token)
        try await first.release()
        await assertPressError(.invalidPhase) { try await first.retryRelease() }
        await worker.emit(Data([99, 0]), id: first.token.id)
        await worker.fail("stale native error", id: first.token.id)
        await worker.emit(Data([7, 0]), id: next.token.id)
        await assertPressPhase(lease, .adopted)
        try await next.release()
        XCTAssertEqual(log.pcm, Data([3, 0, 7, 0, 3, 0]))
        XCTAssertTrue(log.events.isEmpty)
        let quiesces = await worker.quiesces
        let closes = await worker.closes
        XCTAssertEqual(quiesces, [first.token.id, next.token.id])
        XCTAssertEqual(closes, [first.token.id, next.token.id])
    }

    func testLegacyWorkerKeepsFenceBeforeCloseAndRejectsStopTimePCM() async throws {
        let worker = PressCaptureTestWorker(holdCloses: true)
        let log = PressCaptureTestLog()
        let (_, owned) = try await quiescenceRun(worker, log: log)
        await worker.emit(Data([1, 0]), id: owned.token.id)
        let release = Task { try await owned.release() }
        retainQuiescenceTask(release, worker: worker)
        await worker.waitForCloses()
        await worker.emit(Data([9, 0]), id: owned.token.id)
        await worker.releaseCloses()
        try await release.value
        XCTAssertEqual(log.pcm, Data([1, 0]))
        XCTAssertTrue(log.events.isEmpty)
    }

    func testFinalPCMDrainCompletesBeforeCloseEvenWithBlockedSynchronousSink() async throws {
        let gate = QuiescenceSinkGate()
        addTeardownBlock { gate.release() }
        defer { gate.release() }
        let log = PressCaptureTestLog()
        let worker = QuiescingTestWorker(beforeClose: { XCTAssertTrue(log.finished) })
        let lease = quiescenceLease(worker, log: log, unblock: { gate.release() })
        let owned = try await lease.beginOwned(
            identity: pressCaptureIdentity(), admission: pressCaptureAdmission(), limits: pressCaptureLimits()
        )
        retainQuiescenceOwned(owned, worker: worker, unblock: { gate.release() })
        try await lease.waitUntilReady(owned.token)
        try await lease.reserve(owned.token, identity: owned.identity, admission: pressCaptureAdmission())
        let entered = expectation(description: "Final partial sample reached synchronous sink")
        try await lease.adopt(owned.token, identity: owned.identity, admission: pressCaptureAdmission()) { data in
            entered.fulfill(); gate.pass(); log.append(data); log.finish()
        }
        await worker.quiescing.release()
        let release = Task { try await owned.release() }
        retainQuiescenceTask(release, worker: worker, unblock: { gate.release() })
        await fulfillment(of: [entered], timeout: 2)
        let closes = await worker.closes
        XCTAssertTrue(closes.isEmpty)
        gate.release()
        try await release.value
        XCTAssertEqual(log.pcm, Data([3, 0]))
    }

    func testFinalFlushStillUsesReservedBoundAndRetainsOverflowCause() async throws {
        let worker = QuiescingTestWorker(tail: Data(repeating: 1, count: 34), closeFailure: "secondary")
        let log = PressCaptureTestLog()
        let (_, owned) = try await quiescenceRun(worker, log: log)
        await worker.quiescing.release()
        try await owned.release()
        XCTAssertEqual(log.events.map(\.error), [.startupOverflow])
        XCTAssertTrue(log.pcm.isEmpty)
        let closes = await worker.closes
        XCTAssertEqual(closes, [owned.token.id])
    }
}
