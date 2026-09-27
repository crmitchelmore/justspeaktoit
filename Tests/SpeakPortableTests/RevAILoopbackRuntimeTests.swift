import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The Rev.ai scenarios of `scripts/websocket-loopback-probe.py` over the Apple
/// default transport (`URLSessionStreamingConnection`); `RevAIWinHTTPRuntimeTests`
/// runs the same scenarios over WinHTTP. The client's own path and query reach
/// the peer; only the origin is redirected. Enabled only with the
/// standard-library loopback peer: the access token is a synthetic marker and
/// no credential, provider or external network is involved. FoundationNetworking
/// is not a qualified WebSocket transport for any host, so it is skipped there.
final class RevAILoopbackRuntimeTests: XCTestCase {
    func testAudioWaitsForConnectedAndTheStreamCompletesOnTheNormalClosureAfterEOS() async throws {
        let harness = try RevAILoopbackHarness(scenario: "complete")
        defer { harness.invalidate() }
        await harness.streamUntilTheLiveFinal(self)
        let began = Date()
        let transcript = await harness.finish()
        XCTAssertLessThan(Date().timeIntervalSince(began), RevAIStreaming.finishBudget,
                          "The closure, not the deadline, completes a healthy finish")
        XCTAssertEqual(transcript.map { Array($0.unicodeScalars) }, Array(RevAILoopback.whole.unicodeScalars))
        XCTAssertEqual(harness.entries, [
            .transcript(RevAILoopback.partial, final: false), .transcript(RevAILoopback.final, final: true),
            .finished(RevAILoopback.whole)
        ], "The tail answering EOS is returned once, not also delivered")
        XCTAssertEqual(harness.binary, RevAILoopback.frames, "100 ms frames leave byte for byte, in capture order")
        XCTAssertEqual(harness.texts, ["EOS"])
        XCTAssertFalse(harness.sentBeforeConnected, "Audio waits for Rev.ai's connected message")
    }

    func testExhaustedCreditMidStreamIsReportedWithTheConfirmedTextKept() async throws {
        let harness = try RevAILoopbackHarness(scenario: "credits")
        defer { harness.invalidate() }
        await harness.streamUntilTheError(self)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, RevAILoopback.final)
        XCTAssertEqual(harness.entries, [
            .transcript(RevAILoopback.partial, final: false), .transcript(RevAILoopback.final, final: true),
            .error("insufficientCredits"), .finished(RevAILoopback.final)
        ], "The status reaches the client through the transport's close reporting")
    }

    func testNormalClosureBeforeEOSIsAnEarlyEndNeverACompletion() async throws {
        let harness = try RevAILoopbackHarness(scenario: "early")
        defer { harness.invalidate() }
        await harness.streamUntilTheError(self)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, RevAILoopback.final)
        XCTAssertEqual(harness.entries, [
            .transcript(RevAILoopback.partial, final: false), .transcript(RevAILoopback.final, final: true),
            .error("unexpectedCompletion"), .finished(RevAILoopback.final)
        ])
        XCTAssertTrue(harness.texts.isEmpty, "The stream had already ended, so EOS is never sent")
    }

    func testDroppedConnectionAfterEOSIsAFailureThatKeepsTheFlushedFinal() async throws {
        let harness = try RevAILoopbackHarness(scenario: "abrupt")
        defer { harness.invalidate() }
        await harness.streamUntilTheLiveFinal(self)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, RevAILoopback.whole, "A final is confirmed text even without the closure")
        let entries = harness.entries
        XCTAssertEqual(Array(entries.prefix(3)), [
            .transcript(RevAILoopback.partial, final: false), .transcript(RevAILoopback.final, final: true),
            .transcript(RevAILoopback.tailFinal, final: true)
        ], "The withheld tail reaches the host before the error")
        XCTAssertEqual(entries.last, .finished(RevAILoopback.whole))
        guard entries.count == 5 else { return XCTFail("Unexpected outcome for a dropped connection: \(entries)") }
        XCTAssertTrue([RevAILoopbackEntry.error("transport"), .error("closed(closeCode: 1006)")].contains(entries[3]),
                      "A connection that drops without a close frame never completes the stream: \(entries)")
    }

    func testNormalClosureWithTheLastPartialUnconfirmedIsReportedWithIt() async throws {
        let harness = try RevAILoopbackHarness(scenario: "incomplete")
        defer { harness.invalidate() }
        await harness.streamUntilTheLiveFinal(self)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, RevAILoopback.final)
        XCTAssertEqual(harness.entries, [
            .transcript(RevAILoopback.partial, final: false), .transcript(RevAILoopback.final, final: true),
            .transcript(RevAILoopback.tailPartial, final: false), .error("incompleteSegment"),
            .finished(RevAILoopback.final)
        ])
    }

    func testCancellingAnUnansweredFinishReleasesItPromptlyWithoutAnError() async throws {
        let harness = try RevAILoopbackHarness(scenario: "hold")
        defer { harness.invalidate() }
        await harness.streamUntilTheLiveFinal(self)
        let delivered = expectation(description: "EOS completed by the transport")
        harness.onEndOfStreamDelivered { delivered.fulfill() }
        let finish = Task { await harness.finish() }
        await fulfillment(of: [delivered], timeout: 10)
        let cancelled = Date()
        finish.cancel()
        let transcript = await finish.value
        XCTAssertEqual(transcript, RevAILoopback.final)
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 2, "Cancellation must not wait out the finish budget")
        XCTAssertEqual(harness.entries.last, .finished(RevAILoopback.final))
        XCTAssertFalse(harness.entries.contains { if case .error = $0 { true } else { false } },
                       "Cancellation is not a provider failure")
    }
}

/// Mirrors the peer's REVAI_* constants, scalar for scalar.
private enum RevAILoopback {
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

private enum RevAILoopbackEntry: Equatable {
    case transcript(String, final: Bool)
    case error(String)
    case finished(String?)
}

private final class RevAILoopbackHarness: @unchecked Sendable {
    let client: RevAILiveClient
    private let session: URLSession
    private let lock = NSLock()
    private var entriesValue: [RevAILoopbackEntry] = []
    private var sent: [StreamingWebSocketMessage] = []
    private var connected = false
    private var sentBeforeConnectedValue = false
    private var finalObserver: (@Sendable () -> Void)?
    private var errorObserver: (@Sendable () -> Void)?
    private var endOfStreamObserver: (@Sendable () -> Void)?

    var entries: [RevAILoopbackEntry] { lock.withLock { entriesValue } }
    var sentBeforeConnected: Bool { lock.withLock { sentBeforeConnectedValue } }
    var binary: [Data] {
        lock.withLock { sent.compactMap { if case .binary(let data) = $0 { data } else { nil } } }
    }
    var texts: [String] {
        lock.withLock { sent.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    }

    init(scenario: String) throws {
        #if canImport(FoundationNetworking)
        throw XCTSkip("FoundationNetworking is not a qualified WebSocket transport; Windows uses WinHTTP.")
        #else
        guard let value = ProcessInfo.processInfo.environment["JSTI_WEBSOCKET_PROBE_PORT"] else {
            throw XCTSkip("Set JSTI_WEBSOCKET_PROBE_PORT only with the local WebSocket probe server.")
        }
        let port = try XCTUnwrap(UInt16(value))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        self.session = session
        let observed = RevAIObservedTransport()
        client = RevAILiveClient(accessToken: RevAILoopback.token, language: "fr_FR", makeConnection: { request in
            var local = request
            var components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            components?.scheme = "ws"
            components?.host = "127.0.0.1"
            components?.port = Int(port)
            local.url = components?.url
            local.setValue("local-only", forHTTPHeaderField: "X-JSTI-Probe")
            local.setValue("jsti-probe", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            local.setValue(scenario, forHTTPHeaderField: "X-JSTI-RevAI-Scenario")
            return RevAIObservedConnection(URLSessionStreamingConnection(session: session, request: local), observed)
        })
        observed.harness = self
        #endif
    }

    func invalidate() {
        client.cancel()
        session.invalidateAndCancel()
    }

    func onEndOfStreamDelivered(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { endOfStreamObserver = observer }
    }

    func start() {
        client.start(onTranscript: { [weak self] text, isFinal in
            guard let self else { return }
            self.record(.transcript(text, final: isFinal))
            if isFinal { self.lock.withLock { self.finalObserver }?() }
        }, onError: { [weak self] error in
            guard let self else { return }
            // Transport errors differ by platform; the stream outcome does not.
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
        RevAILoopback.frames.forEach(client.sendAudio)
        await test.fulfillment(of: [live], timeout: 10)
        lock.withLock { finalObserver = nil }
    }

    /// Starts, offers every frame and waits for the stream's failure.
    func streamUntilTheError(_ test: XCTestCase) async {
        let failed = test.expectation(description: "The failure is published")
        lock.withLock { errorObserver = { failed.fulfill() } }
        start()
        RevAILoopback.frames.forEach(client.sendAudio)
        await test.fulfillment(of: [failed], timeout: 10)
    }

    func finish() async -> String? {
        let transcript = await client.finishAndWait()
        record(.finished(transcript))
        return transcript
    }

    fileprivate func received(_ result: Result<StreamingWebSocketMessage, Error>) {
        guard case .success(.text(let text)) = result, text.contains(#""type":"connected""#) else { return }
        lock.withLock { connected = true }
    }

    fileprivate func sending(_ message: StreamingWebSocketMessage) {
        lock.withLock {
            if !connected { sentBeforeConnectedValue = true }
            sent.append(message)
        }
    }

    fileprivate func completed(_ message: StreamingWebSocketMessage, error: Error?) {
        guard error == nil, message == .text(RevAILiveClient.endOfStreamToken) else { return }
        lock.withLock { endOfStreamObserver }?()
    }

    private func record(_ entry: RevAILoopbackEntry) { lock.withLock { entriesValue.append(entry) } }

    private static func describe(_ error: Error) -> String {
        if let live = error as? RevAILiveError { return "\(live)" }
        if let streaming = error as? RevAIStreamingError { return "\(streaming)" }
        if let shared = error as? StreamingClientError { return "\(shared)" }
        return "transport"
    }
}

private final class RevAIObservedTransport: @unchecked Sendable {
    weak var harness: RevAILoopbackHarness?
}

/// Forwards every call to the production transport unchanged, recording what
/// the shared client asked of it and what it received.
private final class RevAIObservedConnection: StreamingWebSocketConnection, @unchecked Sendable {
    private let inner: any StreamingWebSocketConnection
    private let observed: RevAIObservedTransport

    init(_ inner: any StreamingWebSocketConnection, _ observed: RevAIObservedTransport) {
        self.inner = inner
        self.observed = observed
    }

    func resume(onOpen: @escaping @Sendable () -> Void) { inner.resume(onOpen: onOpen) }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        let observed = observed
        observed.harness?.sending(message)
        inner.send(message) { error in
            observed.harness?.completed(message, error: error)
            completion(error)
        }
    }

    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        let observed = observed
        inner.receive { result in
            observed.harness?.received(result)
            completion(result)
        }
    }

    func cancel() { inner.cancel() }
}
