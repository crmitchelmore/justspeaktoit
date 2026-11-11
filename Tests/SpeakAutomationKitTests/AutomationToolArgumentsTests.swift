import Foundation
import SpeakCore
import XCTest
@testable import SpeakAutomationKit

/// MCP `tools/call` and CLI flags share one argument type. These tables drive
/// both front ends with the same inputs and expect the same outcome.
final class AutomationToolArgumentsTests: XCTestCase {
    private func mcpArguments(_ tool: AutomationCommand, _ json: String) throws -> AutomationToolArguments {
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":""#
            + tool.rawValue + #"","arguments":"# + json + "}}"
        return try AutomationToolArguments.decode(toolCall: Data(line.utf8))
    }

    private func cliArguments(_ argv: [String]) throws -> (AutomationCommand, AutomationToolArguments) {
        guard case .run(let plan) = try CommandLineParser.parse(argv) else {
            throw CLIUsageError(message: "not a command")
        }
        return (plan.command, plan.arguments)
    }

    // MARK: - One surface

    func testEveryToolSchema_isExactlyTheCLIFlagsAndPositionalArgument() throws {
        for tool in MCPRequestHandler.toolDefinitions {
            let name = try XCTUnwrap(tool["name"] as? String)
            let command = try XCTUnwrap(AutomationCommand(rawValue: name))
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            let advertised = Set((schema["properties"] as? [String: Any] ?? [:]).keys)
            let options = try XCTUnwrap(CommandLineParser.options[command], name)
            var flagged = Set(options.compactMap(\.argument?.rawValue))
            if let positional = CommandLineParser.positionalArgument[command] { flagged.insert(positional.rawValue) }
            XCTAssertEqual(advertised, flagged, name)
            let decodable = Set(AutomationToolArguments.CodingKeys.allCases.map(\.rawValue))
            XCTAssertTrue(advertised.isSubset(of: decodable), name)
        }
    }

    func testSameInputs_buildTheSameArgumentsFromMCPAndCLI() throws {
        let rows: [Row] = [
            Row(.history, #"{"limit":3}"#, ["history", "--last", "3"]),
            Row(.transcribeFile, #"{"path":"/srv/a.m4a","timeout_seconds":12.5}"#,
                ["transcribe", "/srv/a.m4a", "--timeout", "12.5"]),
            Row(.awaitTranscript,
                #"{"capture_id":"7A1D2D4F-2B7A-4A6B-9C1E-2C9A0C8F6E11","timeout_seconds":30}"#,
                ["await", "--capture-id", "7A1D2D4F-2B7A-4A6B-9C1E-2C9A0C8F6E11", "--timeout", "30"]),
            Row(.listVoices, #"{"provider":"openai"}"#, ["voices", "--provider", "openai"]),
            Row(.speakText,
                #"{"text":"hi there","voice":"alloy","model":"tts-1","speed":1.5,"pitch":-2,"#
                    + #""quality":"high","language":"en-GB","path":"/srv/out.wav","play":true}"#,
                ["say", "hi", "there", "--voice", "alloy", "--model", "tts-1", "--speed", "1.5", "--pitch", "-2",
                 "--quality", "high", "--language", "en-GB", "-o", "/srv/out.wav", "--play"])
        ]
        for row in rows {
            let (tool, json, argv) = (row.tool, row.json, row.argv ?? [])
            let fromMCP = try self.mcpArguments(tool, json)
            var (command, fromCLI) = try self.cliArguments(argv)
            XCTAssertEqual(command, tool)
            // `say` reads its text after parsing; MCP carries it inline.
            if tool == .speakText { fromCLI.text = "hi there" }
            XCTAssertEqual(fromMCP, fromCLI, tool.rawValue)
            XCTAssertEqual(
                fromMCP.request(id: "same", command: tool), fromCLI.request(id: "same", command: tool), tool.rawValue
            )
        }
    }

    // MARK: - Malformed input

    func testWronglyTypedArguments_areRejectedByBothFrontEnds() throws {
        let rows: [Row] = [
            Row(.history, #"{"limit":2.5}"#, #""limit" must be an integer."#, ["history", "--last", "2.5"]),
            Row(.history, #"{"limit":"3"}"#, #""limit" must be an integer."#, nil),
            Row(.transcribeFile, #"{"timeout_seconds":0}"#, #""timeout_seconds" must be a positive number."#,
                ["transcribe", "/srv/a.m4a", "--timeout", "0"]),
            Row(.transcribeFile, #"{"timeout_seconds":"5"}"#, #""timeout_seconds" must be a positive number."#,
                ["transcribe", "/srv/a.m4a", "--timeout", "five"]),
            Row(.speakText, #"{"speed":"fast"}"#, #""speed" must be a number."#, ["say", "hi", "--speed", "fast"]),
            Row(.speakText, #"{"pitch":true}"#, #""pitch" must be a number."#, ["say", "hi", "--pitch", "up"]),
            Row(.speakText, #"{"play":"yes"}"#, #""play" must be a boolean."#, ["say", "hi", "--play=yes"]),
            Row(.speakText, #"{"voice":7}"#, #""voice" must be a string."#, ["say", "hi", "--voice", ""]),
            Row(.transcribeFile, #"{"path":null}"#, #""path" must be a string."#, nil),
            Row(.awaitTranscript, #"{"capture_id":42}"#, "Capture and cursor must be UUID strings.", nil),
            Row(.awaitTranscript, #"{"since_id":false}"#, "Capture and cursor must be UUID strings.", nil)
        ]
        for row in rows {
            let (tool, json, message, argv) = (row.tool, row.json, row.message, row.argv)
            XCTAssertThrowsError(try self.mcpArguments(tool, json), json) { error in
                XCTAssertEqual(error as? AutomationError, AutomationError(code: .invalidArgument, message: message))
            }
            guard let argv else { continue }
            XCTAssertThrowsError(try CommandLineParser.parse(argv), argv.joined(separator: " ")) { error in
                XCTAssertTrue(error is CLIUsageError, "\(error)")
            }
        }
    }

    func testTheFirstWronglyTypedArgument_namesItself() {
        XCTAssertThrowsError(try self.mcpArguments(.speakText, #"{"play":1,"text":2}"#)) { error in
            XCTAssertEqual((error as? AutomationError)?.message, #""text" must be a string."#)
        }
    }

    func testMissingOrNonObjectArguments_meanNone() throws {
        XCTAssertEqual(try self.mcpArguments(.status, "[1]"), AutomationToolArguments())
        XCTAssertEqual(try self.mcpArguments(.status, "null"), AutomationToolArguments())
        let bare = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"status"}}"#.utf8)
        XCTAssertEqual(try AutomationToolArguments.decode(toolCall: bare), AutomationToolArguments())
        XCTAssertEqual(try self.mcpArguments(.status, #"{"future":true}"#), AutomationToolArguments())
    }

    func testIntegralNumbers_satisfyNumberArgumentsOnEveryPlatform() throws {
        let arguments = try self.mcpArguments(.speakText, #"{"speed":2,"timeout_seconds":5}"#)
        XCTAssertEqual(arguments.speed, 2)
        XCTAssertEqual(arguments.timeoutSeconds, 5)
    }

    func testArguments_encodeUnderTheirMCPNames() throws {
        var arguments = AutomationToolArguments()
        arguments.timeoutSeconds = 5
        arguments.captureID = "C"
        let json = try JSONEncoder().encode(arguments)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["timeout_seconds", "capture_id"])
        XCTAssertEqual(try JSONDecoder().decode(AutomationToolArguments.self, from: json), arguments)
    }

    /// One MCP argument object and the CLI words that should match it.
    private struct Row {
        let tool: AutomationCommand
        let json: String
        let message: String
        let argv: [String]?

        init(_ tool: AutomationCommand, _ json: String, _ argv: [String]) {
            self.init(tool, json, "", argv)
        }

        init(_ tool: AutomationCommand, _ json: String, _ message: String, _ argv: [String]?) {
            (self.tool, self.json, self.message, self.argv) = (tool, json, message, argv)
        }
    }
}
