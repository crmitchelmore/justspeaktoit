import SpeakCore
import XCTest
@testable import SpeakAutomationKit

/// Behavioural coverage of the `speak` command line: what a user types in,
/// what the process prints out, and what exit code a script sees.
final class CLIBehaviourTests: XCTestCase {
    private func runner(_ client: AutomationRequesting) -> CLIRunner {
        CLIRunner(client: client, version: "9.9.9")
    }

    private func output(_ outcome: CLIOutcome) throws -> CLIOutput {
        guard case .finished(let output) = outcome else {
            throw XCTSkip("Expected a finished invocation")
        }
        return output
    }

    // MARK: - Parsing

    func testTranscribe_withOptions_buildsBoundedRequest() throws {
        let plan = try XCTUnwrap(self.plan(from: ["transcribe", "/tmp/a.m4a",
                                                 "--timeout", "42", "--json"]))
        XCTAssertEqual(plan.command, .transcribeFile)
        XCTAssertEqual(plan.path, "/tmp/a.m4a")
        XCTAssertEqual(plan.timeout, 42)
        XCTAssertTrue(plan.json)
    }

    func testListen_matchesIssueInvocation() throws {
        let plan = try XCTUnwrap(self.plan(from: ["listen"]))
        XCTAssertEqual(plan.command, .startDictation)
        XCTAssertFalse(plan.json)
    }

    func testHistory_lastAndJSON_matchesIssueInvocation() throws {
        let plan = try XCTUnwrap(self.plan(from: ["history", "--last", "5", "--json"]))
        XCTAssertEqual(plan.command, .history)
        XCTAssertEqual(plan.limit, 5)
        XCTAssertTrue(plan.json)
    }

    func testOptions_acceptEqualsForm() throws {
        let plan = try XCTUnwrap(self.plan(from: ["history", "--last=3"]))
        XCTAssertEqual(plan.limit, 3)
    }

    func testRelativePath_isResolvedAgainstCallerDirectory() {
        let resolved = CommandLineParser.absolutePath(for: "clip.m4a", currentDirectory: "/Users/example/audio")
        XCTAssertEqual(resolved, "/Users/example/audio/clip.m4a")
    }

    func testMCPVerb_selectsServerMode() throws {
        XCTAssertEqual(try CommandLineParser.parse(["mcp"]), .mcpServer)
    }

    func testNoArguments_showsHelp() throws {
        XCTAssertEqual(try CommandLineParser.parse([]), .help)
    }

    // MARK: - Usage errors

    func testUnknownCommand_exitsWithUsageCode() throws {
        let output = try self.output(self.runner(StubAutomationClient(result: AutomationResult())).run(
            arguments: ["dictate"]
        ))
        XCTAssertEqual(output.exitCode, CLIExitCode.usage)
        XCTAssertTrue(output.stderr.contains("Unknown command"))
        XCTAssertTrue(output.stderr.contains("USAGE"), "Usage errors must show how to recover")
        XCTAssertTrue(output.stdout.isEmpty)
    }

    func testTranscribeWithoutPath_exitsWithUsageCode() throws {
        let output = try self.output(self.runner(StubAutomationClient(result: AutomationResult())).run(
            arguments: ["transcribe"]
        ))
        XCTAssertEqual(output.exitCode, CLIExitCode.usage)
        XCTAssertTrue(output.stderr.contains("requires an audio file path"))
    }

    func testOption_rejectedForCommand_exitsWithUsageCode() throws {
        let output = try self.output(self.runner(StubAutomationClient(result: AutomationResult())).run(
            arguments: ["status", "--last", "5"]
        ))
        XCTAssertEqual(output.exitCode, CLIExitCode.usage)
        XCTAssertTrue(output.stderr.contains("--last is not valid"))
    }

    func testHistoryLimitOutOfRange_isRejectedBeforeAnyRequest() throws {
        let client = StubAutomationClient(result: AutomationResult())
        let output = try self.output(self.runner(client).run(arguments: ["history", "--last", "9999"]))
        XCTAssertEqual(output.exitCode, CLIExitCode.usage)
        XCTAssertTrue(client.sentRequests.isEmpty, "Bounds must be enforced without touching the socket")
    }

    // MARK: - Output

    func testTranscribe_humanOutput_isBareTranscript() throws {
        let client = StubAutomationClient(result: AutomationResult(text: "hello world", model: "nova-3"))
        let output = try self.output(self.runner(client).run(arguments: ["transcribe", "/tmp/a.m4a"]))
        XCTAssertEqual(output.stdout, "hello world\n", "Plain output must stay pipeable")
        XCTAssertEqual(output.exitCode, CLIExitCode.success)
    }

    func testTranscribe_jsonOutput_isStableVersionedEnvelope() throws {
        let client = StubAutomationClient(result: AutomationResult(text: "hi", model: "nova-3", durationSeconds: 1.5))
        let output = try self.output(self.runner(client).run(arguments: ["transcribe", "/tmp/a.m4a", "--json"]))

        let envelope = try JSONDecoder().decode(
            CLIJSONEnvelope.self,
            from: Data(output.stdout.utf8)
        )
        XCTAssertEqual(envelope.schemaVersion, AutomationSchema.currentVersion)
        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(envelope.command, "transcribe_file")
        XCTAssertEqual(envelope.data?.text, "hi")
        XCTAssertEqual(envelope.data?.model, "nova-3")
        XCTAssertNil(envelope.error)
    }

    func testHistory_jsonOutput_carriesEntries() throws {
        let entry = AutomationHistoryEntry(
            id: "A1",
            text: "two words",
            createdAt: Date(timeIntervalSince1970: 0),
            model: "nova-3",
            durationSeconds: 2,
            wordCount: 2
        )
        let client = StubAutomationClient(result: AutomationResult(entries: [entry]))
        let output = try self.output(self.runner(client).run(arguments: ["history", "--last", "1", "--json"]))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(CLIJSONEnvelope.self, from: Data(output.stdout.utf8))
        XCTAssertEqual(envelope.data?.entries?.count, 1)
        XCTAssertEqual(envelope.data?.entries?.first?.text, "two words")
        XCTAssertEqual(client.sentRequests.first?.limit, 1)
    }

    func testStatus_humanOutput_reportsDictationState() throws {
        let client = StubAutomationClient(result: AutomationResult(sessionActive: true, appVersion: "2.1.0"))
        let output = try self.output(self.runner(client).run(arguments: ["status"]))
        XCTAssertTrue(output.stdout.contains("2.1.0"))
        XCTAssertTrue(output.stdout.contains("dictating"))
    }

    func testVersion_reportsCLIVersion() throws {
        let output = try self.output(self.runner(StubAutomationClient(result: AutomationResult())).run(
            arguments: ["--version"]
        ))
        XCTAssertEqual(output.stdout, "speak 9.9.9\n")
    }

    // MARK: - App unavailable

    func testAppNotRunning_hasDedicatedExitCodeAndActionableMessage() throws {
        let client = StubAutomationClient(throwing: StubAutomationClient.unavailable)
        let output = try self.output(self.runner(client).run(arguments: ["status"]))
        XCTAssertEqual(output.exitCode, CLIExitCode.appUnavailable)
        XCTAssertTrue(output.stderr.contains("isn't running"))
        XCTAssertTrue(output.stderr.contains("/tmp/speak-test.sock"))
    }

    func testAppNotRunning_withJSON_stillEmitsParsableEnvelope() throws {
        let client = StubAutomationClient(throwing: StubAutomationClient.unavailable)
        let output = try self.output(self.runner(client).run(arguments: ["status", "--json"]))
        XCTAssertEqual(output.exitCode, CLIExitCode.appUnavailable)

        let envelope = try JSONDecoder().decode(CLIJSONEnvelope.self, from: Data(output.stdout.utf8))
        XCTAssertFalse(envelope.ok)
        XCTAssertEqual(envelope.error?.code, .appUnavailable)
        XCTAssertTrue(output.stderr.isEmpty, "--json consumers parse a single stream")
    }

    func testAppReportedFailure_exitsNonZero() throws {
        let client = StubAutomationClient(failure: AutomationError(
            code: .notRecording,
            message: "No dictation session is running."
        ))
        let output = try self.output(self.runner(client).run(arguments: ["stop"]))
        XCTAssertEqual(output.exitCode, CLIExitCode.failed)
        XCTAssertTrue(output.stderr.contains("No dictation session"))
    }

    // MARK: - Helpers

    private func plan(from arguments: [String]) -> CLIPlan? {
        guard case .run(let plan) = try? CommandLineParser.parse(arguments) else { return nil }
        return plan
    }
}
