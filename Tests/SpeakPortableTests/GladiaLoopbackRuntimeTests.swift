import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The Gladia routes of `scripts/websocket-loopback-probe.py` over the Apple
/// default transports: the production session request on `URLSession`, then
/// `URLSessionStreamingConnection`. `GladiaWinHTTPRuntimeTests` runs the same
/// scenarios over WinHTTP. Enabled only with the standard-library loopback
/// peer; the key is a synthetic marker and no credential, provider or external
/// network is involved. FoundationNetworking is not a qualified WebSocket
/// transport for any host, so it is skipped there.
final class GladiaLoopbackRuntimeTests: XCTestCase {
    func testTwoStageSessionStreamsExactPCMAndCompletesOnEndSession() async throws {
        let loopback = try GladiaURLSessionLoopback(scenario: "gladia")
        defer { loopback.invalidate() }
        let firstFinal = expectation(description: "The first final arrives while streaming")
        loopback.events.onFinal = { if $0 == GladiaURLSessionLoopback.firstFinal { firstFinal.fulfill() } }
        loopback.start()
        for index in 0..<GladiaURLSessionLoopback.frameCount {
            loopback.client.sendAudio(GladiaURLSessionLoopback.pcm(index))
        }
        await fulfillment(of: [firstFinal], timeout: 10)

        let began = Date()
        let transcript = await loopback.client.finishAndWait()
        XCTAssertLessThan(Date().timeIntervalSince(began), GladiaLive.finishBudget,
                          "end_session, not the deadline, completes a healthy finish")
        let events = loopback.events
        XCTAssertTrue(events.errors.isEmpty, "\(events.errors.map(\.localizedDescription))")
        XCTAssertEqual(
            transcript.map { Data($0.utf8) },
            Data("\(GladiaURLSessionLoopback.firstFinal) \(GladiaURLSessionLoopback.tailFinal)".utf8)
        )
        XCTAssertEqual(events.partials.map { Data($0.utf8) },
                       [GladiaURLSessionLoopback.partial, GladiaURLSessionLoopback.tailPartial].map { Data($0.utf8) },
                       "Fragmented UTF-8 arrives scalar for scalar")
        XCTAssertEqual(events.finals.map { Data($0.utf8) },
                       [GladiaURLSessionLoopback.firstFinal, GladiaURLSessionLoopback.tailFinal].map { Data($0.utf8) })
        let recorder = loopback.recorder
        XCTAssertEqual(recorder.sessionRequests, 1)
        XCTAssertEqual(recorder.socketCount, 1)
        XCTAssertEqual(recorder.sentAudio, (0..<GladiaURLSessionLoopback.frameCount).map(GladiaURLSessionLoopback.pcm),
                       "100 ms frames leave byte for byte, in capture order")
        XCTAssertEqual(recorder.sentTexts, [#"{"type":"stop_recording"}"#])
    }

    func testTerminalFailureIsReportedOnceWithConfirmedTextKept() async throws {
        let loopback = try GladiaURLSessionLoopback(scenario: "gladia-failure")
        defer { loopback.invalidate() }
        let failed = expectation(description: "The failure is published")
        loopback.events.onError = { _ in failed.fulfill() }
        loopback.start()
        for index in 0..<GladiaURLSessionLoopback.frameCount {
            loopback.client.sendAudio(GladiaURLSessionLoopback.pcm(index))
        }
        await fulfillment(of: [failed], timeout: 10)

        let transcript = await loopback.client.finishAndWait()
        let events = loopback.events
        XCTAssertEqual(transcript.map { Data($0.utf8) }, Data(GladiaURLSessionLoopback.failureFinal.utf8))
        XCTAssertEqual(events.errors.count, 1)
        XCTAssertEqual(events.errors.first as? GladiaStreamingError, .connectionLost)
        XCTAssertFalse(events.errors.map(\.localizedDescription).joined().contains("token"))
        XCTAssertTrue(loopback.recorder.sentTexts.isEmpty, "A failed run sends no stop_recording")
    }

    func testCancellingWhileEndSessionIsWithheldReturnsPromptly() async throws {
        let loopback = try GladiaURLSessionLoopback(scenario: "gladia-hold")
        defer { loopback.invalidate() }
        let heldFinal = expectation(description: "The held scenario's final arrives")
        loopback.events.onFinal = { if $0 == GladiaURLSessionLoopback.heldFinal { heldFinal.fulfill() } }
        let stopSent = expectation(description: "stop_recording is handed to the socket")
        loopback.recorder.onStop = { stopSent.fulfill() }
        loopback.start()
        for index in 0..<3 { loopback.client.sendAudio(GladiaURLSessionLoopback.pcm(index)) }
        await fulfillment(of: [heldFinal], timeout: 10)
        let client = loopback.client
        let finish = Task { await client.finishAndWait() }
        await fulfillment(of: [stopSent], timeout: 10)

        let began = Date()
        client.cancel()
        let transcript = await finish.value
        XCTAssertLessThan(Date().timeIntervalSince(began), 1, "Cancellation never waits for the finish budget")
        XCTAssertEqual(transcript.map { Data($0.utf8) }, Data(GladiaURLSessionLoopback.heldFinal.utf8))
        XCTAssertTrue(loopback.events.errors.isEmpty, "An explicit cancel is not a failure")
    }

    /// Proves prompt abandonment of the in-flight session request. The finish
    /// may be cancelled before the request reaches the peer's held reply.
    func testCancellingTheFinishDuringAHeldSessionRequestOpensNothing() async throws {
        let loopback = try GladiaURLSessionLoopback(scenario: "gladia-held-session")
        defer { loopback.invalidate() }
        loopback.start()
        loopback.client.sendAudio(GladiaURLSessionLoopback.pcm(0))
        XCTAssertEqual(loopback.recorder.sessionRequests, 1, "The session request is in flight")
        let client = loopback.client
        let finish = Task { await client.finishAndWait() }

        let began = Date()
        finish.cancel()
        let transcript = await finish.value
        XCTAssertLessThan(Date().timeIntervalSince(began), 1, "The held request is abandoned, not awaited")
        XCTAssertNil(transcript)
        XCTAssertEqual(loopback.recorder.socketCount, 0)
        XCTAssertTrue(loopback.events.errors.isEmpty)
    }
}

/// One shared client wired to the loopback peer for a scenario route, with a
/// private ephemeral session for both the session request and the socket.
private final class GladiaURLSessionLoopback: @unchecked Sendable {
    static let frameCount = 10
    // Mirrors the peer's GLADIA_* constants, scalar for scalar.
    static let partial = "Caf\u{E9} \u{2014} na\u{EF}ve"
    static let firstFinal = "Caf\u{E9} \u{2014} na\u{EF}ve e\u{301} \u{1F469}\u{1F3FD}\u{200D}\u{1F4BB} \u{754C}."
    static let tailPartial = "\u{DC}bergr\u{F6}\u{DF}e"
    static let tailFinal = "\u{DC}bergr\u{F6}\u{DF}e \u{2013} \u{BD} \u{2713} \u{1F600}"
    static let failureFinal = "Vor dem Fehler \u{2014} \u{E7}a va."
    static let heldFinal = "Held \u{23F8} final."

    let recorder: GladiaURLSessionRecorder
    let events = GladiaURLSessionEvents()
    let client: GladiaLiveClient
    private let session: URLSession

    init(scenario: String) throws {
        #if canImport(FoundationNetworking)
        throw XCTSkip("FoundationNetworking is not a qualified WebSocket transport; Windows uses WinHTTP.")
        #else
        guard let value = ProcessInfo.processInfo.environment["JSTI_WEBSOCKET_PROBE_PORT"] else {
            throw XCTSkip("Requires the bounded local WebSocket probe server.")
        }
        let port = try XCTUnwrap(UInt16(value))
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(scenario)"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        let recorder = GladiaURLSessionRecorder()
        let production = GladiaLiveClient.sessionInitiator(session: session)
        self.session = session
        self.recorder = recorder
        client = GladiaLiveClient(
            apiKey: "synthetic-loopback-key", baseURL: baseURL,
            initiateSession: { request, completion in
                recorder.noteSessionRequest()
                return production(GladiaURLSessionLoopback.marked(request), completion)
            },
            makeConnection: { request in
                var marked = GladiaURLSessionLoopback.marked(request)
                marked.setValue("jsti-probe", forHTTPHeaderField: "Sec-WebSocket-Protocol")
                return recorder.record(URLSessionStreamingConnection(session: session, request: marked))
            }
        )
        #endif
    }

    func start() {
        let events = events
        client.start(
            onTranscript: { text, isFinal in events.transcript(text, isFinal: isFinal) },
            onError: { error in events.fail(error) }
        )
    }

    func invalidate() {
        client.cancel()
        session.invalidateAndCancel()
    }

    /// The peer only serves requests carrying the local-only probe marker.
    static func marked(_ request: URLRequest) -> URLRequest {
        var marked = request
        marked.setValue("local-only", forHTTPHeaderField: "X-JSTI-Probe")
        return marked
    }

    /// The same pattern the peer verifies for the frame at `index`.
    static func pcm(_ index: Int) -> Data {
        Data((0..<3_200).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ index &* 31) })
    }
}

/// Counts session requests and sockets and records every frame handed to the
/// production transport, which it wraps without changing.
private final class GladiaURLSessionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var sockets = 0
    private var messages: [StreamingWebSocketMessage] = []
    private var stopHook: (@Sendable () -> Void)?

    var sessionRequests: Int { lock.withLock { requests } }
    var socketCount: Int { lock.withLock { sockets } }
    var sentAudio: [Data] {
        lock.withLock { messages.compactMap { if case .binary(let data) = $0 { data } else { nil } } }
    }
    var sentTexts: [String] {
        lock.withLock { messages.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    }
    var onStop: (@Sendable () -> Void)? {
        get { lock.withLock { stopHook } }
        set { lock.withLock { stopHook = newValue } }
    }

    func noteSessionRequest() { lock.withLock { requests += 1 } }

    func record(_ inner: any StreamingWebSocketConnection) -> any StreamingWebSocketConnection {
        lock.withLock { sockets += 1 }
        return GladiaURLSessionRecordingConnection(inner: inner, recorder: self)
    }

    func sent(_ message: StreamingWebSocketMessage) {
        let hook = lock.withLock { () -> (@Sendable () -> Void)? in
            messages.append(message)
            guard case .text(let text) = message, text.contains("stop_recording") else { return nil }
            return stopHook
        }
        hook?()
    }
}

private final class GladiaURLSessionRecordingConnection: StreamingWebSocketConnection, @unchecked Sendable {
    private let inner: any StreamingWebSocketConnection
    private let recorder: GladiaURLSessionRecorder

    init(inner: any StreamingWebSocketConnection, recorder: GladiaURLSessionRecorder) {
        self.inner = inner
        self.recorder = recorder
    }

    func resume(onOpen: @escaping @Sendable () -> Void) { inner.resume(onOpen: onOpen) }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        recorder.sent(message)
        inner.send(message, completion: completion)
    }

    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        inner.receive(completion: completion)
    }

    func cancel() { inner.cancel() }
}

private final class GladiaURLSessionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var partialValues: [String] = []
    private var finalValues: [String] = []
    private var failures: [Error] = []
    private var finalHook: (@Sendable (String) -> Void)?
    private var errorHook: (@Sendable (Error) -> Void)?

    var partials: [String] { lock.withLock { partialValues } }
    var finals: [String] { lock.withLock { finalValues } }
    var errors: [Error] { lock.withLock { failures } }
    var onFinal: (@Sendable (String) -> Void)? {
        get { lock.withLock { finalHook } }
        set { lock.withLock { finalHook = newValue } }
    }
    var onError: (@Sendable (Error) -> Void)? {
        get { lock.withLock { errorHook } }
        set { lock.withLock { errorHook = newValue } }
    }

    func transcript(_ text: String, isFinal: Bool) {
        let hook = lock.withLock { () -> (@Sendable (String) -> Void)? in
            if isFinal { finalValues.append(text) } else { partialValues.append(text) }
            return isFinal ? finalHook : nil
        }
        hook?(text)
    }

    func fail(_ error: Error) {
        let hook = lock.withLock { () -> (@Sendable (Error) -> Void)? in
            failures.append(error)
            return errorHook
        }
        hook?(error)
    }
}
