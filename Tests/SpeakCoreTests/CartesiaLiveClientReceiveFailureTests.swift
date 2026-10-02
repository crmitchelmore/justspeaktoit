import Foundation
@testable import SpeakCore
import XCTest

/// A receive failure that `WebSocketErrorFilter` treats as ignorable (the
/// socket is not connected) is retried briefly, because ENOTCONN can be
/// spurious around the handshake, but a socket that keeps failing must reach a
/// terminal outcome instead of leaving the run current with nothing to read.
final class CartesiaLiveClientReceiveFailureTests: XCTestCase {
    private static let notConnected = NSError(domain: NSPOSIXErrorDomain, code: 57)

    func testSpuriousIgnoredReceiveFailureRearmsTheReceiveLoop() async {
        let socket = TestLiveWebSocket()
        let client = CartesiaLiveClient(socketFactory: TestSocketFactory([socket]).make)
        let lock = NSLock()
        var transcripts: [String] = []
        var errors: [Error] = []
        client.start(
            onTranscript: { text, _ in lock.withLock { transcripts.append(text) } },
            onError: { error in lock.withLock { errors.append(error) } }
        )
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)

        socket.failReceive(Self.notConnected)
        socket.emit(#"{"type":"turn.update","results":[{"transcript":"still here"}]}"#)

        let didReceive = await eventually { lock.withLock { transcripts == ["still here"] } }
        XCTAssertTrue(didReceive)
        XCTAssertTrue(lock.withLock { errors.isEmpty })
        XCTAssertEqual(socket.cancelCount, 0)
    }

    func testPersistentIgnoredReceiveFailureWhileRecordingIsReported() async {
        let socket = TestLiveWebSocket()
        let client = CartesiaLiveClient(socketFactory: TestSocketFactory([socket]).make)
        let failed = expectation(description: "lost connection reported")
        client.start(onTranscript: { _, _ in }, onError: { error in
            if case StreamingClientError.transportStalled = error { failed.fulfill() }
        })
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)

        for _ in 0..<100 { socket.failReceive(Self.notConnected) }

        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(socket.cancelCount, 1)
    }

    func testPersistentIgnoredReceiveFailureWhileFinishingReportsErrorBeforeReturningCollectedTranscript() async {
        let socket = TestLiveWebSocket()
        // A long post-close budget proves the run ends on the lost socket
        // rather than on the finish deadline.
        let client = CartesiaLiveClient(
            postStopFinalizeBudget: 30,
            socketFactory: TestSocketFactory([socket]).make
        )
        let lock = NSLock()
        var errors: [Error] = []
        var delivery: [String] = []
        client.start(onTranscript: { _, _ in }, onError: { error in
            lock.withLock { errors.append(error); delivery.append("error") }
        })
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)
        socket.emit(#"{"type":"turn.end","results":[{"transcript":"kept"}]}"#)
        let finish = Task {
            let text = await client.finishAndWait()
            lock.withLock { delivery.append("finish") }
            return text
        }
        let didSendClose = await eventually { textMessages(socket).contains(#"{"type":"close"}"#) }
        XCTAssertTrue(didSendClose)

        for _ in 0..<100 { socket.failReceive(Self.notConnected) }

        let didFinish = await eventually(timeout: 3) { socket.cancelCount == 1 }
        XCTAssertTrue(didFinish)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "kept")
        XCTAssertEqual(lock.withLock { delivery }, ["error", "finish"])
        XCTAssertEqual(lock.withLock { errors.count }, 1)
        XCTAssertEqual(lock.withLock { (errors.first as NSError?)?.domain }, NSPOSIXErrorDomain)
        XCTAssertEqual(lock.withLock { (errors.first as NSError?)?.code }, 57)
    }
}
