import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

/// The shared desktop session over the shared Rev.ai client: the normal server
/// closure after `EOS` is the only success, every failure keeps the best
/// visible text as recovery material rather than a completed transcript, and a
/// failure that is still being delivered can never be overtaken by a finish
/// reporting success.
final class RevAIDesktopSessionTests: XCTestCase {
    func testSessionReturnsTheWholeTranscriptOnceTheServerClosesNormallyAfterEOS() async throws {
        let fixture = try makeFixture()
        let session = fixture.session, socket = fixture.socket
        socket.connected()
        session.sendAudio(Data(repeating: 1, count: 3_200))
        socket.completeSend()
        socket.finalHypothesis("First segment.")
        socket.partialHypothesis("second")
        XCTAssertEqual(session.snapshot().text, "First segment. second")

        let finish = await finishUntilEndOfStreamSent(session, socket)
        socket.completeSend()
        socket.finalHypothesis("Second segment.")
        socket.close(code: 1_000)

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .finished)
        XCTAssertEqual(snapshot.text, "First segment. Second segment.")
        XCTAssertNil(snapshot.error)
    }

    func testDroppedConnectionAfterEOSFailsAndKeepsEveryFlushedWord() async throws {
        let fixture = try makeFixture()
        let session = fixture.session, socket = fixture.socket
        streamOneConfirmedSegment(fixture, "First segment.")
        let finish = await finishUntilEndOfStreamSent(session, socket)
        socket.completeSend()
        socket.finalHypothesis("Second segment.")
        socket.drop()

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .failed, "A dropped connection is never a completed transcript")
        XCTAssertEqual(snapshot.text, "First segment. Second segment.", "The flushed words stay visible")
        XCTAssertNotNil(snapshot.error)
    }

    func testAbnormalCloseAfterEOSFailsWithItsStatus() async throws {
        let fixture = try makeFixture()
        let session = fixture.session, socket = fixture.socket
        streamOneConfirmedSegment(fixture, "First segment.")
        let finish = await finishUntilEndOfStreamSent(session, socket)
        socket.completeSend()
        socket.close(code: 1_011)

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.text, "First segment.")
        XCTAssertEqual(snapshot.error, RevAIStreamingError.closed(closeCode: 1_011).localizedDescription)
    }

    func testUnconfirmedLastPartialAtTheNormalCloseFailsAndStaysVisible() async throws {
        let fixture = try makeFixture()
        let session = fixture.session, socket = fixture.socket
        streamOneConfirmedSegment(fixture, "Confirmed.")
        let finish = await finishUntilEndOfStreamSent(session, socket)
        socket.completeSend()
        socket.partialHypothesis("trailing", "words")
        socket.close(code: 1_000)

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.text, "Confirmed. trailing words", "The flushed partial stays visible as recovery text")
        XCTAssertEqual(snapshot.error, RevAILiveError.incompleteSegment.localizedDescription)
    }

    func testExhaustedCreditWhileRecordingFailsAtOnceAndKeepsTheDraft() async throws {
        let fixture = try makeFixture()
        let session = fixture.session, socket = fixture.socket
        streamOneConfirmedSegment(fixture, "Confirmed.")
        socket.partialHypothesis("draft", "words")
        socket.close(code: 4_003)
        XCTAssertEqual(session.snapshot().phase, .failed)
        XCTAssertEqual(session.snapshot().error, RevAIStreamingError.insufficientCredits.localizedDescription)

        let finished = await session.finish()
        XCTAssertEqual(finished.phase, .failed, "The failed session is never reported as finished")
        XCTAssertEqual(finished.text, "Confirmed. draft words", "The visible draft stays the recovery text")
    }

    func testNormalCloseBeforeEOSWhileRecordingIsAFailureNotACompletion() async throws {
        let fixture = try makeFixture()
        let session = fixture.session, socket = fixture.socket
        streamOneConfirmedSegment(fixture, "Early.")
        socket.close(code: 1_000)
        XCTAssertEqual(session.snapshot().phase, .failed)
        XCTAssertEqual(session.snapshot().error, RevAILiveError.unexpectedCompletion.localizedDescription)

        let finished = await session.finish()
        XCTAssertEqual(finished.phase, .failed)
        XCTAssertEqual(finished.text, "Early.")
    }

    /// A transport failure retires the run on a background thread and is still
    /// cancelling its socket when the host stops. The finish joins a terminal
    /// run whose error is not delivered yet; it must wait for that error rather
    /// than report success.
    func testFinishJoiningWhileAFailureIsDeliveredNeverReportsSuccess() async throws {
        let fixture = try makeFixture()
        let session = fixture.session, socket = fixture.socket, client = fixture.client
        streamOneConfirmedSegment(fixture, "Confirmed.")
        let release = DispatchSemaphore(value: 0)
        let cancelling = expectation(description: "The failed run is cancelling its socket")
        socket.holdCancel(until: release) { cancelling.fulfill() }
        DispatchQueue.global().async { socket.close(code: 4_003) }
        await fulfillment(of: [cancelling], timeout: 2)
        XCTAssertEqual(session.snapshot().phase, .recording, "The error has not reached the session yet")

        let finish = Task { await session.finish() }
        try await waitUntil { client.pendingFinishes == 1 }
        XCTAssertEqual(session.snapshot().phase, .finishing)
        release.signal()

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .failed, "A premature success must never overtake the delivered error")
        XCTAssertEqual(snapshot.error, RevAIStreamingError.insufficientCredits.localizedDescription)
        XCTAssertEqual(snapshot.text, "Confirmed.")
    }

    func testCancellingDuringTheFinishIsNotAFailure() async throws {
        let fixture = try makeFixture()
        let session = fixture.session, socket = fixture.socket
        streamOneConfirmedSegment(fixture, "Confirmed.")
        let finish = await finishUntilEndOfStreamSent(session, socket)
        XCTAssertEqual(session.cancel().phase, .cancelled)

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .cancelled)
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.text, "Confirmed.")
    }

    private struct Fixture {
        let session: DesktopLiveSession
        let socket: RevAIDesktopSocket
        let client: RevAILiveClient
    }

    private func makeFixture() throws -> Fixture {
        let socket = RevAIDesktopSocket()
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: RevAIStreaming.liveCatalogID, apiKey: "synthetic", makeConnection: { _ in socket }
        ) as? RevAILiveClient)
        let session = DesktopLiveSession(client: client)
        session.start()
        return Fixture(session: session, socket: socket, client: client)
    }

    /// `connected`, one frame on the wire and one confirmed final.
    private func streamOneConfirmedSegment(_ fixture: Fixture, _ text: String) {
        fixture.socket.connected()
        fixture.session.sendAudio(Data(repeating: 1, count: 3_200))
        fixture.socket.completeSend()
        fixture.socket.finalHypothesis(text)
        XCTAssertEqual(fixture.session.snapshot().text, text)
    }

    private func finishUntilEndOfStreamSent(
        _ session: DesktopLiveSession, _ socket: RevAIDesktopSocket
    ) async -> Task<DesktopLiveSession.Snapshot, Never> {
        let sent = expectation(description: "EOS sent after the drain")
        socket.onEndOfStream { sent.fulfill() }
        let finish = Task { await session.finish() }
        await fulfillment(of: [sent], timeout: 2)
        return finish
    }

    /// Polls a condition within a bound; it never sleeps for an outcome.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition not reached", file: file, line: line)
    }
}

/// A scripted transport: send completions, frames, closures and a cancellation
/// that can be held on its calling thread all happen on request.
final class RevAIDesktopSocket: StreamingWebSocketConnection, @unchecked Sendable {
    typealias Receiver = @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void

    private struct PeerClose: StreamingWebSocketCloseReporting {
        let webSocketCloseCode: Int?
    }

    private let lock = NSLock()
    private var receiver: Receiver?
    private var buffered: [Result<StreamingWebSocketMessage, Error>] = []
    private var completions: [@Sendable (Error?) -> Void] = []
    private var endOfStreamObserver: (@Sendable () -> Void)?
    private var cancelHold: (entered: @Sendable () -> Void, release: DispatchSemaphore)?

    func resume(onOpen: @escaping @Sendable () -> Void) { onOpen() }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        let observer = lock.withLock { () -> (@Sendable () -> Void)? in
            completions.append(completion)
            guard case .text(let text) = message, text == RevAILiveClient.endOfStreamToken else { return nil }
            return endOfStreamObserver
        }
        observer?()
    }

    func receive(completion: @escaping Receiver) {
        let next = lock.withLock { () -> Result<StreamingWebSocketMessage, Error>? in
            guard buffered.isEmpty else { return buffered.removeFirst() }
            receiver = completion
            return nil
        }
        if let next { completion(next) }
    }

    func cancel() {
        if let hold = lock.withLock({ cancelHold }) {
            hold.entered()
            XCTAssertEqual(hold.release.wait(timeout: .now() + 5), .success, "A held cancel was never released")
        }
        let (pending, sends) = lock.withLock { () -> (Receiver?, [@Sendable (Error?) -> Void]) in
            defer { receiver = nil; completions = [] }
            return (receiver, completions)
        }
        pending?(.failure(CancellationError()))
        sends.forEach { $0(CancellationError()) }
    }

    func completeSend(_ error: Error? = nil) {
        let callback = lock.withLock { completions.isEmpty ? nil : completions.removeFirst() }
        callback?(error)
    }

    func onEndOfStream(_ observer: @escaping @Sendable () -> Void) { lock.withLock { endOfStreamObserver = observer } }

    func holdCancel(until release: DispatchSemaphore, entered: @escaping @Sendable () -> Void) {
        lock.withLock { cancelHold = (entered, release) }
    }

    func connected() { emit(#"{"type":"connected","id":"synthetic"}"#) }

    func partialHypothesis(_ words: String...) {
        hypothesis("partial", words.map { ["type": "text", "value": $0] })
    }

    func finalHypothesis(_ text: String) { hypothesis("final", [["type": "text", "value": text]]) }

    func close(code: Int) { deliver(.failure(PeerClose(webSocketCloseCode: code))) }
    func drop() { deliver(.failure(URLError(.networkConnectionLost))) }

    private func hypothesis(_ type: String, _ elements: [[String: String]]) {
        let object: [String: Any] = ["type": type, "ts": 0.5, "end_ts": 1.5, "elements": elements]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        emit(data.flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}")
    }

    private func emit(_ text: String) { deliver(.success(.text(text))) }

    private func deliver(_ result: Result<StreamingWebSocketMessage, Error>) {
        let callback = lock.withLock { () -> Receiver? in
            guard let armed = receiver else {
                buffered.append(result)
                return nil
            }
            receiver = nil
            return armed
        }
        callback?(result)
    }
}
