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

    func testPersistentIgnoredReceiveFailureWhileFinishingReturnsCollectedTranscript() async {
        let socket = TestLiveWebSocket()
        // A long post-close budget proves the run ends on the lost socket
        // rather than on the finish deadline.
        let client = CartesiaLiveClient(
            postStopFinalizeBudget: 30,
            socketFactory: TestSocketFactory([socket]).make
        )
        let lock = NSLock()
        var errors: [Error] = []
        client.start(onTranscript: { _, _ in }, onError: { error in lock.withLock { errors.append(error) } })
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)
        socket.emit(#"{"type":"turn.end","results":[{"transcript":"kept"}]}"#)
        let finish = Task { await client.finishAndWait() }
        let didSendClose = await eventually { textMessages(socket).contains(#"{"type":"close"}"#) }
        XCTAssertTrue(didSendClose)

        for _ in 0..<100 { socket.failReceive(Self.notConnected) }

        let didFinish = await eventually(timeout: 3) { socket.cancelCount == 1 }
        XCTAssertTrue(didFinish)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "kept")
        XCTAssertTrue(lock.withLock { errors.isEmpty })
    }

    // MARK: - Failures and closures after `close`

    func testNetworkFailureAfterCloseIsSurfaced() async {
        let failedSocket = TestLiveWebSocket()
        let failedFactory = TestSocketFactory([failedSocket])
        let failedClient = makeClient(failedFactory)
        let lock = NSLock()
        var errors: [Error] = []
        failedClient.start(
            onTranscript: { _, _ in },
            onError: { error in lock.withLock { errors.append(error) } }
        )
        let didStart = await eventually { failedSocket.state == .running }
        XCTAssertTrue(didStart)
        let failedFinish = Task { await failedClient.finishAndWait() }
        let didSendClose = await eventually {
            textMessages(failedSocket).contains(#"{"type":"close"}"#)
        }
        XCTAssertTrue(didSendClose)
        failedSocket.failReceive(URLError(.networkConnectionLost))
        let failedTranscript = await failedFinish.value
        XCTAssertNil(failedTranscript)
        let didSurfaceError = await eventually { lock.withLock { errors.count == 1 } }
        XCTAssertTrue(didSurfaceError)
    }

    func testNormalServerCloseAfterClientCloseIsNotSurfaced() async {
        let normalSocket = TestLiveWebSocket()
        let normalFactory = TestSocketFactory([normalSocket])
        let normalClient = makeClient(normalFactory)
        let lock = NSLock()
        var errors: [Error] = []
        normalClient.start(
            onTranscript: { _, _ in },
            onError: { error in lock.withLock { errors.append(error) } }
        )
        let didStartNormal = await eventually { normalSocket.state == .running }
        XCTAssertTrue(didStartNormal)
        let normalFinish = Task { await normalClient.finishAndWait() }
        let didSendNormalClose = await eventually {
            textMessages(normalSocket).contains(#"{"type":"close"}"#)
        }
        XCTAssertTrue(didSendNormalClose)
        normalSocket.closeFromServer()
        _ = await normalFinish.value
        XCTAssertTrue(lock.withLock { errors.isEmpty })
    }

    private func makeClient(_ factory: TestSocketFactory) -> CartesiaLiveClient {
        CartesiaLiveClient(sendBudget: 0.5, postStopFinalizeBudget: 0.5, socketFactory: factory.make)
    }
}
