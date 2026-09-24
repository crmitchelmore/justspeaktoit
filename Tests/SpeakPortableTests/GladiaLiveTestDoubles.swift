import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Deterministic gates for the shared Gladia live client: every session
/// request, socket operation and deadline waits for the test to release it.
/// Nothing here opens a network connection or needs a credential.

/// Holds each `POST /v2/live` until the test replies, or replies at once when
/// `immediateReply` is set.
final class GladiaFakeSessions: @unchecked Sendable {
    final class Request: GladiaLiveSessionRequest, @unchecked Sendable {
        let urlRequest: URLRequest
        let completion: @Sendable (Result<(statusCode: Int, body: Data), Error>) -> Void
        private let lock = NSLock()
        private var cancels = 0

        init(
            urlRequest: URLRequest,
            completion: @escaping @Sendable (Result<(statusCode: Int, body: Data), Error>) -> Void
        ) {
            self.urlRequest = urlRequest
            self.completion = completion
        }

        var cancelCount: Int { lock.withLock { cancels } }

        func cancel() { lock.withLock { cancels += 1 } }

        var jsonBody: [String: Any] {
            guard let body = urlRequest.httpBody,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
            return object
        }
    }

    private let lock = NSLock()
    private var stored: [Request] = []
    private var immediate: Result<(statusCode: Int, body: Data), Error>?

    var requests: [Request] { lock.withLock { stored } }

    var immediateReply: Result<(statusCode: Int, body: Data), Error>? {
        get { lock.withLock { immediate } }
        set { lock.withLock { immediate = newValue } }
    }

    var initiator: GladiaLiveClient.SessionInitiator {
        { [self] request, completion in
            let pending = Request(urlRequest: request, completion: completion)
            let reply = lock.withLock { () -> Result<(statusCode: Int, body: Data), Error>? in
                stored.append(pending)
                return immediate
            }
            if let reply { completion(reply) }
            return pending
        }
    }

    func reply(status: Int, json: String, to index: Int? = nil) {
        request(index).completion(.success((status, Data(json.utf8))))
    }

    func grant(url: String = GladiaHarness.sessionURL, to index: Int? = nil) {
        reply(status: 201, json: GladiaFakeSessions.grantJSON(url: url), to: index)
    }

    func fail(_ error: Error, to index: Int? = nil) { request(index).completion(.failure(error)) }

    static func grantJSON(url: String) -> String {
        #"{"id":"636c70f6-92c1-4026-a8b6-0dfe3ecf826f","created_at":"2026-09-22T12:00:00Z","url":"\#(url)"}"#
    }

    private func request(_ index: Int?) -> Request {
        let all = requests
        return all[index ?? all.count - 1]
    }
}

/// One scripted socket. Sends are held until `completeSend` unless they
/// complete synchronously; server frames wait in an inbox until a receive is
/// outstanding. Re-entry into `send` or `receive` is measured, so a client
/// that recursed on a synchronous transport would show a depth above one.
final class GladiaFakeSocket: StreamingWebSocketConnection, @unchecked Sendable {
    let request: URLRequest
    private let lock = NSLock()
    private var opener: (@Sendable () -> Void)?
    private var receiver: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var inbox: [Result<StreamingWebSocketMessage, Error>] = []
    private var held: [@Sendable (Error?) -> Void] = []
    private var messages: [StreamingWebSocketMessage] = []
    private var cancels = 0
    private var synchronousSends = false
    private var sendDepth = 0
    private var receiveDepth = 0
    private var deepestSend = 0
    private var deepestReceive = 0
    private var sendHook: (@Sendable (StreamingWebSocketMessage) -> Void)?
    private var cancelHold: (entered: @Sendable () -> Void, gate: DispatchSemaphore)?

    init(request: URLRequest) { self.request = request }

    var sent: [StreamingWebSocketMessage] { lock.withLock { messages } }
    var sentAudio: [Data] { sent.compactMap { if case .binary(let data) = $0 { data } else { nil } } }
    var sentTexts: [String] { sent.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    var cancelCount: Int { lock.withLock { cancels } }
    var heldSendCount: Int { lock.withLock { held.count } }
    var maximumSendDepth: Int { lock.withLock { deepestSend } }
    var maximumReceiveDepth: Int { lock.withLock { deepestReceive } }
    var hasPendingReceive: Bool { lock.withLock { receiver != nil } }
    var stopRecordingSent: Bool { sentTexts.contains(GladiaLiveProtocol.stopRecordingJSON) }

    var completesSendsSynchronously: Bool {
        get { lock.withLock { synchronousSends } }
        set { lock.withLock { synchronousSends = newValue } }
    }

    var onSend: (@Sendable (StreamingWebSocketMessage) -> Void)? {
        get { lock.withLock { sendHook } }
        set { lock.withLock { sendHook = newValue } }
    }

    func resume(onOpen: @escaping @Sendable () -> Void) { lock.withLock { opener = onOpen } }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        let (synchronous, hook) = lock.withLock { () -> (Bool, (@Sendable (StreamingWebSocketMessage) -> Void)?) in
            sendDepth += 1
            deepestSend = max(deepestSend, sendDepth)
            messages.append(message)
            if !synchronousSends { held.append(completion) }
            return (synchronousSends, sendHook)
        }
        hook?(message)
        if synchronous { completion(nil) }
        lock.withLock { sendDepth -= 1 }
    }

    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        let ready = lock.withLock { () -> Result<StreamingWebSocketMessage, Error>? in
            receiveDepth += 1
            deepestReceive = max(deepestReceive, receiveDepth)
            guard inbox.isEmpty else { return inbox.removeFirst() }
            receiver = completion
            return nil
        }
        if let ready { completion(ready) }
        lock.withLock { receiveDepth -= 1 }
    }

    /// Real transports release pending work promptly on cancellation; the
    /// client must ignore those late completions by run identity.
    func cancel() {
        let hold = lock.withLock { () -> (entered: @Sendable () -> Void, gate: DispatchSemaphore)? in
            defer { cancelHold = nil }
            return cancelHold
        }
        if let hold {
            hold.entered()
            hold.gate.wait()
        }
        let (pendingReceive, pendingSends) = lock.withLock {
            cancels += 1
            let pending = (receiver, held)
            receiver = nil
            held.removeAll()
            return pending
        }
        pendingReceive?(.failure(URLError(.cancelled)))
        pendingSends.forEach { $0(URLError(.cancelled)) }
    }

    // MARK: Test controls

    /// The next `cancel()` reports that it started, then blocks the calling
    /// thread until `gate` is signalled.
    func holdNextCancel(entered: @escaping @Sendable () -> Void, until gate: DispatchSemaphore) {
        lock.withLock { cancelHold = (entered, gate) }
    }

    func open() { lock.withLock { opener }?() }

    func completeSend(_ error: Error? = nil) {
        let callback = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        callback?(error)
    }

    func completeAllSends() { while heldSendCount > 0 { completeSend() } }

    func emit(_ text: String) { deliver(.success(.text(text))) }

    func emitBinary(_ data: Data) { deliver(.success(.binary(data))) }

    func failReceive(_ error: Error = URLError(.networkConnectionLost)) { deliver(.failure(error)) }

    func partial(_ text: String, id: String) { emit(GladiaFrames.transcript(text, id: id, isFinal: false)) }

    func final(_ text: String, id: String?) { emit(GladiaFrames.transcript(text, id: id, isFinal: true)) }

    func endSession() { emit(GladiaFrames.endSession) }

    private func deliver(_ result: Result<StreamingWebSocketMessage, Error>) {
        let callback = lock.withLock { () -> (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)? in
            guard let pending = receiver else {
                inbox.append(result)
                return nil
            }
            receiver = nil
            return pending
        }
        callback?(result)
    }
}

final class GladiaFakeSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [GladiaFakeSocket] = []
    private var prepare: (@Sendable (GladiaFakeSocket) -> Void)?

    var sockets: [GladiaFakeSocket] { lock.withLock { made } }

    /// Runs on each new socket before the client sees it.
    var configure: (@Sendable (GladiaFakeSocket) -> Void)? {
        get { lock.withLock { prepare } }
        set { lock.withLock { prepare = newValue } }
    }

    var connectionFactory: GladiaLiveClient.ConnectionFactory {
        { [self] request in
            let socket = GladiaFakeSocket(request: request)
            let setup = lock.withLock { () -> (@Sendable (GladiaFakeSocket) -> Void)? in
                made.append(socket)
                return prepare
            }
            setup?(socket)
            return socket
        }
    }
}

/// Every callback in arrival order, with markers tests add around them.
final class GladiaEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var failures: [Error] = []
    private var deliveries: [(text: String, isFinal: Bool)] = []

    var timeline: [String] { lock.withLock { entries } }
    var errors: [Error] { lock.withLock { failures } }
    var transcripts: [(text: String, isFinal: Bool)] { lock.withLock { deliveries } }
    var finals: [String] { transcripts.filter(\.isFinal).map(\.text) }
    var partials: [String] { transcripts.filter { !$0.isFinal }.map(\.text) }

    func transcript(_ text: String, isFinal: Bool) {
        lock.withLock {
            deliveries.append((text, isFinal))
            entries.append(isFinal ? "final:\(text)" : "partial:\(text)")
        }
    }

    func fail(_ error: Error) {
        lock.withLock {
            failures.append(error)
            entries.append("error")
        }
    }

    func note(_ marker: String) { lock.withLock { entries.append(marker) } }
}

enum GladiaFrames {
    static let startSession = #"{"session_id":"s","created_at":"2026-09-22T12:00:00Z","type":"start_session"}"#
    static let endRecording = #"{"session_id":"s","type":"end_recording","data":{"reason":"user_request"}}"#
    static let endSession = #"{"session_id":"s","created_at":"2026-09-22T12:00:05Z","type":"end_session"}"#

    static func transcript(_ text: String, id: String?, isFinal: Bool) -> String {
        var data: [String: Any] = [
            "is_final": isFinal,
            "utterance": ["text": text, "start": 0, "end": 0.48, "language": "en"] as [String: Any]
        ]
        if let id { data["id"] = id }
        let frame: [String: Any] = ["session_id": "s", "type": "transcript", "data": data]
        let encoded = (try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])) ?? Data()
        return String(bytes: encoded, encoding: .utf8) ?? ""
    }
}

/// One client wired to the fakes above.
final class GladiaHarness: @unchecked Sendable {
    static let sessionURL = "wss://api.gladia.io/v2/live?token=synthetic-session-token"

    let sessions = GladiaFakeSessions()
    let sockets = GladiaFakeSocketFactory()
    let clock = GladiaManualClock()
    let log = GladiaEventLog()
    let client: GladiaLiveClient

    init(
        apiKey: String = "synthetic-key", model: String = GladiaLive.defaultModel,
        language: String? = nil, sampleRate: Int = 16_000
    ) {
        client = GladiaLiveClient(
            apiKey: apiKey, model: model, language: language, sampleRate: sampleRate,
            initiateSession: sessions.initiator, makeConnection: sockets.connectionFactory,
            schedule: clock.scheduler
        )
    }

    var socket: GladiaFakeSocket { sockets.sockets[sockets.sockets.count - 1] }

    func start() {
        client.start(
            onTranscript: { [log] text, isFinal in log.transcript(text, isFinal: isFinal) },
            onError: { [log] error in log.fail(error) }
        )
    }

    /// Start, the session reply, then the real handshake.
    @discardableResult
    func startOpen() -> GladiaFakeSocket {
        start()
        sessions.grant()
        socket.open()
        return socket
    }

    /// 100 ms of 16 kHz PCM16 with a pattern unique to `index`.
    static func pcm(_ index: Int, bytes: Int = 3_200) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ index &* 31) })
    }
}

extension XCTestCase {
    /// Starts `finishAndWait()` and returns once the finish has armed its one
    /// whole deadline, which proves it registered before the test moves on.
    func beginFinish(_ harness: GladiaHarness) async -> Task<String?, Never> {
        let armed = expectation(description: "Finish armed its deadline")
        harness.clock.whenScheduled(GladiaLive.finishBudget) { armed.fulfill() }
        let client = harness.client
        let task = Task { await client.finishAndWait() }
        await fulfillment(of: [armed], timeout: 5)
        return task
    }

    /// Condition-driven wait with a bounded deadline; no fixed sleep.
    func waitUntil(_ description: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(description)")
                return
            }
            await Task.yield()
        }
    }
}
