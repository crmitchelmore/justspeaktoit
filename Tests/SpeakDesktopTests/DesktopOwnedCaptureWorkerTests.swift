import Foundation
import XCTest
@testable import SpeakDesktop

final class OwnedNativeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    func wait() {
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

enum OwnedNativeTestError: Error, Equatable { case partialOpen, retirement }

final class OwnedNativeScript: @unchecked Sendable {
    let lock = NSLock()
    let opening = OwnedNativeGate()
    let flushing = OwnedNativeGate()
    var holdOpen = false
    var holdFlush = false
    var failOpen = false
    var retireFailures = 0
    var bridge: DesktopOwnedCaptureCallbackBridge?
    var calls: [String] = []
    var received = Data()
    var failures: [String] = []
    var retired = false
    var enteredOpen: @Sendable () -> Void = {}

    func record(_ call: String) { lock.withLock { calls.append(call) } }
    func samples(_ data: Data) { lock.withLock { received.append(data) } }
    func failure(_ message: String) { lock.withLock { failures.append(message) } }
}

struct OwnedNativeFactory: DesktopOwnedCaptureDriverFactory {
    let script: OwnedNativeScript
    func makeDriver() -> OwnedNativeDriver { OwnedNativeDriver(script: script) }
}

final class OwnedNativeDriver: DesktopOwnedCaptureDriver {
    private let script: OwnedNativeScript
    private var flushed = false
    init(script: OwnedNativeScript) { self.script = script }
    func open(bridge: DesktopOwnedCaptureCallbackBridge) throws {
        script.lock.withLock { script.bridge = bridge }
        script.record("open")
        script.enteredOpen()
        if script.holdOpen { script.opening.wait() }
        if script.failOpen { throw OwnedNativeTestError.partialOpen }
    }
    func quiesce() throws -> DesktopOwnedCaptureReceipt {
        script.record("quiesce")
        if script.holdFlush { script.flushing.wait() }
        if !flushed {
            let samples = Array(Int16(1)...Int16(73))
            samples.withUnsafeBufferPointer { script.bridge?.receivePCM($0.baseAddress, count: $0.count) }
            flushed = true
        }
        return .init(producerQuiesced: true, callbacksDrained: true, resourcesRetired: false)
    }
    func retire() throws -> DesktopOwnedCaptureReceipt {
        script.record("retire")
        let failed = script.lock.withLock {
            if script.retireFailures > 0 { script.retireFailures -= 1; return true }
            script.retired = true
            script.bridge = nil
            return false
        }
        if failed { throw OwnedNativeTestError.retirement }
        return .init(producerQuiesced: true, callbacksDrained: true, resourcesRetired: true)
    }
}

let ownedNativeIdentity = DesktopPressCaptureIdentity(
    deviceID: "synthetic", routeID: "test", profileID: "fixture", sampleRate: 24000, frameMilliseconds: 100
)

@MainActor
final class OwnedNativeFixture {
    let script = OwnedNativeScript()
    let id = UUID()
    let worker: DesktopOwnedCaptureWorker<OwnedNativeFactory>
    var pending: Task<Void, Error>?
    init() { self.worker = DesktopOwnedCaptureWorker(factory: OwnedNativeFactory(script: script)) }
    func open() async throws {
        try await worker.open(
            id: id, identity: ownedNativeIdentity, receive: { [script] in script.samples($0) },
            onFailure: { [script] in script.failure($0) }
        )
    }
    func cleanup() async {
        script.opening.release()
        script.flushing.release()
        if let pending { _ = await pending.result }
        guard script.lock.withLock({ script.bridge != nil }) else { return }
        guard !script.lock.withLock({ script.retired }) else { return }
        do {
            try await worker.close(id: id)
        } catch OwnedNativeTestError.retirement {
            // The only deliberately injected cleanup failure has one explicit retry.
            do { try await worker.close(id: id) } catch { XCTFail("Cleanup retry failed: \(error)") }
        } catch { XCTFail("Owned fixture cleanup failed: \(error)") }
    }
}

@MainActor
final class DesktopOwnedCaptureWorkerTests: XCTestCase {
    private func fixture() -> OwnedNativeFixture {
        let fixture = OwnedNativeFixture()
        addTeardownBlock { await fixture.cleanup() }
        return fixture
    }

    func testFinal73SamplesAndRetirementAreSeparateAndExactlyOnce() async throws {
        let fixture = fixture()
        try await fixture.open()
        try await fixture.worker.quiesce(id: fixture.id)
        XCTAssertEqual(fixture.script.lock.withLock { fixture.script.received.count }, 146)
        XCTAssertFalse(fixture.script.lock.withLock { fixture.script.retired })
        try await fixture.worker.quiesce(id: fixture.id)
        try await fixture.worker.close(id: fixture.id)
        XCTAssertEqual(fixture.script.lock.withLock { fixture.script.received.count }, 146)
        XCTAssertEqual(fixture.script.lock.withLock { fixture.script.calls }, ["open", "quiesce", "quiesce", "retire"])
    }

    func testPartialOpenRetainsDriverUntilExplicitClose() async throws {
        let fixture = fixture()
        fixture.script.failOpen = true
        do { try await fixture.open(); XCTFail("Partial open must throw") } catch OwnedNativeTestError.partialOpen {}
        do { try await fixture.open(); XCTFail("Owner must stay occupied") } catch DesktopPressCaptureError.occupied {}
        XCTAssertFalse(fixture.script.lock.withLock { fixture.script.retired })
        try await fixture.worker.close(id: fixture.id)
        XCTAssertTrue(fixture.script.lock.withLock { fixture.script.retired })
    }

    func testFailedRetirementRetainsExclusionAndDoesNotReplayFinalPCM() async throws {
        let fixture = fixture()
        fixture.script.retireFailures = 1
        try await fixture.open()
        try await fixture.worker.quiesce(id: fixture.id)
        do {
            try await fixture.worker.close(id: fixture.id)
            XCTFail("Retirement must fail")
        } catch OwnedNativeTestError.retirement {}
        do {
            try await fixture.open()
            XCTFail("Unsafe owner must stay occupied")
        } catch DesktopPressCaptureError.occupied {}
        try await fixture.worker.close(id: fixture.id)
        XCTAssertEqual(fixture.script.lock.withLock { fixture.script.received.count }, 146)
    }

    func testStaleIdentityCannotControlCurrentRun() async throws {
        let fixture = fixture()
        try await fixture.open()
        do {
            try await fixture.worker.quiesce(id: UUID())
            XCTFail("Stale quiesce must fail")
        } catch DesktopPressCaptureError.staleLease {}
        do {
            try await fixture.worker.close(id: UUID())
            XCTFail("Stale close must fail")
        } catch DesktopPressCaptureError.staleLease {}
        XCTAssertEqual(fixture.script.lock.withLock { fixture.script.calls }, ["open"])
        try await fixture.worker.close(id: fixture.id)
    }

    func testCancelledOpenWaiterDoesNotFreePartialOwnership() async throws {
        let fixture = fixture()
        fixture.script.holdOpen = true
        let began = expectation(description: "entered native open")
        fixture.script.enteredOpen = { began.fulfill() }
        let task = Task { try await fixture.open() }
        fixture.pending = task
        await fulfillment(of: [began], timeout: 3)
        task.cancel()
        XCTAssertFalse(fixture.script.lock.withLock { fixture.script.retired })
        fixture.script.opening.release()
        _ = await task.result
        try await fixture.worker.close(id: fixture.id)
        XCTAssertTrue(fixture.script.lock.withLock { fixture.script.retired })
    }
}
