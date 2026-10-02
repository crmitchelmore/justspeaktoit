import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform

/// Drives the shared Azure Voice Live client, built by the desktop factory as
/// Windows builds it, over the production WinHTTP adapter against the Azure
/// scenario of `scripts/websocket-loopback-probe.py`. The client's own path,
/// query and api-key header reach the peer; only the origin is redirected to
/// loopback. No credential, microphone, provider account or external network.
final class AzureWinHTTPRuntimeTests: XCTestCase {
    func testExactPCMFlowsAndTheFinishCompletesOnceTheCommitBarrierAndItemsSettle() async throws {
        let harness = try AzureWinHTTPHarness(scenario: "complete")
        try await harness.streamUntilTheServerVADTurnArrives(self)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, AzureLoopback.whole)
        XCTAssertEqual(harness.entries, AzureLoopback.live + [.finished(AzureLoopback.whole)],
                       "The turn completing during the finish is returned once, not also delivered")
        XCTAssertEqual(harness.recorder.audio, AzureLoopback.frames)
        XCTAssertEqual(harness.recorder.types.filter { $0 != "input_audio_buffer.append" },
                       ["session.update", "input_audio_buffer.commit", "session.update"])
        XCTAssertFalse(harness.recorder.sentBeforeOpen, "Nothing is sent before the native handshake")
    }

    func testAnEmptyBufferAnswerToTheCommitStillCompletesTheFinish() async throws {
        let harness = try AzureWinHTTPHarness(scenario: "commit-empty")
        try await harness.streamUntilTheServerVADTurnArrives(self)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, AzureLoopback.vadFinal)
        XCTAssertEqual(harness.entries, AzureLoopback.live + [.finished(AzureLoopback.vadFinal)])
    }

    func testABarrierCorrelatedServerErrorIsPublishedAsAFailureBeforeTheFinishReturns() async throws {
        let harness = try AzureWinHTTPHarness(scenario: "barrier-error")
        try await harness.streamUntilTheServerVADTurnArrives(self)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, AzureLoopback.whole, "A failed finish returns confirmed text only")
        XCTAssertEqual(harness.entries, AzureLoopback.live + [
            .transcript(AzureLoopback.whole, final: true),
            .error(#"serverError(code: "server_error")"#), .finished(AzureLoopback.whole)
        ], "Withheld words reach the host, then the error, then the confirmed return")
        XCTAssertEqual(harness.recorder.cancels, 1)
    }

    func testADroppedConnectionAfterTheBarrierIsAFailure() async throws {
        let harness = try AzureWinHTTPHarness(scenario: "abrupt")
        try await harness.streamUntilTheServerVADTurnArrives(self)
        let transcript = await harness.finish()
        XCTAssertEqual(transcript, AzureLoopback.vadFinal, "Confirmed words are still returned")
        XCTAssertEqual(harness.entries, AzureLoopback.live + [.error("transport"), .finished(AzureLoopback.vadFinal)],
                       "Without an answer to the barrier the finish is a failure, never a completion")
    }

    func testCancellingAHeldFinishReleasesItPromptlyWithoutAnError() async throws {
        let harness = try AzureWinHTTPHarness(scenario: "hold")
        let barrierDelivered = expectation(description: "Finalisation barrier completed by the native socket")
        harness.recorder.onBarrierSent { barrierDelivered.fulfill() }
        try await harness.streamUntilTheServerVADTurnArrives(self)
        let finish = Task { await harness.finish() }
        await fulfillment(of: [barrierDelivered], timeout: 10)
        let cancelled = Date()
        finish.cancel()
        let transcript = await finish.value
        XCTAssertEqual(transcript, AzureLoopback.vadFinal)
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 2, "Cancellation must not wait out the finish budget")
        XCTAssertEqual(harness.entries, AzureLoopback.live + [.finished(AzureLoopback.vadFinal)],
                       "Cancellation is not a provider failure")
        XCTAssertEqual(harness.recorder.cancels, 1)
    }
}

private enum AzureLoopback {
    static let credentials = "loopback-synthetic-key:uksouth"
    static let endpoint = "https://synthetic.services.ai.azure.com"
    static let vadDraft = "Grüße aus"
    static let vadFinal = "Grüße aus Zürich — 世界"
    static let tailFinal = "naïve café 👩🏽‍💻"
    static let whole = vadFinal + " " + tailFinal
    /// What the host sees while audio streams: server VAD's draft, then its final.
    static let live: [AzureLoopbackEntry] = [.transcript(vadDraft, final: false), .transcript(vadFinal, final: true)]
    /// Ten 100 ms frames of 24 kHz PCM16 mono, generated identically by the peer.
    static let frames: [Data] = (0..<10).map { index in
        Data((0..<4_800).map { UInt8(truncatingIfNeeded: index &* 31 &+ $0 &* 7) })
    }
}

private enum AzureLoopbackEntry: Equatable {
    case transcript(String, final: Bool)
    case error(String)
    case finished(String?)
}

private final class AzureWinHTTPHarness: @unchecked Sendable {
    let client: any FinalizingStreamingTranscriptionClient
    let recorder: AzureLoopbackRecorder
    private let lock = NSLock()
    private var entriesValue: [AzureLoopbackEntry] = []
    private var finalObserver: (@Sendable (String) -> Void)?

    var entries: [AzureLoopbackEntry] { lock.withLock { entriesValue } }

    init(scenario: String) throws {
        guard let value = ProcessInfo.processInfo.environment["JSTI_WEBSOCKET_PROBE_PORT"] else {
            throw XCTSkip("Requires the bounded local WebSocket probe server.")
        }
        let port = try XCTUnwrap(UInt16(value))
        let recorder = AzureLoopbackRecorder()
        self.recorder = recorder
        client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: AzureTranscriptionModels.speechLive, apiKey: AzureLoopback.credentials,
            azureEndpoint: AzureLoopback.endpoint,
            makeConnection: { request in
                let local = AzureWinHTTPHarness.redirect(request, port: port, scenario: scenario)
                return AzureRecordingConnection(inner: WinHTTPStreamingConnection(request: local), recorder: recorder)
            }
        ))
    }

    func start() {
        client.start(onTranscript: { [weak self] text, isFinal in
            guard let self else { return }
            self.record(.transcript(text, final: isFinal))
            if isFinal { self.lock.withLock { self.finalObserver }?(text) }
        }, onError: { [weak self] error in
            self?.record(.error(Self.describe(error)))
        })
    }

    /// Streams every frame, then waits for the turn server VAD ends part way,
    /// so that turn is delivered live and never races the finish.
    func streamUntilTheServerVADTurnArrives(_ test: XCTestCase) async throws {
        let turn = test.expectation(description: "A server-VAD turn is delivered while audio streams")
        lock.withLock { finalObserver = { if $0 == AzureLoopback.vadFinal { turn.fulfill() } } }
        start()
        let client = client
        AzureLoopback.frames.forEach { client.sendAudio($0) }
        await test.fulfillment(of: [turn], timeout: 10)
    }

    func finish() async -> String? {
        let transcript = await client.finishAndWait()
        record(.finished(transcript))
        return transcript
    }

    private func record(_ entry: AzureLoopbackEntry) { lock.withLock { entriesValue.append(entry) } }

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
        local.setValue(scenario, forHTTPHeaderField: "X-JSTI-Azure-Scenario")
        return local
    }

    /// Transport errors differ by platform; the session outcome does not.
    private static func describe(_ error: Error) -> String {
        if let voiceLive = error as? AzureVoiceLiveError { return "\(voiceLive)" }
        if let speech = error as? AzureSpeechError { return "\(speech)" }
        if let shared = error as? StreamingClientError { return "\(shared)" }
        return "transport"
    }
}

/// Forwards every call to the production WinHTTP adapter unchanged, recording
/// what the shared client asked of it.
private final class AzureRecordingConnection: StreamingWebSocketConnection, @unchecked Sendable {
    private let inner: WinHTTPStreamingConnection
    private let recorder: AzureLoopbackRecorder

    init(inner: WinHTTPStreamingConnection, recorder: AzureLoopbackRecorder) {
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

private final class AzureLoopbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var sentBeforeOpenValue = false
    private var textsValue: [String] = []
    private var cancelsValue = 0
    private var barrierObserver: (@Sendable () -> Void)?

    var sentBeforeOpen: Bool { lock.withLock { sentBeforeOpenValue } }
    var cancels: Int { lock.withLock { cancelsValue } }
    var types: [String] { objects.compactMap { $0["type"] as? String } }
    var audio: [Data] {
        objects.compactMap { object in
            guard object["type"] as? String == "input_audio_buffer.append",
                  let base64 = object["audio"] as? String else { return nil }
            return Data(base64Encoded: base64)
        }
    }

    private var objects: [[String: Any]] {
        lock.withLock { textsValue }.compactMap { text in
            try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
    }

    func onBarrierSent(_ observer: @escaping @Sendable () -> Void) { lock.withLock { barrierObserver = observer } }

    func opened() { lock.withLock { isOpen = true } }

    func sending(_ message: StreamingWebSocketMessage) {
        guard case .text(let text) = message else { return }
        lock.withLock {
            if !isOpen { sentBeforeOpenValue = true }
            textsValue.append(text)
        }
    }

    func completed(_ message: StreamingWebSocketMessage, error: Error?) {
        guard error == nil, case .text(let text) = message, text.contains("\"session.update\""),
              text.contains("-barrier\"") else { return }
        lock.withLock { barrierObserver }?()
    }

    func cancelled() { lock.withLock { cancelsValue += 1 } }
}
