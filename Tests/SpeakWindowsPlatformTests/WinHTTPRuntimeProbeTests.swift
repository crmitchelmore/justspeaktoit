import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SpeakCore
import SpeakWindowsPlatform

/// Exercises the production Windows adapter against a bounded loopback server;
/// no microphone, provider account or external network is involved.
final class WinHTTPRuntimeProbeTests: XCTestCase {
    func testHandshakePCMServerPingAndPeerClose() async throws {
        let socket = try socket(path: "echo")
        defer { socket.cancel() }
        await opened(socket)
        try await send(.text("hello loopback"), on: socket)
        let greeting = try await received(socket)
        XCTAssertEqual(greeting, .text("hello loopback"))
        for frame in 0..<8 {
            let pcm = Data((0..<3_200).map { UInt8(truncatingIfNeeded: $0 + frame) })
            try await send(.binary(pcm), on: socket)
            let echo = try await received(socket)
            XCTAssertEqual(echo, .binary(pcm))
        }
        // WinHTTP manages ping/pong internally. The peer verifies an automatic
        // pong with the exact payload before returning this application message.
        try await send(.text("server-ping"), on: socket)
        let pong = try await received(socket)
        XCTAssertEqual(pong, .text("server-pong-verified"))
        try await send(.text("server-close"), on: socket)
        do {
            _ = try await received(socket)
            XCTFail("Peer close should terminate receive")
        } catch {
            XCTAssertEqual((error as? WinHTTPWebSocketError)?.closeCode, 1_000)
            XCTAssertEqual((error as? WinHTTPWebSocketError)?.closeReason, "probe-complete")
        }
    }

    func testSlowPeerTwoLargeBinaryMessagesHaveExactFidelity() async throws {
        let socket = try socket(path: "slow")
        defer { socket.cancel() }
        await opened(socket)
        for offset in 0..<2 {
            let data = Data((0..<(2 * 1_024 * 1_024)).map { UInt8(truncatingIfNeeded: $0 + offset) })
            try await send(.binary(data), on: socket, timeout: 15)
            let echo = try await received(socket, timeout: 15)
            guard case .binary(let bytes) = echo else { return XCTFail("Expected one complete binary message") }
            XCTAssertEqual(bytes.count, data.count)
            XCTAssertTrue(bytes == data, "Native transport changed the binary payload")
        }
    }

    func testFragmentedUnicodeAndBinaryMessagesAreAssembled() async throws {
        let socket = try socket(path: "fragment")
        defer { socket.cancel() }
        await opened(socket)
        let text = "界 — café e\u{301} 👩🏽‍💻"
        try await send(.text(text), on: socket)
        let echoedText = try await received(socket)
        XCTAssertEqual(echoedText, .text(text))
        let data = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0) })
        try await send(.binary(data), on: socket)
        let echoedData = try await received(socket)
        XCTAssertEqual(echoedData, .binary(data))
    }

    func testCancellationReleasesReceiveAndPendingHandshakeSend() async throws {
        let socket = try socket(path: "hold")
        await opened(socket)
        let received = RuntimeResult<StreamingWebSocketMessage>()
        let receiveDone = expectation(description: "Cancellation releases receiver")
        socket.receive { result in received.store(result); receiveDone.fulfill() }
        socket.cancel()
        await fulfillment(of: [receiveDone], timeout: 5)
        guard case .failure = try XCTUnwrap(received.value) else { return XCTFail("Cancelled receive succeeded") }

        let connecting = try self.socket(path: "delay")
        defer { connecting.cancel() }
        let opened = RuntimeResult<Void>()
        connecting.resume { opened.store(.success(())) }
        let connectingReceive = RuntimeResult<StreamingWebSocketMessage>()
        let connectDone = expectation(description: "Cancellation releases connecting receiver")
        connecting.receive { result in connectingReceive.store(result); connectDone.fulfill() }
        let sent = RuntimeResult<Void>()
        let sendDone = expectation(description: "Cancellation releases connecting sender")
        connecting.send(.binary(Data(repeating: 1, count: 3_200))) { error in
            sent.store(error.map { .failure($0) } ?? .success(()))
            sendDone.fulfill()
        }
        connecting.cancel()
        await fulfillment(of: [sendDone, connectDone], timeout: 5)
        guard case .failure = try XCTUnwrap(sent.value) else { return XCTFail("Cancelled connecting send succeeded") }
        guard case .failure = try XCTUnwrap(connectingReceive.value) else {
            return XCTFail("Cancelled connecting receive succeeded")
        }
        XCTAssertNil(opened.value, "Cancelled handshake must not become ready")
    }

    func testAbruptDisconnectAndOversizedMessageFailPromptly() async throws {
        for path in ["abrupt", "oversize"] {
            let socket = try socket(path: path)
            defer { socket.cancel() }
            await opened(socket)
            try await send(.text("probe"), on: socket)
            do {
                _ = try await received(socket, timeout: 10)
                XCTFail("\(path) should fail the receive")
            } catch { XCTAssertTrue(error is WinHTTPWebSocketError) }
        }
    }
}

private extension WinHTTPRuntimeProbeTests {
    func socket(path: String) throws -> WinHTTPStreamingConnection {
        guard let value = ProcessInfo.processInfo.environment["JSTI_WEBSOCKET_PROBE_PORT"] else {
            throw XCTSkip("Requires the bounded local WebSocket probe server.")
        }
        let port = try XCTUnwrap(UInt16(value))
        XCTAssertGreaterThan(port, 0)
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/\(path)"))
        var request = URLRequest(url: url)
        request.setValue("local-only", forHTTPHeaderField: "X-JSTI-Probe")
        request.setValue("jsti-probe", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return WinHTTPStreamingConnection(request: request)
    }

    func opened(_ socket: WinHTTPStreamingConnection) async {
        let ready = expectation(description: "Native handshake completed")
        socket.resume { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 5)
    }

    func send(_ message: StreamingWebSocketMessage, on socket: WinHTTPStreamingConnection,
              timeout: TimeInterval = 5) async throws {
        let result = RuntimeResult<Void>()
        let done = expectation(description: "Native send completed once")
        done.assertForOverFulfill = true
        socket.send(message) { error in
            result.store(error.map { .failure($0) } ?? .success(()))
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: timeout)
        _ = try XCTUnwrap(result.value, "Native send exceeded deadline").get()
    }

    func received(_ socket: WinHTTPStreamingConnection, timeout: TimeInterval = 5)
        async throws -> StreamingWebSocketMessage {
        let result = RuntimeResult<StreamingWebSocketMessage>()
        let done = expectation(description: "Native receive completed once")
        done.assertForOverFulfill = true
        socket.receive { response in result.store(response); done.fulfill() }
        await fulfillment(of: [done], timeout: timeout)
        return try XCTUnwrap(result.value, "Native receive exceeded deadline").get()
    }
}

private final class RuntimeResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?
    var value: Result<Value, Error>? { lock.withLock { stored } }
    func store(_ result: Result<Value, Error>) { lock.withLock { stored = result } }
}
