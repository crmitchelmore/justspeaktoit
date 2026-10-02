import Foundation
@testable import SpeakCore
import XCTest

final class LiveClientStopOwnershipTests: XCTestCase {
    func testAssemblyAIStopOwnsImmediateCleanupWhenOwnerReleases() {
        let socket = TestLiveWebSocket()
        socket.automaticallyRunsOnResume = false
        var client: AssemblyAILiveClient? = AssemblyAILiveClient(socketFactory: { _ in socket })
        weak var released = client
        client?.start(onTranscript: { _, _ in }, onError: { _ in })
        XCTAssertEqual(socket.state, .suspended)

        // The portable client owns cleanup synchronously. In particular, a
        // queued weak capture must not defer it until after this method returns.
        client?.stop()
        XCTAssertEqual(socket.cancelCount, 1, "stop must finish cleanup before returning")
        client?.stop()
        client = nil

        XCTAssertNil(released, "cleanup must not retain the client")
        XCTAssertEqual(socket.cancelCount, 1, "repeated stop and deinit must cancel exactly once")
    }

    func testCartesiaStopOwnsImmediateCleanupWhenOwnerReleases() {
        let socket = TestLiveWebSocket()
        socket.automaticallyRunsOnResume = false
        var client: CartesiaLiveClient? = CartesiaLiveClient(socketFactory: { _ in socket })
        weak var released = client
        client?.start(onTranscript: { _, _ in }, onError: { _ in })
        XCTAssertEqual(socket.state, .suspended)

        client?.stop()
        XCTAssertEqual(socket.cancelCount, 1, "stop must perform its detached effects before returning")
        client?.stop()
        client = nil

        XCTAssertNil(released, "cleanup must not retain the client")
        XCTAssertEqual(socket.cancelCount, 1, "repeated stop and deinit must cancel exactly once")
    }
}
