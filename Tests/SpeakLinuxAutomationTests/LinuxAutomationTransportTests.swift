import CLinuxAutomation
import Foundation
import Glibc
import SpeakAutomationKit
import SpeakCore
import SpeakLinuxAutomation
import XCTest

/// Private throwaway sockets only: no app, display, microphone, credentials,
/// clipboard, provider request or external network is involved.
final class LinuxAutomationTransportTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("automation.sock").path }
    private var server: LinuxAutomationServer!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp/jsti-automation-\(UUID().uuidString.prefix(12))")
        server = LinuxAutomationServer(socketPath: path, requestMilliseconds: 150)
    }

    override func tearDownWithError() throws {
        server.stop()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func start() throws {
        try server.start { request in
            .success(id: request.id, command: request.command, result: .init(text: "synthetic", sessionActive: false))
        }
    }

    private func connect() throws -> OpaquePointer {
        var connection: OpaquePointer?
        try LinuxAutomationStream.check(jsti_automation_connect(path, jsti_automation_deadline(1_000), &connection))
        return try XCTUnwrap(connection)
    }

    private func exchange(_ frame: Data, fragmented: Bool = false) throws -> AutomationResponse {
        let connection = try connect()
        defer { jsti_automation_close(connection) }
        let stream = LinuxAutomationStream(connection: connection, deadline: jsti_automation_deadline(2_000))
        if fragmented {
            for byte in frame { try stream.writeAll(Data([byte])) }
        } else { try stream.writeAll(frame) }
        return try AutomationWireExchange.readResponse(from: stream)
    }

    func testEndpoint_UsesPrivatePerUserTrainDirectoryAndOverride() {
        let path = LinuxAutomationEndpoint.socketPath(environment: ["XDG_RUNTIME_DIR": "/run/user/42"], userID: 42)
        XCTAssertTrue(path.hasPrefix("/run/user/42/"))
        XCTAssertTrue(path.hasSuffix("-automation-42/automation.sock"))
        XCTAssertTrue(LinuxAutomationEndpoint.socketPath(environment: [:], userID: 42).hasPrefix("/tmp/"))
        XCTAssertEqual(
            LinuxAutomationEndpoint.socketPath(environment: ["SPEAK_AUTOMATION_SOCKET": "/private/test.sock"]),
            "/private/test.sock"
        )
    }

    func testPeerAndMetadataPolicies_RejectWrongOwnerPermissiveAndWrongType() {
        let user = jsti_automation_uid()
        XCTAssertEqual(jsti_automation_peer_allowed(user), 1)
        XCTAssertEqual(jsti_automation_peer_allowed(user &+ 1), 0)
        XCTAssertEqual(jsti_automation_private_metadata(user, UInt32(S_IFDIR | 0o700), 1), 1)
        XCTAssertEqual(jsti_automation_private_metadata(user, UInt32(S_IFDIR | 0o755), 1), 0)
        XCTAssertEqual(jsti_automation_private_metadata(user &+ 1, UInt32(S_IFDIR | 0o700), 1), 0)
        XCTAssertEqual(jsti_automation_private_metadata(user, UInt32(S_IFLNK | 0o700), 1), 0)
        XCTAssertEqual(jsti_automation_private_metadata(user, UInt32(S_IFSOCK | 0o600), 0), 1)
        XCTAssertEqual(jsti_automation_private_metadata(user, UInt32(S_IFSOCK | 0o666), 0), 0)
        XCTAssertEqual(jsti_automation_private_metadata(user, UInt32(S_IFREG | 0o600), 0), 0)
    }

    func testServer_CreatesPrivateDirectorySocketAndAnswersFragmentedFrame() throws {
        try start()
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let socketMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(socketMode, 0o600)
        let request = AutomationRequest(id: "fragmented", command: .status)
        let reply = try exchange(AutomationWireExchange.requestFrame(for: request), fragmented: true)
        XCTAssertEqual(reply.id, "fragmented")
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.result?.text, "synthetic")
    }

    func testMalformedAndOversizedFrames_ReturnStructuredErrorsWithoutEcho() throws {
        try start()
        for frame in [Data([255, 255, 255, 255]), try AutomationFraming.frame(Data("secret-not-json".utf8))] {
            let reply = try exchange(frame)
            XCTAssertEqual(reply.error?.code, .invalidArgument)
            XCTAssertFalse(reply.error?.message.contains("secret-not-json") == true)
        }
        let request = AutomationRequest(schemaVersion: 99, id: "schema", command: .status)
        let reply = try exchange(AutomationFraming.frame(AutomationCoding.encoder().encode(request)))
        XCTAssertEqual(reply.id, "schema")
        XCTAssertEqual(reply.error?.code, .schemaMismatch)
    }

    func testCLI_UsesExistingGrammarJSONAndStructuredErrorsOverSocket() throws {
        try start()
        let runner = CLIRunner(client: UnixSocketAutomationClient(socketPath: path), version: "test")
        guard case .finished(let output) = runner.run(arguments: ["status", "--json"]) else {
            return XCTFail("CLI did not finish")
        }
        XCTAssertEqual(output.exitCode, CLIExitCode.success)
        let envelope = try JSONDecoder().decode(CLIJSONEnvelope.self, from: Data(output.stdout.utf8))
        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(envelope.data?.sessionActive, false)
        guard case .finished(let invalid) = runner.run(arguments: ["status", "--language", "en"]) else {
            return XCTFail("CLI accepted an unsupported option")
        }
        XCTAssertEqual(invalid.exitCode, CLIExitCode.usage)
        server.stop()
        guard case .finished(let unavailable) = runner.run(arguments: ["status", "--json"]) else {
            return XCTFail("CLI did not report an unavailable app")
        }
        XCTAssertEqual(unavailable.exitCode, CLIExitCode.appUnavailable)
        XCTAssertEqual(
            try JSONDecoder().decode(CLIJSONEnvelope.self, from: Data(unavailable.stdout.utf8)).error?.code,
            .appUnavailable
        )
    }

    func testExistingCompetitor_IsNeverUnlinkedAndStillAnswers() throws {
        try start()
        let competitor = LinuxAutomationServer(socketPath: path)
        XCTAssertThrowsError(try competitor.start { .success(id: $0.id, command: $0.command, result: .init()) })
        XCTAssertTrue(server.isRunning)
        XCTAssertTrue(try UnixSocketAutomationClient(socketPath: path).send(.init(command: .status)).ok)
        competitor.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testStop_DoesNotRemoveReplacementEndpoint() throws {
        try start()
        XCTAssertEqual(unlink(path), 0)
        let replacement = LinuxAutomationServer(socketPath: path)
        defer { replacement.stop() }
        try replacement.start { .success(id: $0.id, command: $0.command, result: .init(text: "replacement")) }
        server.stop()
        let reply = try UnixSocketAutomationClient(socketPath: path).send(.init(command: .status))
        XCTAssertEqual(reply.result?.text, "replacement")
    }

    func testStop_RejectsReplacedRootAndPreservesItsNewEndpoint() throws {
        try start()
        let retired = directory.appendingPathExtension("retired")
        try FileManager.default.moveItem(at: directory, to: retired)
        let replacement = LinuxAutomationServer(socketPath: path)
        defer {
            replacement.stop()
            try? FileManager.default.removeItem(at: retired)
        }
        try replacement.start { .success(id: $0.id, command: $0.command, result: .init(text: "new root")) }
        XCTAssertFalse(server.isRunning, "A retained descriptor cannot make a replaced root look ready")
        server.stop()
        let reply = try UnixSocketAutomationClient(socketPath: path).send(.init(command: .status))
        XCTAssertEqual(reply.result?.text, "new root")
    }

    func testUnsafeDirectoryAndSymlinkComponents_AreRejectedWithoutChmod() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try start())
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o755
        )
        let target = directory.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linked = LinuxAutomationServer(socketPath: link.appendingPathComponent("automation.sock").path)
        XCTAssertThrowsError(try linked.start { .success(id: $0.id, command: $0.command, result: .init()) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("automation.sock").path))
    }

    func testDisable_JoinsHalfOpenWorkersAndRestartsWithoutLeakedEndpoint() throws {
        try start()
        let connections = try (0..<LinuxAutomationServer.maximumConnections).map { _ in try connect() }
        defer { connections.forEach { jsti_automation_close($0) } }
        let clock = ContinuousClock()
        let started = clock.now
        server.stop()
        XCTAssertLessThan(clock.now - started, .seconds(1))
        XCTAssertFalse(server.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        try start()
        XCTAssertTrue(try UnixSocketAutomationClient(socketPath: path).send(.init(command: .status)).ok)
    }

    func testConnectionLimit_RejectsFifthHalfOpenClientWithoutFailingListener() throws {
        server = LinuxAutomationServer(socketPath: path, requestMilliseconds: 10_000)
        try start()
        let connections = try (0..<LinuxAutomationServer.maximumConnections).map { _ in try connect() }
        defer { connections.forEach { jsti_automation_close($0) } }
        let fifth = try connect()
        defer { jsti_automation_close(fifth) }
        let stream = LinuxAutomationStream(connection: fifth, deadline: jsti_automation_deadline(2_000))
        XCTAssertThrowsError(try stream.readExactly(1)) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .appUnavailable)
        }
        XCTAssertTrue(server.isRunning)
    }

    func testReadDeadline_ClosesIncompletePrefix() throws {
        try start()
        let connection = try connect()
        defer { jsti_automation_close(connection) }
        let stream = LinuxAutomationStream(connection: connection, deadline: jsti_automation_deadline(1_000))
        try stream.writeAll(Data([0]))
        XCTAssertThrowsError(try stream.readExactly(1)) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .appUnavailable)
        }
        XCTAssertThrowsError(try stream.writeAll(Data([0, 0, 5]))) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .appUnavailable)
        }
    }

    func testReadDeadline_IsAbsoluteDespiteTrickledPayload() throws {
        try start()
        let connection = try connect()
        defer { jsti_automation_close(connection) }
        let stream = LinuxAutomationStream(connection: connection, deadline: jsti_automation_deadline(2_000))
        try stream.writeAll(Data([0, 0, 16, 0]))
        let producer = AutomationTrickleProducer(stream: stream)
        let failure = producer.untilDisconnected()
        XCTAssertEqual(failure?.code, .appUnavailable)
        let disconnected = failure != nil
        XCTAssertTrue(disconnected, "Progress must not reset the request's absolute IO deadline")
    }

    func testClient_RejectsPermissiveSocketAndRegularFileAndLongPath() throws {
        try start()
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: path)
        XCTAssertThrowsError(try UnixSocketAutomationClient(socketPath: path).send(.init(command: .status)))
        server.stop()
        try Data().write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try UnixSocketAutomationClient(socketPath: path).send(.init(command: .status)))
        XCTAssertThrowsError(try UnixSocketAutomationClient(socketPath: "/" + String(repeating: "x", count: 108))
            .send(.init(command: .status)))
        XCTAssertThrowsError(
            try UnixSocketAutomationClient(socketPath: path + "\0suffix").send(.init(command: .status))
        )
    }

    func testStreamCheck_MapsEachNativeStatusToItsExpectedOutcome() {
        // Regression: the anonymous C enum constants import as `Int`; `check` must widen
        // its `Int32` status to pattern-match them rather than switching on `Int32` directly.
        XCTAssertNoThrow(try LinuxAutomationStream.check(Int32(JSTI_AUTOMATION_OK)))
        XCTAssertThrowsError(try LinuxAutomationStream.check(Int32(JSTI_AUTOMATION_TIMEOUT))) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .timedOut)
        }
        for status in [JSTI_AUTOMATION_CANCELLED, JSTI_AUTOMATION_UNAVAILABLE] {
            XCTAssertThrowsError(try LinuxAutomationStream.check(Int32(status))) { error in
                XCTAssertEqual((error as? AutomationError)?.code, .appUnavailable)
            }
        }
        XCTAssertThrowsError(try LinuxAutomationStream.check(Int32(JSTI_AUTOMATION_UNSAFE))) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .internalError)
        }
        XCTAssertThrowsError(try LinuxAutomationStream.check(Int32(JSTI_AUTOMATION_IO))) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .internalError)
        }
    }

    func testDisable_CancelsLongCommandAndJoinsReplyWorker() async throws {
        let entered = expectation(description: "long command entered")
        let cancelled = expectation(description: "long command cancelled")
        try server.start { request in
            entered.fulfill()
            do { try await Task.sleep(for: .seconds(3_600)) } catch { cancelled.fulfill() }
            return .failure(
                id: request.id, command: request.command,
                error: .init(code: .appUnavailable, message: "Synthetic command cancelled.")
            )
        }
        let socket = path
        async let reply = automationOffThread {
            try? UnixSocketAutomationClient(socketPath: socket).send(.init(command: .status, timeout: 3_600))
        }
        await fulfillment(of: [entered], timeout: 2)
        let service = server!
        let started = ContinuousClock.now
        await automationOffThread { service.stop() }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        await fulfillment(of: [cancelled], timeout: 2)
        let result = await reply
        XCTAssertNotEqual(result?.ok, true)
        XCTAssertFalse(service.isRunning)
    }
}

/// A periodic input producer, not a sleep/poll readiness gate. Cancellation and
/// queue retirement finish before the test releases its connection.
private final class AutomationTrickleProducer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "automation-test-trickle")
    private let completed = DispatchSemaphore(value: 0)
    private let stream: LinuxAutomationStream
    private var timer: (any DispatchSourceTimer)?
    private var failure: AutomationError?
    init(stream: LinuxAutomationStream) { self.stream = stream }

    func untilDisconnected() -> AutomationError? {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [self] in
            do { try stream.writeAll(Data([32])) } catch {
                failure = error as? AutomationError
                    ?? AutomationError(code: .internalError, message: "Synthetic producer failed.")
                self.timer?.cancel()
                completed.signal()
            }
        }
        timer.resume()
        _ = completed.wait(timeout: .now() + 1)
        timer.cancel()
        return queue.sync {
            timer.setEventHandler {}
            self.timer = nil
            return failure
        }
    }
}

private func automationOffThread<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: operation()) }.start()
    }
}
