import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

/// The shared desktop session over the shared Cartesia client: a normal server
/// closure after `close` is the only success, every failure keeps the best
/// visible text, and a failure that is still being delivered can never be
/// overtaken by a finish reporting success.
final class CartesiaDesktopSessionTests: XCTestCase {
    private static let serverError = #"{"type":"error","status_code":500,"title":"Synthetic","message":"Synthetic"}"#

    func testSessionReturnsTheWholeTranscriptOnceTheServerClosesNormally() async throws {
        let fixture = try makeFixture()
        let session = fixture.session, socket = fixture.socket
        socket.open()
        session.sendAudio(Data(repeating: 1, count: 3_200))
        socket.completeSend()
        socket.turn("First turn.")
        XCTAssertEqual(session.snapshot().text, "First turn.")

        let finish = await finishUntilCloseSent(session, socket)
        socket.completeSend()
        socket.turn(" Second turn.")
        socket.close(code: 1_000)

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .finished)
        XCTAssertEqual(snapshot.text, "First turn. Second turn.")
        XCTAssertNil(snapshot.error)
    }

    func testDroppedConnectionAfterTheFlushFailsAndKeepsEveryWord() async throws {
        let fixture = try makeFixture()
        let session = fixture.session, socket = fixture.socket
        socket.open()
        socket.turn("First turn.")
        let finish = await finishUntilCloseSent(session, socket)
        socket.completeSend()
        socket.turn(" Second turn.")
        socket.drop()

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .failed, "A dropped connection is never a completed transcript")
        XCTAssertEqual(snapshot.text, "First turn. Second turn.", "The flushed words stay visible")
        XCTAssertNotNil(snapshot.error)
    }

    func testAbnormalCloseAfterTheFlushFails() async throws {
        let fixture = try makeFixture()
        let session = fixture.session, socket = fixture.socket
        socket.open()
        socket.turn("First turn.")
        let finish = await finishUntilCloseSent(session, socket)
        socket.completeSend()
        socket.close(code: 1_011)

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.text, "First turn.")
        XCTAssertEqual(snapshot.error, CartesiaStreamingError.closed(code: 1_011).localizedDescription)
    }

    func testSessionKeepsTheBestVisibleDraftWhenTheLastTurnIsNeverConfirmed() async throws {
        let fixture = try makeFixture()
        let session = fixture.session, socket = fixture.socket
        socket.open()
        socket.turn("Confirmed.")
        socket.event("turn.start")
        socket.event("turn.update", "Trailing")
        XCTAssertEqual(session.snapshot().text, "Confirmed. Trailing")

        let finish = await finishUntilCloseSent(session, socket)
        socket.completeSend()
        socket.event("turn.update", "Trailing words")
        socket.close(code: 1_000)

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.text, "Confirmed. Trailing words", "The flushed draft stays visible as recovery text")
        XCTAssertEqual(snapshot.error, CartesiaStreamingError.incompleteTurn.localizedDescription)
    }

    func testServerFailureDuringFinishIsReportedAndTheDraftIsKept() async throws {
        let fixture = try makeFixture()
        let session = fixture.session, socket = fixture.socket
        socket.open()
        socket.event("turn.start")
        socket.event("turn.update", "Partial words")
        let finish = await finishUntilCloseSent(session, socket)
        socket.completeSend()
        socket.emit(Self.serverError)

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.text, "Partial words")
        XCTAssertNotNil(snapshot.error)
    }

    /// A transport failure retires the run on a background thread and is still
    /// cancelling its socket when the host stops. The finish joins a terminal
    /// run whose error is not delivered yet; it must wait for that error rather
    /// than report success.
    func testFinishJoiningWhileAFailureIsDeliveredNeverReportsSuccess() async throws {
        let fixture = try makeFixture()
        let session = fixture.session, socket = fixture.socket, client = fixture.client
        socket.open()
        socket.turn("Confirmed.")
        let release = DispatchSemaphore(value: 0)
        let cancelling = expectation(description: "The failed run is cancelling its socket")
        socket.holdCancel(until: release) { cancelling.fulfill() }
        DispatchQueue.global().async { socket.emit(Self.serverError) }
        await fulfillment(of: [cancelling], timeout: 2)
        XCTAssertEqual(session.snapshot().phase, .recording, "The error has not reached the session yet")

        let finish = Task { await session.finish() }
        try await waitUntil { client.pendingFinishes == 1 }
        XCTAssertEqual(session.snapshot().phase, .finishing)
        release.signal()

        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .failed, "A premature success must never overtake the delivered error")
        XCTAssertNotNil(snapshot.error)
        XCTAssertEqual(snapshot.text, "Confirmed.")
    }

    /// The receive worker is handing a final to the session when the capture
    /// thread sends a partial sample. The capture call must not wait for the
    /// host, and the error must reach the session only after that final, or
    /// the session fails with the confirmed words missing from its text.
    func testCaptureFailureCannotOvertakeAFinalTheSessionIsReceiving() async throws {
        let option = try XCTUnwrap(
            ModelCatalog.liveTranscription.first { LiveTranscriptionRouting.route(for: $0.id)?.provider == .cartesia }
        )
        let socket = CartesiaDesktopSocket()
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: option.id, apiKey: "synthetic", makeConnection: { _ in socket }
        ) as? CartesiaLiveClient)
        let release = DispatchSemaphore(value: 0)
        let receiving = expectation(description: "The final is on its way to the session")
        let held = HeldFinalClient(inner: client, heldText: "Final words.", release: release) { receiving.fulfill() }
        let session = DesktopLiveSession(client: held)
        session.start()
        socket.open()
        DispatchQueue.global().async {
            socket.event("turn.start")
            socket.event("turn.update", "Final")
            socket.event("turn.end", "Final words.")
        }
        await fulfillment(of: [receiving], timeout: 2)
        XCTAssertEqual(session.snapshot().text, "Final")

        let returned = expectation(description: "The capture call returned without waiting for the host")
        DispatchQueue.global().async {
            session.sendAudio(Data([1, 2, 3]))
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(session.snapshot().phase, .recording, "The error waits behind the final being delivered")
        release.signal()

        try await waitUntil { session.snapshot().phase == .failed }
        let snapshot = session.snapshot()
        XCTAssertEqual(snapshot.text, "Final words.", "The confirmed words stay visible as recovery text")
        XCTAssertEqual(snapshot.error, CartesiaStreamingError.invalidPCM.localizedDescription)
        let finished = await session.finish()
        XCTAssertEqual(finished.phase, .failed, "The failed session is never reported as finished")
        XCTAssertEqual(finished.text, "Final words.")
    }

    private struct Fixture {
        let session: DesktopLiveSession
        let socket: CartesiaDesktopSocket
        let client: CartesiaLiveClient
    }

    private func makeFixture() throws -> Fixture {
        let option = try XCTUnwrap(
            ModelCatalog.liveTranscription.first { LiveTranscriptionRouting.route(for: $0.id)?.provider == .cartesia }
        )
        let socket = CartesiaDesktopSocket()
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: option.id, apiKey: "synthetic", makeConnection: { _ in socket }
        ) as? CartesiaLiveClient)
        let session = DesktopLiveSession(client: client)
        session.start()
        return Fixture(session: session, socket: socket, client: client)
    }

    private func finishUntilCloseSent(
        _ session: DesktopLiveSession, _ socket: CartesiaDesktopSocket
    ) async -> Task<DesktopLiveSession.Snapshot, Never> {
        let closeSent = expectation(description: "Close command sent after the drain")
        socket.onCloseCommand { closeSent.fulfill() }
        let finish = Task { await session.finish() }
        await fulfillment(of: [closeSent], timeout: 2)
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

/// A scripted transport: open, send completions, frames, closures and a
/// cancellation that can be held on its calling thread all happen on request.
final class CartesiaDesktopSocket: StreamingWebSocketConnection, @unchecked Sendable {
    typealias Receiver = @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void

    private struct PeerClose: StreamingWebSocketCloseReporting {
        let webSocketCloseCode: Int?
    }

    private let lock = NSLock()
    private var opener: (@Sendable () -> Void)?
    private var receiver: Receiver?
    private var buffered: [Result<StreamingWebSocketMessage, Error>] = []
    private var completions: [@Sendable (Error?) -> Void] = []
    private var closeObserver: (@Sendable () -> Void)?
    private var cancelHold: (entered: @Sendable () -> Void, release: DispatchSemaphore)?

    func resume(onOpen: @escaping @Sendable () -> Void) { lock.withLock { opener = onOpen } }
    func open() { lock.withLock { opener }?() }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        let observer = lock.withLock { () -> (@Sendable () -> Void)? in
            completions.append(completion)
            if case .text(let text) = message, text == CartesiaLiveProtocol.closeCommand { return closeObserver }
            return nil
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

    func onCloseCommand(_ observer: @escaping @Sendable () -> Void) { lock.withLock { closeObserver = observer } }

    func holdCancel(until release: DispatchSemaphore, entered: @escaping @Sendable () -> Void) {
        lock.withLock { cancelHold = (entered, release) }
    }

    func emit(_ text: String) { deliver(.success(.text(text))) }
    func close(code: Int) { deliver(.failure(PeerClose(webSocketCloseCode: code))) }
    func drop() { deliver(.failure(URLError(.networkConnectionLost))) }

    func event(_ type: String, _ transcript: String? = nil) {
        var object: [String: String] = ["type": type, "request_id": "synthetic"]
        object["transcript"] = transcript
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        emit(data.flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}")
    }

    func turn(_ text: String) {
        event("turn.start")
        event("turn.update", text)
        event("turn.end", text)
    }

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

/// Forwards every call to the real client unchanged, and only holds one final
/// on the thread delivering it before the session's own handler sees it.
private final class HeldFinalClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    private let inner: CartesiaLiveClient
    private let heldText: String
    private let release: DispatchSemaphore
    private let entered: @Sendable () -> Void

    init(
        inner: CartesiaLiveClient, heldText: String, release: DispatchSemaphore,
        entered: @escaping @Sendable () -> Void
    ) {
        self.inner = inner
        self.heldText = heldText
        self.release = release
        self.entered = entered
    }

    var finalShape: TranscriptFinalShape { inner.finalShape }
    var finalisationBudget: TimeInterval? { inner.finalisationBudget }
    var finishFlushesBufferedAudio: Bool { inner.finishFlushesBufferedAudio }

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        let heldText = heldText, release = release, entered = entered
        inner.start(onTranscript: { text, isFinal in
            if isFinal, text == heldText {
                entered()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success, "The held final was never released")
            }
            onTranscript(text, isFinal)
        }, onError: onError)
    }

    func sendAudio(_ audioData: Data) { inner.sendAudio(audioData) }
    func stop() { inner.stop() }
    func cancel() { inner.cancel() }
    func finishAndWait() async -> String? { await inner.finishAndWait() }
}
