import Foundation
import XCTest
import SpeakDesktop
@testable import SpeakDesktopSync

/// The shared Windows/Linux sign-in listener over a synthetic `jsti_loopback_*` table.
final class DesktopNativeLoopbackListenerTests: XCTestCase {
    private struct NativeFailure: Error, Equatable { let message: String }

    /// Records what the listener asks of the fake native side.
    private final class Native: @unchecked Sendable {
        let lock = NSLock()
        var acceptResults: [Int32] = []
        var calls: [String] = []
        let listener = OpaquePointer(bitPattern: 0x10)!
        let connection = OpaquePointer(bitPattern: 0x20)!
        let body: UnsafeMutableBufferPointer<UInt8> = {
            let bytes = Array("GET /cloudkit-sign-in?ckWebAuthToken=t HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
            _ = buffer.initialize(from: bytes)
            return buffer
        }()

        deinit { body.deallocate() }

        func record(_ call: String) { lock.withLock { calls.append(call) } }

        func table(failListen: Bool = false) -> DesktopNativeLoopback {
            DesktopNativeLoopback(
                listen: { port, _, bound, error, capacity in
                    if failListen {
                        DesktopNativeStrings.copy("Address in use", into: error, capacity: capacity)
                        return nil
                    }
                    bound?.pointee = port == 0 ? 4242 : port
                    return self.listener
                },
                accept: { _, _, connection, error, capacity in
                    let result = self.lock.withLock {
                        self.acceptResults.isEmpty ? -1 : self.acceptResults.removeFirst()
                    }
                    if result == 0 { connection?.pointee = self.connection }
                    if result == -1 { DesktopNativeStrings.copy("Accept failed", into: error, capacity: capacity) }
                    return result
                },
                request: { _, count in
                    count?.pointee = self.body.count
                    return UnsafePointer(self.body.baseAddress)
                },
                peerOwner: { _ in 1 },
                respond: { _, _, count in self.record("respond \(count)"); return 0 },
                destroyConnection: { _ in self.record("destroyConnection") },
                cancel: { _ in self.record("cancel") },
                destroy: { _ in self.record("destroy") },
                failure: { NativeFailure(message: $0) }
            )
        }
    }

    func testListenFailureUsesTheHostError() {
        let native = Native()
        XCTAssertThrowsError(try DesktopNativeLoopbackListener(native: native.table(failListen: true))) {
            XCTAssertEqual($0 as? NativeFailure, NativeFailure(message: "Address in use"))
        }
    }

    func testAcceptStatusesMapToRequestTimeoutCancellationAndFailure() async throws {
        let native = Native()
        native.acceptResults = [0, 1, 3, -1]
        let listener = try DesktopNativeLoopbackListener(native: native.table())
        XCTAssertEqual(listener.port, 4242)

        let accepted = try await listener.nextRequest(within: .seconds(1))
        let connection = try XCTUnwrap(accepted)
        XCTAssertEqual(connection.head?.target, "/cloudkit-sign-in?ckWebAuthToken=t")
        XCTAssertEqual(connection.peer, .otherUser)
        connection.respond(Data("ok".utf8))
        let timedOut = try await listener.nextRequest(within: .seconds(1))
        XCTAssertNil(timedOut)
        do {
            _ = try await listener.nextRequest(within: .seconds(1))
            XCTFail("Status 3 is a cancellation")
        } catch is CancellationError {}
        do {
            _ = try await listener.nextRequest(within: .seconds(1))
            XCTFail("Status -1 is a native failure")
        } catch {
            XCTAssertEqual(error as? NativeFailure, NativeFailure(message: "Accept failed"))
        }

        listener.close()
        listener.cancel()
        listener.close()
        do {
            _ = try await listener.nextRequest(within: .seconds(1))
            XCTFail("A closed listener only cancels")
        } catch is CancellationError {}
        XCTAssertEqual(native.calls, ["respond 2", "destroyConnection", "destroy"])
    }

    func testMillisecondsClampToTheNativeRange() {
        XCTAssertEqual(DesktopNativeLoopbackListener.milliseconds(.milliseconds(1_500)), 1_500)
        XCTAssertEqual(DesktopNativeLoopbackListener.milliseconds(.seconds(-1)), 0)
        XCTAssertEqual(DesktopNativeLoopbackListener.milliseconds(.seconds(Int64.max)), Int32.max)
    }
}
