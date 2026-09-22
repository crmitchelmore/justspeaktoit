import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

final class DesktopLiveSessionTests: XCTestCase {
    func testSessionIdentityIsStableAndStartIsOneShot() {
        let client = DesktopLiveTestClient()
        let id = UUID()
        let session = DesktopLiveSession(client: client, id: id)
        XCTAssertEqual(session.snapshot().phase, .idle)
        XCTAssertEqual(session.snapshot().revision, 0)
        session.start()
        session.start()
        XCTAssertEqual(client.starts, 1)
        XCTAssertEqual(session.snapshot().id, id)
        XCTAssertEqual(session.snapshot().phase, .recording)
        XCTAssertEqual(session.snapshot().revision, 1)
        session.cancel()
        session.start()
        XCTAssertEqual(client.starts, 1)
        XCTAssertEqual(session.snapshot().phase, .cancelled)
    }

    func testAudioIsPassedSynchronouslyOnlyWhileRecording() {
        let client = DesktopLiveTestClient()
        let session = DesktopLiveSession(client: client)
        session.sendAudio(Data([9]))
        session.start()
        session.sendAudio(Data())
        session.sendAudio(Data([0, 1, 255]))
        XCTAssertEqual(client.audio, [Data([0, 1, 255])])
        session.cancel()
        session.sendAudio(Data([8]))
        XCTAssertEqual(client.audio.count, 1)
    }

    func testStandaloneFinalsAppendRepeatedWordsAndInterimsReplace() {
        let client = DesktopLiveTestClient()
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("Yes.", final: true)
        client.emit("Yes.", final: true)
        client.emit("Maybe", final: false)
        XCTAssertEqual(session.snapshot().text, "Yes. Yes. Maybe")
        client.emit("Maybe later", final: false)
        XCTAssertEqual(session.snapshot().text, "Yes. Yes. Maybe later")
        client.emit("Later.", final: true)
        XCTAssertEqual(session.snapshot().text, "Yes. Yes. Later.")
    }

    func testCumulativeRevisionsReplaceInsteadOfAppending() {
        let client = DesktopLiveTestClient(shape: .cumulativeTranscript)
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("hello word", final: true)
        client.emit("Hello, world.", final: true)
        client.emit("Hello, world. Next", final: false)
        XCTAssertEqual(session.snapshot().text, "Hello, world. Next")
    }

    func testIdenticalInterimsDoNotPublishNewRevisions() {
        let client = DesktopLiveTestClient()
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("Working", final: false)
        let snapshot = session.snapshot()
        client.emit(" Working \n", final: false)
        XCTAssertEqual(session.snapshot(), snapshot)
    }

    func testFinishReplacesWithWholeTranscriptAndRejectsLaterAudioAndCallbacks() async {
        let client = DesktopLiveTestClient()
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("First.", final: true)
        let began = expectation(description: "Provider finalisation begins")
        client.onFinish = { began.fulfill() }
        let finish = Task { await session.finish() }
        await fulfillment(of: [began], timeout: 2)
        XCTAssertEqual(session.snapshot().phase, .finishing)
        session.sendAudio(Data([1, 2]))
        client.emit("Second.", final: true)
        client.completeFinish("First. Second. Third.")
        let result = await finish.value
        XCTAssertEqual(result.text, "First. Second. Third.")
        XCTAssertEqual(result.phase, .finished)
        XCTAssertEqual(client.finishes, 1)
        XCTAssertTrue(client.audio.isEmpty)
        client.emit("Late.", final: true)
        client.fail()
        session.cancel()
        XCTAssertEqual(session.snapshot(), result)
    }

    func testConcurrentFinishCallsShareOneProviderFinalisation() async {
        let client = DesktopLiveTestClient()
        let session = DesktopLiveSession(client: client)
        session.start()
        let began = expectation(description: "One provider finish")
        client.onFinish = { began.fulfill() }
        let first = Task { await session.finish() }
        let second = Task { await session.finish() }
        await fulfillment(of: [began], timeout: 2)
        client.completeFinish("Complete.")
        let values = await [first.value, second.value]
        XCTAssertEqual(values[0], values[1])
        XCTAssertEqual(client.finishes, 1)
    }

    func testNilAndWhitespaceFinalisationRemainEmpty() async {
        for response: String? in [nil, " \n"] {
            let client = DesktopLiveTestClient()
            let session = DesktopLiveSession(client: client)
            session.start()
            client.emit("Unconfirmed interim", final: false)
            let began = expectation(description: "Finish empty input")
            client.onFinish = { began.fulfill() }
            let finish = Task { await session.finish() }
            await fulfillment(of: [began], timeout: 2)
            client.completeFinish(response)
            let result = await finish.value
            XCTAssertEqual(result.text, "")
            XCTAssertNil(result.error)
            XCTAssertEqual(result.phase, .finished)
        }
    }

    func testFinishBeforeStartDoesNotOpenTransportOrInventText() async {
        let client = DesktopLiveTestClient()
        let session = DesktopLiveSession(client: client)
        let result = await session.finish()
        session.start()
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.phase, .finished)
        XCTAssertEqual(client.starts, 0)
        XCTAssertEqual(client.finishes, 0)
    }

    func testCancellationKeepsBestAvailableTextAndIgnoresLateCallbacks() {
        let client = DesktopLiveTestClient()
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("Final.", final: true)
        client.emit("Unfinished", final: false)
        let cancelled = session.cancel()
        XCTAssertEqual(cancelled.text, "Final. Unfinished")
        XCTAssertEqual(cancelled.phase, .cancelled)
        client.emit("Stale", final: true)
        client.fail()
        session.cancel()
        XCTAssertEqual(session.snapshot(), cancelled)
        XCTAssertEqual(client.stops, 1)
    }

    func testCancellingFinishTaskStopsClientAndKeepsCurrentText() async {
        let client = DesktopLiveTestClient()
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("Retain this", final: false)
        let began = expectation(description: "Finish pending")
        client.onFinish = { began.fulfill() }
        let finish = Task { await session.finish() }
        await fulfillment(of: [began], timeout: 2)
        finish.cancel()
        let result = await finish.value
        XCTAssertEqual(result.phase, .cancelled)
        XCTAssertEqual(result.text, "Retain this")
        XCTAssertEqual(client.stops, 1)
    }

    func testLateFinalisationCannotMutateCancelledSnapshot() async {
        let client = DesktopLiveTestClient(resumeFinishOnStop: false)
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("Current", final: false)
        let began = expectation(description: "Finish pending")
        client.onFinish = { began.fulfill() }
        let finish = Task { await session.finish() }
        await fulfillment(of: [began], timeout: 2)
        let cancelled = session.cancel()
        client.completeFinish("Late whole transcript")
        let result = await finish.value
        XCTAssertEqual(result, cancelled)
        XCTAssertEqual(session.snapshot(), cancelled)
    }

    func testFailurePreservesTextAndCannotBecomeSuccessfulAfterFinishReturns() async {
        let client = DesktopLiveTestClient(resumeFinishOnStop: false)
        let session = DesktopLiveSession(client: client)
        session.start()
        client.emit("Best available", final: false)
        let began = expectation(description: "Finish pending")
        client.onFinish = { began.fulfill() }
        let finish = Task { await session.finish() }
        await fulfillment(of: [began], timeout: 2)
        client.fail()
        let failed = session.snapshot()
        client.completeFinish("Untrusted late result")
        let result = await finish.value
        XCTAssertEqual(result, failed)
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.error, "Synthetic live failure")
        XCTAssertEqual(result.text, "Best available")
        XCTAssertEqual(session.cancel(), failed)
    }

    func testCancellationCannotBeOvertakenByAStartingClient() {
        let client = DesktopLiveTestClient()
        let session = DesktopLiveSession(client: client)
        let entered = expectation(description: "Client start entered")
        let started = expectation(description: "Client start returned")
        let cancelled = expectation(description: "Concurrent cancellation completed")
        let release = DispatchSemaphore(value: 0)
        client.onStart = {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
        }
        DispatchQueue.global().async { session.start(); started.fulfill() }
        wait(for: [entered], timeout: 2)
        DispatchQueue.global().async { session.cancel(); cancelled.fulfill() }
        release.signal()
        wait(for: [started, cancelled], timeout: 2)
        session.start()
        XCTAssertEqual(session.snapshot().phase, .cancelled)
        XCTAssertEqual(client.starts, 1)
        XCTAssertEqual(client.stops, 1)
    }

    func testActualSharedDeepgramAdmissionFailureReachesSessionWithoutQueueDeadlock() {
        let client = DeepgramLiveClient(apiKey: "synthetic", makeConnection: { _ in DesktopUnopenedSocket() })
        let session = DesktopLiveSession(client: client)
        let completed = expectation(description: "Provider queue can synchronously report bounded admission failure")
        DispatchQueue.global().async {
            session.start()
            session.sendAudio(Data(repeating: 0, count: 160_002))
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(session.snapshot().phase, .failed)
        XCTAssertNotNil(session.snapshot().error)
        XCTAssertEqual(session.snapshot().text, "")
    }

    func testSynchronousClientCallbacksCannotDeadlockStartOrAudioAdmission() {
        let client = DesktopLiveTestClient()
        let session = DesktopLiveSession(client: client)
        client.onStart = { [weak client] in client?.emit("Opening", final: false) }
        client.onAudio = { [weak client] in client?.fail() }
        let completed = expectation(description: "Synchronous provider callbacks remain safe")
        DispatchQueue.global().async {
            session.start()
            session.sendAudio(Data([1, 2]))
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(session.snapshot().phase, .failed)
        XCTAssertEqual(session.snapshot().text, "Opening")
        XCTAssertEqual(client.stops, 1)
    }
}

extension DesktopLiveSessionTests {
    func testLiveProjectionAndDescriptorsUseCanonicalCatalogueAndRoutes() throws {
        let canonical = ModelCatalog.liveTranscription.filter {
            guard let route = LiveTranscriptionRouting.route(for: $0.id) else { return false }
            return [.deepgram, .assemblyai, .openai, .speechmatics, .soniox, .elevenlabs].contains(route.provider)
                || route.modelID == XAISpeechToText.liveCatalogID
        }
        XCTAssertFalse(canonical.isEmpty)
        XCTAssertTrue(canonical.contains { $0.id == XAISpeechToText.liveCatalogID })
        XCTAssertEqual(DesktopLiveTranscription.liveModels.map(\.id), canonical.map(\.id))
        for model in canonical {
            let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: model.id))
            XCTAssertEqual(route, LiveTranscriptionRouting.route(for: model.id))
            let provider = try XCTUnwrap(DesktopLiveTranscription.provider(forID: model.id))
            XCTAssertEqual(provider.id, route.provider.rawValue)
            XCTAssertEqual(provider.apiKeyIdentifier, route.apiKeyIdentifier)
            XCTAssertEqual(provider.displayName, route.provider.displayName)
            XCTAssertEqual(provider.website, route.provider.apiKeyURL?.absoluteString)
            let client = DesktopLiveTranscription.makeClient(model: model.id, apiKey: "", makeConnection: { _ in
                fatalError("Constructing a client must not open a connection")
            })
            XCTAssertNotNil(client)
            if route.provider == .deepgram { XCTAssertTrue(client is DeepgramLiveClient) }
            if route.provider == .assemblyai { XCTAssertTrue(client is AssemblyAILiveClient) }
            if route.provider == .speechmatics { XCTAssertTrue(client is SpeechmaticsLiveClient) }
            if route.provider == .soniox { XCTAssertTrue(client is SonioxLiveClient) }
            if route.provider == .elevenlabs { XCTAssertTrue(client is ElevenLabsLiveClient) }
            if route.provider == .openai {
                XCTAssertTrue(client is OpenAIRealtimeLiveClient)
                XCTAssertEqual(route.sampleRate, OpenAIRealtimeProtocol.sampleRate)
            }
            if route.provider == .xai {
                XCTAssertEqual(model.id, XAISpeechToText.liveCatalogID)
                XCTAssertTrue(client is XAISpeechToTextLiveClient)
                XCTAssertEqual(route.sampleRate, 24_000)
            }
        }
        XCTAssertNil(DesktopLiveTranscription.route(forID: "deepgram/unknown-streaming"))
        XCTAssertNil(DesktopLiveTranscription.provider(forID: "deepgram/nova-3"))
        XCTAssertNil(DesktopLiveTranscription.route(forID: "openai/gpt-live-transcribe"))
    }

    /// Grok Voice shares the xAI provider prefix and credential with the
    /// dedicated speech-to-text stream but speaks a different protocol with no
    /// shared client, so admitting the provider wholesale would expose the
    /// wrong engine. Only the dedicated stream's identifier is a desktop route.
    func testGrokVoiceRouteStaysUnavailableInTheDesktopFactory() {
        let grokVoice = XAIVoiceModels.thinkFast2CatalogID
        XCTAssertEqual(LiveTranscriptionRouting.route(for: grokVoice)?.provider, .xai)
        XCTAssertFalse(DesktopLiveTranscription.liveModels.contains { $0.id == grokVoice })
        XCTAssertNil(DesktopLiveTranscription.route(forID: grokVoice))
        XCTAssertNil(DesktopLiveTranscription.provider(forID: grokVoice))
        XCTAssertNil(DesktopLiveTranscription.makeClient(model: grokVoice, apiKey: "", makeConnection: { _ in
            fatalError("An unavailable route must not open a connection")
        }))
        XCTAssertEqual(
            DesktopLiveTranscription.liveModels.filter { $0.id.hasPrefix("xai/") }.map(\.id),
            [XAISpeechToText.liveCatalogID]
        )
        XCTAssertEqual(DesktopLiveTranscription.provider(forID: XAISpeechToText.liveCatalogID)?.apiKeyIdentifier,
                       "xai.apiKey")
    }

}

private struct DesktopLiveTestError: LocalizedError {
    var errorDescription: String? { "Synthetic live failure" }
}

private final class DesktopLiveTestClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    let finalShape: TranscriptFinalShape
    let resumeFinishOnStop: Bool
    private let lock = NSLock()
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var pendingFinish: CheckedContinuation<String?, Never>?
    private var startCount = 0
    private var finishCount = 0
    private var stopCount = 0
    private var frames: [Data] = []
    var onStart: (@Sendable () -> Void)?
    var onAudio: (@Sendable () -> Void)?
    var onFinish: (@Sendable () -> Void)?
    var starts: Int { lock.withLock { startCount } }
    var finishes: Int { lock.withLock { finishCount } }
    var stops: Int { lock.withLock { stopCount } }
    var audio: [Data] { lock.withLock { frames } }

    init(shape: TranscriptFinalShape = .standaloneSegments, resumeFinishOnStop: Bool = true) {
        self.finalShape = shape
        self.resumeFinishOnStop = resumeFinishOnStop
    }

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        lock.withLock { startCount += 1; self.onTranscript = onTranscript; self.onError = onError }
        onStart?()
    }
    func sendAudio(_ data: Data) { lock.withLock { frames.append(data) }; onAudio?() }
    func emit(_ text: String, final: Bool) { lock.withLock { onTranscript }?(text, final) }
    func fail() { lock.withLock { onError }?(DesktopLiveTestError()) }
    func finishAndWait() async -> String? {
        await withCheckedContinuation { continuation in
            let alreadyStopped = lock.withLock {
                finishCount += 1
                if stopCount > 0 && resumeFinishOnStop { return true }
                pendingFinish = continuation
                return false
            }
            if alreadyStopped { continuation.resume(returning: nil) }
            onFinish?()
        }
    }
    func completeFinish(_ transcript: String?) {
        let continuation = lock.withLock { let result = pendingFinish; pendingFinish = nil; return result }
        continuation?.resume(returning: transcript)
    }
    func stop() {
        lock.withLock { stopCount += 1 }
        if resumeFinishOnStop { completeFinish(nil) }
    }
}

/// Leaves the handshake pending so the real shared client's admission bound is
/// exercised without networking, provider credentials or a parallel PCM queue.
private final class DesktopUnopenedSocket: StreamingWebSocketConnection, @unchecked Sendable {
    func resume(onOpen: @escaping @Sendable () -> Void) {}
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        XCTFail("Audio cannot be sent before the handshake")
    }
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {}
    func cancel() {}
}
