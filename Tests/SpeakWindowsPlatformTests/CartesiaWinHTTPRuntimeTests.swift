import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SpeakCore
import SpeakWindowsPlatform

/// Drives the shared Cartesia client over the production WinHTTP adapter against
/// the Ink-2 scenario of `scripts/websocket-loopback-probe.py`. The client's own
/// path, query and headers reach the peer; only the origin is redirected to
/// loopback. No credential, microphone, provider account or external network.
final class CartesiaWinHTTPRuntimeTests: XCTestCase {
    func testExactPCMReachesThePeerAndTheStreamCompletesOnItsClosure() async throws {
        let harness = try CartesiaWinHTTPHarness(scenario: "complete")
        let midStream = expectation(description: "A turn that ends while audio streams is delivered live")
        harness.onFinal { if $0 == CartesiaLoopback.turns[0].end { midStream.fulfill() } }
        harness.start()
        CartesiaLoopback.frames.forEach(harness.client.sendAudio)
        await fulfillment(of: [midStream], timeout: 10)
        let transcript = await harness.finish()
        let whole = "Grüße aus Zürich — 世界 naïve café 👩🏽‍💻"
        XCTAssertEqual(transcript, whole)
        XCTAssertEqual(harness.entries, [
            .transcript("Grüße aus", final: false), .transcript("Grüße aus Zürich — 世界", final: true),
            .finished(whole)
        ], "The turn ending after close is returned once, not also delivered")
        XCTAssertEqual(harness.recorder.binary, CartesiaLoopback.frames)
        XCTAssertEqual(harness.recorder.texts, [#"{"type":"close"}"#])
        XCTAssertFalse(harness.recorder.sentBeforeOpen, "Audio waits for the native handshake")
    }

    func testServerFailureIsPublishedBeforeTheFinishReturnsConfirmedText() async throws {
        let harness = try CartesiaWinHTTPHarness(scenario: "failure")
        harness.start()
        CartesiaLoopback.frames.forEach(harness.client.sendAudio)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, "naïve café 👩🏽‍💻")
        XCTAssertEqual(harness.entries, [
            .transcript(" naïve café 👩🏽‍💻", final: true),
            .error(#"server(statusCode: Optional(500), code: Optional("loopback_failure"), "#
                + #"message: "Synthetic terminal failure")"#),
            .finished("naïve café 👩🏽‍💻")
        ], "Withheld words reach the host, then the error, then the confirmed return")
        XCTAssertEqual(harness.recorder.binary, CartesiaLoopback.frames)
    }

    func testClosureWithAnUnendedTurnIsReportedAndItsDraftDelivered() async throws {
        let harness = try CartesiaWinHTTPHarness(scenario: "incomplete")
        harness.start()
        CartesiaLoopback.frames.forEach(harness.client.sendAudio)
        let transcript = await harness.finish()
        XCTAssertNil(transcript)
        XCTAssertEqual(harness.entries, [
            .transcript("Unfinished thought", final: false), .error("incompleteTurn"), .finished(nil)
        ])
    }

    func testDroppedConnectionAfterAValidFlushIsAFailure() async throws {
        let harness = try CartesiaWinHTTPHarness(scenario: "abrupt")
        harness.start()
        CartesiaLoopback.frames.forEach(harness.client.sendAudio)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, "naïve café 👩🏽‍💻", "Confirmed words are still returned")
        let entries = harness.entries
        XCTAssertEqual(entries.first, .transcript(" naïve café 👩🏽‍💻", final: true))
        XCTAssertEqual(entries.last, .finished("naïve café 👩🏽‍💻"))
        // Without a close frame the native bridge reports a failure; it must
        // never be the normal closure that completes a stream.
        guard entries.count == 3 else { return XCTFail("Unexpected outcome for a dropped connection: \(entries)") }
        XCTAssertTrue(
            [LoopbackEntry.error("transport"), .error("closed(code: 1006)")].contains(entries[1]),
            "Unexpected outcome for a dropped connection: \(entries)"
        )
    }

    func testAbnormalCloseAfterAValidFlushIsAFailure() async throws {
        let harness = try CartesiaWinHTTPHarness(scenario: "abnormal")
        harness.start()
        CartesiaLoopback.frames.forEach(harness.client.sendAudio)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, "naïve café 👩🏽‍💻")
        XCTAssertEqual(harness.entries, [
            .transcript(" naïve café 👩🏽‍💻", final: true), .error("closed(code: 1011)"), .finished("naïve café 👩🏽‍💻")
        ], "The status reaches the client through the adapter's close-reporting conformance")
    }

    func testCancellingAHeldFinishReleasesItPromptly() async throws {
        let harness = try CartesiaWinHTTPHarness(scenario: "hold")
        let closeDelivered = expectation(description: "Close command completed by the native socket")
        harness.recorder.onCloseCompleted { closeDelivered.fulfill() }
        harness.start()
        CartesiaLoopback.frames.forEach(harness.client.sendAudio)
        let finish = Task { await harness.finish() }
        await fulfillment(of: [closeDelivered], timeout: 10)
        let cancelled = Date()
        finish.cancel()
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 2, "Cancellation must not wait out the finish budget")
        XCTAssertEqual(harness.entries, [.finished(nil)], "Cancellation is not a provider failure")
        XCTAssertEqual(harness.recorder.cancels, 1)
    }
}

private enum CartesiaLoopback {
    static let key = "loopback-synthetic-key"
    static let turns: [(update: String, end: String)] = [
        ("Grüße aus", "Grüße aus Zürich — 世界"), (" naïve", " naïve café 👩🏽‍💻")
    ]
    /// Ten 100 ms frames of 16 kHz PCM16 mono, generated identically by the peer.
    static let frames: [Data] = (0..<10).map { index in
        Data((0..<3_200).map { UInt8(truncatingIfNeeded: index * 7 + $0 * 13) })
    }
}

private enum LoopbackEntry: Equatable {
    case transcript(String, final: Bool)
    case error(String)
    case finished(String?)
}

private final class CartesiaWinHTTPHarness: @unchecked Sendable {
    let client: CartesiaLiveClient
    let recorder: LoopbackRecorder
    private let lock = NSLock()
    private var entriesValue: [LoopbackEntry] = []
    private var finalObserver: (@Sendable (String) -> Void)?

    var entries: [LoopbackEntry] { lock.withLock { entriesValue } }

    init(scenario: String) throws {
        guard let value = ProcessInfo.processInfo.environment["JSTI_WEBSOCKET_PROBE_PORT"] else {
            throw XCTSkip("Requires the bounded local WebSocket probe server.")
        }
        let port = try XCTUnwrap(UInt16(value))
        let recorder = LoopbackRecorder()
        self.recorder = recorder
        client = CartesiaLiveClient(apiKey: CartesiaLoopback.key, makeConnection: { request in
            let local = CartesiaWinHTTPHarness.redirect(request, port: port, scenario: scenario)
            return RecordingConnection(inner: WinHTTPStreamingConnection(request: local), recorder: recorder)
        })
    }

    func onFinal(_ observer: @escaping @Sendable (String) -> Void) { lock.withLock { finalObserver = observer } }

    func start() {
        client.start(onTranscript: { [weak self] text, isFinal in
            guard let self else { return }
            self.record(.transcript(text, final: isFinal))
            if isFinal { self.lock.withLock { self.finalObserver }?(text) }
        }, onError: { [weak self] error in
            self?.record(.error(Self.describe(error)))
        })
    }

    func finish() async -> String? {
        let transcript = await client.finishAndWait()
        record(.finished(transcript))
        return transcript
    }

    private func record(_ entry: LoopbackEntry) { lock.withLock { entriesValue.append(entry) } }

    /// The client's exact path, query and headers; only the origin moves to the
    /// loopback peer, plus the probe's own marker and scenario headers.
    private static func redirect(_ request: URLRequest, port: UInt16, scenario: String) -> URLRequest {
        var local = request
        var components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        components?.scheme = "ws"
        components?.host = "127.0.0.1"
        components?.port = Int(port)
        local.url = components?.url
        local.setValue("local-only", forHTTPHeaderField: "X-JSTI-Probe")
        local.setValue("jsti-probe", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        local.setValue(scenario, forHTTPHeaderField: "X-JSTI-Cartesia-Scenario")
        return local
    }

    /// Transport errors differ by platform; the stream outcome does not.
    private static func describe(_ error: Error) -> String {
        if let streaming = error as? CartesiaStreamingError { return "\(streaming)" }
        if let shared = error as? StreamingClientError { return "\(shared)" }
        return "transport"
    }
}

/// Forwards every call to the production WinHTTP adapter unchanged, recording
/// what the shared client asked of it.
private final class RecordingConnection: StreamingWebSocketConnection, @unchecked Sendable {
    private let inner: WinHTTPStreamingConnection
    private let recorder: LoopbackRecorder

    init(inner: WinHTTPStreamingConnection, recorder: LoopbackRecorder) {
        self.inner = inner
        self.recorder = recorder
    }

    func resume(onOpen: @escaping @Sendable () -> Void) {
        let recorder = recorder
        inner.resume {
            recorder.opened()
            onOpen()
        }
    }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        let recorder = recorder
        recorder.sending(message)
        inner.send(message) { error in
            recorder.completed(message, error: error)
            completion(error)
        }
    }

    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        inner.receive(completion: completion)
    }

    func cancel() {
        recorder.cancelled()
        inner.cancel()
    }
}

private final class LoopbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var sentBeforeOpenValue = false
    private var sentValue: [StreamingWebSocketMessage] = []
    private var cancelsValue = 0
    private var closeObserver: (@Sendable () -> Void)?

    var sentBeforeOpen: Bool { lock.withLock { sentBeforeOpenValue } }
    var cancels: Int { lock.withLock { cancelsValue } }
    var binary: [Data] {
        lock.withLock { sentValue.compactMap { if case .binary(let data) = $0 { data } else { nil } } }
    }
    var texts: [String] {
        lock.withLock { sentValue.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    }

    func onCloseCompleted(_ observer: @escaping @Sendable () -> Void) { lock.withLock { closeObserver = observer } }

    func opened() { lock.withLock { isOpen = true } }

    func sending(_ message: StreamingWebSocketMessage) {
        lock.withLock {
            if !isOpen { sentBeforeOpenValue = true }
            sentValue.append(message)
        }
    }

    func completed(_ message: StreamingWebSocketMessage, error: Error?) {
        guard error == nil, case .text = message else { return }
        lock.withLock { closeObserver }?()
    }

    func cancelled() { lock.withLock { cancelsValue += 1 } }
}
