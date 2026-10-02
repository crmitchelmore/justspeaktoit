import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
import SpeakWindowsPlatform

/// Drives the shared Rev.ai client over the production WinHTTP adapter against
/// the Rev.ai scenarios of `scripts/websocket-loopback-probe.py`. The client's
/// own path and query, synthetic access token included, reach the peer; only
/// the origin is redirected to loopback. No credential, microphone, provider
/// account or external network.
final class RevAIWinHTTPRuntimeTests: XCTestCase {
    func testAudioWaitsForConnectedAndTheStreamCompletesOnTheNormalClosureAfterEOS() async throws {
        let harness = try RevAIWinHTTPHarness(scenario: "complete")
        await harness.streamUntilTheLiveFinal(self)
        let began = Date()
        let transcript = await harness.finish()
        XCTAssertLessThan(Date().timeIntervalSince(began), RevAIStreaming.finishBudget,
                          "The closure, not the deadline, completes a healthy finish")
        XCTAssertEqual(transcript.map { Array($0.unicodeScalars) }, Array(RevAIWinHTTPLoopback.whole.unicodeScalars))
        XCTAssertEqual(harness.entries, [
            .transcript(RevAIWinHTTPLoopback.partial, final: false),
            .transcript(RevAIWinHTTPLoopback.final, final: true), .finished(RevAIWinHTTPLoopback.whole)
        ], "The tail answering EOS is returned once, not also delivered")
        XCTAssertEqual(harness.recorder.binary, RevAIWinHTTPLoopback.frames)
        XCTAssertEqual(harness.recorder.texts, ["EOS"])
        XCTAssertFalse(harness.recorder.sentBeforeConnected, "Audio waits for Rev.ai's connected message")
    }

    func testExhaustedCreditMidStreamIsReportedWithTheConfirmedTextKept() async throws {
        let harness = try RevAIWinHTTPHarness(scenario: "credits")
        await harness.streamUntilTheError(self)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, RevAIWinHTTPLoopback.final)
        XCTAssertEqual(harness.entries, [
            .transcript(RevAIWinHTTPLoopback.partial, final: false),
            .transcript(RevAIWinHTTPLoopback.final, final: true), .error("insufficientCredits"),
            .finished(RevAIWinHTTPLoopback.final)
        ], "The status reaches the client through the adapter's close-reporting conformance")
    }

    func testNormalClosureBeforeEOSIsAnEarlyEndNeverACompletion() async throws {
        let harness = try RevAIWinHTTPHarness(scenario: "early")
        await harness.streamUntilTheError(self)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, RevAIWinHTTPLoopback.final)
        XCTAssertEqual(harness.entries, [
            .transcript(RevAIWinHTTPLoopback.partial, final: false),
            .transcript(RevAIWinHTTPLoopback.final, final: true), .error("unexpectedCompletion"),
            .finished(RevAIWinHTTPLoopback.final)
        ])
        XCTAssertTrue(harness.recorder.texts.isEmpty, "The stream had already ended, so EOS is never sent")
    }

    func testDroppedConnectionAfterEOSIsAFailureThatKeepsTheFlushedFinal() async throws {
        let harness = try RevAIWinHTTPHarness(scenario: "abrupt")
        await harness.streamUntilTheLiveFinal(self)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, RevAIWinHTTPLoopback.whole, "A final is confirmed text even without the closure")
        let entries = harness.entries
        XCTAssertEqual(Array(entries.prefix(3)), [
            .transcript(RevAIWinHTTPLoopback.partial, final: false),
            .transcript(RevAIWinHTTPLoopback.final, final: true),
            .transcript(RevAIWinHTTPLoopback.tailFinal, final: true)
        ], "The withheld tail reaches the host before the error")
        XCTAssertEqual(entries.last, .finished(RevAIWinHTTPLoopback.whole))
        // Without a close frame the native bridge reports a failure; it must
        // never be the normal closure that completes a stream.
        guard entries.count == 5 else { return XCTFail("Unexpected outcome for a dropped connection: \(entries)") }
        XCTAssertTrue(
            [RevAIWinHTTPEntry.error("transport"), .error("closed(closeCode: 1006)")].contains(entries[3]),
            "Unexpected outcome for a dropped connection: \(entries)"
        )
    }

    func testNormalClosureWithTheLastPartialUnconfirmedIsReportedWithIt() async throws {
        let harness = try RevAIWinHTTPHarness(scenario: "incomplete")
        await harness.streamUntilTheLiveFinal(self)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, RevAIWinHTTPLoopback.final)
        XCTAssertEqual(harness.entries, [
            .transcript(RevAIWinHTTPLoopback.partial, final: false),
            .transcript(RevAIWinHTTPLoopback.final, final: true),
            .transcript(RevAIWinHTTPLoopback.tailPartial, final: false), .error("incompleteSegment"),
            .finished(RevAIWinHTTPLoopback.final)
        ])
    }

    func testCancellingAnUnansweredFinishReleasesItPromptlyWithoutAnError() async throws {
        let harness = try RevAIWinHTTPHarness(scenario: "hold")
        await harness.streamUntilTheLiveFinal(self)
        let delivered = expectation(description: "EOS completed by the native socket")
        harness.recorder.onEndOfStreamDelivered { delivered.fulfill() }
        let finish = Task { await harness.finish() }
        await fulfillment(of: [delivered], timeout: 10)
        let cancelled = Date()
        finish.cancel()
        let transcript = await finish.value
        XCTAssertEqual(transcript, RevAIWinHTTPLoopback.final)
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 2, "Cancellation must not wait out the finish budget")
        XCTAssertEqual(harness.entries.last, .finished(RevAIWinHTTPLoopback.final))
        XCTAssertFalse(harness.entries.contains { if case .error = $0 { true } else { false } },
                       "Cancellation is not a provider failure")
        XCTAssertEqual(harness.recorder.cancels, 1)
    }
}

/// Mirrors the peer's REVAI_* constants, scalar for scalar.
private enum RevAIWinHTTPLoopback {
    static let token = "loopback-synthetic-token"
    static let partial = "Bonjour caf\u{E9}"
    static let final = "Bonjour, caf\u{E9} cr\u{E8}me \u{2014} na\u{EF}ve."
    static let tailPartial = "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}"
    static let tailFinal = "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB} fin."
    static let whole = final + " " + tailFinal
    /// Ten 100 ms frames of 16 kHz PCM16 mono, generated identically by the peer.
    static let frames: [Data] = (0..<10).map { index in
        Data((0..<3_200).map { UInt8(truncatingIfNeeded: index * 11 + $0 * 17) })
    }
}

private enum RevAIWinHTTPEntry: Equatable {
    case transcript(String, final: Bool)
    case error(String)
    case finished(String?)
}

private final class RevAIWinHTTPHarness: @unchecked Sendable {
    let client: RevAILiveClient
    let recorder: RevAIWinHTTPRecorder
    private let lock = NSLock()
    private var entriesValue: [RevAIWinHTTPEntry] = []
    private var finalObserver: (@Sendable () -> Void)?
    private var errorObserver: (@Sendable () -> Void)?

    var entries: [RevAIWinHTTPEntry] { lock.withLock { entriesValue } }

    init(scenario: String) throws {
        guard let value = ProcessInfo.processInfo.environment["JSTI_WEBSOCKET_PROBE_PORT"] else {
            throw XCTSkip("Requires the bounded local WebSocket probe server.")
        }
        let port = try XCTUnwrap(UInt16(value))
        let recorder = RevAIWinHTTPRecorder()
        self.recorder = recorder
        client = RevAILiveClient(
            accessToken: RevAIWinHTTPLoopback.token, language: "fr_FR", makeConnection: { request in
                let local = RevAIWinHTTPHarness.redirect(request, port: port, scenario: scenario)
                return RevAIRecordingConnection(inner: WinHTTPStreamingConnection(request: local), recorder: recorder)
            }
        )
    }

    func start() {
        client.start(onTranscript: { [weak self] text, isFinal in
            guard let self else { return }
            self.record(.transcript(text, final: isFinal))
            if isFinal { self.lock.withLock { self.finalObserver }?() }
        }, onError: { [weak self] error in
            guard let self else { return }
            self.record(.error(Self.describe(error)))
            self.lock.withLock { self.errorObserver }?()
        })
    }

    /// Starts, offers every frame at once (before `connected` arrives), and
    /// waits for the final Rev.ai sends while audio streams.
    func streamUntilTheLiveFinal(_ test: XCTestCase) async {
        let live = test.expectation(description: "The mid-stream final is delivered live")
        lock.withLock { finalObserver = { live.fulfill() } }
        start()
        RevAIWinHTTPLoopback.frames.forEach(client.sendAudio)
        await test.fulfillment(of: [live], timeout: 10)
        lock.withLock { finalObserver = nil }
    }

    /// Starts, offers every frame and waits for the stream's failure.
    func streamUntilTheError(_ test: XCTestCase) async {
        let failed = test.expectation(description: "The failure is published")
        lock.withLock { errorObserver = { failed.fulfill() } }
        start()
        RevAIWinHTTPLoopback.frames.forEach(client.sendAudio)
        await test.fulfillment(of: [failed], timeout: 10)
    }

    func finish() async -> String? {
        let transcript = await client.finishAndWait()
        record(.finished(transcript))
        return transcript
    }

    private func record(_ entry: RevAIWinHTTPEntry) { lock.withLock { entriesValue.append(entry) } }

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
        local.setValue(scenario, forHTTPHeaderField: "X-JSTI-RevAI-Scenario")
        return local
    }

    /// Transport errors differ by platform; the stream outcome does not.
    private static func describe(_ error: Error) -> String {
        if let live = error as? RevAILiveError { return "\(live)" }
        if let streaming = error as? RevAIStreamingError { return "\(streaming)" }
        if let shared = error as? StreamingClientError { return "\(shared)" }
        return "transport"
    }
}

/// Forwards every call to the production WinHTTP adapter unchanged, recording
/// what the shared client asked of it and what it received.
private final class RevAIRecordingConnection: StreamingWebSocketConnection, @unchecked Sendable {
    private let inner: WinHTTPStreamingConnection
    private let recorder: RevAIWinHTTPRecorder

    init(inner: WinHTTPStreamingConnection, recorder: RevAIWinHTTPRecorder) {
        self.inner = inner
        self.recorder = recorder
    }

    func resume(onOpen: @escaping @Sendable () -> Void) { inner.resume(onOpen: onOpen) }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        let recorder = recorder
        recorder.sending(message)
        inner.send(message) { error in
            recorder.completed(message, error: error)
            completion(error)
        }
    }

    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        let recorder = recorder
        inner.receive { result in
            recorder.received(result)
            completion(result)
        }
    }

    func cancel() {
        recorder.cancelled()
        inner.cancel()
    }
}

private final class RevAIWinHTTPRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var connected = false
    private var sentBeforeConnectedValue = false
    private var sentValue: [StreamingWebSocketMessage] = []
    private var cancelsValue = 0
    private var endOfStreamObserver: (@Sendable () -> Void)?

    var sentBeforeConnected: Bool { lock.withLock { sentBeforeConnectedValue } }
    var cancels: Int { lock.withLock { cancelsValue } }
    var binary: [Data] {
        lock.withLock { sentValue.compactMap { if case .binary(let data) = $0 { data } else { nil } } }
    }
    var texts: [String] {
        lock.withLock { sentValue.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    }

    func onEndOfStreamDelivered(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { endOfStreamObserver = observer }
    }

    func received(_ result: Result<StreamingWebSocketMessage, Error>) {
        guard case .success(.text(let text)) = result, text.contains(#""type":"connected""#) else { return }
        lock.withLock { connected = true }
    }

    func sending(_ message: StreamingWebSocketMessage) {
        lock.withLock {
            if !connected { sentBeforeConnectedValue = true }
            sentValue.append(message)
        }
    }

    func completed(_ message: StreamingWebSocketMessage, error: Error?) {
        guard error == nil, message == .text(RevAILiveClient.endOfStreamToken) else { return }
        lock.withLock { endOfStreamObserver }?()
    }

    func cancelled() { lock.withLock { cancelsValue += 1 } }
}
