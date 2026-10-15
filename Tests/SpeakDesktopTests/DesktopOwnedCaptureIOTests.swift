import Dispatch
import Foundation
import XCTest
@testable import SpeakDesktop

@MainActor
final class DesktopOwnedCaptureIOTests: XCTestCase {
    func testBlockedNativeOpenDoesNotBlockOtherWorkerOrMainActor() async throws {
        let first = OwnedNativeFixture()
        let second = OwnedNativeFixture()
        addTeardownBlock { await first.cleanup(); await second.cleanup() }
        first.script.holdOpen = true
        let entered = expectation(description: "first native I/O open")
        first.script.enteredOpen = { entered.fulfill() }
        let opening = Task { try await first.open() }
        first.pending = opening
        await fulfillment(of: [entered], timeout: 3)
        try await second.open()
        try await second.worker.quiesce(id: second.id)
        try await second.worker.close(id: second.id)
        XCTAssertFalse(first.script.lock.withLock { first.script.retired })
        first.script.opening.release()
        try await opening.value
        try await first.worker.close(id: first.id)
    }

    func testBridgeCopiesSynchronouslyAndRejectsInvalidFramesBeforeAllocation() {
        let script = OwnedNativeScript()
        let bridge = DesktopOwnedCaptureCallbackBridge(
            id: UUID(), identity: ownedNativeIdentity,
            receive: { script.samples($0) }, onFailure: { script.failure($0) }
        )
        var samples = [Int16](repeating: 42, count: 2400)
        samples.withUnsafeBufferPointer { bridge.receivePCM($0.baseAddress, count: $0.count) }
        XCTAssertEqual(script.lock.withLock { script.received.count }, 4800)
        samples[0] = 99
        XCTAssertEqual(script.lock.withLock { script.received.first }, 42)
        bridge.receivePCM(nil, count: 1)
        samples.withUnsafeBufferPointer {
            bridge.receivePCM($0.baseAddress, count: 2401)
            bridge.receivePCM($0.baseAddress, count: -1)
            bridge.receivePCM($0.baseAddress, count: Int.max)
        }
        XCTAssertEqual(script.lock.withLock { script.received.count }, 4800)
        XCTAssertEqual(script.lock.withLock { script.failures.count }, 4)
    }

    func testTwentyMillisecondBridgeUsesNegotiatedBound() {
        let script = OwnedNativeScript()
        let identity = DesktopPressCaptureIdentity(
            deviceID: "", routeID: "fixture", profileID: "", sampleRate: 16000, frameMilliseconds: 20
        )
        let bridge = DesktopOwnedCaptureCallbackBridge(
            id: UUID(), identity: identity, receive: { script.samples($0) }, onFailure: { script.failure($0) }
        )
        let samples = [Int16](repeating: 1, count: 321)
        samples.withUnsafeBufferPointer {
            bridge.receivePCM($0.baseAddress, count: 320)
            bridge.receivePCM($0.baseAddress, count: 321)
        }
        XCTAssertEqual(script.lock.withLock { script.received.count }, 640)
        XCTAssertEqual(script.lock.withLock { script.failures.count }, 1)
    }
}
