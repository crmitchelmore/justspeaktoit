import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

final class DeepgramPortableLifecycleTests: XCTestCase {
    func testHandshakeGatesAudioAndOnlyOneSendIsInFlight() {
        let fixture = DeepgramFixture()
        fixture.start()
        let socket = fixture.factory.sockets[0]
        fixture.client.sendAudio(Data([1, 2]))
        fixture.client.sendAudio(Data([3, 4]))
        XCTAssertFalse(fixture.client.isConnected)
        XCTAssertTrue(socket.sent.isEmpty)
        socket.open()
        XCTAssertTrue(fixture.client.isConnected)
        XCTAssertEqual(socket.binaryMessages, [Data([1, 2])])
        socket.completeSend()
        XCTAssertEqual(socket.binaryMessages, [Data([1, 2]), Data([3, 4])])
        socket.completeSend()
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.stop()
    }

    func testQueuedAndInFlightPCMShareABoundedBudgetAndOverflowFailsOnce() {
        let fixture = DeepgramFixture()
        fixture.start()
        let socket = fixture.factory.sockets[0]
        socket.open()
        fixture.client.sendAudio(Data(repeating: 1, count: 160_000))
        fixture.client.sendAudio(Data([1, 2]))
        fixture.client.sendAudio(Data([3, 4]))
        XCTAssertEqual(socket.sent.count, 1)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(socket.cancelCount, 1)
        XCTAssertFalse(fixture.client.isConnected)
    }

    func testSmallChunksAlsoHaveABoundedQueueBeforeHandshake() {
        let fixture = DeepgramFixture()
        fixture.start()
        let socket = fixture.factory.sockets[0]
        for _ in 0..<257 { fixture.client.sendAudio(Data([1, 0])) }
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(socket.cancelCount, 1)
        socket.open()
        XCTAssertTrue(socket.sent.isEmpty)
    }

    func testMissingKeyFailsWithoutCreatingATransport() {
        let fixture = DeepgramFixture(key: " \n")
        fixture.start()
        XCTAssertTrue(fixture.factory.sockets.isEmpty)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertTrue(fixture.events.errors[0] is DeepgramLiveError)
    }

    func testFinishDrainsAudioBeforeCloseAndReturnsAllTrailingFinalsOnce() async throws {
        let fixture = DeepgramFixture()
        fixture.start()
        let socket = fixture.factory.sockets[0]
        socket.open()
        socket.emit(Self.final("Hello."))
        fixture.client.sendAudio(Data([1, 2]))
        fixture.client.sendAudio(Data([3, 4]))
        let closeSent = expectation(description: "CloseStream follows completed PCM")
        socket.onCloseSent = { closeSent.fulfill() }
        let finish = Task { await fixture.client.finishAndWait() }
        XCTAssertEqual(socket.sent.count, 1)
        socket.completeSend()
        XCTAssertEqual(socket.sent.count, 2)
        XCTAssertTrue(socket.textMessages.isEmpty)
        socket.completeSend()
        await fulfillment(of: [closeSent], timeout: 2)
        XCTAssertEqual(socket.textMessages, [#"{"type":"CloseStream"}"#])
        socket.completeSend()
        socket.emit(Self.final("Second."))
        socket.emit(Self.final("Third."))
        socket.emit(#"{"type":"Metadata"}"#)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Hello. Second. Third.")
        XCTAssertEqual(fixture.events.transcripts, ["Hello."])
        XCTAssertEqual(socket.cancelCount, 1)
    }

    func testFinishDuringHandshakeKeepsAdmittedAudioUntilDidOpen() async {
        let fixture = DeepgramFixture()
        fixture.start()
        let socket = fixture.factory.sockets[0]
        fixture.client.sendAudio(Data([1, 2]))
        let closeSent = expectation(description: "Connecting recording drains after opening")
        socket.onCloseSent = { closeSent.fulfill() }
        let finish = Task { await fixture.client.finishAndWait() }
        XCTAssertTrue(socket.sent.isEmpty)
        socket.open()
        XCTAssertEqual(socket.binaryMessages, [Data([1, 2])])
        socket.completeSend()
        await fulfillment(of: [closeSent], timeout: 2)
        socket.completeSend()
        socket.emit(Self.final("Opening words."))
        socket.emit(#"{"type":"Metadata"}"#)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Opening words.")
    }

    func testCancelFinishClosesItsSocketAndResumesItsWaiter() async {
        let fixture = DeepgramFixture()
        fixture.start()
        let socket = fixture.factory.sockets[0]
        socket.open()
        socket.emit(Self.final("Retained."))
        let closeSent = expectation(description: "Finish begins")
        socket.onCloseSent = { closeSent.fulfill() }
        let finish = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [closeSent], timeout: 2)
        finish.cancel()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Retained.")
        XCTAssertEqual(socket.cancelCount, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testOldOpenReceiveSendAndDeadlineCannotMutateReplacementSession() {
        let fixture = DeepgramFixture()
        fixture.start()
        let old = fixture.factory.sockets[0]
        old.open()
        fixture.client.sendAudio(Data([1, 2]))
        let oldDeadlines = fixture.clock.drain()
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        old.open()
        old.completeSend(error: URLError(.networkConnectionLost))
        old.emit(Self.final("Stale."))
        oldDeadlines.forEach { $0.action() }
        XCTAssertFalse(fixture.client.isConnected)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertTrue(fixture.events.transcripts.isEmpty)
        replacement.open()
        replacement.emit(Self.final("Current."))
        fixture.client.sendAudio(Data([3, 4]))
        XCTAssertEqual(replacement.binaryMessages, [Data([3, 4])])
        XCTAssertEqual(fixture.events.transcripts, ["Current."])
        XCTAssertTrue(fixture.client.isConnected)
        fixture.client.stop()
    }

    func testHandshakeAndSendStallsFailWithinTheirScheduledBudgets() {
        let connecting = DeepgramFixture()
        connecting.start()
        connecting.clock.drain().filter { $0.seconds == 10 }.forEach { $0.action() }
        XCTAssertEqual(connecting.events.errors.count, 1)
        XCTAssertEqual(connecting.factory.sockets[0].cancelCount, 1)
        let sending = DeepgramFixture()
        sending.start()
        sending.factory.sockets[0].open()
        sending.client.sendAudio(Data([1, 2]))
        sending.clock.drain().filter { $0.seconds == 5 }.forEach { $0.action() }
        XCTAssertEqual(sending.events.errors.count, 1)
        XCTAssertEqual(sending.factory.sockets[0].cancelCount, 1)
    }

    func testOfflineFullTranscriptAndPrerollContractsRemainCompatible() async {
        let fixture = DeepgramFixture()
        fixture.client.sendAudio(Data([1, 2]))
        XCTAssertEqual(fixture.client.preroll.drain(), [Data([1, 2])])
        fixture.client.parseTranscriptResponse(Self.final("Yes."))
        fixture.client.parseTranscriptResponse(Self.final("Yes."))
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Yes. Yes.")
        fixture.client.stop()
        fixture.client.sendAudio(Data([3, 4]))
        XCTAssertTrue(fixture.client.preroll.isEmpty)
    }

    private static func final(_ text: String) -> String {
        #"{"is_final":true,"channel":{"alternatives":[{"transcript":""# + text + #""}]}}"#
    }
}

private final class DeepgramFixture: @unchecked Sendable {
    let factory = FakeSocketFactory()
    let clock = FakeSocketClock()
    let events = FakeSocketEvents()
    let client: DeepgramLiveClient

    init(key: String = "test-key") {
        let factory = factory
        let clock = clock
        client = DeepgramLiveClient(apiKey: key, makeConnection: { factory.make($0) },
                                    schedule: { clock.schedule($0, action: $1) })
    }

    func start() {
        client.start(onTranscript: { [events] text, _ in events.transcript(text) },
                     onError: { [events] error in events.error(error) })
    }
}

private final class FakeSocketFactory: @unchecked Sendable {
    private(set) var sockets: [FakeStreamingSocket] = []
    func make(_ request: URLRequest) -> FakeStreamingSocket {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token test-key")
        let socket = FakeStreamingSocket()
        sockets.append(socket)
        return socket
    }
}

private final class FakeSocketClock: @unchecked Sendable {
    struct Deadline: Sendable { let seconds: TimeInterval; let action: @Sendable () -> Void }
    private let lock = NSLock()
    private var deadlines: [Deadline] = []
    func schedule(_ seconds: TimeInterval, action: @escaping @Sendable () -> Void) {
        lock.withLock { deadlines.append(Deadline(seconds: seconds, action: action)) }
    }
    func drain() -> [Deadline] { lock.withLock { let result = deadlines; deadlines.removeAll(); return result } }
}

private final class FakeSocketEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var failures: [Error] = []
    var transcripts: [String] { lock.withLock { texts } }
    var errors: [Error] { lock.withLock { failures } }
    func transcript(_ text: String) { lock.withLock { texts.append(text) } }
    func error(_ error: Error) { lock.withLock { failures.append(error) } }
}

private final class FakeStreamingSocket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var onOpen: (@Sendable () -> Void)?
    private var receiver: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var completions: [@Sendable (Error?) -> Void] = []
    private var messages: [StreamingWebSocketMessage] = []
    private var cancellations = 0
    var onCloseSent: (@Sendable () -> Void)?
    var sent: [StreamingWebSocketMessage] { lock.withLock { messages } }
    var cancelCount: Int { lock.withLock { cancellations } }
    var binaryMessages: [Data] { sent.compactMap { if case .binary(let data) = $0 { return data }; return nil } }
    var textMessages: [String] { sent.compactMap { if case .text(let text) = $0 { return text }; return nil } }
    func resume(onOpen: @escaping @Sendable () -> Void) { lock.withLock { self.onOpen = onOpen } }
    func open() { lock.withLock { onOpen }?() }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { messages.append(message); completions.append(completion) }
        if case .text = message { onCloseSent?() }
    }
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        lock.withLock { receiver = completion }
    }
    func completeSend(error: Error? = nil) {
        let completion = lock.withLock { completions.removeFirst() }
        completion(error)
    }
    func emit(_ text: String) {
        let callback = lock.withLock { let callback = receiver; receiver = nil; return callback }
        callback?(.success(.text(text)))
    }
    func cancel() { lock.withLock { cancellations += 1 } }
}
