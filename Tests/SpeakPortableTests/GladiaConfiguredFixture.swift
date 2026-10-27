import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

final class GladiaConfiguredFixture: @unchecked Sendable {
    struct Finish {
        let task: Task<String?, Never>
        let done: XCTestExpectation
        let exited: XCTestExpectation
    }
    let sessions = GladiaFakeSessions()
    let sockets = GladiaFakeSocketFactory()
    let clock = GladiaManualClock()
    let log = GladiaEventLog()
    let client: GladiaLiveClient
    private let stopGrace: TimeInterval

    init(grace: TimeInterval = 0, window: TimeInterval? = nil, sampleRate: Int = 16_000) {
        stopGrace = Self.options(grace: grace, window: window).stopGracePeriod
        client = GladiaLiveClient(
            apiKey: "synthetic-key", sampleRate: sampleRate,
            options: Self.options(grace: grace, window: window),
            initiateSession: sessions.initiator, makeConnection: sockets.connectionFactory, schedule: clock.scheduler
        )
    }

    static func options(grace: TimeInterval, window: TimeInterval?) -> LiveClientOptions {
        LiveClientOptions(
            keywords: [], assemblyAIKeyterms: [], modulate: .none,
            postStopFinalizeBudget: window, stopGracePeriod: grace
        )
    }

    func start(open: Bool = true) {
        client.start(onTranscript: { [log] in log.transcript($0, isFinal: $1) }, onError: { [log] in log.fail($0) })
        if open { sessions.grant(); sockets.sockets.last?.open() }
    }

    func beginFinish(in test: XCTestCase) async throws -> Finish {
        let admission = GladiaFinishAdmission()
        clock.whenScheduled(GladiaConfiguredTiming.drain) { admission.signal() }
        if stopGrace > 0, stopGrace != GladiaConfiguredTiming.drain {
            clock.whenScheduled(stopGrace) { admission.signal() }
        }
        let finish = ownFinish(in: test)
        guard await XCTWaiter.fulfillment(of: [admission.entered], timeout: 2) == .completed else {
            finish.task.cancel(); client.cancel()
            XCTFail("Configured finish did not arm its first active phase")
            throw Timeout()
        }
        return finish
    }

    func ownFinish(in test: XCTestCase) -> Finish {
        let done = XCTestExpectation(description: "configured finish returned")
        let exited = XCTestExpectation(description: "owned configured finish exited")
        let client = client
        let task = Task {
            defer { exited.fulfill() }
            let result = await client.finishAndWait()
            done.fulfill()
            return result
        }
        test.addTeardownBlock {
            task.cancel(); client.cancel()
            let outcome = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
            XCTAssertEqual(outcome, .completed)
        }
        return Finish(task: task, done: done, exited: exited)
    }

    func result(_ finish: Finish) async throws -> String? {
        guard await XCTWaiter.fulfillment(of: [finish.done], timeout: 2) == .completed else {
            finish.task.cancel(); client.cancel()
            XCTFail("Configured finish did not settle")
            throw Timeout()
        }
        return await finish.task.value
    }

    struct Timeout: Error {}
}

/// A drain can immediately advance before effects execute; observe whichever
/// active phase really arms first, without registering a teardown-only signal.
private final class GladiaFinishAdmission: @unchecked Sendable {
    let entered = XCTestExpectation(description: "configured finish admission armed an active phase")
    private let lock = NSLock()
    private var signalled = false

    func signal() {
        let first = lock.withLock {
            guard !signalled else { return false }
            signalled = true
            return true
        }
        if first { entered.fulfill() }
    }
}
