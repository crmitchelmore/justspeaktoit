import Foundation
@testable import SpeakCore
import XCTest

final class CartesiaLiveClientTests: XCTestCase {
    func testWebSocketURL_usesTurnsEndpointAndInk2Parameters() throws {
        let socket = TestLiveWebSocket()
        let factory = TestSocketFactory([socket])
        let client = makeClient(factory)
        let request = try XCTUnwrap(client.makeRequest())
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map {
            ($0.name, $0.value ?? "")
        })

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.cartesia.ai")
        XCTAssertEqual(components.path, "/stt/turns/websocket")
        XCTAssertEqual(query["model"], "ink-2")
        XCTAssertEqual(query["encoding"], "pcm_s16le")
        XCTAssertEqual(query["sample_rate"], "16000")
        XCTAssertEqual(query["cartesia_version"], CartesiaLiveClient.apiVersion)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Cartesia-Version"), CartesiaLiveClient.apiVersion
        )
    }

    func testTranscriptEvent_turnUpdateProducesPartial() {
        let event = CartesiaLiveClient.transcriptEvent(
            from: #"{"type":"turn.update","results":[{"transcript":"book a table"}]}"#
        )
        XCTAssertEqual(event?.text, "book a table")
        XCTAssertEqual(event?.isFinal, false)
    }

    func testTranscriptEvent_turnEndProducesFinal() {
        let event = CartesiaLiveClient.transcriptEvent(
            from: #"{"type":"turn.end","results":[{"transcript":"book a table for two"}]}"#
        )
        XCTAssertEqual(event?.text, "book a table for two")
        XCTAssertEqual(event?.isFinal, true)
    }

    func testTranscriptEvent_ignoresEmptyTranscript() {
        let json = #"{"type":"turn.update","results":[{"transcript":""}]}"#
        XCTAssertNil(CartesiaLiveClient.transcriptEvent(from: json))
    }

    func testTranscriptEventAcceptsTopLevelAndIgnoresLifecycleEvents() {
        XCTAssertEqual(
            CartesiaLiveClient.transcriptEvent(
                from: #"{"type":"transcript","transcript":"top level"}"#
            )?.text,
            "top level"
        )
        XCTAssertNil(CartesiaLiveClient.transcriptEvent(
            from: #"{"type":"turn.resume","transcript":"do not replace"}"#
        ))
        XCTAssertNil(CartesiaLiveClient.transcriptEvent(
            from: #"{"type":"connected","transcript":"not speech"}"#
        ))
    }

    /// Error frames become typed failures: a rejected key is recognised, and
    /// any other provider error keeps its status and message.
    func testProviderErrorPreservesStatusAndMessage() {
        func error(_ json: String) -> Error? {
            guard case .failure(let failure)? = CartesiaTurnEvent(data: Data(json.utf8)) else { return nil }
            return CartesiaLiveProtocol.error(for: failure)
        }

        let limited = error(#"{"type":"error","status_code":429,"message":"denied"}"#)
        XCTAssertEqual(
            limited as? CartesiaStreamingError, .server(statusCode: 429, code: nil, message: "denied")
        )
        XCTAssertEqual(limited?.localizedDescription.contains("denied"), true)
        let rejected = error(#"{"type":"error","status_code":403,"message":"denied"}"#)
        guard case .invalidAPIKey? = rejected as? StreamingClientError else {
            return XCTFail("403 must be a rejected key")
        }
    }

    /// Capture frames reach the socket byte-for-byte, in order and unrepacked;
    /// a frame of partial samples is refused before it could misalign them.
    func testPCMIsSentAsCapturedWithoutRepacking() async {
        let socket = TestLiveWebSocket()
        let client = makeClient(TestSocketFactory([socket]), sampleRate: 1_000)
        let lock = NSLock()
        var errors: [Error] = []
        client.start(onTranscript: { _, _ in }, onError: { error in lock.withLock { errors.append(error) } })
        let frames = [Data(repeating: 1, count: 98), Data(repeating: 2, count: 152), Data(repeating: 3, count: 120)]
        frames.forEach(client.sendAudio)
        let didSend = await eventually { socket.messages.count == 3 }
        XCTAssertTrue(didSend)
        XCTAssertEqual(socket.messages.compactMap { if case .data(let data) = $0 { data } else { nil } }, frames)

        client.sendAudio(Data(repeating: 4, count: 99))
        let didRefuse = await eventually { lock.withLock { errors.count == 1 } }
        XCTAssertTrue(didRefuse)
        XCTAssertEqual(socket.messages.count, 3)
    }
}

extension CartesiaLiveClientTests {
    /// Audio held while the handshake is pending drains once it completes,
    /// without another capture chunk. Startup audio is bounded by the
    /// five-second admission budget, whose overflow is reported rather than
    /// trimmed (`CartesiaLiveStreamingTests`).
    func testDelayedTransportDrainsBoundedStartupAudioWithoutAnotherCaptureChunk() async {
        let socket = TestLiveWebSocket()
        socket.automaticallyRunsOnResume = false
        let factory = TestSocketFactory([socket])
        let client = makeClient(factory, sampleRate: 1_000)
        client.start(onTranscript: { _, _ in }, onError: { _ in })

        for index in 0..<20 {
            client.sendAudio(Data(repeating: UInt8(index), count: 200))
        }
        _ = client.transcriptSnapshot(captureDuration: 0)
        XCTAssertTrue(socket.messages.isEmpty)
        socket.markRunning()

        let didDrain = await eventually { socket.messages.count == 20 }
        XCTAssertTrue(didDrain)
        guard case .data(let first) = socket.messages[0] else {
            return XCTFail("Expected startup PCM")
        }
        XCTAssertEqual(first.first, 0)
    }

    func testFinishDrainsResidualThenCloseAndConsumesLateFinals() async {
        let socket = TestLiveWebSocket()
        socket.automaticallyCompletesSends = false
        let factory = TestSocketFactory([socket])
        let client = makeClient(factory)
        let lock = NSLock()
        var callbacks: [String] = []
        var boundaries = 0
        client.onUtteranceBoundary = { _ in lock.withLock { boundaries += 1 } }
        client.start(
            onTranscript: { text, _ in lock.withLock { callbacks.append(text) } },
            onError: { _ in }
        )
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)
        client.sendAudio(Data(repeating: 4, count: 800))

        let finish = Task { await client.finishAndWait() }
        let didSendResidual = await eventually { socket.messages.count == 1 }
        XCTAssertTrue(didSendResidual)
        XCTAssertTrue(textMessages(socket).isEmpty)
        socket.completeNextSend()
        let didSendClose = await eventually {
            textMessages(socket).contains(#"{"type":"close"}"#)
        }
        XCTAssertTrue(didSendClose)
        socket.completeNextSend()
        socket.emit(Self.final("One."))
        socket.emit(Self.final("One."))
        socket.closeFromServer()

        let transcript = await finish.value
        XCTAssertEqual(transcript, "One. One.")
        XCTAssertTrue(lock.withLock { callbacks.isEmpty })
        XCTAssertEqual(lock.withLock { boundaries }, 0)
        let snapshot = client.transcriptSnapshot(captureDuration: 2)
        XCTAssertEqual(snapshot.segments.map(\.text), ["One.", "One."])
        XCTAssertNil(snapshot.duration)
        guard case .data(let residual) = socket.messages[0] else {
            return XCTFail("Expected residual PCM before close")
        }
        XCTAssertEqual(residual.count, 800, "Audio is sent as captured, not padded")
    }

    func testOrdinaryEventsKeepStandaloneCallbackShapeAndSnapshotInterim() async {
        let socket = TestLiveWebSocket()
        let factory = TestSocketFactory([socket])
        let client = makeClient(factory)
        let lock = NSLock()
        var callbacks: [(String, Bool)] = []
        client.start(
            onTranscript: { text, isFinal in lock.withLock { callbacks.append((text, isFinal)) } },
            onError: { _ in }
        )
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)
        socket.emit(Self.partial("inter"))
        socket.emit(Self.final("Final."))
        socket.emit(Self.partial("tail"))
        let didReceive = await eventually { lock.withLock { callbacks.count == 3 } }
        XCTAssertTrue(didReceive)

        XCTAssertEqual(lock.withLock { callbacks.map(\.0) }, ["inter", "Final.", "tail"])
        XCTAssertEqual(lock.withLock { callbacks.map(\.1) }, [false, true, false])
        let snapshot = client.transcriptSnapshot(captureDuration: 0)
        XCTAssertEqual(snapshot.confirmedText, "Final.")
        XCTAssertEqual(snapshot.pendingInterim, "tail")
        XCTAssertEqual(snapshot.resolvedDisplayText, "Final. tail")
        XCTAssertEqual(snapshot.segments.map(\.text), ["Final."])
    }

    /// A finish the server never closes is bounded. Only the server's normal
    /// closure completes one, so the missing completion is reported and the
    /// finish returns confirmed text only; the draft already reached the host.
    func testNoResponseFinishIsBoundedAndRetainsInterim() async {
        let socket = TestLiveWebSocket()
        let factory = TestSocketFactory([socket])
        let client = makeClient(factory)
        let lock = NSLock()
        var callbacks: [String] = []
        var errors: [Error] = []
        client.start(
            onTranscript: { text, _ in lock.withLock { callbacks.append(text) } },
            onError: { error in lock.withLock { errors.append(error) } }
        )
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)
        socket.emit(Self.partial("unfinished"))
        let didReceive = await eventually {
            client.transcriptSnapshot(captureDuration: 0).pendingInterim == "unfinished"
        }
        XCTAssertTrue(didReceive)

        let transcript = await client.finishAndWait()

        XCTAssertNil(transcript)
        XCTAssertEqual(lock.withLock { callbacks }, ["unfinished"])
        XCTAssertEqual(lock.withLock { errors }.first as? CartesiaStreamingError, .missingCompletion)
        XCTAssertEqual(textMessages(socket), [#"{"type":"close"}"#])
        XCTAssertEqual(socket.cancelCount, 1)
    }

    func testConcurrentFinishCallsShareOneCloseAndResult() async {
        let socket = TestLiveWebSocket()
        let factory = TestSocketFactory([socket])
        let client = makeClient(factory)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)
        socket.emit(Self.final("shared"))

        async let first = client.finishAndWait()
        async let second = client.finishAndWait()
        let didSendClose = await eventually { textMessages(socket).contains(#"{"type":"close"}"#) }
        XCTAssertTrue(didSendClose)
        socket.closeFromServer()
        let firstResult = await first
        let secondResult = await second

        XCTAssertEqual([firstResult, secondResult], ["shared", "shared"])
        XCTAssertEqual(textMessages(socket), [#"{"type":"close"}"#])
    }

    func testRepeatedFinishRetainsResultUntilNextStart() async {
        let firstSocket = TestLiveWebSocket()
        let secondSocket = TestLiveWebSocket()
        let factory = TestSocketFactory([firstSocket, secondSocket])
        let client = makeClient(factory)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        let didStartFirst = await eventually { firstSocket.state == .running }
        XCTAssertTrue(didStartFirst)
        firstSocket.emit(Self.final("retained"))

        let finish = Task { await client.finishAndWait() }
        let didSendClose = await eventually { textMessages(firstSocket).contains(#"{"type":"close"}"#) }
        XCTAssertTrue(didSendClose)
        firstSocket.closeFromServer()
        let firstResult = await finish.value
        let repeatedResult = await client.finishAndWait()
        XCTAssertEqual(firstResult, "retained")
        XCTAssertEqual(repeatedResult, "retained")

        client.start(onTranscript: { _, _ in }, onError: { _ in })
        let didStartSecond = await eventually { secondSocket.state == .running }
        XCTAssertTrue(didStartSecond)
        let secondResult = await client.finishAndWait()
        XCTAssertNil(secondResult)
    }
}

extension CartesiaLiveClientTests {
    func testStalledAudioSendFailsWithinInjectedBudgetWithoutSendingClose() async {
        let socket = TestLiveWebSocket()
        socket.automaticallyCompletesSends = false
        let factory = TestSocketFactory([socket])
        let lock = NSLock()
        var errors: [Error] = []
        let client = CartesiaLiveClient(
            sendBudget: 0.05,
            postStopFinalizeBudget: 0.05,
            socketFactory: factory.make
        )
        client.start(
            onTranscript: { _, _ in },
            onError: { error in lock.withLock { errors.append(error) } }
        )
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)
        client.sendAudio(Data(repeating: 1, count: 3_200))
        let didSendAudio = await eventually { socket.messages.count == 1 }
        XCTAssertTrue(didSendAudio)

        let transcript = await client.finishAndWait()

        XCTAssertNil(transcript)
        XCTAssertTrue(textMessages(socket).isEmpty)
        let didSurfaceError = await eventually { lock.withLock { errors.count == 1 } }
        XCTAssertTrue(didSurfaceError)
    }

    func testRestartIgnoresOldSocketEvents() async {
        let oldSocket = TestLiveWebSocket()
        let newSocket = TestLiveWebSocket()
        let factory = TestSocketFactory([oldSocket, newSocket])
        let client = makeClient(factory)
        let lock = NSLock()
        var callbacks: [String] = []
        client.start(
            onTranscript: { text, _ in lock.withLock { callbacks.append("old:\(text)") } },
            onError: { _ in }
        )
        let didStartOld = await eventually { oldSocket.state == .running }
        XCTAssertTrue(didStartOld)
        client.start(
            onTranscript: { text, _ in lock.withLock { callbacks.append("new:\(text)") } },
            onError: { _ in }
        )
        let didStartNew = await eventually { newSocket.state == .running }
        XCTAssertTrue(didStartNew)

        oldSocket.emit(Self.final("stale"))
        newSocket.emit(Self.partial("fresh"))
        let didReceiveFresh = await eventually { lock.withLock { callbacks == ["new:fresh"] } }
        XCTAssertTrue(didReceiveFresh)
        XCTAssertEqual(oldSocket.cancelCount, 1)
    }

    /// Bounds long enough that a scripted closure always lands inside them.
    private func makeClient(
        _ factory: TestSocketFactory,
        sampleRate: Int = 16_000
    ) -> CartesiaLiveClient {
        CartesiaLiveClient(
            sampleRate: sampleRate,
            sendBudget: 0.5,
            postStopFinalizeBudget: 0.5,
            stopGracePeriod: 0,
            socketFactory: factory.make
        )
    }

    private static func partial(_ text: String) -> String {
        #"{"type":"turn.update","results":[{"transcript":"\#(text)"}]}"#
    }

    private static func final(_ text: String) -> String {
        #"{"type":"turn.end","results":[{"transcript":"\#(text)"}]}"#
    }
}
