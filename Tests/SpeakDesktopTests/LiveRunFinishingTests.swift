import Foundation
import XCTest
@testable import SpeakCore

/// The finish join and socket attach that Cartesia and Rev AI share, driven
/// through a minimal client so each phase rule is pinned on its own. The real
/// clients' finish behaviour stays covered by their own suites and by
/// `LiveClientMechanicsContractTests`.
final class LiveRunFinishingTests: XCTestCase {
    func testFinishOnAnIdleRun_retiresItAndReturnsItsTranscript() async {
        let client = FinishingClient(phase: .idle, transcript: "held")
        let result = await client.finishActiveRun()
        XCTAssertEqual(result, "held")
        XCTAssertEqual(client.retired, 1)
        XCTAssertEqual(client.finishesBegun, 0)
    }

    func testFinishOnAStreamingRun_waitsForTheProviderFinish() async {
        let client = FinishingClient(phase: .streaming, transcript: "words")
        let finish = Task { await client.finishActiveRun() }
        await waitUntil { client.waiterCount == 1 }
        XCTAssertEqual(client.finishesBegun, 1)
        client.resumeWaiters(with: "final")
        let result = await finish.value
        XCTAssertEqual(result, "final")
        XCTAssertEqual(client.retired, 0)
    }

    func testFinishWhileAFailureIsPublished_waitsUntilTheErrorIsOut() async {
        let client = FinishingClient(phase: .closed, transcript: "partial", deliveringFailure: true)
        let finish = Task { await client.finishActiveRun() }
        await waitUntil { client.lateWaiterCount == 1 }
        client.resumeLateWaiters(with: "partial")
        let result = await finish.value
        XCTAssertEqual(result, "partial")
    }

    func testFinishOnAClosedRun_returnsItsTranscriptAtOnce() async {
        let client = FinishingClient(phase: .closed, transcript: nil)
        let result = await client.finishActiveRun()
        XCTAssertNil(result)
        XCTAssertEqual(client.retired, 0)
    }

    func testAttachToARunThatIsNoLongerCurrent_cancelsTheSocket() {
        let client = FinishingClient(phase: .closed, transcript: nil)
        let socket = AssemblyAITestSocket()
        client.attach(socket, to: client.run)
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertNil(client.run.connection)
        XCTAssertEqual(client.received, 0)
    }

    func testAttachToTheCurrentRun_resumesTheSocketAndReportsItsHandshake() {
        let client = FinishingClient(phase: .connecting, transcript: nil)
        let socket = AssemblyAITestSocket()
        client.attach(socket, to: client.run)
        XCTAssertTrue(client.run.connection === socket)
        XCTAssertEqual(client.received, 1)
        XCTAssertEqual(client.opened, 0)
        socket.open()
        XCTAssertEqual(client.opened, 1)
        XCTAssertEqual(socket.cancels, 0)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition())
    }
}

private final class FinishingRun: LiveFinishableRun, @unchecked Sendable {
    var phase: LiveRunPhase
    var connection: (any StreamingWebSocketConnection)?
    var transcript: String?
    var delivery = LiveRunDelivery()

    init(phase: LiveRunPhase, transcript: String?, deliveringFailure: Bool) {
        self.phase = phase
        self.transcript = transcript
        self.delivery.deliveringFailure = deliveringFailure
    }

    func dropOutboundAudio() {}
}

private final class FinishingClient: LiveRunFinishing, @unchecked Sendable {
    let lock = NSLock()
    let run: FinishingRun
    private var counts = (retired: 0, finishesBegun: 0, received: 0, opened: 0)

    init(phase: LiveRunPhase, transcript: String?, deliveringFailure: Bool = false) {
        run = FinishingRun(phase: phase, transcript: transcript, deliveringFailure: deliveringFailure)
    }

    var retired: Int { lock.withLock { counts.retired } }
    var finishesBegun: Int { lock.withLock { counts.finishesBegun } }
    var received: Int { lock.withLock { counts.received } }
    var opened: Int { lock.withLock { counts.opened } }
    var waiterCount: Int { lock.withLock { run.delivery.waiters.count } }
    var lateWaiterCount: Int { lock.withLock { run.delivery.lateWaiters.count } }

    func withState<Value>(_ body: (inout LiveDeferredEffects) -> Value) -> Value {
        LiveDeferredEffects.applying(under: lock, body)
    }

    func isCurrent(_ active: FinishingRun) -> Bool { active === run && active.phase != .closed }

    func retire(_ active: FinishingRun, _ effects: inout LiveDeferredEffects) {
        counts.retired += 1
        active.phase = .closed
    }

    func beginFinish(_ active: FinishingRun, _ effects: inout LiveDeferredEffects) {
        counts.finishesBegun += 1
        active.phase = .finishing
    }

    func receive(_ active: FinishingRun, _ connection: any StreamingWebSocketConnection) {
        lock.withLock { counts.received += 1 }
    }

    func connectionOpened(_ active: FinishingRun) { lock.withLock { counts.opened += 1 } }

    func log(_ event: String) {}

    func resumeWaiters(with text: String?) {
        let waiters = lock.withLock { () -> [CheckedContinuation<String?, Never>] in
            defer { run.delivery.waiters.removeAll() }
            return run.delivery.waiters
        }
        waiters.forEach { $0.resume(returning: text) }
    }

    func resumeLateWaiters(with text: String?) {
        let waiters = lock.withLock { () -> [CheckedContinuation<String?, Never>] in
            defer { run.delivery.lateWaiters.removeAll() }
            return run.delivery.lateWaiters
        }
        waiters.forEach { $0.resume(returning: text) }
    }
}
