#if !APP_STORE
import Darwin
import Foundation
import XCTest
@testable import SpeakApp

final class LocalProcessRunnerTests: XCTestCase {
    func testSuccessfulProcess_preservesUTF8InputAndEnvironment() async throws {
        let run = start(
            script: "printf '%s\\n' \"$SPEAK_PROCESS_TEST_VALUE\"; cat",
            input: Data("Café 🎤".utf8), environment: ["SPEAK_PROCESS_TEST_VALUE": "literal value"], timeout: 2
        )
        defer { run.task.cancel() }
        await fulfillment(of: [run.finished], timeout: 5)
        let result = try XCTUnwrap(run.result.value)
        XCTAssertEqual(try result.get(), "literal value\nCafé 🎤")
    }

    func testNonzeroExit_preservesActionableStderr() async throws {
        let run = start(script: "printf 'fatal: compiler unavailable' >&2; exit 7", timeout: 2)
        defer { run.task.cancel() }
        await fulfillment(of: [run.finished], timeout: 5)
        let result = try XCTUnwrap(run.result.value)
        guard case .failure(let error) = result else { return XCTFail("Expected process failure") }
        XCTAssertTrue(error.localizedDescription.contains("fatal: compiler unavailable"))
    }

    func testNoisyFailure_keepsDiagnosticTailAlongsideOutputLimit() async throws {
        let script = "dd if=/dev/zero bs=65536 count=32 2>/dev/null; printf 'fatal: model corrupt' >&2; exit 7"
        let run = start(script: script, timeout: 2)
        defer { run.task.cancel() }
        await fulfillment(of: [run.finished], timeout: 5)
        let result = try XCTUnwrap(run.result.value)
        guard case .failure(let error) = result else { return XCTFail("Expected process failure") }
        XCTAssertTrue(error.localizedDescription.contains("fatal: model corrupt"))
        XCTAssertTrue(error.localizedDescription.contains("exceeded the 1048576-byte limit"))
    }

    func testTimeout_killsOwnedDescendantsEvenWhenTheyIgnoreTermination() async throws {
        let marker = try markerURL()
        let run = start(script: Self.stubbornTree, arguments: [marker.path], timeout: 2)
        defer { run.task.cancel() }
        let identifiers = try await waitForIdentifiers(at: marker, count: 2)
        await fulfillment(of: [run.finished], timeout: 5)
        let result = try XCTUnwrap(run.result.value)
        guard case .failure(let error) = result else { return XCTFail("Expected timeout") }
        guard case LocalProcessError.timedOut = error else { return XCTFail("Unexpected error: \(error)") }
        for identifier in identifiers { await assertProcessGone(identifier) }
    }

    func testCancellation_stopsOwnedProcessGroupAfterReadiness() async throws {
        let marker = try markerURL()
        let run = start(script: Self.stubbornTree, arguments: [marker.path], timeout: 30)
        defer { run.task.cancel() }
        let identifiers = try await waitForIdentifiers(at: marker, count: 2)
        run.task.cancel()
        await fulfillment(of: [run.finished], timeout: 5)
        let result = try XCTUnwrap(run.result.value)
        guard case .failure(let error) = result else { return XCTFail("Expected cancellation") }
        XCTAssertTrue(error is CancellationError)
        for identifier in identifiers { await assertProcessGone(identifier) }
    }

    func testCancellation_doesNotStopAnotherOwnedInvocation() async throws {
        let firstMarker = try markerURL()
        let secondMarker = try markerURL()
        let first = start(script: Self.stubbornTree, arguments: [firstMarker.path], timeout: 30)
        let second = start(script: Self.stubbornTree, arguments: [secondMarker.path], timeout: 30)
        defer {
            first.task.cancel()
            second.task.cancel()
        }
        _ = try await waitForIdentifiers(at: firstMarker, count: 2)
        let secondIdentifiers = try await waitForIdentifiers(at: secondMarker, count: 2)

        first.task.cancel()
        await fulfillment(of: [first.finished], timeout: 5)

        for identifier in secondIdentifiers { XCTAssertEqual(kill(identifier, 0), 0) }
        second.task.cancel()
        await fulfillment(of: [second.finished], timeout: 5)
    }

    func testChildClosingStdin_doesNotRaiseSIGPIPEInApp() async throws {
        let run = start(
            script: "exec 0<&-; sleep 0.1; printf finished",
            input: Data(repeating: 0x61, count: 4 * 1024 * 1024), timeout: 2
        )
        defer { run.task.cancel() }
        await fulfillment(of: [run.finished], timeout: 5)
        let result = try XCTUnwrap(run.result.value)
        XCTAssertEqual(try result.get(), "finished")
    }

    func testExitedLeader_doesNotLeaveDescendantsHoldingOutputPipes() async throws {
        let marker = try markerURL()
        let script = "sleep 30 & printf '%s\\n' \"$!\" > \"$1\"; printf finished; exit 0"
        let run = start(script: script, arguments: [marker.path], timeout: 10)
        defer { run.task.cancel() }
        await fulfillment(of: [run.finished], timeout: 5)
        let result = try XCTUnwrap(run.result.value)
        XCTAssertEqual(try result.get(), "finished")
        let identifiers = try await waitForIdentifiers(at: marker, count: 1)
        for identifier in identifiers { await assertProcessGone(identifier) }
    }

    func testChildIgnoringLargeStdin_doesNotBlockTimeout() async throws {
        let run = start(
            script: "trap '' TERM; while :; do sleep 1; done",
            input: Data(repeating: 0x61, count: 4 * 1024 * 1024), timeout: 0.25
        )
        defer { run.task.cancel() }
        await fulfillment(of: [run.finished], timeout: 5)
        let result = try XCTUnwrap(run.result.value)
        guard case .failure(let error) = result else { return XCTFail("Expected timeout") }
        guard case LocalProcessError.timedOut = error else { return XCTFail("Unexpected error: \(error)") }
    }

    func testAlreadyCancelledTask_doesNotLaunchHelper() async throws {
        let marker = try markerURL()
        let run = start(
            script: "printf launched > \"$1\"", arguments: [marker.path], timeout: 2, cancelBeforeRunning: true
        )
        await fulfillment(of: [run.finished], timeout: 5)
        let result = try XCTUnwrap(run.result.value)
        guard case .failure(let error) = result else { return XCTFail("Expected cancellation") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testMissingExecutable_reportsSpawnFailureWithoutWaitingForTimeout() async throws {
        let missingExecutable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let run = start(script: "", timeout: 30, executableURL: missingExecutable)
        defer { run.task.cancel() }
        await fulfillment(of: [run.finished], timeout: 5)
        let result = try XCTUnwrap(run.result.value)
        guard case .failure(let error) = result else { return XCTFail("Expected launch failure") }
        guard case LocalProcessError.systemCall("spawn", ENOENT) = error else {
            return XCTFail("Unexpected error: \(error)")
        }
    }

    private static let stubbornTree = """
    trap '' TERM
    /bin/sh -c 'trap "" TERM; while :; do sleep 1; done' &
    printf '%s\\n' "$$" "$!" > "$1"
    wait
    """

    // Fixture controls keep readiness, cancellation and subprocess setup in one helper.
    // swiftlint:disable:next function_parameter_count
    private func start(
        script: String,
        arguments: [String] = [],
        input: Data? = nil,
        environment: [String: String] = [:],
        timeout: TimeInterval,
        cancelBeforeRunning: Bool = false,
        executableURL: URL = URL(fileURLWithPath: "/bin/sh")
    ) -> (task: Task<Void, Never>, result: ProcessTestResult, finished: XCTestExpectation) {
        let result = ProcessTestResult()
        let finished = expectation(description: "bounded subprocess finishes")
        let task = Task {
            if cancelBeforeRunning { withUnsafeCurrentTask { $0?.cancel() } }
            do {
                let output = try await LocalProcessRunner.run(
                    executableURL: executableURL, arguments: ["-c", script, "fixture"] + arguments,
                    standardInput: input, environment: environment, timeout: timeout
                )
                result.store(.success(output))
            } catch {
                result.store(.failure(error))
            }
            finished.fulfill()
        }
        return (task, result, finished)
    }

    private func markerURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("pids")
    }

    private func waitForIdentifiers(at url: URL, count: Int) async throws -> [pid_t] {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let identifiers = text.split(separator: "\n").compactMap { pid_t($0) }
                if identifiers.count == count, identifiers.allSatisfy({ $0 > 1 }) { return identifiers }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LocalProcessError.failed("Test helper did not publish readiness")
    }

    private func assertProcessGone(_ identifier: pid_t) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if kill(identifier, 0) == -1, errno == ESRCH { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Owned helper process \(identifier) survived teardown")
    }
}

private final class ProcessTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String, Error>?

    var value: Result<String, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func store(_ result: Result<String, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.result = result
    }
}
#endif
