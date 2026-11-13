import SpeakCore
import XCTest
@testable import SpeakAutomationKit

/// `get_configuration`/`set_configuration` over MCP and `speak config` on the CLI.
final class AutomationConfigurationToolTests: XCTestCase {
    private func call(
        _ client: StubAutomationClient, _ name: String, _ arguments: [String: Any]
    ) throws -> [String: Any] {
        let handler = MCPRequestHandler(client: client, version: "9.9.9")
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ]
        let data = try JSONSerialization.data(withJSONObject: message)
        let line = try XCTUnwrap(handler.handle(line: String(decoding: data, as: UTF8.self)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return try XCTUnwrap(object["result"] as? [String: Any])
    }

    private func plan(_ arguments: [String]) throws -> CLIPlan {
        guard case .run(let plan) = try CommandLineParser.parse(arguments) else {
            throw XCTSkip("Expected a request")
        }
        return plan
    }

    private static func setResult(
        dryRun: Bool, changes: [String: AnyCodable.JSONValue]
    ) throws -> AutomationResult {
        try AutomationConfiguration.setResult(SettingsValidationReport(changes: changes), dryRun: dryRun)
    }

    // MARK: - MCP

    func testGetConfiguration_forwardsFiltersAndReturnsStructuredSettings() throws {
        let document = SettingsDocument(
            settings: ["ttsSpeed": .double(1.2), "showHUD": .bool(true)], apiKeys: ["openai": true]
        )
        let client = StubAutomationClient(
            result: AutomationConfiguration.getResult(document, keys: ["ttsSpeed"], prefix: nil)
        )
        let result = try self.call(client, "get_configuration", ["keys": ["ttsSpeed"], "prefix": "tts"])

        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(client.sentRequests.first?.command, .getConfiguration)
        XCTAssertEqual(client.sentRequests.first?.keys, ["ttsSpeed"])
        XCTAssertEqual(client.sentRequests.first?.prefix, "tts")
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let configuration = try XCTUnwrap(structured["configuration"] as? [String: Any])
        let settings = try XCTUnwrap(configuration["settings"] as? [String: Any])
        XCTAssertEqual(Set(settings.keys), ["ttsSpeed"])
        let schema = try XCTUnwrap(configuration["schema"] as? [String: Any])
        XCTAssertNotNil(schema["ttsSpeed"])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "ttsSpeed = 1.2\napiKeys.openai = set")
    }

    func testSetConfiguration_dryRunWithSeveralValues_sendsEveryChangeOnce() throws {
        let changes: [String: AnyCodable.JSONValue] = ["ttsSpeed": .double(1.5), "showHUD": .bool(false)]
        let client = try StubAutomationClient(result: Self.setResult(dryRun: true, changes: changes))
        let result = try self.call(
            client, "set_configuration", ["changes": ["ttsSpeed": 1.5, "showHUD": false], "dry_run": true]
        )

        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(client.sentRequests.count, 1)
        let request = try XCTUnwrap(client.sentRequests.first)
        XCTAssertEqual(request.command, .setConfiguration)
        XCTAssertEqual(request.dryRun, true)
        XCTAssertEqual(request.changes?.mapValues(\.storage), changes)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(
            content.first?["text"] as? String, "Valid. Would change:\n  showHUD = false\n  ttsSpeed = 1.5"
        )
    }

    func testSetConfiguration_appRejection_isAToolErrorNamingEachPath() throws {
        let client = StubAutomationClient(failure: AutomationError(
            code: .invalidArgument, message: "Configuration not changed. settings.ttsSpeed: must be at most 4"
        ))
        let result = try self.call(client, "set_configuration", ["changes": ["ttsSpeed": 9]])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String ?? "").contains("settings.ttsSpeed"))
    }

    func testSetConfiguration_withoutChanges_isRejectedBeforeTheApp() throws {
        let client = StubAutomationClient(result: AutomationResult())
        let empty = try self.call(client, "set_configuration", ["changes": [String: Any]()])
        let filtered = try self.call(client, "set_configuration", ["changes": ["a": 1], "prefix": "t"])
        XCTAssertEqual(empty["isError"] as? Bool, true)
        XCTAssertEqual(filtered["isError"] as? Bool, true)
        XCTAssertTrue(client.sentRequests.isEmpty)
    }

    // MARK: - CLI

    func testConfigGet_parsesKeysPrefixAndJSON() throws {
        let plan = try self.plan(["config", "get", "ttsSpeed", "showHUD", "--prefix", "tts", "--json"])
        XCTAssertEqual(plan.command, .getConfiguration)
        XCTAssertEqual(plan.keys, ["ttsSpeed", "showHUD"])
        XCTAssertEqual(plan.prefix, "tts")
        XCTAssertTrue(plan.json)
        XCTAssertNil(try self.plan(["config", "get"]).keys)
    }

    func testConfigSet_parsesJSONLiteralsAndBareText() throws {
        let plan = try self.plan([
            "config", "set", "ttsSpeed=1.5", "showHUD=false", "postProcessingModel=openai/gpt-4o-mini",
            "outputLanguage=\"true\"", "transcriptionKeywords=", "--dry-run"
        ])
        XCTAssertEqual(plan.command, .setConfiguration)
        XCTAssertEqual(plan.dryRun, true)
        XCTAssertEqual(plan.changes?.mapValues(\.storage), [
            "ttsSpeed": .double(1.5), "showHUD": .bool(false),
            "postProcessingModel": .string("openai/gpt-4o-mini"), "outputLanguage": .string("true"),
            "transcriptionKeywords": .string("")
        ])
    }

    func testConfigSet_rejectsMalformedAssignments() {
        for arguments in [["config", "set"], ["config", "set", "noEquals"], ["config", "set", "=1"],
                          ["config", "set", "a=1", "a=2"], ["config", "unset", "a"], ["config"]] {
            XCTAssertThrowsError(try CommandLineParser.parse(arguments), arguments.joined(separator: " "))
        }
    }

    func testConfigSet_runsAgainstTheAppAndPrintsTheSummary() throws {
        let result = try Self.setResult(dryRun: false, changes: ["ttsSpeed": .double(2)])
        let client = StubAutomationClient(result: result)
        let outcome = CLIRunner(client: client, version: "9.9.9").run(arguments: ["config", "set", "ttsSpeed=2"])
        guard case .finished(let output) = outcome else { return XCTFail("Expected output") }
        XCTAssertEqual(output.exitCode, CLIExitCode.success)
        XCTAssertEqual(output.stdout, "Changed:\n  ttsSpeed = 2\n")
        XCTAssertEqual(client.sentRequests.first?.dryRun, nil)
    }
}
