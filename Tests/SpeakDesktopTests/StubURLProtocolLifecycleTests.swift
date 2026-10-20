import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakTestSupport

final class StubURLProtocolLifecycleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testStopAfterReset_callsOnlyCapturedCallbackExactlyOnce() async {
        let events = StubLifecycleEvents()
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { events.record("A.start") }
        StubURLProtocol.onStopLoading = { events.record("A.stop") }
        let stub = makeProtocol()
        defer { stub.stopLoading() }
        stub.startLoading()
        await stub.waitForLoadingTask()
        XCTAssertEqual(events.values, ["A.start"])

        installReplacementCallbacks(events)
        stub.stopLoading()
        stub.stopLoading()
        XCTAssertEqual(events.values, ["A.start", "A.stop"])
    }

    func testHeldHandlerAfterReset_deliversOnlyCapturedStartCallback() async {
        let events = StubLifecycleEvents()
        let gate = StubLifecycleGate()
        let entered = expectation(description: "A handler entered")
        StubURLProtocol.handler = { _ in
            events.record("A.handler")
            entered.fulfill()
            await gate.wait()
            return .hang
        }
        StubURLProtocol.onStartLoading = { events.record("A.start") }
        StubURLProtocol.onStopLoading = { events.record("A.stop") }
        let stub = makeProtocol()
        defer { stub.stopLoading() }
        stub.startLoading()
        await fulfillment(of: [entered], timeout: 2)

        installReplacementCallbacks(events)
        await gate.open()
        await stub.waitForLoadingTask()
        XCTAssertEqual(events.values, ["A.handler", "A.start"])
        stub.stopLoading()
        XCTAssertEqual(events.values, ["A.handler", "A.start", "A.stop"])
    }

    func testStopBeforeHeldHandlerReturns_cancelsOwnedTaskAndSuppressesLateStart() async {
        let events = StubLifecycleEvents()
        let gate = StubLifecycleGate()
        let entered = expectation(description: "A handler entered")
        StubURLProtocol.handler = { _ in
            events.record("A.handler")
            entered.fulfill()
            await gate.wait()
            events.record(Task.isCancelled ? "A.cancelled" : "A.notCancelled")
            return .ok(Data("late response".utf8))
        }
        StubURLProtocol.onStartLoading = { events.record("A.start") }
        StubURLProtocol.onStopLoading = { events.record("A.stop") }
        let stub = makeProtocol()
        defer { stub.stopLoading() }
        stub.startLoading()
        await fulfillment(of: [entered], timeout: 2)

        installReplacementCallbacks(events)
        stub.stopLoading()
        stub.stopLoading()
        await gate.open()
        await stub.waitForLoadingTask()
        XCTAssertEqual(events.values, ["A.handler", "A.stop", "A.cancelled"])
    }

    private func makeProtocol() -> StubURLProtocol {
        StubURLProtocol(
            request: URLRequest(url: URL(string: "https://stub.invalid/lifecycle")!),
            cachedResponse: nil,
            client: nil
        )
    }

    private func installReplacementCallbacks(_ events: StubLifecycleEvents) {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in
            events.record("B.handler")
            return .hang
        }
        StubURLProtocol.onStartLoading = { events.record("B.start") }
        StubURLProtocol.onStopLoading = { events.record("B.stop") }
    }
}

private final class StubLifecycleEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var values: [String] { lock.withLock { entries } }

    func record(_ value: String) {
        lock.withLock { entries.append(value) }
    }
}

private actor StubLifecycleGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
