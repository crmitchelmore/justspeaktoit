import Foundation
import XCTest
@testable import SpeakCore

final class AutomationClientSetupTests: XCTestCase {
    func testMCPConfiguration_IsValidJSONNamingSpeakMCPByFullPath() throws {
        let path = #"C:\Program Files\Just Speak to It\speak.exe"#
        let text = AutomationClientSetup.mcpConfiguration(command: path)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers[AutomationClientSetup.mcpServerName] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, path)
        XCTAssertEqual(server["args"] as? [String], ["mcp"])
        XCTAssertTrue(text.contains(#""C:\\Program Files\\Just Speak to It\\speak.exe""#))
    }

    func testMCPConfiguration_EscapesQuotesAndKeepsSlashesReadable() throws {
        let path = #"/home/a "b"/bin/speak"#
        let text = AutomationClientSetup.mcpConfiguration(command: path)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers[AutomationClientSetup.mcpServerName]?["command"] as? String, path)
        XCTAssertFalse(text.contains(#"\/"#))
    }

    func testClaudeCodeCommand_QuotesPathForEachShell() {
        XCTAssertEqual(
            AutomationClientSetup.claudeCodeCommand(command: #"C:\Users\O'Neil\speak.exe"#, shell: .powerShell),
            #"claude mcp add justspeaktoit -- 'C:\Users\O''Neil\speak.exe' mcp"#
        )
        XCTAssertEqual(
            AutomationClientSetup.claudeCodeCommand(command: "/opt/o'neil/speak", shell: .posix),
            #"claude mcp add justspeaktoit -- '/opt/o'\''neil/speak' mcp"#
        )
    }

    func testUsageExamples_CoverEveryCLIVerbWithACallablePath() {
        let powerShell = AutomationClientSetup.usageExamples(command: #"C:\$app\speak.exe"#, shell: .powerShell)
        let lines = powerShell.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix(#"& 'C:\$app\speak.exe' "#) })
        for verb in ["status", "listen", "stop", "history", "transcribe", "--help"] {
            XCTAssertTrue(lines.contains { $0.contains(" \(verb)") }, verb)
        }
        let posix = AutomationClientSetup.usageExamples(command: "/usr/bin/speak", shell: .posix)
        XCTAssertTrue(posix.split(separator: "\n").allSatisfy { $0.hasPrefix("'/usr/bin/speak' ") })
    }
}
