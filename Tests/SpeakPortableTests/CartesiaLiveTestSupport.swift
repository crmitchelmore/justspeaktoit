import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Drives the real shared Cartesia client through its injected transport and
/// scheduler. Every handshake, send completion, server frame, closure and
/// deadline happens only when a test says so: no sleeps, no network, no
/// credential. Payloads are generated.
final class CartesiaLiveFixture: @unchecked Sendable {
    let factory = CartesiaSocketFactory()
    let clock = CartesiaTestClock()
    let log = CartesiaEventLog()
    let client: CartesiaLiveClient

    init(key: String = "synthetic-key", model: String = "ink-2", sampleRate: Int = 16_000) {
        let factory = factory, clock = clock
        client = CartesiaLiveClient(
            apiKey: key, model: model, sampleRate: sampleRate,
            makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
    }

    var socket: CartesiaTestSocket { factory.sockets[0] }

    func start() {
        client.start(onTranscript: { [log] in log.transcript($0, final: $1) }, onError: { [log] in log.fail($0) })
    }

    /// The real handshake: audio may move from here on.
    func startAndOpen() {
        start()
        socket.open()
    }

    /// Runs `finishAndWait()` and records its return in the ordered log.
    func finish() -> Task<String?, Never> {
        let client = client, log = log
        return Task {
            let transcript = await client.finishAndWait()
            log.finished(transcript)
            return transcript
        }
    }

    /// Fulfils when the client hands `{"type":"close"}` to the first socket.
    func expectClose(_ test: XCTestCase) -> XCTestExpectation {
        let sent = test.expectation(description: "Close command handed to the transport")
        socket.onSend { message in
            if case .text(let text) = message, text == CartesiaLiveProtocol.closeCommand { sent.fulfill() }
        }
        return sent
    }

    /// Waits, within a bound, until `count` finish callers are registered on
    /// the active run. It polls a condition; it never sleeps for an outcome.
    func waitForFinishes(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if client.pendingFinishes >= count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Only \(client.pendingFinishes) of \(count) finishes registered", file: file, line: line)
    }

    /// 100 ms of generated 16 kHz PCM16 mono with a recognisable fill byte.
    static func frame(_ fill: UInt8, count: Int = 3_200) -> Data { Data(repeating: fill, count: count) }
}

final class CartesiaSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var socketsValue: [CartesiaTestSocket] = []
    private var requestsValue: [URLRequest] = []
    private var configureValue: (@Sendable (CartesiaTestSocket) -> Void)?

    var sockets: [CartesiaTestSocket] { lock.withLock { socketsValue } }
    var requests: [URLRequest] { lock.withLock { requestsValue } }

    /// Applied to every socket before the client sees it.
    func configure(_ body: @escaping @Sendable (CartesiaTestSocket) -> Void) { lock.withLock { configureValue = body } }

    func make(_ request: URLRequest) -> CartesiaTestSocket {
        let socket = CartesiaTestSocket()
        let configure = lock.withLock { () -> (@Sendable (CartesiaTestSocket) -> Void)? in
            socketsValue.append(socket)
            requestsValue.append(request)
            return configureValue
        }
        configure?(socket)
        return socket
    }
}

/// A scripted `StreamingWebSocketConnection`. Sends are held until completed,
/// or complete synchronously inside `send`; frames emitted while no receive is
/// armed are buffered and complete the next `receive` synchronously, as the
/// WinHTTP adapter does. Cancellation releases pending work, like the real ones.
final class CartesiaTestSocket: StreamingWebSocketConnection, @unchecked Sendable {
    enum SendMode { case held, synchronous }
    typealias Receiver = @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void

    private let lock = NSLock()
    private var opener: (@Sendable () -> Void)?
    private var receiver: Receiver?
    private var buffered: [Result<StreamingWebSocketMessage, Error>] = []
    private var completions: [@Sendable (Error?) -> Void] = []
    private var sentValue: [StreamingWebSocketMessage] = []
    private var cancelValue = 0
    private var sendDepth = 0
    private var receiveDepth = 0
    private var maximumSendDepthValue = 0
    private var maximumReceiveDepthValue = 0
    private var modeValue = SendMode.held
    private var releasesOnCancel = true
    private var resumesValue = 0
    private var cancelHold: (entered: @Sendable () -> Void, release: DispatchSemaphore)?
    private var onSendValue: (@Sendable (StreamingWebSocketMessage) -> Void)?

    var sent: [StreamingWebSocketMessage] { lock.withLock { sentValue } }
    var binary: [Data] { sent.compactMap { if case .binary(let data) = $0 { data } else { nil } } }
    var texts: [String] { sent.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    var cancels: Int { lock.withLock { cancelValue } }
    var resumes: Int { lock.withLock { resumesValue } }
    var pendingCompletions: Int { lock.withLock { completions.count } }
    var maximumSendDepth: Int { lock.withLock { maximumSendDepthValue } }
    var maximumReceiveDepth: Int { lock.withLock { maximumReceiveDepthValue } }
    var isReceiving: Bool { lock.withLock { receiver != nil } }
    var closeCommands: Int { texts.filter { $0 == CartesiaLiveProtocol.closeCommand }.count }

    func setSendMode(_ mode: SendMode) { lock.withLock { modeValue = mode } }

    /// Keeps pending callbacks after cancellation so a test can deliver them late.
    func keepCallbacksAfterCancel() { lock.withLock { releasesOnCancel = false } }

    /// Holds `cancel()` on whichever thread calls it until `release` is
    /// signalled, after reporting that it was entered: a failure is then
    /// demonstrably retired but not yet delivered.
    func holdCancel(until release: DispatchSemaphore, entered: @escaping @Sendable () -> Void) {
        lock.withLock { cancelHold = (entered, release) }
    }

    func onSend(_ body: @escaping @Sendable (StreamingWebSocketMessage) -> Void) {
        lock.withLock { onSendValue = body }
    }

    /// Queues frames that the next receives return synchronously.
    func preload(_ frames: [String]) { lock.withLock { buffered += frames.map { .success(.text($0)) } } }

    func resume(onOpen: @escaping @Sendable () -> Void) {
        lock.withLock {
            opener = onOpen
            resumesValue += 1
        }
    }

    /// Reports the handshake. Calling it on a retired socket models a late open.
    func open() { lock.withLock { opener }?() }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        let (mode, observer) = lock.withLock { () -> (SendMode, (@Sendable (StreamingWebSocketMessage) -> Void)?) in
            sentValue.append(message)
            sendDepth += 1
            maximumSendDepthValue = max(maximumSendDepthValue, sendDepth)
            if modeValue == .held { completions.append(completion) }
            return (modeValue, onSendValue)
        }
        observer?(message)
        if mode == .synchronous { completion(nil) }
        lock.withLock { sendDepth -= 1 }
    }

    func receive(completion: @escaping Receiver) {
        let next = lock.withLock { () -> Result<StreamingWebSocketMessage, Error>? in
            receiveDepth += 1
            maximumReceiveDepthValue = max(maximumReceiveDepthValue, receiveDepth)
            guard buffered.isEmpty else { return buffered.removeFirst() }
            receiver = completion
            return nil
        }
        if let next { completion(next) }
        lock.withLock { receiveDepth -= 1 }
    }

    /// Completes the oldest held send.
    func completeSend(_ error: Error? = nil) {
        let callback = lock.withLock { completions.isEmpty ? nil : completions.removeFirst() }
        callback?(error)
    }

    func emit(_ text: String) { deliver(.success(.text(text))) }
    func emitBinary(_ data: Data) { deliver(.success(.binary(data))) }

    /// The transport breaking, by default with no close frame at all.
    func closeByPeer(_ error: Error = URLError(.networkConnectionLost)) { deliver(.failure(error)) }

    /// The server's close frame with this status, as a transport reports it.
    func closeByPeer(code: Int) { closeByPeer(CartesiaTestPeerClose(webSocketCloseCode: code)) }

    /// The server's normal closure (1000): the documented end of the stream.
    func closeNormally() { closeByPeer(code: 1_000) }

    func cancel() {
        let (pendingReceiver, pendingSends) = lock.withLock { () -> (Receiver?, [@Sendable (Error?) -> Void]) in
            cancelValue += 1
            guard releasesOnCancel else { return (nil, []) }
            defer { receiver = nil; completions = [] }
            return (receiver, completions)
        }
        if let hold = lock.withLock({ cancelHold }) {
            hold.entered()
            XCTAssertEqual(hold.release.wait(timeout: .now() + 5), .success, "A held cancel was never released")
        }
        pendingReceiver?(.failure(CancellationError()))
        pendingSends.forEach { $0(CancellationError()) }
    }

    private func deliver(_ result: Result<StreamingWebSocketMessage, Error>) {
        let callback = lock.withLock { () -> Receiver? in
            guard let armed = receiver else {
                buffered.append(result)
                return nil
            }
            receiver = nil
            return armed
        }
        callback?(result)
    }
}

extension CartesiaTestSocket {
    func connected() { event(["type": "connected"]) }
    func turnStart() { event(["type": "turn.start"]) }
    func turnUpdate(_ text: String) { event(["type": "turn.update", "transcript": text]) }
    func turnEagerEnd(_ text: String) { event(["type": "turn.eager_end", "transcript": text]) }
    func turnResume() { event(["type": "turn.resume"]) }
    func turnEnd(_ text: String) { event(["type": "turn.end", "transcript": text]) }

    /// A whole turn as the service reports it: start, cumulative update, end.
    func turn(_ text: String) {
        turnStart()
        turnUpdate(text)
        turnEnd(text)
    }

    func serverError(status: Int, code: String? = nil, message: String = "Synthetic failure") {
        var object: [String: Any] = ["type": "error", "status_code": status, "title": "Synthetic", "message": message]
        if let code { object["error_code"] = code }
        event(object)
    }

    static func eventJSON(_ object: [String: Any]) -> String {
        var object = object
        object["request_id"] = "synthetic-request"
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("Invalid synthetic Cartesia event")
            return "{}"
        }
        return text
    }

    private func event(_ object: [String: Any]) { emit(Self.eventJSON(object)) }
}

/// A scheduler whose deadlines fire only when a test fires them.
final class CartesiaTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(seconds: TimeInterval, action: @Sendable () -> Void)] = []
    private var watchers: [(seconds: TimeInterval, expectation: XCTestExpectation)] = []

    func schedule(_ seconds: TimeInterval, action: @escaping @Sendable () -> Void) {
        let matched = lock.withLock { () -> [XCTestExpectation] in
            entries.append((seconds, action))
            let matched = watchers.filter { $0.seconds == seconds }.map(\.expectation)
            watchers.removeAll { $0.seconds == seconds }
            return matched
        }
        matched.forEach { $0.fulfill() }
    }

    /// Fulfils once a deadline of exactly this length is armed, which proves an
    /// asynchronous wait has registered without sleeping for it.
    func armed(_ seconds: TimeInterval, _ expectation: XCTestExpectation) {
        let already = lock.withLock { () -> Bool in
            guard !entries.contains(where: { $0.seconds == seconds }) else { return true }
            watchers.append((seconds, expectation))
            return false
        }
        if already { expectation.fulfill() }
    }

    /// Fires every armed deadline of exactly this length, outside the lock.
    func fire(_ seconds: TimeInterval) {
        let selected = lock.withLock { () -> [@Sendable () -> Void] in
            let selected = entries.filter { $0.seconds == seconds }.map(\.action)
            entries.removeAll { $0.seconds == seconds }
            return selected
        }
        selected.forEach { $0() }
    }

    func fireAll() {
        let selected = lock.withLock { () -> [@Sendable () -> Void] in
            defer { entries.removeAll() }
            return entries.map(\.action)
        }
        selected.forEach { $0() }
    }

    func pending(_ seconds: TimeInterval) -> Int { lock.withLock { entries.filter { $0.seconds == seconds }.count } }
}

/// A receive failure carrying a peer close status through the shared seam.
struct CartesiaTestPeerClose: StreamingWebSocketCloseReporting {
    let webSocketCloseCode: Int?
}

final class CartesiaFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Transcript callbacks, errors and finish returns in the order they happened.
final class CartesiaEventLog: @unchecked Sendable {
    enum Entry: Equatable {
        case transcript(String, final: Bool)
        case error(String)
        case finished(String?)
    }

    private let lock = NSLock()
    private var entriesValue: [Entry] = []
    private var errorsValue: [Error] = []

    var entries: [Entry] { lock.withLock { entriesValue } }
    var errors: [Error] { lock.withLock { errorsValue } }
    var transcripts: [Entry] { entries.filter { if case .transcript = $0 { true } else { false } } }

    func transcript(_ text: String, final: Bool) {
        lock.withLock { entriesValue.append(.transcript(text, final: final)) }
    }

    func fail(_ error: Error) {
        lock.withLock {
            errorsValue.append(error)
            entriesValue.append(.error(Self.describe(error)))
        }
    }

    func finished(_ transcript: String?) { lock.withLock { entriesValue.append(.finished(transcript)) } }

    static func describe(_ error: Error) -> String {
        if let streaming = error as? CartesiaStreamingError { return "\(streaming)" }
        if let shared = error as? StreamingClientError { return "\(shared)" }
        if let url = error as? URLError { return "URLError(\(url.code.rawValue))" }
        return "\(type(of: error))"
    }

    static func urlError(_ code: URLError.Code) -> Entry { .error(describe(URLError(code))) }
}
