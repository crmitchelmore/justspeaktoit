import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The Ink-2 scenario of `scripts/websocket-loopback-probe.py` over the Apple
/// default transport (`URLSessionStreamingConnection`); the WinHTTP adapter runs
/// the same scenario in `CartesiaWinHTTPRuntimeTests`. Enabled only with the
/// standard-library loopback peer: no credential, provider or external network.
final class CartesiaLoopbackRuntimeTests: XCTestCase {
    func testExactPCMReachesThePeerAndTheStreamCompletesOnItsClosure() async throws {
        let harness = try CartesiaLoopbackHarness(scenario: "complete")
        defer { harness.invalidate() }
        let midStream = expectation(description: "A turn that ends while audio streams is delivered live")
        harness.onFinal { if $0 == "Grüße aus Zürich — 世界" { midStream.fulfill() } }
        harness.start()
        CartesiaLoopbackHarness.frames.forEach(harness.client.sendAudio)
        await fulfillment(of: [midStream], timeout: 10)
        let transcript = await harness.finish()
        let whole = "Grüße aus Zürich — 世界 naïve café 👩🏽‍💻"
        XCTAssertEqual(transcript, whole)
        XCTAssertEqual(harness.entries, [
            .transcript("Grüße aus", final: false), .transcript("Grüße aus Zürich — 世界", final: true),
            .finished(whole)
        ])
        XCTAssertEqual(harness.binary, CartesiaLoopbackHarness.frames)
        XCTAssertEqual(harness.texts, [#"{"type":"close"}"#])
        XCTAssertFalse(harness.sentBeforeOpen, "Audio waits for the actual handshake")
    }

    func testServerFailureIsPublishedBeforeTheFinishReturnsConfirmedText() async throws {
        let harness = try CartesiaLoopbackHarness(scenario: "failure")
        defer { harness.invalidate() }
        harness.start()
        CartesiaLoopbackHarness.frames.forEach(harness.client.sendAudio)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, "naïve café 👩🏽‍💻")
        XCTAssertEqual(harness.entries, [
            .transcript(" naïve café 👩🏽‍💻", final: true),
            .error(#"server(statusCode: Optional(500), code: Optional("loopback_failure"), "#
                + #"message: "Synthetic terminal failure")"#),
            .finished("naïve café 👩🏽‍💻")
        ])
    }

    func testClosureWithAnUnendedTurnIsReportedAndItsDraftDelivered() async throws {
        let harness = try CartesiaLoopbackHarness(scenario: "incomplete")
        defer { harness.invalidate() }
        harness.start()
        CartesiaLoopbackHarness.frames.forEach(harness.client.sendAudio)
        let transcript = await harness.finish()
        XCTAssertNil(transcript)
        XCTAssertEqual(harness.entries, [
            .transcript("Unfinished thought", final: false), .error("incompleteTurn"), .finished(nil)
        ])
    }

    func testCancellingAHeldFinishReleasesItPromptly() async throws {
        let harness = try CartesiaLoopbackHarness(scenario: "hold")
        defer { harness.invalidate() }
        let closeDelivered = expectation(description: "Close command completed by the transport")
        harness.onCloseCompleted { closeDelivered.fulfill() }
        harness.start()
        CartesiaLoopbackHarness.frames.forEach(harness.client.sendAudio)
        let finish = Task { await harness.finish() }
        await fulfillment(of: [closeDelivered], timeout: 10)
        let cancelled = Date()
        finish.cancel()
        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 2, "Cancellation must not wait out the finish budget")
        XCTAssertEqual(harness.entries, [.finished(nil)], "Cancellation is not a provider failure")
    }
}

private final class CartesiaLoopbackHarness: @unchecked Sendable {
    enum Entry: Equatable {
        case transcript(String, final: Bool)
        case error(String)
        case finished(String?)
    }

    /// Ten 100 ms frames of 16 kHz PCM16 mono, generated identically by the peer.
    static let frames: [Data] = (0..<10).map { index in
        Data((0..<3_200).map { UInt8(truncatingIfNeeded: index * 7 + $0 * 13) })
    }

    let client: CartesiaLiveClient
    private let session: URLSession
    private let lock = NSLock()
    private var entriesValue: [Entry] = []
    private var sent: [StreamingWebSocketMessage] = []
    private var isOpen = false
    private var sentBeforeOpenValue = false
    private var finalObserver: (@Sendable (String) -> Void)?
    private var closeObserver: (@Sendable () -> Void)?

    var entries: [Entry] { lock.withLock { entriesValue } }
    var sentBeforeOpen: Bool { lock.withLock { sentBeforeOpenValue } }
    var binary: [Data] {
        lock.withLock { sent.compactMap { if case .binary(let data) = $0 { data } else { nil } } }
    }
    var texts: [String] {
        lock.withLock { sent.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    }

    init(scenario: String) throws {
        guard let value = ProcessInfo.processInfo.environment["JSTI_WEBSOCKET_PROBE_PORT"] else {
            throw XCTSkip("Set JSTI_WEBSOCKET_PROBE_PORT only with the local WebSocket probe server.")
        }
        let port = try XCTUnwrap(UInt16(value))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        self.session = session
        let observed = ObservedTransport()
        client = CartesiaLiveClient(apiKey: "loopback-synthetic-key", makeConnection: { request in
            var local = request
            var components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            components?.scheme = "ws"
            components?.host = "127.0.0.1"
            components?.port = Int(port)
            local.url = components?.url
            local.setValue("local-only", forHTTPHeaderField: "X-JSTI-Probe")
            local.setValue("jsti-probe", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            local.setValue(scenario, forHTTPHeaderField: "X-JSTI-Cartesia-Scenario")
            return ObservedConnection(URLSessionStreamingConnection(session: session, request: local), observed)
        })
        observed.harness = self
    }

    func invalidate() {
        client.cancel()
        session.invalidateAndCancel()
    }

    func onFinal(_ observer: @escaping @Sendable (String) -> Void) { lock.withLock { finalObserver = observer } }
    func onCloseCompleted(_ observer: @escaping @Sendable () -> Void) { lock.withLock { closeObserver = observer } }

    func start() {
        client.start(onTranscript: { [weak self] text, isFinal in
            guard let self else { return }
            self.record(.transcript(text, final: isFinal))
            if isFinal { self.lock.withLock { self.finalObserver }?(text) }
        }, onError: { [weak self] error in
            let description: String
            if let streaming = error as? CartesiaStreamingError {
                description = "\(streaming)"
            } else {
                description = "\(type(of: error)): \(error.localizedDescription)"
            }
            self?.record(.error(description))
        })
    }

    func finish() async -> String? {
        let transcript = await client.finishAndWait()
        record(.finished(transcript))
        return transcript
    }

    fileprivate func opened() { lock.withLock { isOpen = true } }

    fileprivate func sending(_ message: StreamingWebSocketMessage) {
        lock.withLock {
            if !isOpen { sentBeforeOpenValue = true }
            sent.append(message)
        }
    }

    fileprivate func completed(_ message: StreamingWebSocketMessage, error: Error?) {
        guard error == nil, case .text = message else { return }
        lock.withLock { closeObserver }?()
    }

    private func record(_ entry: Entry) { lock.withLock { entriesValue.append(entry) } }
}

private final class ObservedTransport: @unchecked Sendable {
    weak var harness: CartesiaLoopbackHarness?
}

/// Forwards every call to the production transport unchanged, recording what
/// the shared client asked of it.
private final class ObservedConnection: StreamingWebSocketConnection, @unchecked Sendable {
    private let inner: any StreamingWebSocketConnection
    private let observed: ObservedTransport

    init(_ inner: any StreamingWebSocketConnection, _ observed: ObservedTransport) {
        self.inner = inner
        self.observed = observed
    }

    func resume(onOpen: @escaping @Sendable () -> Void) {
        let observed = observed
        inner.resume {
            observed.harness?.opened()
            onOpen()
        }
    }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        let observed = observed
        observed.harness?.sending(message)
        inner.send(message) { error in
            observed.harness?.completed(message, error: error)
            completion(error)
        }
    }

    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        inner.receive(completion: completion)
    }

    func cancel() { inner.cancel() }
}
