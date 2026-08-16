#if os(macOS)
import Foundation
import SpeakAutomationKit
import SpeakCore
import XCTest
@testable import SpeakApp

/// End-to-end coverage of the automation socket: a real listener, a real UNIX
/// domain socket on disk and a real length-prefixed exchange, with only the
/// command handler stubbed. The behaviours that matter to a CLI or MCP client —
/// getting an answer, not being reachable by other users, and never running a
/// retried command twice — only exist once all of that is wired together.
@MainActor
final class AutomationServerTests: XCTestCase {
    private var directory: URL!
    private var socketPath: String!
    private var server: AutomationServer!
    private var handler: StubAutomationHandler!

    override func setUp() async throws {
        try await super.setUp()
        // Short parent path: `sockaddr_un.sun_path` is 104 bytes on Darwin, and
        // the default temporary directory plus a UUID would crowd that limit.
        self.directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("speak-automation-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
        // Resolved the same way the app and the `speak` CLI resolve it, so the
        // test exercises the documented override rather than a private path.
        self.socketPath = AutomationEndpoint.socketPath(
            environment: [AutomationEndpoint.environmentKey: self.directory.appendingPathComponent("a.sock").path]
        )

        self.handler = StubAutomationHandler()
        self.server = AutomationServer(socketPath: self.socketPath)
        try self.server.start(handler: self.handler)
    }

    override func tearDown() async throws {
        self.server?.stop()
        self.server = nil
        self.handler = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: - Round trip

    func testRequest_isAnsweredOverTheSocket() async throws {
        let response = try await self.send(AutomationRequest(id: "req-1", command: .status))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, "req-1")
        XCTAssertEqual(response.command, .status)
        XCTAssertEqual(response.result?.text, "handled-status")
        XCTAssertEqual(self.handler.handledCommands, [.status])
    }

    func testOversizedReply_returnsABoundedStructuredFailure() async throws {
        self.handler.responseText = String(repeating: "x", count: AutomationLimits.maxFrameBytes + 1)

        let response = try await self.send(AutomationRequest(id: "req-large", command: .history))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.id, "req-large")
        XCTAssertEqual(response.command, .history)
        XCTAssertEqual(response.error?.code, .internalError)
        XCTAssertTrue(response.error?.message.contains("size limit") == true)
    }

    func testSocketFile_isReadableOnlyByItsOwner() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: self.socketPath)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

        XCTAssertEqual(
            permissions.uint16Value,
            0o600,
            "Any other local user must not be able to drive dictation through the socket"
        )
    }

    func testExistingSharedSocketParent_isRejectedWithoutChangingItsPermissions() throws {
        let sharedDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("speak-automation-shared-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sharedDirectory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedDirectory.path)
        let insecureServer = AutomationServer(socketPath: sharedDirectory.appendingPathComponent("a.sock").path)

        XCTAssertThrowsError(try insecureServer.start(handler: self.handler))
        let attributes = try FileManager.default.attributesOfItem(atPath: sharedDirectory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.uint16Value, 0o755, "The override must not chmod a caller-owned parent")
    }

    func testAcceptedSocket_suppressesSIGPIPEWhenThePeerDisconnects() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer {
            for descriptor in descriptors where descriptor >= 0 {
                close(descriptor)
            }
        }

        AutomationServer.configureAcceptedSocket(descriptors[0])
        var noSignal: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, &size), 0)
        XCTAssertEqual(noSignal, 1, "A client disconnect must produce EPIPE rather than terminate the app")

        close(descriptors[1])
        descriptors[1] = -1
        var byte: UInt8 = 0
        let written = withUnsafePointer(to: &byte) { Darwin.write(descriptors[0], $0, 1) }
        XCTAssertEqual(written, -1)
        XCTAssertEqual(errno, EPIPE)
    }

    // MARK: - Idempotency

    func testRepeatedRequestID_replaysTheAnswerWithoutRunningTheCommandAgain() async throws {
        let request = AutomationRequest(id: "req-repeat", command: .startDictation)

        let first = try await self.send(request)
        let second = try await self.send(request)

        XCTAssertEqual(second, first, "A retry must re-read its result, not start a second session")
        XCTAssertEqual(
            self.handler.handledCommands,
            [.startDictation],
            "The cached response must be replayed instead of re-running the command"
        )
    }

    func testSameRequestID_withADifferentCommandIsNotReplayed() async throws {
        _ = try await self.send(AutomationRequest(id: "req-shared", command: .startDictation))
        let second = try await self.send(AutomationRequest(id: "req-shared", command: .stopDictation))

        XCTAssertEqual(second.command, .stopDictation)
        XCTAssertEqual(second.result?.text, "handled-stop_dictation")
        XCTAssertEqual(self.handler.handledCommands, [.startDictation, .stopDictation])
    }

    // MARK: - Deadlines

    func testCommandPastItsDeadline_timesOutAndTheRetryCollectsTheRealResult() async throws {
        self.handler.delay = .seconds(2)
        let request = AutomationRequest(id: "req-slow", command: .stopDictation, timeout: 0.5)

        let clock = ContinuousClock()
        let started = clock.now
        let timedOut = try await self.sendWithProductionClient(request)
        let elapsed = clock.now - started

        XCTAssertFalse(timedOut.ok)
        XCTAssertEqual(timedOut.error?.code, .timedOut)
        // A reply that only arrives once the command finishes is worthless: the
        // real client's socket read deadline is the request timeout, so it would
        // already have hung up and the retry hint would be written to a dead socket.
        XCTAssertLessThan(
            elapsed,
            .seconds(1.5),
            "The timeout must be answered at the deadline, not after the command it gave up on"
        )

        // The command was never abandoned — it owns app state — so retrying with
        // the same id joins the run in progress rather than starting another.
        var retry = request
        retry.timeout = 30
        let collected = try await self.send(retry)

        XCTAssertTrue(collected.ok)
        XCTAssertEqual(collected.result?.text, "handled-stop_dictation")
        XCTAssertEqual(
            self.handler.handledCommands,
            [.stopDictation],
            "A retry after a timeout must not run the command a second time"
        )
    }

    // MARK: - Helpers

    /// Sends on a background queue so the main actor stays free for the server to
    /// answer on: the socket client blocks, and the command handler is main-actor
    /// isolated, so sending inline would deadlock the exchange.
    private func send(_ request: AutomationRequest) async throws -> AutomationResponse {
        let path = self.socketPath!
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try TestAutomationClient(socketPath: path).send(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Uses the shipped client to pin the relationship between the command
    /// deadline and the slightly longer socket deadline.
    private func sendWithProductionClient(_ request: AutomationRequest) async throws -> AutomationResponse {
        let path = self.socketPath!
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(
                        returning: try UnixSocketAutomationClient(socketPath: path).send(request)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Stub handler

/// Records what it was asked to do and answers immediately, so the tests observe
/// the server's own behaviour rather than the app's dictation pipeline.
@MainActor
private final class StubAutomationHandler: AutomationCommandHandling {
    private(set) var handledCommands: [AutomationCommand] = []
    /// Holds the command past the caller's deadline when set.
    var delay: Duration?
    var responseText: String?

    func handle(_ request: AutomationRequest) async -> AutomationResponse {
        self.handledCommands.append(request.command)
        if let delay {
            try? await Task.sleep(for: delay)
        }
        return .success(
            id: request.id,
            command: request.command,
            result: AutomationResult(text: self.responseText ?? "handled-\(request.command.rawValue)")
        )
    }
}

// MARK: - Test client

/// Minimal length-prefixed client for the automation socket.
///
/// Deliberately not `UnixSocketAutomationClient`: that client derives its socket
/// read deadline from the request's own timeout, which makes "the app took
/// longer than the caller asked for" unobservable — the client would give up in
/// the same instant the server reports the timeout.
private struct TestAutomationClient {
    let socketPath: String
    /// Generous, and independent of the request deadline under test.
    private static let readTimeout: TimeInterval = 30

    func send(_ request: AutomationRequest) throws -> AutomationResponse {
        let frame = try AutomationFraming.frame(AutomationCoding.encoder().encode(request))
        let descriptor = try self.connect()
        defer { close(descriptor) }

        try self.writeAll(descriptor: descriptor, data: frame)
        let prefix = try self.readExactly(descriptor: descriptor, count: AutomationFraming.prefixLength)
        let body = try self.readExactly(
            descriptor: descriptor,
            count: try AutomationFraming.payloadLength(from: prefix)
        )
        return try AutomationCoding.decoder().decode(AutomationResponse.self, from: body)
    }

    private func connect() throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(self.socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw AutomationError(code: .invalidArgument, message: "Test socket path is too long.")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for offset in 0..<pathBytes.count {
                    destination[offset] = CChar(bitPattern: pathBytes[offset])
                }
                destination[pathBytes.count] = 0
            }
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AutomationError(code: .internalError, message: "Could not open a test socket.")
        }
        var timeout = timeval(tv_sec: Int(Self.readTimeout), tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)

        let addressSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, addressSize)
            }
        }
        guard result == 0 else {
            close(descriptor)
            throw AutomationError.appUnavailable(socketPath: self.socketPath)
        }
        return descriptor
    }

    private func writeAll(descriptor: Int32, data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while sent < data.count {
                let written = Darwin.write(descriptor, base.advanced(by: sent), data.count - sent)
                if written > 0 {
                    sent += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                throw AutomationError(code: .internalError, message: "Test client could not send the request.")
            }
        }
    }

    private func readExactly(descriptor: Int32, count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let read = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base.advanced(by: received), count - received)
            }
            if read > 0 {
                received += read
                continue
            }
            if read < 0, errno == EINTR { continue }
            throw AutomationError(code: .internalError, message: "Test client could not read the reply.")
        }
        return Data(buffer)
    }
}
#endif
