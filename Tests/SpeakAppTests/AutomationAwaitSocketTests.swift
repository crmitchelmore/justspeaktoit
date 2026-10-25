#if os(macOS)
import Darwin
import Foundation
import SpeakAutomationKit
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class AutomationAwaitSocketTests: XCTestCase {
    private var root: URL!
    private var path: String!
    private var server: AutomationServer!
    private var handler: AwaitSocketHandler!

    override func setUp() async throws {
        try await super.setUp()
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("aw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
        self.path = self.root.appendingPathComponent("a.sock").path
        self.handler = AwaitSocketHandler()
        self.server = AutomationServer(socketPath: self.path)
        try self.server.start(handler: self.handler)
    }

    override func tearDown() async throws {
        self.server.stop()
        self.handler.finish()
        self.server = nil
        self.handler = nil
        try? FileManager.default.removeItem(at: self.root)
        try await super.tearDown()
    }

    private func request(_ id: String = "await-socket") -> AutomationRequest {
        AutomationRequest(id: id, command: .awaitTranscript, timeout: 30, captureID: UUID().uuidString)
    }

    func testRealEOF_LastDisconnectCancelsAndRetryReplaysTerminal() async throws {
        let entered = expectation(description: "handler registered")
        let cancelled = expectation(description: "handler cancelled by actual EOF")
        self.handler.didEnter = { entered.fulfill() }
        self.handler.didCancel = { cancelled.fulfill() }
        let request = self.request()
        let token = AutomationRequestCancellation()
        let client = UnixSocketAutomationClient(socketPath: self.path)
        let pending = Task.detached { try? client.send(request, cancellation: token) }
        await fulfillment(of: [entered], timeout: 2)
        token.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        _ = await pending.value
        let replay = try await Task.detached { try client.send(request) }.value
        XCTAssertEqual(replay.error?.code, .appUnavailable)
        XCTAssertEqual(self.handler.calls, 1)
    }

    func testSameCaptureRetryConnectionSurvivesOtherEOF_AndStatusStillAnswers() async throws {
        let installed = expectation(description: "two subscribers installed")
        let removed = expectation(description: "one subscriber disconnected")
        var twoInstalled = false
        self.server.awaitSubscriptionDidChange = { _, count in
            if count == 2 { twoInstalled = true; installed.fulfill() }
            if twoInstalled, count == 1 { removed.fulfill() }
        }
        let client = UnixSocketAutomationClient(socketPath: self.path)
        let request = self.request()
        let firstToken = AutomationRequestCancellation()
        let secondToken = AutomationRequestCancellation()
        let first = Task.detached { try? client.send(request, cancellation: firstToken) }
        let second = Task.detached { try? client.send(request, cancellation: secondToken) }
        await fulfillment(of: [installed], timeout: 2)
        guard twoInstalled else { firstToken.cancel(); secondToken.cancel(); return }
        firstToken.cancel()
        await fulfillment(of: [removed], timeout: 2)
        let status = try await Task.detached { try client.send(.init(command: .status)) }.value
        XCTAssertTrue(status.ok)
        self.handler.finish()
        let survivor = await second.value
        XCTAssertEqual(survivor?.result?.text, "owned fixture")
        _ = await first.value
        XCTAssertEqual(self.handler.calls, 1)
    }

    func testExtraBytesAfterAwaitFrame_CancelOnlyThatConnection() async throws {
        let entered = expectation(description: "await active")
        let cancelled = expectation(description: "extra input cancelled wait")
        self.handler.didEnter = { entered.fulfill() }
        self.handler.didCancel = { cancelled.fulfill() }
        let descriptor = try self.connectRaw()
        defer { close(descriptor) }
        let frame = try AutomationWireExchange.requestFrame(for: self.request())
        XCTAssertEqual(frame.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, frame.count) }, frame.count)
        await fulfillment(of: [entered], timeout: 2)
        var byte: UInt8 = 1
        XCTAssertEqual(Darwin.write(descriptor, &byte, 1), 1)
        await fulfillment(of: [cancelled], timeout: 2)
        let client = UnixSocketAutomationClient(socketPath: self.path)
        let status = try await Task.detached { try client.send(.init(command: .status)) }.value
        XCTAssertTrue(status.ok)
    }

    func testAcceptedPartialFrameBeforeOff_CannotJoinReactivatedListener() async throws {
        let accepted = expectation(description: "old socket accepted before stop")
        self.server.didAcceptClient = { accepted.fulfill() }
        let descriptor = try self.connectRaw()
        defer { close(descriptor) }
        let frame = try AutomationWireExchange.requestFrame(for: self.request())
        XCTAssertEqual(frame.prefix(2).withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, 2) }, 2)
        await fulfillment(of: [accepted], timeout: 2)
        self.server.didAcceptClient = nil
        self.server.stop()
        try self.server.start(handler: self.handler)
        let suffix = Data(frame.dropFirst(2))
        XCTAssertEqual(suffix.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, suffix.count) }, suffix.count)
        // The read is off actor and bounded independently of the request's own deadline.
        let response = try await Task.detached { try Self.readResponse(descriptor) }.value
        XCTAssertEqual(response.error?.code, .appUnavailable)
        XCTAssertEqual(self.handler.calls, 0)
    }

    func testCancellationBeforeConnect_DoesNotAcceptOrRunCapture() async throws {
        let token = AutomationRequestCancellation()
        token.cancel()
        let client = UnixSocketAutomationClient(socketPath: self.path)
        let request = self.request()
        do {
            _ = try await Task.detached { try client.send(request, cancellation: token) }.value
            XCTFail("Cancelled")
        } catch {
            XCTAssertEqual((error as? AutomationError)?.code, .appUnavailable) }
        XCTAssertEqual(self.handler.calls, 0)
    }

    private func connectRaw() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(self.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw AutomationError(code: .invalidArgument, message: "Fixture socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes + [0]) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(descriptor); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return descriptor
    }

    private nonisolated static func readResponse(_ descriptor: Int32) throws -> AutomationResponse {
        func read(_ count: Int) throws -> Data {
            var data = Data(count: count)
            var offset = 0
            while offset < count {
                let result = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset),
                    count - offset) }
                guard result > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                offset += result
            }
            return data
        }
        let count = try AutomationFraming.payloadLength(from: read(4))
        return try AutomationWireExchange.decodeResponse(read(count))
    }
}

@MainActor
private final class AwaitSocketHandler: AutomationCommandHandling {
    var didEnter: (() -> Void)?
    var didCancel: (() -> Void)?
    private(set) var calls = 0
    private var pending: [String: CheckedContinuation<AutomationResponse, Never>] = [:]
    func handle(_ request: AutomationRequest) async -> AutomationResponse {
        guard request.command == .awaitTranscript else { return .success(id: request.id, command: request.command,
            result: .init()) }
        self.calls += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.pending[request.id] = continuation
                self.didEnter?()
                if Task.isCancelled { self.cancel(request) }
            }
        } onCancel: { Task { @MainActor in self.cancel(request) } }
    }
    private func cancel(_ request: AutomationRequest) {
        guard let continuation = self.pending.removeValue(forKey: request.id) else { return }
        self.didCancel?()
        continuation.resume(returning: .failure(id: request.id, command: request.command,
            error: .init(code: .appUnavailable, message: "Fixture cancelled")))
    }
    func finish() {
        let pending = self.pending
        self.pending.removeAll()
        for (id, continuation) in pending {
            continuation.resume(returning: .success(id: id, command: .awaitTranscript,
                result: .init(text: "owned fixture")))
        }
    }
}
#endif
