import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SpeakCore
@testable import SpeakLinuxWebSocket

/// The Linux WebSocket transport against scripts/websocket-loopback-probe.py,
/// the same bounded RFC 6455 peer the Windows WinHTTP adapter is qualified
/// with. Each test starts its own probe on IPv4 loopback; no provider, key or
/// external network is used.
final class NIOStreamingConnectionProbeTests: XCTestCase {
    private var probe: LoopbackProbe!
    var probePort: Int? { probe?.port }

    override func setUpWithError() throws { probe = try LoopbackProbe() }
    override func tearDown() { probe.stop() }

    func testHandshakePCMServerPingAndPeerClose() async throws {
        let socket = probe.socket(path: "echo")
        defer { socket.cancel() }
        try await opened(socket)
        try await send(.text("hello loopback"), on: socket)
        let greeting = try await received(socket)
        XCTAssertEqual(greeting, .text("hello loopback"))
        for frame in 0..<8 {
            let pcm = Data((0..<3_200).map { UInt8(truncatingIfNeeded: $0 + frame) })
            try await send(.binary(pcm), on: socket)
            let echo = try await received(socket)
            XCTAssertEqual(echo, .binary(pcm))
        }
        // The peer verifies the pong carries its exact ping payload.
        try await send(.text("server-ping"), on: socket)
        let pong = try await received(socket)
        XCTAssertEqual(pong, .text("server-pong-verified"))
        try await send(.text("server-close"), on: socket)
        do {
            _ = try await received(socket)
            XCTFail("Peer close should terminate receive")
        } catch {
            let failure = try XCTUnwrap(error as? NIOWebSocketTransportError)
            XCTAssertEqual(failure.closeCode, 1_000)
            XCTAssertEqual(failure.closeReason, "probe-complete")
        }
        try probe.requireLogged("close-acknowledged")
    }

    func testSlowPeerTwoLargeBinaryMessagesHaveExactFidelity() async throws {
        let socket = probe.socket(path: "slow")
        defer { socket.cancel() }
        try await opened(socket)
        for offset in 0..<2 {
            let data = Data((0..<(2 * 1_024 * 1_024)).map { UInt8(truncatingIfNeeded: $0 + offset) })
            try await send(.binary(data), on: socket, timeout: 15)
            let echo = try await received(socket, timeout: 15)
            guard case .binary(let bytes) = echo else { return XCTFail("Expected one complete binary message") }
            XCTAssertEqual(bytes.count, data.count)
            XCTAssertTrue(bytes == data, "The transport changed the binary payload")
        }
    }

    func testFragmentedUnicodeAndBinaryMessagesAreAssembled() async throws {
        let socket = probe.socket(path: "fragment")
        defer { socket.cancel() }
        try await opened(socket)
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
        let socket = probe.socket(path: "hold")
        try await opened(socket)
        let receive = Outcome<StreamingWebSocketMessage>()
        socket.receive { receive.store($0) }
        socket.cancel()
        guard case .failure = try await receive.wait() else { return XCTFail("Cancelled receive succeeded") }

        let connecting = probe.socket(path: "delay")
        defer { connecting.cancel() }
        let opened = Outcome<Void>()
        connecting.resume { opened.store(.success(())) }
        let connectingReceive = Outcome<StreamingWebSocketMessage>()
        connecting.receive { connectingReceive.store($0) }
        let sent = Outcome<Void>()
        connecting.send(.binary(Data(repeating: 1, count: 3_200))) { error in
            sent.store(error.map { .failure($0) } ?? .success(()))
        }
        connecting.cancel()
        guard case .failure = try await sent.wait() else { return XCTFail("Cancelled connecting send succeeded") }
        guard case .failure = try await connectingReceive.wait() else {
            return XCTFail("Cancelled connecting receive succeeded")
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNil(opened.value, "A cancelled handshake must not become ready")
    }

    func testAbruptDisconnectAndOversizedMessageFailPromptly() async throws {
        for path in ["abrupt", "oversize"] {
            let socket = probe.socket(path: path)
            defer { socket.cancel() }
            try await opened(socket)
            try await send(.text("probe"), on: socket)
            do {
                _ = try await received(socket, timeout: 10)
                XCTFail("\(path) should fail the receive")
            } catch { XCTAssertTrue(error is NIOWebSocketTransportError, "\(path): \(error)") }
        }
    }

    func testRefusedUpgradeFailsWithoutOpening() async throws {
        let socket = probe.socket(path: "not-a-route")
        let opened = Outcome<Void>()
        socket.resume { opened.store(.success(())) }
        let receive = Outcome<StreamingWebSocketMessage>()
        socket.receive { receive.store($0) }
        guard case .failure = try await receive.wait(timeout: 10) else { return XCTFail("A refused upgrade opened") }
        XCTAssertNil(opened.value)
    }
}

// MARK: - Helpers

extension NIOStreamingConnectionProbeTests {
    func opened(_ socket: NIOStreamingConnection) async throws {
        let ready = Outcome<Void>()
        socket.resume { ready.store(.success(())) }
        _ = try await ready.wait().get()
    }

    func send(_ message: StreamingWebSocketMessage, on socket: NIOStreamingConnection, timeout: TimeInterval = 5)
        async throws {
        let result = Outcome<Void>()
        socket.send(message) { error in result.store(error.map { .failure($0) } ?? .success(())) }
        try await result.wait(timeout: timeout).get()
    }

    func received(_ socket: NIOStreamingConnection, timeout: TimeInterval = 5)
        async throws -> StreamingWebSocketMessage {
        let result = Outcome<StreamingWebSocketMessage>()
        socket.receive { result.store($0) }
        return try await result.wait(timeout: timeout).get()
    }
}

/// One callback result; storing twice is a contract violation.
final class Outcome<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?
    private var count = 0
    var value: Result<Value, Error>? { lock.withLock { stored } }

    func store(_ result: Result<Value, Error>) {
        lock.withLock {
            count += 1
            if stored == nil { stored = result }
        }
    }

    func wait(timeout: TimeInterval = 5) async throws -> Result<Value, Error> {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = lock.withLock({ stored }) {
                XCTAssertEqual(lock.withLock { count }, 1, "A completion was called more than once")
                return value
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NIOWebSocketTransportError("Timed out waiting for a transport callback")
    }
}

/// Runs scripts/websocket-loopback-probe.py for one test.
final class LoopbackProbe {
    let port: Int
    private let process = Process()
    private let log = Pipe()
    private var output = Data()
    private let directory: URL

    static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("jsti-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = directory.appendingPathComponent("ready.json")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            ProcessInfo.processInfo.environment["PYTHON"] ?? "python3",
            Self.repository.appendingPathComponent("scripts/websocket-loopback-probe.py").path,
            "--ready-file", ready.path, "--max-seconds", "120"
        ]
        process.standardOutput = log
        process.standardError = log
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: ready.path) {
            guard Date() < deadline, process.isRunning else {
                throw NIOWebSocketTransportError("The loopback probe did not start.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Any]
        guard let port = info?["port"] as? Int else { throw NIOWebSocketTransportError("The probe gave no port.") }
        self.port = port
    }

    func socket(path: String) -> NIOStreamingConnection {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/\(path)")!)
        request.setValue("local-only", forHTTPHeaderField: "X-JSTI-Probe")
        request.setValue("jsti-probe", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return NIOStreamingConnection(request: request)
    }

    /// Waits for the probe to log `event` (its log is JSON lines).
    func requireLogged(_ event: String) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            output.append(log.fileHandleForReading.availableDataNonBlocking())
            if String(decoding: output, as: UTF8.self).contains("\"\(event)\"") { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw NIOWebSocketTransportError("The probe never logged \(event).")
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }
}

private extension FileHandle {
    /// Reads what is buffered without blocking on an open pipe.
    func availableDataNonBlocking() -> Data {
        let descriptor = fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Glibc.read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }
}
