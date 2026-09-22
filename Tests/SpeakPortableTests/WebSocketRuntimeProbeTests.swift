import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

/// Explicitly enabled only with the standard-library loopback peer. This
/// validates the installed transport, not any credentialled speech provider.
final class WebSocketRuntimeProbeTests: XCTestCase {
    func testHandshakePCMFramesPingAndPeerClose() async throws {
        let connection = try connection(path: "echo")
        defer { connection.stop() }
        try await opened(connection)
        try await asyncSend(.string("hello loopback"), on: connection.task)
        let greeting = try await receive(on: connection.task)
        guard case .string(let text) = greeting else { return XCTFail("Expected text echo") }
        XCTAssertEqual(text, "hello loopback")
        for frame in 0..<8 {
            // 100ms of 16kHz mono PCM16, including varying nonzero bytes.
            let pcm = Data((0..<3_200).map { UInt8(truncatingIfNeeded: $0 + frame) })
            try await send(.data(pcm), on: connection.task)
            try assertBinary(try await receive(on: connection.task), equals: pcm)
        }
        let ping = ProbeResult<Void>()
        let pong = expectation(description: "Pong received")
        connection.task.sendPing { error in
            ping.store(error.map { .failure($0) } ?? .success(()))
            pong.fulfill()
        }
        await fulfillment(of: [pong], timeout: 5)
        _ = try XCTUnwrap(ping.value).get()
        let finalReceive = ProbeResult<URLSessionWebSocketTask.Message>()
        let receivedClose = expectation(description: "Peer close finishes pending receive")
        connection.task.receive { response in finalReceive.store(response); receivedClose.fulfill() }
        try await send(.string("server-close"), on: connection.task)
        await fulfillment(of: [receivedClose, connection.delegate.closed], timeout: 5)
        guard case .failure = try XCTUnwrap(finalReceive.value) else { return XCTFail("Peer close returned a message") }
        XCTAssertEqual(connection.delegate.closeCode, .normalClosure)
        XCTAssertEqual(connection.delegate.closeReason, Data("probe-complete".utf8))
    }

    func testSlowPeerLargeBinaryPayloadHasExactFidelityWithOneSendInFlight() async throws {
        let connection = try connection(path: "slow")
        defer { connection.stop() }
        try await opened(connection)
        // Two bounded messages, sent sequentially. The peer delays reads and
        // uses a small socket buffer to exercise the runtime's short-write path.
        for offset in 0..<2 {
            let payload = Data((0..<(2 * 1_024 * 1_024)).map { UInt8(truncatingIfNeeded: $0 + offset) })
            try await send(.data(payload), on: connection.task, timeout: 15)
            try assertBinary(try await receive(on: connection.task, timeout: 15), equals: payload)
        }
    }

    func testCancellationUnblocksPendingReceive() async throws {
        let connection = try connection(path: "hold")
        defer { connection.stop() }
        try await opened(connection)
        let result = ProbeResult<URLSessionWebSocketTask.Message>()
        let completed = expectation(description: "Cancelled receive finishes")
        connection.task.receive { response in result.store(response); completed.fulfill() }
        connection.task.cancel(with: .goingAway, reason: Data("probe-cancel".utf8))
        await fulfillment(of: [completed], timeout: 5)
        guard case .failure = try XCTUnwrap(result.value) else { return XCTFail("Cancelled receive succeeded") }
    }

    func testCancellationBeforeHandshakeUnblocksPendingSend() async throws {
        let connection = try connection(path: "delay")
        defer { connection.stop() }
        let result = ProbeResult<Void>()
        let completed = expectation(description: "Cancelled connecting send finishes")
        connection.task.send(.data(Data(repeating: 1, count: 3_200))) { error in
            result.store(error.map { .failure($0) } ?? .success(()))
            completed.fulfill()
        }
        connection.task.cancel(with: .goingAway, reason: nil)
        await fulfillment(of: [completed], timeout: 5)
        guard case .failure = try XCTUnwrap(result.value) else { return XCTFail("Cancelled connecting send succeeded") }
    }

    func testAbruptPeerDisconnectFinishesReceive() async throws {
        let connection = try connection(path: "abrupt")
        defer { connection.stop() }
        try await opened(connection)
        try await send(.string("disconnect"), on: connection.task)
        let result = ProbeResult<URLSessionWebSocketTask.Message>()
        let completed = expectation(description: "Abrupt disconnect finishes")
        connection.task.receive { response in result.store(response); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)
        guard case .failure = try XCTUnwrap(result.value) else { return XCTFail("Disconnected receive succeeded") }
    }
}

private extension WebSocketRuntimeProbeTests {
    struct Connection {
        let session: URLSession
        let task: URLSessionWebSocketTask
        let delegate: ProbeDelegate

        func stop() {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
    }

    func connection(path: String) throws -> Connection {
        guard let value = ProcessInfo.processInfo.environment["JSTI_WEBSOCKET_PROBE_PORT"] else {
            throw XCTSkip("Set JSTI_WEBSOCKET_PROBE_PORT only with the local WebSocket probe server.")
        }
        let port = try XCTUnwrap(UInt16(value), "Invalid loopback probe port")
        XCTAssertGreaterThan(port, 0)
        let delegate = ProbeDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/\(path)")))
        request.setValue("local-only", forHTTPHeaderField: "X-JSTI-Probe")
        request.setValue("jsti-probe", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1_024 * 1_024
        task.resume()
        return Connection(session: session, task: task, delegate: delegate)
    }

    func opened(_ connection: Connection) async throws {
        await fulfillment(of: [connection.delegate.opened], timeout: 5)
        XCTAssertEqual(try XCTUnwrap(connection.delegate.negotiatedProtocol), "jsti-probe")
    }

    func send(_ message: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask,
              timeout: TimeInterval = 5) async throws {
        let result = ProbeResult<Void>()
        let completed = expectation(description: "WebSocket send finishes")
        task.send(message) { error in
            result.store(error.map { .failure($0) } ?? .success(()))
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: timeout)
        _ = try XCTUnwrap(result.value, "WebSocket send exceeded deadline").get()
    }

    func asyncSend(_ message: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask) async throws {
        let result = ProbeResult<Void>()
        let completed = expectation(description: "Async WebSocket send finishes")
        let operation = Task {
            do {
                try await task.send(message)
                result.store(.success(()))
            } catch { result.store(.failure(error)) }
            completed.fulfill()
        }
        defer { operation.cancel() }
        await fulfillment(of: [completed], timeout: 5)
        _ = try XCTUnwrap(result.value, "Async WebSocket send exceeded deadline").get()
    }

    func receive(on task: URLSessionWebSocketTask, timeout: TimeInterval = 5)
        async throws -> URLSessionWebSocketTask.Message {
        let result = ProbeResult<URLSessionWebSocketTask.Message>()
        let completed = expectation(description: "WebSocket receive finishes")
        let operation = Task {
            do { result.store(.success(try await task.receive())) } catch { result.store(.failure(error)) }
            completed.fulfill()
        }
        defer { operation.cancel() }
        await fulfillment(of: [completed], timeout: timeout)
        return try XCTUnwrap(result.value, "WebSocket receive exceeded deadline").get()
    }

    func assertBinary(_ message: URLSessionWebSocketTask.Message, equals expected: Data) throws {
        guard case .data(let actual) = message else { return XCTFail("Expected binary message") }
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertTrue(actual == expected, "Binary payload changed during transport (\(expected.count) bytes)")
    }
}

private final class ProbeResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?
    var value: Result<Value, Error>? { lock.withLock { stored } }
    func store(_ result: Result<Value, Error>) { lock.withLock { stored = result } }
}

private final class ProbeDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let opened = XCTestExpectation(description: "WebSocket handshake completes")
    let closed = XCTestExpectation(description: "Peer close arrives")
    private let lock = NSLock()
    private var storedProtocol: String?
    private var storedCloseCode: URLSessionWebSocketTask.CloseCode?
    private var storedCloseReason: Data?
    var negotiatedProtocol: String? { lock.withLock { storedProtocol } }
    var closeCode: URLSessionWebSocketTask.CloseCode? { lock.withLock { storedCloseCode } }
    var closeReason: Data? { lock.withLock { storedCloseReason } }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        lock.withLock { storedProtocol = `protocol` }
        opened.fulfill()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock { storedCloseCode = closeCode; storedCloseReason = reason }
        closed.fulfill()
    }
}
