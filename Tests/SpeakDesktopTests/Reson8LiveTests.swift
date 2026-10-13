import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

final class Reson8LiveTests: XCTestCase {
    func testDesktopAndSharedRoutingUseTheRealClient() throws {
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: FileSpeechProvider.reson8LiveID))
        XCTAssertEqual(route.provider, .reson8)
        XCTAssertEqual(route.sampleRate, 16_000)
        XCTAssertEqual(route.apiKeyIdentifier, "reson8.apiKey")
        XCTAssertTrue(route.isSupportedOnIOS)
        XCTAssertTrue(DesktopLiveTranscription.liveModels.contains { $0.id == route.modelID })
        XCTAssertTrue(DesktopLiveTranscription.languageHintModelIDs.contains(route.modelID))
        let client = DesktopLiveTranscription.makeClient(
            model: route.modelID, apiKey: "synthetic", language: "nl_NL", makeConnection: { _ in Reson8Socket() }
        )
        XCTAssertTrue(client is Reson8LiveClient)
        XCTAssertEqual(client?.finalisationBudget, FileSpeechProvider.reson8FinishBudget)
        XCTAssertEqual(ModelCatalog.liveCapabilities(for: route.modelID).postStopFinalizeBudget,
                       FileSpeechProvider.reson8FinishBudget)
    }

    func testHandshakeGatesPCMAndCredentialsNeverReachQuery() throws {
        let fixture = Fixture()
        fixture.client.sendAudio(Data([0, 0]))
        fixture.start()
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "ApiKey synthetic")
        XCTAssertEqual(request.url?.host, "api.reson8.dev")
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.path, "/v1/speech-to-text/realtime")
        XCTAssertFalse(request.url!.absoluteString.contains("synthetic"))
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "encoding", value: "pcm_s16le")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "include_interim", value: "true")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "language", value: "nl")))
        XCTAssertFalse(items.contains { $0.name == "model" })
        XCTAssertTrue(fixture.socket.sent.isEmpty)
        fixture.open()
        XCTAssertEqual(fixture.socket.sent, [.binary(Data([0, 0]))])
        fixture.client.cancel()
        fixture.settle()
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testInterimsReplaceAndRetractWhileFinalsPreserveRepeatedUtterances() {
        let fixture = Fixture()
        fixture.start()
        fixture.open()
        fixture.emit(#"{"type":"transcript","text":"long hypothesis","is_final":false}"#)
        XCTAssertEqual(fixture.snapshot.displayText, "long hypothesis")
        fixture.emit(#"{"type":"transcript","text":"short","is_final":false}"#)
        XCTAssertEqual(fixture.snapshot.displayText, "short")
        fixture.emit(#"{"type":"transcript","text":"","is_final":false}"#)
        XCTAssertEqual(fixture.snapshot.displayText, "")
        fixture.emit(#"{"type":"transcript","text":"yes","is_final":true,"start_ms":0,"duration_ms":500}"#)
        fixture.emit(#"{"type":"transcript","text":"yes","is_final":true,"start_ms":1000,"duration_ms":500}"#)
        XCTAssertEqual(fixture.snapshot.confirmedText, "yes yes")
        XCTAssertEqual(fixture.snapshot.segments.map(\.startTime), [0, 1])
        fixture.emit(#"{"type":"transcript","text":"Yes.","is_final":true,"start_ms":1000,"duration_ms":500}"#)
        XCTAssertEqual(fixture.snapshot.confirmedText, "yes Yes.")
        XCTAssertEqual(fixture.snapshot.segments.count, 2)
        fixture.client.cancel()
    }

    func testFinishDrainsAudioThenRequiresItsOwnFlushConfirmation() async throws {
        let fixture = Fixture(autoComplete: false)
        fixture.start()
        fixture.open()
        fixture.client.sendAudio(Data([1, 0]))
        fixture.client.sendAudio(Data([2, 0]))
        fixture.settle()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForFinishing()
        XCTAssertEqual(fixture.socket.sent, [.binary(Data([1, 0]))])
        fixture.socket.complete()
        fixture.settle()
        XCTAssertEqual(fixture.socket.sent, [.binary(Data([1, 0])), .binary(Data([2, 0]))])
        fixture.socket.complete()
        fixture.settle()
        let flush = try XCTUnwrap(fixture.flush)
        XCTAssertEqual(fixture.socket.sent.count, 3)
        fixture.emit(#"{"type":"flush_confirmation","id":"wrong"}"#)
        XCTAssertFalse(fixture.snapshot.isTerminal)
        fixture.emit(#"{"type":"transcript","text":"tail","is_final":true,"start_ms":0}"#)
        fixture.emit("{\"type\":\"flush_confirmation\",\"id\":\"\(flush)\"}")
        let result = await finish.value
        XCTAssertEqual(result, "tail")
        XCTAssertTrue(fixture.snapshot.isTerminal)
        XCTAssertTrue(fixture.events.isEmpty, "A final consumed by finish is not delivered twice")
        XCTAssertTrue(fixture.errors.isEmpty)
    }

    func testFinishTimeoutReportsFailureBeforeReturningRecoveryText() async {
        let fixture = Fixture()
        fixture.start()
        fixture.open()
        fixture.emit(#"{"type":"transcript","text":"locked","is_final":true,"start_ms":0}"#)
        fixture.client.sendAudio(Data([0, 0]))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForFinishing()
        fixture.fireDeadlines(5)
        let text = await finish.value
        XCTAssertEqual(text, "locked")
        XCTAssertEqual(fixture.errors.count, 1)
        XCTAssertTrue(fixture.errors.first is FileSpeechError)
        XCTAssertTrue(fixture.snapshot.isTerminal)
    }

    func testEarlyClosureIsAnErrorEvenAfterFlushWasSent() async {
        let fixture = Fixture()
        fixture.start()
        fixture.open()
        fixture.client.sendAudio(Data([0, 0]))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForFinishing()
        fixture.socket.fail(URLError(.networkConnectionLost))
        fixture.settle()
        let text = await finish.value
        XCTAssertNil(text)
        XCTAssertEqual(fixture.errors.count, 1)
    }

    func testFinishingBeforeHandshakeDrainsOnlyAfterOpen() async throws {
        let fixture = Fixture()
        fixture.start()
        fixture.client.sendAudio(Data([0, 0]))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForFinishing()
        XCTAssertTrue(fixture.socket.sent.isEmpty)
        fixture.open()
        XCTAssertEqual(fixture.socket.sent.count, 2)
        let flush = try XCTUnwrap(fixture.flush)
        fixture.emit("{\"type\":\"flush_confirmation\",\"id\":\"\(flush)\"}")
        let result = await finish.value
        XCTAssertNil(result)
        XCTAssertTrue(fixture.errors.isEmpty)
    }

    func testFinishWithoutAudioAndSendFailureRetireCleanly() async {
        let empty = Fixture()
        empty.start()
        let result = await empty.client.finishAndWait()
        XCTAssertNil(result)
        empty.settle()
        XCTAssertTrue(empty.errors.isEmpty)
        XCTAssertTrue(empty.socket.sent.isEmpty)
        let failed = Fixture(autoComplete: false)
        failed.start()
        failed.open()
        failed.client.sendAudio(Data([0, 0]))
        failed.settle()
        failed.socket.complete(URLError(.networkConnectionLost))
        failed.settle()
        XCTAssertEqual(failed.errors.count, 1)
        XCTAssertEqual(failed.socket.cancels, 1)
        failed.fireDeadlines(5)
        XCTAssertEqual(failed.errors.count, 1)
    }

    func testCancellationReleasesConcurrentFinishWaitersAndCancelsSocket() async {
        let fixture = Fixture()
        fixture.start()
        fixture.open()
        fixture.client.sendAudio(Data([0, 0]))
        let first = Task { await fixture.client.finishAndWait() }
        let second = Task { await fixture.client.finishAndWait() }
        await fixture.waitForFinishing()
        first.cancel()
        let firstValue = await first.value
        let secondValue = await second.value
        XCTAssertNil(firstValue)
        XCTAssertNil(secondValue)
        fixture.settle()
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testLateCallbackFromRetiredRunCannotUpdateReplacement() {
        let fixture = Fixture()
        fixture.start()
        fixture.open()
        let callback = fixture.socket.takeReceiver()
        fixture.client.cancel()
        fixture.start()
        callback?(.success(.text(#"{"type":"transcript","text":"stale","is_final":true,"start_ms":0}"#)))
        fixture.settle()
        XCTAssertEqual(fixture.snapshot.confirmedText, "")
        XCTAssertTrue(fixture.errors.isEmpty)
        fixture.client.cancel()
    }

    func testBufferOverflowMisalignmentHandshakeAndSendDeadlinesAreVisible() {
        for beforeStart in [false, true] {
            let fixture = Fixture()
            if !beforeStart { fixture.start() }
            fixture.client.sendAudio(Data(repeating: 0, count: 160_002))
            if beforeStart { fixture.start() }
            fixture.settle()
            XCTAssertEqual(fixture.errors.count, 1)
            XCTAssertTrue(fixture.errors.first is StreamingClientError)
        }
        let misaligned = Fixture()
        misaligned.client.sendAudio(Data([0]))
        misaligned.start()
        XCTAssertEqual(misaligned.errors.count, 1)
        let handshake = Fixture()
        handshake.start()
        handshake.fireDeadlines(10)
        XCTAssertEqual(handshake.errors.count, 1)
        let send = Fixture(autoComplete: false)
        send.start()
        send.open()
        send.client.sendAudio(Data([0, 0]))
        send.settle()
        send.fireDeadlines(5)
        XCTAssertEqual(send.errors.count, 1)
        let frames = Fixture()
        for _ in 0..<257 { frames.client.sendAudio(Data([0, 0])) }
        frames.start()
        XCTAssertEqual(frames.errors.count, 1)
    }

    func testMissingKeyAndUnsupportedLanguageNeverCreateConnection() {
        for (key, language) in [("", "nl"), ("synthetic", "ja")] {
            let fixture = Fixture(key: key, language: language)
            fixture.start()
            XCTAssertTrue(fixture.requests.isEmpty)
            XCTAssertEqual(fixture.errors.count, 1)
        }
    }

}

private extension Reson8LiveTests {
    final class Fixture: @unchecked Sendable {
        let socket: Reson8Socket
        private let lock = NSLock()
        private var requestValues: [URLRequest] = []
        private var errorValues: [Error] = []
        private var eventValues: [String] = []
        private var timers: [(TimeInterval, @Sendable () -> Void)] = []
        private let finishing = XCTestExpectation(description: "Finish enters its bounded phase")
        lazy var client: Reson8LiveClient = Reson8LiveClient(
            apiKey: key, language: language,
            makeConnection: { [unowned self] request in
                self.lock.withLock { self.requestValues.append(request) }
                return self.socket
            },
            schedule: { [unowned self] seconds, action in
                self.lock.withLock { self.timers.append((seconds, action)) }
                if seconds == 5, self.client.state.sync(execute: { self.client.run.phase == .finishing }) {
                    self.finishing.fulfill()
                }
            }
        )
        let key: String
        let language: String
        init(autoComplete: Bool = true, key: String = " synthetic \n", language: String = "nl_NL") {
            socket = Reson8Socket(autoComplete: autoComplete)
            self.key = key
            self.language = language
        }
        var requests: [URLRequest] { lock.withLock { requestValues } }
        var errors: [Error] { lock.withLock { errorValues } }
        var events: [String] { lock.withLock { eventValues } }
        var snapshot: StreamingTranscriptSnapshot { client.transcriptSnapshot(captureDuration: 1) }
        var flush: String? { client.state.sync { client.run.flushID } }
        func start() {
            client.start(onTranscript: { [weak self] text, _ in
                self?.lock.withLock { self?.eventValues.append(text) }
            }, onError: { [weak self] error in
                self?.lock.withLock { self?.errorValues.append(error) }
            })
            settle()
        }
        func open() { socket.open(); settle() }
        func emit(_ text: String) { socket.emit(text); settle() }
        func settle() {
            for _ in 0..<6 { client.state.sync {}; client.effects.sync {} }
        }
        func waitForFinishing() async {
            let outcome = await XCTWaiter.fulfillment(of: [finishing], timeout: 5)
            XCTAssertEqual(outcome, .completed)
            settle()
        }
        func fireDeadlines(_ seconds: TimeInterval) {
            settle()
            let actions = lock.withLock { timers.filter { $0.0 == seconds }.map(\.1) }
            actions.forEach { $0() }
            settle()
        }
    }
}

private final class Reson8Socket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let autoComplete: Bool
    private var openCallback: (@Sendable () -> Void)?
    private var receiver: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var completion: (@Sendable (Error?) -> Void)?
    private var sentValues: [StreamingWebSocketMessage] = []
    private var cancelCount = 0
    init(autoComplete: Bool = true) { self.autoComplete = autoComplete }
    var sent: [StreamingWebSocketMessage] { lock.withLock { sentValues } }
    var cancels: Int { lock.withLock { cancelCount } }
    func resume(onOpen: @escaping @Sendable () -> Void) { lock.withLock { openCallback = onOpen } }
    func open() { lock.withLock { openCallback }?() }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { sentValues.append(message); self.completion = completion }
        if autoComplete { complete() }
    }
    func complete(_ error: Error? = nil) {
        let callback = lock.withLock { defer { completion = nil }; return completion }
        callback?(error)
    }
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        lock.withLock { receiver = completion }
    }
    func takeReceiver() -> (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)? {
        lock.withLock { defer { receiver = nil }; return receiver }
    }
    func emit(_ text: String) { takeReceiver()?(.success(.text(text))) }
    func fail(_ error: Error) { takeReceiver()?(.failure(error)) }
    func cancel() { lock.withLock { cancelCount += 1 } }
}
