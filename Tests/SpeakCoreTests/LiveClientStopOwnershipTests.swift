import Foundation
@testable import SpeakCore
import XCTest

final class LiveClientStopOwnershipTests: XCTestCase {
    func testAssemblyAIStopRetainsPendingCleanupWhenOwnerReleases() async {
        let entered = expectation(description: "start entered transport factory")
        let gate = DispatchSemaphore(value: 0)
        let socket = TestLiveWebSocket()
        var client: AssemblyAILiveClient? = AssemblyAILiveClient(socketFactory: { _ in
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return socket
        })
        weak var released: AssemblyAILiveClient?
        released = client
        client?.start(onTranscript: { _, _ in }, onError: { _ in })
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(socket.state, .suspended, "the factory must still hold the serial queue")
        client?.stop()
        client?.stop()
        client = nil
        gate.signal()

        let deallocated = await eventually { released == nil }
        XCTAssertTrue(deallocated, "cleanup must release its temporary ownership")
        XCTAssertEqual(socket.cancelCount, 1, "queued repeated stops must cancel exactly once")
    }

    func testCartesiaStopRetainsPendingCleanupWhenOwnerReleases() async {
        let entered = expectation(description: "start entered transport factory")
        let gate = DispatchSemaphore(value: 0)
        let socket = TestLiveWebSocket()
        var client: CartesiaLiveClient? = CartesiaLiveClient(socketFactory: { _ in
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return socket
        })
        weak var released: CartesiaLiveClient?
        released = client
        client?.start(onTranscript: { _, _ in }, onError: { _ in })
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(socket.state, .suspended, "the factory must still hold the serial queue")
        client?.stop()
        client?.stop()
        client = nil
        gate.signal()

        let deallocated = await eventually { released == nil }
        XCTAssertTrue(deallocated, "cleanup must release its temporary ownership")
        XCTAssertEqual(socket.cancelCount, 1, "queued repeated stops must cancel exactly once")
    }
}
